-- =====================================================================
-- A number and a wait
--
-- A busy shop on a Saturday has more parties than tables, and the way
-- that is handled today is a scrap of paper by the door. The paper
-- cannot tell the next customer how long they are likely to stand
-- there, cannot be read from the floor by the waiter who just cleared
-- table 6, and does not exist at all by Monday, so nobody ever learns
-- whether Saturday's wait is twenty minutes or fifty.
--
-- ---------------------------------------------------------------------
-- A ticket number, not an id
--
-- The number is shouted across a room. It has to be small, it has to
-- start again every morning, and two people arriving at once must not
-- get the same one. So it is per outlet per trading day, derived by
-- taking the highest issued today and adding one, under a transaction
-- advisory lock keyed on the outlet and the date.
--
-- Derived rather than kept in a counter row for the reason every other
-- count in this module is derived: a counter has to be reset by
-- something, and the something is always missing on the morning it
-- matters. `queue_date` is stored beside it so the unique index can
-- exist at all — an index cannot be built on `at time zone`, which is
-- stable but not immutable.
--
-- ---------------------------------------------------------------------
-- The quoted wait is measured, or it is not given
--
-- "About twenty minutes" is the single most useful thing a queue can
-- say and the easiest thing to invent. This one is the median of what
-- parties of a similar size actually waited at this outlet today —
-- joined to seated, in minutes — and it is null when fewer than three
-- parties have been seated. A shop that has just opened is told nothing
-- rather than told a guess, because a guess that is wrong twice teaches
-- the staff to stop reading it.
--
-- The median rather than the mean: one party that waited two hours
-- because they went to the car park should not move everybody else's
-- quote.
--
-- ---------------------------------------------------------------------
-- Five states, and no way back out of the last three
--
-- waiting -> called -> seated is the happy path. `left` is a party that
-- walked before they were called; `no_show` is one that was called and
-- did not come. They are separate because they are different problems:
-- the first is the wait being too long, the second is somebody standing
-- outside on the phone, and a shop reading "twelve gave up" cannot tell
-- which it had.
-- =====================================================================

do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_queue_status') then
    create type app.pos_queue_status as enum (
      'waiting',  -- standing there
      'called',   -- their number has been shouted
      'seated',   -- at a table
      'left',     -- walked before being called
      'no_show'   -- called, and did not come
    );
  end if;
end;
$$;

create table if not exists public.pos_queue_entries (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,

  -- The number on the slip. Small, and starts again every morning.
  ticket_no  integer not null check (ticket_no > 0),
  -- The trading day it belongs to, in the shop's own time. Stored
  -- rather than derived because a unique index needs an immutable
  -- expression and `at time zone` is only stable.
  queue_date date not null,

  -- Both optional. A queue works with a number and a party size; a
  -- name makes it easier to call and a phone makes it possible to
  -- text, and neither is a reason to refuse somebody a place in line.
  name       text,
  phone      text,
  party_size integer not null default 2 check (party_size > 0),

  status     app.pos_queue_status not null default 'waiting',

  -- What they were told when they joined, kept as it was said. The
  -- estimate moves all day; what matters afterwards is the number the
  -- customer was actually given.
  quoted_minutes integer,

  -- Where they ended up. Null until they are seated, and null after
  -- that for a shop that does not run a floor plan.
  table_id   uuid references public.pos_tables (id) on delete set null,

  note       text,

  joined_at  timestamptz not null default now(),
  called_at  timestamptz,
  seated_at  timestamptz,
  closed_at  timestamptz,

  created_by uuid references auth.users (id) on delete set null,

  unique (outlet_id, queue_date, ticket_no),

  -- Each stamp belongs to its state, so a row cannot claim to be
  -- seated with nothing saying when.
  constraint pos_queue_seated_ck check (
    (status = 'seated') = (seated_at is not null)),
  constraint pos_queue_closed_ck check (
    (status in ('left', 'no_show')) = (closed_at is not null))
);

create index if not exists pos_queue_entries_open_idx
  on public.pos_queue_entries (outlet_id, queue_date, ticket_no)
  where status in ('waiting', 'called');
create index if not exists pos_queue_entries_org_idx
  on public.pos_queue_entries (org_id, queue_date desc);

comment on table public.pos_queue_entries is
  'The line at the door. One row per party per visit, numbered per outlet per trading day so the number can be shouted across a room.';
comment on column public.pos_queue_entries.quoted_minutes is
  'What this party was told when they joined, kept as it was said. The estimate moves all day; what matters afterwards is the number the customer was given.';
comment on column public.pos_queue_entries.queue_date is
  'The trading day in Asia/Kuala_Lumpur. Stored rather than derived because a unique index needs an immutable expression.';

-- ---------------------------------------------------------------------
-- How long a party of this size has actually been waiting today
-- ---------------------------------------------------------------------
--
-- Null rather than a guess. See the header: three seated parties is the
-- floor, because two data points and a median is arithmetic dressed up
-- as knowledge.
--
-- The size band is "within two of yours", which is the difference
-- between a couple and a party of eight without pretending the shop
-- knows more than it does. If that band is too thin to answer, the
-- whole day is used instead — a wide answer beats no answer, and no
-- answer beats a made-up one.
create or replace function app.pos_queue_quote(
  p_outlet uuid,
  p_party  integer default 2)
returns integer
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_out  numeric;
  v_n    integer;
begin
  select count(*)::integer,
         percentile_cont(0.5) within group (
           order by extract(epoch from (q.seated_at - q.joined_at)) / 60.0)
    into v_n, v_out
    from public.pos_queue_entries q
   where q.outlet_id = p_outlet
     and q.queue_date = v_date
     and q.status = 'seated'
     and q.seated_at is not null
     and abs(q.party_size - coalesce(p_party, 2)) <= 2;

  if v_n < 3 then
    select count(*)::integer,
           percentile_cont(0.5) within group (
             order by extract(epoch from (q.seated_at - q.joined_at)) / 60.0)
      into v_n, v_out
      from public.pos_queue_entries q
     where q.outlet_id = p_outlet
       and q.queue_date = v_date
       and q.status = 'seated'
       and q.seated_at is not null;
  end if;

  if v_n < 3 or v_out is null then
    return null;
  end if;

  -- Rounded up to the next five minutes. Nobody says "eleven minutes",
  -- and a quote that reads precise is a quote somebody will hold the
  -- shop to.
  return greatest(ceil(v_out / 5.0)::integer * 5, 5);
end;
$$;

revoke all on function app.pos_queue_quote(uuid, integer) from public, anon;
grant execute on function app.pos_queue_quote(uuid, integer) to authenticated;

comment on function app.pos_queue_quote(uuid, integer) is
  'The median wait, in minutes, actually served to parties of about this size at this outlet today. Null under three seated parties: a shop that has just opened is told nothing rather than told a guess.';

-- ---------------------------------------------------------------------
-- Joining the line
-- ---------------------------------------------------------------------
create or replace function public.join_pos_queue(
  p_outlet uuid,
  p_party  integer default 2,
  p_name   text default null,
  p_phone  text default null,
  p_note   text default null)
returns table (
  entry_id       uuid,
  ticket_no      integer,
  quoted_minutes integer,
  ahead          integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   uuid;
  v_date  date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_no    integer;
  v_quote integer;
  v_id    uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;
  if coalesce(p_party, 0) <= 0 then
    raise exception 'How many people are waiting?' using errcode = '23514';
  end if;

  -- Two people at the door at once must not get the same number. Held
  -- for the transaction only, and keyed on the outlet and the day, so
  -- one busy shop never blocks another.
  perform pg_advisory_xact_lock(hashtext(p_outlet::text || v_date::text));

  select coalesce(max(q.ticket_no), 0) + 1 into v_no
    from public.pos_queue_entries q
   where q.outlet_id = p_outlet and q.queue_date = v_date;

  v_quote := app.pos_queue_quote(p_outlet, p_party);

  insert into public.pos_queue_entries
    (org_id, outlet_id, ticket_no, queue_date, name, phone, party_size,
     quoted_minutes, note, created_by)
  values
    (v_org, p_outlet, v_no, v_date,
     nullif(btrim(coalesce(p_name, '')), ''),
     nullif(btrim(coalesce(p_phone, '')), ''),
     p_party, v_quote, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  entry_id := v_id;
  ticket_no := v_no;
  quoted_minutes := v_quote;
  select count(*)::integer into ahead
    from public.pos_queue_entries q
   where q.outlet_id = p_outlet and q.queue_date = v_date
     and q.status in ('waiting', 'called')
     and q.id <> v_id;
  return next;
end;
$$;

revoke all on function public.join_pos_queue(uuid, integer, text, text, text)
  from public, anon;
grant execute on function public.join_pos_queue(uuid, integer, text, text, text)
  to authenticated;

comment on function public.join_pos_queue(uuid, integer, text, text, text) is
  'Puts a party in the line and hands back their number, what they were told to expect, and how many are in front of them. The number is allocated under an advisory lock so two people at the door at once cannot get the same one.';

-- ---------------------------------------------------------------------
-- Moving them along
-- ---------------------------------------------------------------------
--
-- One function for every move rather than four, because the rule worth
-- enforcing is the same in all of them: a party that has already been
-- seated, or has already gone, is finished. Splitting it into four
-- would mean writing that rule four times and getting it right three.
create or replace function public.set_pos_queue_status(
  p_entry  uuid,
  p_status app.pos_queue_status,
  p_table  uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_q   public.pos_queue_entries;
  v_out uuid;
begin
  select * into v_q from public.pos_queue_entries where id = p_entry;
  if v_q.id is null then
    raise exception 'No such queue entry.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_q.org_id, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;
  if v_q.status in ('seated', 'left', 'no_show') then
    raise exception
      'That party is already %. Put them back in the line if they have '
      'come back.', v_q.status
      using errcode = '23514';
  end if;
  if p_status = 'waiting' then
    raise exception 'They are already in the line.' using errcode = '23514';
  end if;

  -- A table that belongs to another shop would put a party on a floor
  -- plan they are not standing in.
  if p_table is not null then
    select t.outlet_id into v_out from public.pos_tables t where t.id = p_table;
    if v_out is distinct from v_q.outlet_id then
      raise exception 'That table is in another shop.' using errcode = '23514';
    end if;
  end if;

  update public.pos_queue_entries q
     set status    = p_status,
         table_id  = coalesce(p_table, q.table_id),
         called_at = case when p_status = 'called' then now()
                          else q.called_at end,
         seated_at = case when p_status = 'seated' then now() end,
         closed_at = case when p_status in ('left', 'no_show') then now() end
   where q.id = p_entry;

  return p_entry;
end;
$$;

revoke all on function public.set_pos_queue_status(
  uuid, app.pos_queue_status, uuid) from public, anon;
grant execute on function public.set_pos_queue_status(
  uuid, app.pos_queue_status, uuid) to authenticated;

comment on function public.set_pos_queue_status(uuid, app.pos_queue_status, uuid) is
  'Calls, seats or closes a party. One function for every move, because the rule that matters — a finished party stays finished — has to hold for all of them.';

-- ---------------------------------------------------------------------
-- The line, as the door and the floor read it
-- ---------------------------------------------------------------------
--
-- Everyone still standing there, in the order they arrived, with the
-- two numbers a host is asked for: how long this party has been waiting
-- and how many are in front of them.
--
-- Minutes waited is computed here rather than on the device. A phone
-- with a wrong clock would otherwise show a different queue from the
-- tablet beside it, and the argument that follows is with a customer.
create or replace function public.pos_queue(p_outlet uuid)
returns table (
  id             uuid,
  ticket_no      integer,
  name           text,
  phone          text,
  party_size     integer,
  status         app.pos_queue_status,
  quoted_minutes integer,
  waited_minutes integer,
  ahead          integer,
  table_id       uuid,
  table_code     text,
  note           text,
  joined_at      timestamptz,
  called_at      timestamptz)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select q.id, q.ticket_no, q.name, q.phone, q.party_size, q.status,
         q.quoted_minutes,
         floor(extract(epoch from (now() - q.joined_at)) / 60.0)::integer,
         -- How many arrived before them and are still standing there.
         -- A called party still counts: they are in front of you until
         -- they sit down or give up.
         (select count(*)::integer
            from public.pos_queue_entries e
           where e.outlet_id = q.outlet_id
             and e.queue_date = q.queue_date
             and e.status in ('waiting', 'called')
             and e.ticket_no < q.ticket_no),
         q.table_id, t.code, q.note, q.joined_at, q.called_at
    from public.pos_queue_entries q
    left join public.pos_tables t on t.id = q.table_id
   where q.outlet_id = p_outlet
     and q.queue_date = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and q.status in ('waiting', 'called')
     and app.can_read_module(q.org_id, 'pos')
   order by q.ticket_no;
$$;

grant execute on function public.pos_queue(uuid) to authenticated;

comment on function public.pos_queue(uuid) is
  'Everyone still in the line at this outlet today, in arrival order, with minutes waited computed on the server so two devices with different clocks cannot show two different queues.';

-- ---------------------------------------------------------------------
-- What the day looked like
-- ---------------------------------------------------------------------
--
-- The reason the paper by the door was worth replacing: a shop that
-- cannot say how long Saturday's wait was cannot decide whether to open
-- another section. `gave_up` and `no_show` are kept apart — one is the
-- wait being too long and the other is somebody outside on the phone.
create or replace function public.pos_queue_day(
  p_org  uuid,
  p_date date)
returns table (
  outlet_id     uuid,
  outlet_name   text,
  joined        integer,
  seated        integer,
  gave_up       integer,
  no_shows      integer,
  still_waiting integer,
  median_wait   integer,
  longest_wait  integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select o.id, o.name,
         count(q.id)::integer,
         count(*) filter (where q.status = 'seated')::integer,
         count(*) filter (where q.status = 'left')::integer,
         count(*) filter (where q.status = 'no_show')::integer,
         count(*) filter (where q.status in ('waiting', 'called'))::integer,
         ceil(percentile_cont(0.5) within group (
           order by case when q.status = 'seated'
                    then extract(epoch from (q.seated_at - q.joined_at)) / 60.0
                    end))::integer,
         ceil(max(case when q.status = 'seated'
                  then extract(epoch from (q.seated_at - q.joined_at)) / 60.0
                  end))::integer
    from public.pos_outlets o
    -- Left, so a shop that ran no queue is a row of noughts rather than
    -- missing. Its absence would read as "no problem".
    left join public.pos_queue_entries q
           on q.outlet_id = o.id and q.queue_date = p_date
   where o.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   group by o.id, o.name
   order by o.name;
$$;

grant execute on function public.pos_queue_day(uuid, date) to authenticated;

comment on function public.pos_queue_day(uuid, date) is
  'What the line did on one day, per outlet. Walked-away and no-show are separate columns: one is the wait being too long and the other is somebody standing outside on the phone.';

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_queue_entries enable row level security;

create policy pos_queue_entries_read on public.pos_queue_entries for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policy. The ticket number is allocated under a lock and the
-- state machine is the point of the feature; a client that could insert
-- its own row could hand itself number one.
grant select on public.pos_queue_entries to authenticated;

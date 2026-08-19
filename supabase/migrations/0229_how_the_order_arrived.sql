-- ---------------------------------------------------------------------
-- 0229  How the order arrived
-- ---------------------------------------------------------------------
--
-- `pos_outlets.business_type` says what shape of shop this is — a
-- counter, a dining room, a van, a salon, a machine by the door. It has
-- never said how an order reached it, and those are different
-- questions: one warung takes a bill at a table, a bag over the
-- counter, a phone call and a delivery app, and every one of those is
-- the same shop.
--
-- Nothing in the module could tell them apart, so nothing could answer
-- the questions a shopkeeper actually asks — how much of Friday was
-- delivery, is the dining room worth the seats, did the app pay for
-- itself.
--
-- ## Three levels, resolved at the sale
--
-- The channel on a sale is filled in the order a shop actually sets it
-- up: whatever the register is for, else whatever the outlet's default
-- is, else `walk_in`. A kiosk is takeaway and a waiter's tablet is
-- dine-in, so on most devices nobody ever touches it — which is the
-- point. A control the cashier has to set on every sale is a control
-- that gets set wrong.
--
-- It is a trigger rather than an argument to `open_pos_sale`, and that
-- is a deliberate trade. Adding a parameter would mean restating a
-- function that 0209 wrote and 0212 already restated once, for a
-- default that is pure derivation — and a 250-line diff to add one
-- resolved column is a diff nobody checks.
--
-- ## An outlet accepts what it says it accepts
--
-- `pos_outlet_channels` is the list, not a free-for-all: a market stall
-- that does not deliver should not be able to record a delivery, and a
-- report split by a channel nobody sells is a report with a row that
-- can only be a mistake. Changing the channel on a bill goes through
-- `set_pos_sale_channel`, which checks the list and refuses once the
-- sale has completed — the channel is on the invoice by then, and an
-- issued document does not change because somebody re-categorised it.

-- ---------------------------------------------------------------------
-- The channels a shop can have
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_order_channel') then
    create type app.pos_order_channel as enum (
      'walk_in',     -- somebody at the counter, taking it with them
      'dine_in',     -- sitting down; the bill lives on a table
      'takeaway',    -- ordered at the counter, packed to go
      'delivery',    -- taken to them
      'reservation', -- booked ahead; a slot or a table held
      'phone',       -- rang up and asked
      'online',      -- a web order
      'mobile_app'   -- an order placed in an app
    );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- What this outlet accepts
-- ---------------------------------------------------------------------
create table if not exists public.pos_outlet_channels (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,
  channel    app.pos_order_channel not null,

  -- What a sale gets when the register does not say. An outlet with one
  -- channel sets this and nobody ever thinks about it again.
  is_default boolean not null default false,
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (outlet_id, channel)
);

-- One default per outlet, for the same reason a kitchen has one default
-- station: "what happens when nobody says" is a question with one
-- answer or no answer at all.
create unique index if not exists pos_outlet_channels_one_default
  on public.pos_outlet_channels (outlet_id) where is_default;

create index if not exists pos_outlet_channels_outlet_idx
  on public.pos_outlet_channels (outlet_id) where is_active;

-- ---------------------------------------------------------------------
-- What this till is for
-- ---------------------------------------------------------------------
alter table public.pos_registers
  add column if not exists default_channel app.pos_order_channel;

comment on column public.pos_registers.default_channel is
  'What orders on this till usually are. A kiosk is takeaway, a waiter''s tablet is dine-in — so nobody has to say so on every sale. Null falls back to the outlet default.';

-- ---------------------------------------------------------------------
-- And on the sale itself
-- ---------------------------------------------------------------------
alter table public.pos_sales
  add column if not exists order_channel app.pos_order_channel;

create index if not exists pos_sales_channel_idx
  on public.pos_sales (org_id, order_channel, opened_at desc);

comment on column public.pos_sales.order_channel is
  'How this order arrived. Filled by app.pos_sale_channel_default on insert: the register''s, else the outlet''s, else walk_in.';

-- ---------------------------------------------------------------------
-- Filling it in
-- ---------------------------------------------------------------------
create or replace function app.pos_sale_channel_default()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if new.order_channel is not null then
    return new;
  end if;

  select coalesce(
    (select r.default_channel from public.pos_registers r
      where r.id = new.register_id),
    (select c.channel from public.pos_outlet_channels c
      where c.outlet_id = new.outlet_id and c.is_default and c.is_active),
    'walk_in'::app.pos_order_channel)
  into new.order_channel;

  return new;
end;
$$;

drop trigger if exists pos_sales_channel_default on public.pos_sales;
create trigger pos_sales_channel_default
  before insert on public.pos_sales
  for each row execute function app.pos_sale_channel_default();

-- Everything that already exists. A null here would make every report
-- carry an "unknown" bucket for sales taken before the column existed,
-- which is a permanent footnote on a question nobody can now answer.
update public.pos_sales s
   set order_channel = coalesce(
     (select r.default_channel from public.pos_registers r where r.id = s.register_id),
     case when s.is_kiosk then 'takeaway'::app.pos_order_channel
          when s.table_id is not null then 'dine_in'::app.pos_order_channel
          else 'walk_in'::app.pos_order_channel end)
 where s.order_channel is null;

-- ---------------------------------------------------------------------
-- Saying it was something else
-- ---------------------------------------------------------------------
create or replace function public.set_pos_sale_channel(
  p_sale    uuid,
  p_channel app.pos_order_channel)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  -- Only while it is a basket. Once the sale completes the channel is
  -- on an issued invoice and part of what was reported; an issued
  -- document does not change because somebody re-categorised it.
  if v_sale.status <> 'parked' then
    raise exception
      'That sale is already %. How it arrived is part of what was '
      'reported for the day.', v_sale.status
      using errcode = '23514';
  end if;

  -- A stall that does not deliver should not be able to record a
  -- delivery. A report split by a channel nobody sells has a row that
  -- can only be a mistake.
  if not exists (select 1 from public.pos_outlet_channels c
                  where c.outlet_id = v_sale.outlet_id
                    and c.channel = p_channel and c.is_active) then
    raise exception
      'This outlet does not take % orders. Turn it on in the outlet''s '
      'settings first.', p_channel
      using errcode = '23514';
  end if;

  update public.pos_sales s
     set order_channel = p_channel, updated_at = now()
   where s.id = p_sale;
  return p_sale;
end;
$$;

revoke all on function public.set_pos_sale_channel(uuid, app.pos_order_channel)
  from public, anon;
grant execute on function public.set_pos_sale_channel(uuid, app.pos_order_channel)
  to authenticated;

-- ---------------------------------------------------------------------
-- Turning one on, and picking the default
-- ---------------------------------------------------------------------
create or replace function public.set_outlet_channel(
  p_outlet     uuid,
  p_channel    app.pos_order_channel,
  p_is_active  boolean default true,
  p_is_default boolean default false,
  p_sort_order integer default 0)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- A default nobody can order through is not a default. Refused rather
  -- than silently corrected, because the caller asked for two things
  -- that contradict each other.
  if p_is_default and not coalesce(p_is_active, true) then
    raise exception
      'A channel cannot be the default and be switched off.'
      using errcode = '23514';
  end if;

  -- Cleared in the same transaction, like the kitchen's default
  -- station: the unique partial index rejects a second, and two client
  -- calls leave a moment with no default at all.
  if p_is_default then
    update public.pos_outlet_channels c
       set is_default = false
     where c.outlet_id = p_outlet and c.is_default and c.channel <> p_channel;
  end if;

  insert into public.pos_outlet_channels
    (org_id, outlet_id, channel, is_default, sort_order, is_active)
  values (v_org, p_outlet, p_channel, coalesce(p_is_default, false),
          coalesce(p_sort_order, 0), coalesce(p_is_active, true))
  on conflict (outlet_id, channel) do update
    set sort_order = excluded.sort_order,
        is_active  = excluded.is_active,
        -- The default moves; it does not disappear. Naming a channel
        -- the default cleared the others above; switching one off
        -- clears its own flag, because a default nobody can order
        -- through is not a default. Anything else leaves it alone --
        -- passing `p_is_default => false` while reordering a list must
        -- not quietly unset the shop's default.
        is_default = case
          when excluded.is_default then true
          when not excluded.is_active then false
          else pos_outlet_channels.is_default
        end
  returning id into v_id;

  -- Switching off the last thing a shop sells through would leave it
  -- unable to record how anything arrived.
  if not exists (select 1 from public.pos_outlet_channels c
                  where c.outlet_id = p_outlet and c.is_active) then
    raise exception
      'An outlet has to accept at least one kind of order.'
      using errcode = '23514';
  end if;

  return v_id;
end;
$$;

revoke all on function
  public.set_outlet_channel(uuid, app.pos_order_channel, boolean, boolean, integer)
  from public, anon;
grant execute on function
  public.set_outlet_channel(uuid, app.pos_order_channel, boolean, boolean, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a shop of this shape sells through, to start with
-- ---------------------------------------------------------------------
--
-- Seeded rather than left empty, because an outlet with no channels can
-- record nothing and every existing shop would arrive at this migration
-- with none. The list per business type is the ordinary case, not a
-- rule: `set_outlet_channel` changes any of it.
insert into public.pos_outlet_channels
  (org_id, outlet_id, channel, is_default, sort_order)
select o.org_id, o.id,
       -- Explicit: the VALUES list types these as text, and Postgres
       -- will not cast text to an enum on its own.
       v.channel::app.pos_order_channel, v.is_default, v.sort_order
  from public.pos_outlets o
  join (values
      ('retail',        'walk_in',     true,  1),
      ('retail',        'phone',       false, 2),
      ('retail',        'online',      false, 3),
      ('food_beverage', 'dine_in',     true,  1),
      ('food_beverage', 'takeaway',    false, 2),
      ('food_beverage', 'delivery',    false, 3),
      ('food_beverage', 'reservation', false, 4),
      ('food_beverage', 'phone',       false, 5),
      ('mobile',        'walk_in',     true,  1),
      ('service',       'reservation', true,  1),
      ('service',       'walk_in',     false, 2),
      ('service',       'phone',       false, 3),
      ('kiosk',         'takeaway',    true,  1)
    ) as v(business_type, channel, is_default, sort_order)
    on v.business_type = o.business_type::text
 on conflict (outlet_id, channel) do nothing;

-- A kiosk register is a takeaway machine wherever it stands, which is
-- the one register default worth setting for everybody.
update public.pos_registers r
   set default_channel = 'takeaway'
 where r.is_kiosk and r.default_channel is null;

-- ---------------------------------------------------------------------
-- What the day looked like, split by how it came in
-- ---------------------------------------------------------------------
create or replace function public.pos_sales_by_channel(
  p_org  uuid,
  p_from date default null,
  p_to   date default null)
returns table (
  channel   text,
  sales     integer,
  total     numeric,
  average   numeric,
  covers    integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.order_channel::text,
         count(*)::integer,
         round(sum(s.total_amount), 2),
         round(avg(s.total_amount), 2),
         -- Only dine-in carries covers, and reporting a null as a zero
         -- would make an empty column look like an empty dining room.
         nullif(sum(coalesce(s.covers, 0)), 0)::integer
    from public.pos_sales s
   where s.org_id = p_org
     and s.status = 'completed'
     and (p_from is null or s.completed_at >= p_from::timestamptz)
     and (p_to is null or s.completed_at < (p_to + 1)::timestamptz)
     and app.can_read_module(s.org_id, 'pos')
   group by s.order_channel
   order by 3 desc;
$$;

grant execute on function public.pos_sales_by_channel(uuid, date, date)
  to authenticated;

comment on function public.pos_sales_by_channel(uuid, date, date) is
  'Completed sales split by how the order arrived — how much of Friday was delivery, whether the dining room is worth the seats.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_outlet_channels enable row level security;

drop policy if exists pos_outlet_channels_read on public.pos_outlet_channels;
create policy pos_outlet_channels_read on public.pos_outlet_channels
  for select using (app.can_read_module(org_id, 'pos'));

drop policy if exists pos_outlet_channels_write on public.pos_outlet_channels;
create policy pos_outlet_channels_write on public.pos_outlet_channels
  for all using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- The privilege the policies need to be reachable at all. RLS narrows
-- what a grant already allows.
grant select, insert, update, delete on public.pos_outlet_channels
  to authenticated;

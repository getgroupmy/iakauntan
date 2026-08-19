-- The kitchen display, and the one thing it must never do twice.
--
-- ## Sending is not printing the bill again
--
-- A table orders starters, then mains twenty minutes later, then a
-- round of drinks. Each time the waiter sends the order, the kitchen
-- must receive ONLY what is new. A send that re-issued the whole bill
-- would have the starters cooked twice, and the second plate is a real
-- cost that nothing downstream ever accounts for -- it is not on the
-- bill, it is not in the stock count as a sale, it is just gone.
--
-- So a line records when it was sent, and the send takes the lines
-- where that is null. This is the assertion the file is built around.
--
-- ## Tickets are a snapshot
--
-- What the kitchen is handed is a copy: the dish name, the quantity,
-- the modifiers as text, the table it belongs to. Not a view over the
-- bill, because the bill keeps changing -- a line can be discounted,
-- re-priced by a modifier, or removed entirely -- and none of that
-- should silently rewrite a docket somebody is cooking from.
--
-- A removed line leaves its ticket line behind, with the link nulled.
-- The food was cooked. Whether it gets charged for is a different
-- question from whether it was made.
--
-- ## Routing
--
-- A dish goes to one station, resolved in the order a shop actually
-- sets it up: the dish itself if somebody named a station for it, the
-- category if not -- "drinks go to the bar" is a category rule -- and
-- the outlet's default station if neither. An outlet with one station
-- needs no routing configuration at all, which is the common case.

create type app.pos_ticket_status as enum (
  'new',       -- on the screen, nobody has started
  'cooking',   -- somebody picked it up
  'ready',     -- on the pass, waiting to be run
  'served',    -- gone to the table
  'cancelled'  -- called off; the kitchen was told
);

-- ---------------------------------------------------------------------
-- Where food is made
-- ---------------------------------------------------------------------
create table if not exists public.pos_kitchen_stations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,
  code       text not null,
  name       text not null,
  sort_order integer not null default 0,

  -- Where anything unrouted goes. An outlet with one kitchen sets this
  -- and never thinks about routing again.
  is_default boolean not null default false,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (outlet_id, code)
);

create unique index if not exists pos_kitchen_stations_one_default
  on public.pos_kitchen_stations (outlet_id) where is_default;

-- Two levels of routing, both optional. A dish beats its category,
-- because the exception is the reason somebody wrote it down.
create table if not exists public.item_kitchen_stations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  item_id    uuid not null references public.items (id) on delete cascade,
  station_id uuid not null references public.pos_kitchen_stations (id) on delete cascade,
  unique (item_id, station_id)
);

create table if not exists public.category_kitchen_stations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  category_id uuid not null references public.item_categories (id) on delete cascade,
  station_id  uuid not null references public.pos_kitchen_stations (id) on delete cascade,
  unique (category_id, station_id)
);

-- ---------------------------------------------------------------------
-- What the kitchen was handed
-- ---------------------------------------------------------------------
create table if not exists public.pos_kitchen_tickets (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets (id) on delete cascade,
  station_id  uuid not null references public.pos_kitchen_stations (id) on delete cascade,
  sale_id     uuid references public.pos_sales (id) on delete set null,

  -- A plain increasing number. Kitchen staff call tickets out loud, so
  -- it has to be short and it has to be unambiguous; per-outlet daily
  -- numbering would be prettier and would need a counter that two
  -- tablets could race each other for.
  ticket_no   bigint generated always as identity,

  status      app.pos_ticket_status not null default 'new',

  -- Snapshots. The table can be renamed and the party can move; the
  -- docket says where the food was going when it was ordered.
  table_code  text,
  covers      integer,
  note        text,

  sent_at     timestamptz not null default now(),
  started_at  timestamptz,
  ready_at    timestamptz,
  served_at   timestamptz,
  cancelled_at timestamptz,
  sent_by     uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists pos_kitchen_tickets_station_idx
  on public.pos_kitchen_tickets (station_id, status, sent_at);
create index if not exists pos_kitchen_tickets_sale_idx
  on public.pos_kitchen_tickets (sale_id);

create table if not exists public.pos_kitchen_ticket_lines (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  ticket_id    uuid not null references public.pos_kitchen_tickets (id) on delete cascade,

  -- Nulled rather than deleted when the bill line goes. The food was
  -- cooked; whether it is charged for is a different question.
  sale_line_id uuid references public.pos_sale_lines (id) on delete set null,

  description  text not null,
  quantity     numeric(18, 4) not null default 1,
  modifiers    text,
  note         text,
  created_at   timestamptz not null default now()
);

create index if not exists pos_kitchen_ticket_lines_ticket_idx
  on public.pos_kitchen_ticket_lines (ticket_id);

-- When each line went to the kitchen. Null means the kitchen has never
-- seen it, which is exactly what the next send looks for.
alter table public.pos_sale_lines
  add column if not exists sent_to_kitchen_at timestamptz;

comment on column public.pos_sale_lines.sent_to_kitchen_at is
  'When this line was sent to a kitchen station. Null means never sent — the next send takes exactly these lines, so a second course does not reprint the first.';

-- ---------------------------------------------------------------------
-- Which station cooks this
-- ---------------------------------------------------------------------
create or replace function app.pos_route_item(p_outlet uuid, p_item uuid)
returns uuid
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(
    (select iks.station_id from public.item_kitchen_stations iks
       join public.pos_kitchen_stations st on st.id = iks.station_id
      where iks.item_id = p_item and st.outlet_id = p_outlet and st.is_active
      limit 1),
    (select cks.station_id from public.category_kitchen_stations cks
       join public.pos_kitchen_stations st on st.id = cks.station_id
       join public.items i on i.category_id = cks.category_id
      where i.id = p_item and st.outlet_id = p_outlet and st.is_active
      limit 1),
    (select st.id from public.pos_kitchen_stations st
      where st.outlet_id = p_outlet and st.is_default and st.is_active
      limit 1));
$$;

revoke all on function app.pos_route_item(uuid, uuid) from public, anon, authenticated;

-- The modifiers as the kitchen reads them, in the order they were
-- asked for. Rendered once at send time and stored, because the bill's
-- modifiers can change afterwards and a docket must not.
create or replace function app.pos_line_modifier_text(p_line uuid)
returns text
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select nullif(string_agg(
           case when m.quantity > 1 then m.name || ' x' || m.quantity else m.name end,
           ', ' order by m.created_at), '')
    from public.pos_sale_line_modifiers m where m.line_id = p_line;
$$;

revoke all on function app.pos_line_modifier_text(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Sending the order
-- ---------------------------------------------------------------------
create or replace function public.send_order_to_kitchen(p_sale uuid)
returns table (
  station    text,
  ticket_id  uuid,
  ticket_no  bigint,
  line_count integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_table  text;
  v_gaps   integer;
  v_line   record;
  v_st     uuid;
  v_ticket uuid;
  -- Which station got which ticket in THIS call. Keyed rather than
  -- re-queried by timestamp: `now()` is the transaction's clock, so two
  -- sends inside one transaction would look identical to a lookup on
  -- `sent_at` and the second round would be added to the first round's
  -- docket.
  v_made   jsonb := '{}'::jsonb;
  v_now    timestamptz := clock_timestamp();
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That bill is % and has nothing to send.', v_sale.status
      using errcode = '23514';
  end if;

  -- A cook cannot guess "choose one". 0214 reports the gaps; this is
  -- the first moment at which an unanswered question actually matters,
  -- and refusing here is cheaper than refusing every line as it is rung.
  select count(*)::integer into v_gaps from public.pos_line_modifier_gaps(p_sale);
  if v_gaps > 0 then
    raise exception
      'There are % choices still to make on this order.', v_gaps
      using errcode = '23514';
  end if;

  select t.code into v_table from public.pos_tables t where t.id = v_sale.table_id;

  -- Exactly the lines the kitchen has never seen. See the header: this
  -- is the whole point of the column.
  for v_line in
    select l.* from public.pos_sale_lines l
     where l.sale_id = p_sale
       and l.sent_to_kitchen_at is null
     order by l.line_no
  loop
    v_st := app.pos_route_item(v_sale.outlet_id, v_line.item_id);
    if v_st is null then
      raise exception
        'Nothing tells the kitchen where "%" is made, and this outlet '
        'has no default station.', v_line.description
        using errcode = '23514';
    end if;

    -- One ticket per station per send. A station that already has a
    -- ticket from THIS send gets the line added to it; one from an
    -- earlier round is left alone, because it may already be cooking.
    v_ticket := (v_made ->> v_st::text)::uuid;
    if v_ticket is null then
      insert into public.pos_kitchen_tickets
        (org_id, outlet_id, station_id, sale_id, table_code, covers, sent_at, sent_by)
      values (v_sale.org_id, v_sale.outlet_id, v_st, p_sale, v_table,
              v_sale.covers, v_now, auth.uid())
      returning id into v_ticket;
      v_made := v_made || jsonb_build_object(v_st::text, v_ticket::text);
    end if;

    insert into public.pos_kitchen_ticket_lines
      (org_id, ticket_id, sale_line_id, description, quantity, modifiers, note)
    values (v_sale.org_id, v_ticket, v_line.id, v_line.description, v_line.quantity,
            app.pos_line_modifier_text(v_line.id), v_line.note);

    update public.pos_sale_lines l
       set sent_to_kitchen_at = v_now where l.id = v_line.id;
  end loop;

  return query
    select st.name, k.id, k.ticket_no,
           (select count(*)::integer from public.pos_kitchen_ticket_lines kl
             where kl.ticket_id = k.id)
      from public.pos_kitchen_tickets k
      join public.pos_kitchen_stations st on st.id = k.station_id
     where k.id in (select (value #>> '{}')::uuid from jsonb_each(v_made))
     order by st.sort_order, st.name;
end;
$$;

revoke all on function public.send_order_to_kitchen(uuid) from public, anon;
grant execute on function public.send_order_to_kitchen(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The bump bar
-- ---------------------------------------------------------------------
--
-- Forward only. A ticket that could go back to 'new' is a ticket a
-- second cook starts again, and the timestamps stop meaning anything.
-- Cancelling is the exception, because calling food off is a real thing
-- that happens at any point.
create or replace function public.bump_kitchen_ticket(
  p_ticket uuid,
  p_status app.pos_ticket_status)
returns app.pos_ticket_status
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_t     public.pos_kitchen_tickets;
  v_order integer;
  v_new   integer;
begin
  select * into v_t from public.pos_kitchen_tickets where id = p_ticket;
  if v_t.id is null then
    raise exception 'No such ticket.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_t.org_id, 'pos') then
    raise exception 'not permitted to work this kitchen' using errcode = '42501';
  end if;

  v_order := array_position(array['new','cooking','ready','served']::text[], v_t.status::text);
  v_new   := array_position(array['new','cooking','ready','served']::text[], p_status::text);

  if p_status <> 'cancelled' then
    if v_t.status = 'cancelled' then
      raise exception 'That ticket was called off.' using errcode = '23514';
    end if;
    if v_new is null or v_order is null or v_new <= v_order then
      raise exception
        'A ticket goes forward. It is already %.', v_t.status using errcode = '23514';
    end if;
  end if;

  update public.pos_kitchen_tickets k
     set status = p_status,
         started_at   = case when p_status = 'cooking'   then coalesce(k.started_at, now()) else k.started_at end,
         ready_at     = case when p_status = 'ready'     then coalesce(k.ready_at, now())   else k.ready_at end,
         served_at    = case when p_status = 'served'    then coalesce(k.served_at, now())  else k.served_at end,
         cancelled_at = case when p_status = 'cancelled' then now() else k.cancelled_at end
   where k.id = p_ticket;

  return p_status;
end;
$$;

revoke all on function public.bump_kitchen_ticket(uuid, app.pos_ticket_status) from public, anon;
grant execute on function public.bump_kitchen_ticket(uuid, app.pos_ticket_status) to authenticated;

-- ---------------------------------------------------------------------
-- The screen over the pass
-- ---------------------------------------------------------------------
--
-- Oldest first, because the only ordering a kitchen cares about is who
-- has been waiting longest.
create or replace function public.kitchen_display(p_station uuid)
returns table (
  ticket_id     uuid,
  ticket_no     bigint,
  status        app.pos_ticket_status,
  table_code    text,
  covers        integer,
  sent_at       timestamptz,
  minutes_waiting integer,
  items         jsonb)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select k.id, k.ticket_no, k.status, k.table_code, k.covers, k.sent_at,
         floor(extract(epoch from (now() - k.sent_at)) / 60)::integer,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'description', kl.description,
                    'quantity', kl.quantity,
                    'modifiers', kl.modifiers,
                    'note', kl.note)
                  order by kl.created_at)
             from public.pos_kitchen_ticket_lines kl where kl.ticket_id = k.id
         ), '[]'::jsonb)
    from public.pos_kitchen_tickets k
   where k.station_id = p_station
     and k.status in ('new', 'cooking', 'ready')
     and app.can_read_module(k.org_id, 'pos')
   order by k.sent_at, k.ticket_no;
$$;

grant execute on function public.kitchen_display(uuid) to authenticated;

comment on function public.kitchen_display(uuid) is
  'Open tickets at one station, oldest first — the only ordering a kitchen cares about is who has been waiting longest.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_kitchen_stations      enable row level security;
alter table public.item_kitchen_stations     enable row level security;
alter table public.category_kitchen_stations enable row level security;
alter table public.pos_kitchen_tickets       enable row level security;
alter table public.pos_kitchen_ticket_lines  enable row level security;

create policy pos_kitchen_stations_read on public.pos_kitchen_stations for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_kitchen_stations_write on public.pos_kitchen_stations for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy item_kitchen_stations_read on public.item_kitchen_stations for select
  using (app.can_read_module(org_id, 'pos'));
create policy item_kitchen_stations_write on public.item_kitchen_stations for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy category_kitchen_stations_read on public.category_kitchen_stations for select
  using (app.can_read_module(org_id, 'pos'));
create policy category_kitchen_stations_write on public.category_kitchen_stations for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Tickets are read-only to the API. They are written by the send, which
-- is the thing that knows what the kitchen has already been told; a
-- client that could insert one could have a dish cooked twice.
create policy pos_kitchen_tickets_read on public.pos_kitchen_tickets for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_kitchen_ticket_lines_read on public.pos_kitchen_ticket_lines for select
  using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_kitchen_stations to authenticated;
grant select, insert, update, delete on public.item_kitchen_stations to authenticated;
grant select, insert, update, delete on public.category_kitchen_stations to authenticated;
grant select on public.pos_kitchen_tickets      to authenticated;
grant select on public.pos_kitchen_ticket_lines to authenticated;

create trigger set_updated_at before update on public.pos_kitchen_tickets
  for each row execute function app.set_updated_at();

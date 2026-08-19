-- A restaurant is a shop where the customer sits down.
--
-- ## What actually changes
--
-- Almost nothing about the money. A table's bill is a `pos_sales` row
-- like any other: same lines, same tenders, same posted invoice and
-- receipt at the end. What a dining room adds is that the basket has a
-- PLACE and lasts an hour, so it needs to be findable by where the
-- customer is sitting rather than by which till they are standing at.
--
-- ## Table state is derived
--
-- The tempting shape is `pos_tables.status` -- free, seated, ordered,
-- billed -- updated as things happen. It is the same mistake as a
-- points balance column, and it fails the same way: the status and the
-- bills disagree the first time a sale is voided, a browser tab is
-- closed mid-order, or two waiters tap the same table at once. A table
-- is occupied exactly when a parked sale points at it, which is a fact
-- with one copy.
--
-- ## Tapping an occupied table opens its bill
--
-- This is the behaviour a floor plan needs and the one that is easy to
-- get wrong. A waiter taps table 7 to add a round of drinks; they mean
-- "the bill on table 7", not "a second bill on table 7". Starting a new
-- sale would leave the first one parked and invisible, and the
-- customers would be charged twice or not at all depending on which one
-- got settled.
--
-- After a split there can legitimately be more than one bill on a
-- table, and then there is no single right answer -- so `seat_table`
-- refuses and says so, rather than picking one.

-- ---------------------------------------------------------------------
-- The room
-- ---------------------------------------------------------------------
create table if not exists public.pos_floor_areas (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets (id) on delete cascade,
  code        text not null,
  name        text not null,
  sort_order   integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (outlet_id, code)
);

create table if not exists public.pos_tables (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets (id) on delete cascade,
  area_id     uuid references public.pos_floor_areas (id) on delete set null,
  code        text not null,
  name        text,
  seats       integer not null default 2 check (seats > 0),

  -- Where it is on the plan the waiter looks at. Unitless: the client
  -- decides what a unit is, and a floor plan drawn for a phone and one
  -- drawn for a wall display are the same room at different scales.
  pos_x       numeric(9, 2) not null default 0,
  pos_y       numeric(9, 2) not null default 0,
  shape       text not null default 'square'
              check (shape in ('square', 'round', 'rectangle', 'booth', 'bar')),

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (outlet_id, code)
);

create index if not exists pos_tables_outlet_idx on public.pos_tables (outlet_id)
  where is_active;
create index if not exists pos_floor_areas_outlet_idx on public.pos_floor_areas (outlet_id);

comment on table public.pos_tables is
  'A place in the dining room. Carries no status: a table is occupied exactly when a parked sale points at it, which is a fact with one copy.';

-- An area and a table have to belong to the outlet they are drawn on,
-- and the outlet has to belong to the organization paying for them.
create or replace function app.pos_table_belongs()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_outlet_org uuid;
begin
  select o.org_id into v_outlet_org from public.pos_outlets o where o.id = new.outlet_id;
  if v_outlet_org is null or v_outlet_org <> new.org_id then
    raise exception 'That outlet belongs to another organization.'
      using errcode = '42501';
  end if;
  -- Nested rather than `tg_table_name = 'pos_tables' and new.area_id
  -- is not null`, because SQL's AND does not promise to evaluate its
  -- operands left to right -- and `new.area_id` on a floor-area row is
  -- a field that does not exist. A nested IF is two statements, and the
  -- inner one is only reached when the record really has the column.
  if tg_table_name = 'pos_tables' then
    if new.area_id is not null then
      if not exists (select 1 from public.pos_floor_areas a
                      where a.id = new.area_id and a.outlet_id = new.outlet_id) then
        raise exception 'That area is in a different outlet.' using errcode = '23514';
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists pos_table_belongs on public.pos_tables;
create trigger pos_table_belongs before insert or update on public.pos_tables
  for each row execute function app.pos_table_belongs();
drop trigger if exists pos_area_belongs on public.pos_floor_areas;
create trigger pos_area_belongs before insert or update on public.pos_floor_areas
  for each row execute function app.pos_table_belongs();

-- ---------------------------------------------------------------------
-- Where the bill is sitting
-- ---------------------------------------------------------------------
alter table public.pos_sales
  add column if not exists table_id uuid references public.pos_tables (id) on delete set null,
  add column if not exists covers integer check (covers is null or covers > 0);

create index if not exists pos_sales_table_idx
  on public.pos_sales (table_id) where status = 'parked';

comment on column public.pos_sales.covers is
  'How many people are eating. Not derived from anything: two diners can order four mains, and per-head splitting needs the heads.';

-- ---------------------------------------------------------------------
-- Sitting somebody down
-- ---------------------------------------------------------------------
--
-- Returns the bill already on the table if there is one, because that
-- is what tapping a table means. See the header for why starting a
-- second one silently would be the expensive kind of wrong.
create or replace function public.seat_table(
  p_register uuid,
  p_table    uuid,
  p_covers   integer default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_table  public.pos_tables;
  v_outlet uuid;
  v_open   integer;
  v_sale   uuid;
begin
  select * into v_table from public.pos_tables where id = p_table;
  if v_table.id is null then
    raise exception 'No such table.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_table.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if not v_table.is_active then
    raise exception 'Table % is not in service.', v_table.code using errcode = '23514';
  end if;

  select r.outlet_id into v_outlet from public.pos_registers r where r.id = p_register;
  if v_outlet is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if v_outlet <> v_table.outlet_id then
    raise exception
      'Table % is in another outlet. A waiter cannot seat a table they '
      'are not standing in.', v_table.code
      using errcode = '23514';
  end if;

  select count(*)::integer into v_open from public.pos_sales s
   where s.table_id = p_table and s.status = 'parked';

  if v_open > 1 then
    raise exception
      'Table % has % bills open. Pick the one you mean.', v_table.code, v_open
      using errcode = '23514';
  end if;

  if v_open = 1 then
    select s.id into v_sale from public.pos_sales s
     where s.table_id = p_table and s.status = 'parked';
    -- Covers can be corrected on the way past: a two-top that became a
    -- four-top is the normal case, not an error.
    if p_covers is not null then
      update public.pos_sales s set covers = p_covers where s.id = v_sale;
    end if;
    return v_sale;
  end if;

  v_sale := public.open_pos_sale(p_register);
  update public.pos_sales s
     set table_id = p_table,
         covers = coalesce(p_covers, v_table.seats)
   where s.id = v_sale;
  return v_sale;
end;
$$;

revoke all on function public.seat_table(uuid, uuid, integer) from public, anon;
grant execute on function public.seat_table(uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Moving a party
-- ---------------------------------------------------------------------
--
-- People change tables. The bill goes with them, and nothing about it
-- changes -- not the lines, not what the kitchen has already cooked,
-- not the number on it.
create or replace function public.move_pos_sale(
  p_sale  uuid,
  p_table uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale  public.pos_sales;
  v_table public.pos_tables;
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
    raise exception
      'That bill is already %, so there is nobody left to move.', v_sale.status
      using errcode = '23514';
  end if;

  if p_table is null then
    update public.pos_sales s set table_id = null where s.id = p_sale;
    return;
  end if;

  select * into v_table from public.pos_tables where id = p_table;
  if v_table.id is null then
    raise exception 'No such table.' using errcode = 'P0002';
  end if;
  if v_table.outlet_id <> v_sale.outlet_id then
    raise exception 'That table is in another outlet.' using errcode = '23514';
  end if;

  update public.pos_sales s set table_id = p_table where s.id = p_sale;
end;
$$;

revoke all on function public.move_pos_sale(uuid, uuid) from public, anon;
grant execute on function public.move_pos_sale(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The plan a waiter looks at
-- ---------------------------------------------------------------------
--
-- One row per table, plus one row per open bill on it. A free table
-- appears once with nulls down the right-hand side; a table with two
-- bills after a split appears twice, which is the truth and is what the
-- screen has to draw.
create or replace function public.pos_floor_plan(p_outlet uuid)
returns table (
  table_id    uuid,
  table_code  text,
  table_name  text,
  area        text,
  seats       integer,
  pos_x       numeric,
  pos_y       numeric,
  shape       text,
  sale_id     uuid,
  sale_no     text,
  covers      integer,
  opened_at   timestamptz,
  minutes_seated integer,
  total_amount numeric,
  line_count  integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select t.id, t.code, coalesce(t.name, t.code), a.name, t.seats,
         t.pos_x, t.pos_y, t.shape,
         s.id, s.sale_no, s.covers, s.opened_at,
         case when s.id is null then null
              else floor(extract(epoch from (now() - s.opened_at)) / 60)::integer
         end,
         s.total_amount,
         case when s.id is null then null
              else (select count(*)::integer from public.pos_sale_lines l
                     where l.sale_id = s.id)
         end
    from public.pos_tables t
    left join public.pos_floor_areas a on a.id = t.area_id
    left join public.pos_sales s
      on s.table_id = t.id and s.status = 'parked'
   where t.outlet_id = p_outlet
     and t.is_active
     and app.can_read_module(t.org_id, 'pos')
   order by coalesce(a.sort_order, 0), a.name nulls first, t.code, s.opened_at;
$$;

grant execute on function public.pos_floor_plan(uuid) to authenticated;

comment on function public.pos_floor_plan(uuid) is
  'The dining room as it stands: every table, and every bill open on one. Occupancy is read from the bills rather than stored, so it cannot disagree with them.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_floor_areas enable row level security;
alter table public.pos_tables      enable row level security;

create policy pos_floor_areas_read on public.pos_floor_areas for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_floor_areas_write on public.pos_floor_areas for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_tables_read on public.pos_tables for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_tables_write on public.pos_tables for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_floor_areas to authenticated;
grant select, insert, update, delete on public.pos_tables to authenticated;

create trigger set_updated_at before update on public.pos_tables
  for each row execute function app.set_updated_at();

-- =====================================================================
-- A long table is two tables
--
-- A warung has a twelve-seat table down one side. Two unrelated parties
-- sit at it, which is normal and is the whole point of a long table.
-- Right now the room has one place called T1, so they get one bill
-- between them, or two bills on one table -- and `seat_table` refuses
-- the second case on purpose ("Table T1 has 2 bills open. Pick the one
-- you mean."), because guessing which party a tap meant is the
-- expensive kind of wrong.
--
-- So: split the table. T1 becomes T1-A and T1-B, and the room now has
-- two places where it had one.
--
-- ---------------------------------------------------------------------
-- The parts are real tables
--
-- Not a flag on the bill, not a virtual sub-table the client draws.
-- Rows in `pos_tables`, with their own codes. Everything downstream
-- then works with nothing changed: `seat_table` seats them,
-- `move_pos_sale` moves a party between them, `pos_floor_plan` draws
-- them, `pos_table_by_code` resolves a card that says T1-A, and the
-- printed card sheet prints one. A virtual part would have had to be
-- taught to every one of those.
--
-- ---------------------------------------------------------------------
-- The parent goes out of service while it is split
--
-- Not deleted -- deactivated. T1 is not a place anybody can be seated
-- at while two parties are sitting in its halves, and leaving it
-- seatable would let a waiter put a third party at a table that no
-- longer exists. Every read here filters `is_active`, so deactivating
-- the parent is all it takes for the room to be right.
--
-- The visible consequence: a card printed for T1 stops resolving while
-- T1 is split. That is the truth -- there is no T1 to seat anyone at --
-- and the cards for the parts are printed from the same screen that
-- did the splitting.
--
-- ---------------------------------------------------------------------
-- And merging does not delete anything either
--
-- `pos_sales.table_id` is `on delete set null`, so deleting T1-A would
-- quietly erase which table last Tuesday's bills were served at. A
-- shop that splits its long table every Friday would lose a night of
-- per-table history every week.
--
-- So merging deactivates the parts and wakes the parent, and splitting
-- again reuses the same rows rather than making new ones. T1-A is the
-- same T1-A it was last Friday, and its history accumulates.
--
-- ---------------------------------------------------------------------
-- One level
--
-- A half table does not split again. `T1-A-A` is not a thing anybody
-- has ever said out loud, and allowing it would mean every read that
-- walks the parent chain has to loop rather than look once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which table a part came from
-- ---------------------------------------------------------------------
alter table public.pos_tables
  add column if not exists parent_table_id uuid
    references public.pos_tables (id) on delete cascade;

create index if not exists pos_tables_parent_idx
  on public.pos_tables (parent_table_id) where parent_table_id is not null;

comment on column public.pos_tables.parent_table_id is
  'The table this one is a part of, for a long table split into T1-A and T1-B. Null for an ordinary table. One level only: a part never has parts.';

-- ---------------------------------------------------------------------
-- Splitting it
-- ---------------------------------------------------------------------
--
-- Returns the parts, in order, so the caller can seat somebody at the
-- first one without asking a second question.
--
-- A party already sitting at T1 when it is split goes to T1-A with
-- their bill, their number and everything the kitchen already has.
-- That is not a guess about which end of the table they are at -- they
-- are the only party there, so there is only one answer. Two parties
-- already on it is a different matter and is refused: that is the
-- ambiguity `seat_table` exists to avoid, and splitting is not the
-- place to resolve it.
create or replace function public.split_pos_table(
  p_table uuid,
  p_parts integer default 2)
returns setof uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_table  public.pos_tables;
  v_open   integer;
  v_live   integer;
  v_sale   uuid;
  v_code   text;
  v_seats  integer;
  v_part   uuid;
  v_owner  uuid;
  i        integer;
begin
  select * into v_table from public.pos_tables where id = p_table;
  if v_table.id is null then
    raise exception 'No such table.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_table.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  if v_table.parent_table_id is not null then
    raise exception
      'Table % is already half of another table, and a half table does '
      'not split again.', v_table.code
      using errcode = '23514';
  end if;

  -- A table somebody took out of service is not a table two parties can
  -- sit at, so it is not a table to split. Said separately from the
  -- already-split case, which also leaves the parent inactive, because
  -- the two need different answers.
  if not v_table.is_active
     and not exists (select 1 from public.pos_tables t
                      where t.parent_table_id = p_table and t.is_active) then
    raise exception 'Table % is not in service.', v_table.code
      using errcode = '23514';
  end if;

  if p_parts is null or p_parts < 2 or p_parts > 8 then
    raise exception
      'A table splits into between two and eight parts, not %.',
      coalesce(p_parts::text, 'none')
      using errcode = '23514';
  end if;

  select count(*)::integer into v_live
    from public.pos_tables t
   where t.parent_table_id = p_table and t.is_active;
  if v_live > 0 then
    raise exception
      'Table % is already split into % parts. Put it back together '
      'first.', v_table.code, v_live
      using errcode = '23514';
  end if;

  select count(*)::integer into v_open from public.pos_sales s
   where s.table_id = p_table and s.status = 'parked';
  if v_open > 1 then
    raise exception
      'Table % has % bills open. Settle or move them before splitting, '
      'so nobody has to guess which party went where.', v_table.code, v_open
      using errcode = '23514';
  end if;

  for i in 1 .. p_parts loop
    -- A, B, C ... H. Letters rather than numbers because T1-2 reads as
    -- a table code in its own right and T1-B does not.
    v_code := v_table.code || '-' || chr(64 + i);

    -- Seats divided, remainder to the earlier parts, never below one:
    -- a seven-seat table split in two is a four and a three, and the
    -- check constraint on `seats` will not take a nought.
    v_seats := greatest(1,
      v_table.seats / p_parts
        + case when i <= v_table.seats % p_parts then 1 else 0 end);

    select t.id, t.parent_table_id into v_part, v_owner
      from public.pos_tables t
     where t.outlet_id = v_table.outlet_id
       and upper(t.code) = upper(v_code);

    if v_part is not null and v_owner is distinct from p_table then
      -- Somebody already has a table called T1-A that is not a part of
      -- T1. Renaming theirs out from under them would be worse than
      -- refusing, and there is no second name this could fall back to
      -- that would not be a surprise later.
      raise exception
        'This outlet already has a table called %. Rename it, or rename '
        '%, before splitting.', v_code, v_table.code
        using errcode = '23505';
    end if;

    if v_part is not null then
      -- The same part as last time, woken up. Its history comes with
      -- it, which is the reason merging does not delete these.
      update public.pos_tables t
         set is_active = true,
             seats     = v_seats,
             area_id   = v_table.area_id,
             shape     = v_table.shape,
             name      = coalesce(v_table.name, v_table.code)
                           || ' ' || chr(64 + i)
       where t.id = v_part;
    else
      insert into public.pos_tables
        (org_id, outlet_id, area_id, code, name, seats,
         pos_x, pos_y, shape, parent_table_id)
      values
        (v_table.org_id, v_table.outlet_id, v_table.area_id, v_code,
         coalesce(v_table.name, v_table.code) || ' ' || chr(64 + i),
         v_seats,
         -- Nudged along x so two parts of one table do not land exactly
         -- on top of each other on a drawn plan. The units are whatever
         -- the client decides they are, so this is a hint, not a
         -- position somebody measured.
         v_table.pos_x + (i - 1), v_table.pos_y, v_table.shape, p_table)
      returning id into v_part;
    end if;

    if i = 1 and v_open = 1 then
      select s.id into v_sale from public.pos_sales s
       where s.table_id = p_table and s.status = 'parked';
      update public.pos_sales s set table_id = v_part where s.id = v_sale;
    end if;

    return next v_part;
  end loop;

  -- Last, so that a failure anywhere above leaves the room as it was.
  update public.pos_tables t set is_active = false where t.id = p_table;
end;
$$;

revoke all on function public.split_pos_table(uuid, integer) from public, anon;
grant execute on function public.split_pos_table(uuid, integer) to authenticated;

comment on function public.split_pos_table(uuid, integer) is
  'Turns a long table into T1-A, T1-B and so on: real tables with their own codes, cards and bills. The parent goes out of service until they are merged back.';

-- ---------------------------------------------------------------------
-- Putting it back together
-- ---------------------------------------------------------------------
--
-- Takes the parent or any part, because a waiter looking at the floor
-- plan is looking at T1-B, not at the T1 that is no longer drawn.
--
-- Symmetric with the split: one party left on one part comes back to
-- the whole table with their bill. Two parties cannot, for the same
-- reason two parties could not be split apart -- there would be two
-- bills on one table and the next tap on it would be ambiguous.
create or replace function public.merge_pos_table(p_table uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_table  public.pos_tables;
  v_parent uuid;
  v_parts  integer;
  v_open   integer;
  v_sale   uuid;
  v_codes  text;
begin
  select * into v_table from public.pos_tables where id = p_table;
  if v_table.id is null then
    raise exception 'No such table.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_table.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  v_parent := coalesce(v_table.parent_table_id, v_table.id);

  select count(*)::integer into v_parts
    from public.pos_tables t
   where t.parent_table_id = v_parent and t.is_active;
  if v_parts = 0 then
    raise exception 'Table % is not split.', v_table.code
      using errcode = '23514';
  end if;

  select count(*)::integer into v_open
    from public.pos_sales s
    join public.pos_tables t on t.id = s.table_id
   where t.parent_table_id = v_parent and t.is_active
     and s.status = 'parked';

  if v_open > 1 then
    select string_agg(distinct t.code, ', ' order by t.code) into v_codes
      from public.pos_sales s
      join public.pos_tables t on t.id = s.table_id
     where t.parent_table_id = v_parent and t.is_active
       and s.status = 'parked';
    raise exception
      'There are still % bills open, on %. One table cannot hold two '
      'parties'' bills and be tapped without ambiguity.', v_open, v_codes
      using errcode = '23514';
  end if;

  -- The parent has to be back in service before the bill moves onto it,
  -- or the room briefly holds a party at a table that is not there.
  update public.pos_tables t set is_active = true where t.id = v_parent;

  if v_open = 1 then
    select s.id into v_sale
      from public.pos_sales s
      join public.pos_tables t on t.id = s.table_id
     where t.parent_table_id = v_parent and t.is_active
       and s.status = 'parked';
    update public.pos_sales s set table_id = v_parent where s.id = v_sale;
  end if;

  update public.pos_tables t
     set is_active = false
   where t.parent_table_id = v_parent;
end;
$$;

revoke all on function public.merge_pos_table(uuid) from public, anon;
grant execute on function public.merge_pos_table(uuid) to authenticated;

comment on function public.merge_pos_table(uuid) is
  'Puts a split table back together. Deactivates the parts rather than deleting them, so which table a past bill was served at survives, and so splitting again reuses the same T1-A.';

-- ---------------------------------------------------------------------
-- And the plan says which tables are parts
-- ---------------------------------------------------------------------
--
-- Dropped and recreated rather than replaced, because `create or
-- replace function` cannot change a return type and this adds a
-- column. Nothing else in the database calls it -- only the app and the
-- tests -- and both read by name.
--
-- The screen needs it to know which of the two things to offer: an
-- ordinary table can be split, a part can be merged back, and offering
-- both on both would be offering an action the database will refuse.
drop function if exists public.pos_floor_plan(uuid);

create function public.pos_floor_plan(p_outlet uuid)
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
  line_count  integer,
  parent_table_id uuid)
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
         end,
         t.parent_table_id
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
  'The dining room as it stands: every table, and every bill open on one. Occupancy is read from the bills rather than stored, so it cannot disagree with them. A split table shows as its parts; the whole is out of service until they are merged.';

-- ---------------------------------------------------------------------
-- 0228  Setting up a counter, and saying what goes to it
-- ---------------------------------------------------------------------
--
-- 0215 built the routing and asserted it: a dish goes to the station
-- named on the dish, else the one named on its category, else the
-- outlet's default. All three tables have RLS write policies, so a
-- client could in principle write them directly — and three things go
-- wrong if it does.
--
-- ## One default, and the index that says so
--
-- `pos_kitchen_stations_one_default` is a unique partial index. Making
-- a second station the default therefore has to clear the first in the
-- same transaction, or the write fails. A screen doing that as two
-- calls leaves a moment with no default at all, which is the moment
-- `send_order_to_kitchen` refuses an unrouted dish.
--
-- ## One station per dish per outlet
--
-- `item_kitchen_stations` is unique on `(item_id, station_id)`, which
-- allows a dish to be routed to two stations in the same outlet. It has
-- to allow two rows, because the same dish in two shops is two rows —
-- but `app.pos_route_item` takes `limit 1` from them, so two rows in
-- ONE outlet means the bar and the kitchen take turns receiving the
-- drink and nobody can say why. `route_item_to_station` clears the
-- outlet's other routings for that dish before it writes.
--
-- ## A station is retired, never deleted
--
-- `pos_kitchen_tickets.station_id` cascades on delete. Deleting a
-- station therefore deletes every docket it ever received — a day's
-- kitchen history removed by somebody tidying up a list. Retiring sets
-- `is_active` false, which is what routing already checks.
--
-- ## And the screen has to be able to say why
--
-- `pos_station_routing` returns, for each sellable item, the station it
-- currently goes to AND which of the three rules decided that. A
-- routing screen that showed only the answer would leave somebody
-- unable to tell a rule they set from a default they inherited, which
-- is the difference between changing the dish and changing the
-- category.

-- ---------------------------------------------------------------------
-- Adding a counter, or renaming one
-- ---------------------------------------------------------------------
create or replace function public.upsert_kitchen_station(
  p_outlet     uuid,
  p_code       text,
  p_name       text,
  p_id         uuid    default null,
  p_sort_order integer default 0,
  p_is_default boolean default false,
  p_is_active  boolean default true)
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
  if nullif(btrim(coalesce(p_code, '')), '') is null
     or nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A counter needs a code and a name.'
      using errcode = '23514';
  end if;

  -- Cleared first, in the same transaction. The unique partial index
  -- rejects a second default outright, and doing this as two client
  -- calls would leave a moment with no default at all -- which is
  -- exactly the moment `send_order_to_kitchen` refuses an unrouted
  -- dish.
  if p_is_default then
    update public.pos_kitchen_stations st
       set is_default = false
     where st.outlet_id = p_outlet
       and st.is_default
       and st.id is distinct from p_id;
  end if;

  if p_id is null then
    insert into public.pos_kitchen_stations
      (org_id, outlet_id, code, name, sort_order, is_default, is_active)
    values (v_org, p_outlet, btrim(p_code), btrim(p_name),
            coalesce(p_sort_order, 0), coalesce(p_is_default, false),
            coalesce(p_is_active, true))
    returning id into v_id;
    return v_id;
  end if;

  update public.pos_kitchen_stations st
     set code       = btrim(p_code),
         name       = btrim(p_name),
         sort_order = coalesce(p_sort_order, st.sort_order),
         is_default = coalesce(p_is_default, st.is_default),
         is_active  = coalesce(p_is_active, st.is_active)
   where st.id = p_id and st.outlet_id = p_outlet;
  if not found then
    raise exception 'No such counter in that outlet.' using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;

revoke all on function
  public.upsert_kitchen_station(uuid, text, text, uuid, integer, boolean, boolean)
  from public, anon;
grant execute on function
  public.upsert_kitchen_station(uuid, text, text, uuid, integer, boolean, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- Taking one out of service
-- ---------------------------------------------------------------------
create or replace function public.retire_kitchen_station(p_station uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_st   public.pos_kitchen_stations;
  v_open integer;
begin
  select * into v_st from public.pos_kitchen_stations where id = p_station;
  if v_st.id is null then
    raise exception 'No such counter.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_st.org_id, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- Food somebody is still cooking. Retiring the station it is on takes
  -- the ticket off every screen at once, and the plate does not stop
  -- existing because a list was tidied.
  select count(*) into v_open from public.pos_kitchen_tickets k
   where k.station_id = p_station and k.status in ('new', 'cooking', 'ready');
  if v_open > 0 then
    raise exception
      'That counter has % ticket(s) still in play. Clear them first.',
      v_open
      using errcode = '23514';
  end if;

  if v_st.is_default and exists (
       select 1 from public.pos_kitchen_stations st
        where st.outlet_id = v_st.outlet_id and st.id <> p_station
          and st.is_active) then
    raise exception
      'That is the counter unrouted dishes go to. Make another one the '
      'default first.'
      using errcode = '23514';
  end if;

  -- Retired, not deleted. `pos_kitchen_tickets.station_id` cascades on
  -- delete, so removing the row would remove every docket the counter
  -- ever received -- a day of kitchen history destroyed by somebody
  -- tidying a list.
  update public.pos_kitchen_stations st
     set is_active = false, is_default = false
   where st.id = p_station;
  return p_station;
end;
$$;

revoke all on function public.retire_kitchen_station(uuid) from public, anon;
grant execute on function public.retire_kitchen_station(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- "This dish goes to the bar"
-- ---------------------------------------------------------------------
create or replace function public.route_item_to_station(
  p_item    uuid,
  p_outlet  uuid,
  p_station uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- Cleared for this outlet only. The same dish in another shop keeps
  -- its own routing, which is the reason the table is not unique on
  -- item alone.
  delete from public.item_kitchen_stations iks
   using public.pos_kitchen_stations st
   where iks.station_id = st.id
     and iks.item_id = p_item
     and st.outlet_id = p_outlet;

  if p_station is null then
    return p_item;                       -- back to the category rule
  end if;

  if not exists (select 1 from public.pos_kitchen_stations st
                  where st.id = p_station and st.outlet_id = p_outlet
                    and st.org_id = v_org) then
    raise exception 'That counter is not in that outlet.'
      using errcode = '23514';
  end if;

  insert into public.item_kitchen_stations (org_id, item_id, station_id)
  values (v_org, p_item, p_station)
  on conflict (item_id, station_id) do nothing;
  return p_item;
end;
$$;

revoke all on function public.route_item_to_station(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.route_item_to_station(uuid, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- "Drinks go to the bar"
-- ---------------------------------------------------------------------
create or replace function public.route_category_to_station(
  p_category uuid,
  p_outlet   uuid,
  p_station  uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select c.org_id into v_org from public.item_categories c where c.id = p_category;
  if v_org is null then
    raise exception 'No such category.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  delete from public.category_kitchen_stations cks
   using public.pos_kitchen_stations st
   where cks.station_id = st.id
     and cks.category_id = p_category
     and st.outlet_id = p_outlet;

  if p_station is null then
    return p_category;                   -- back to the outlet default
  end if;

  if not exists (select 1 from public.pos_kitchen_stations st
                  where st.id = p_station and st.outlet_id = p_outlet
                    and st.org_id = v_org) then
    raise exception 'That counter is not in that outlet.'
      using errcode = '23514';
  end if;

  insert into public.category_kitchen_stations (org_id, category_id, station_id)
  values (v_org, p_category, p_station)
  on conflict (category_id, station_id) do nothing;
  return p_category;
end;
$$;

revoke all on function public.route_category_to_station(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.route_category_to_station(uuid, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Where everything currently goes, and why
-- ---------------------------------------------------------------------
--
-- The `why` is the point. A screen showing only the answer would leave
-- somebody unable to tell a rule they set from a default they
-- inherited -- which is the difference between changing this dish and
-- changing every drink on the menu.
create or replace function public.pos_station_routing(p_outlet uuid)
returns table (
  item_id      uuid,
  item_code    text,
  item_name    text,
  category_id  uuid,
  category     text,
  station_id   uuid,
  station      text,
  decided_by   text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select i.id,
         i.code,
         i.name,
         i.category_id,
         c.name,
         app.pos_route_item(p_outlet, i.id),
         (select st.name from public.pos_kitchen_stations st
           where st.id = app.pos_route_item(p_outlet, i.id)),
         case
           when exists (select 1 from public.item_kitchen_stations iks
                          join public.pos_kitchen_stations st on st.id = iks.station_id
                         where iks.item_id = i.id and st.outlet_id = p_outlet
                           and st.is_active)
             then 'item'
           when exists (select 1 from public.category_kitchen_stations cks
                          join public.pos_kitchen_stations st on st.id = cks.station_id
                         where cks.category_id = i.category_id
                           and st.outlet_id = p_outlet and st.is_active)
             then 'category'
           when app.pos_route_item(p_outlet, i.id) is not null then 'default'
           else 'nowhere'
         end
    from public.items i
    left join public.item_categories c on c.id = i.category_id
    join public.pos_outlets o on o.id = p_outlet
   where i.org_id = o.org_id
     and i.is_active
     and i.deleted_at is null
     -- The same sellability rule the menu and the scan path apply: a
     -- style with variants under it is never sold, so routing it would
     -- be configuring something nobody can order.
     and not exists (select 1 from public.items v
                      where v.parent_item_id = i.id and v.deleted_at is null)
     and app.can_read_module(i.org_id, 'pos')
   order by c.name nulls last, i.name;
$$;

grant execute on function public.pos_station_routing(uuid) to authenticated;

comment on function public.pos_station_routing(uuid) is
  'Every sellable item, the counter it goes to, and which of the three rules decided that — the dish, its category, or the outlet default.';

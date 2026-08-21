-- =====================================================================
-- Breakfast stops at eleven
--
-- A kitchen that serves nasi lemak until eleven and burgers after it
-- has one menu in its head and one menu on the till, and the till's
-- does not know what time it is. The cashier remembers, until the
-- Saturday somebody else is on the counter.
--
-- Two different things stop a dish being offered, and they want the
-- same answer from the till:
--
--   * a rule the shop wrote down -- breakfast, happy hour, a weekend
--     special,
--   * the kitchen running out of ayam at half past one.
--
-- ---------------------------------------------------------------------
-- The schedule governs the MENU, never the ledger
--
-- This is the decision the rest of the migration hangs off, and it is
-- not the obvious one. The obvious implementation refuses the sale --
-- a check in `add_pos_sale_line`, or in the `pos_sale_line_sellable`
-- trigger beside the variant rule.
--
-- It would lose real money. 0219 lets a van sell with no signal and
-- land the batch later, and it lands it by calling
-- `add_pos_sale_line`. A breakfast set sold at half past ten from a
-- gerai with no coverage, landing at two o'clock when the driver gets
-- back into town, would be refused by a clock check -- and the food is
-- eaten, the cash is in the tin, and the till would be saying it never
-- happened.
--
-- The same holds for a bill parked at 10:55 and settled at 11:05.
--
-- So the rule is: a schedule decides what the shop OFFERS. What was
-- sold is what was sold. `pos_menu` marks a dish unavailable and says
-- why, the till greys the tile, and nothing downstream changes.
--
-- ---------------------------------------------------------------------
-- Greyed and explained, not hidden
--
-- A dish that vanishes reads as a broken menu; a dish greyed out with
-- "from 07:00" under it reads as a shop with a breakfast menu. The
-- second is also the only one a cashier can answer a customer from.
--
-- ---------------------------------------------------------------------
-- A schedule is a thing, not a pair of columns on an item
--
-- Times on the item itself would mean typing 07:00-11:00 forty times
-- and getting it wrong once. A schedule is named, and dishes are
-- attached to it: change breakfast to half past eleven and forty
-- dishes move together.
--
-- An item on no schedule is always on -- the same empty-means-always
-- rule the promotions in 0256 use. An item on several is on when ANY
-- of them is open, because "breakfast, and also all day on Sunday" is
-- two rules and both of them say yes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Is a window open right now
-- ---------------------------------------------------------------------
--
-- Pulled out as its own function because three features now ask the
-- same question in the same shop's own time, and the case that gets
-- written wrong every time is the one that crosses midnight: a bar
-- open "ten till two" is open at one in the morning, and a naive
-- BETWEEN says it is shut.
create or replace function app.pos_window_open(
  p_weekdays smallint[],
  p_from     time,
  p_to       time,
  p_on_from  date default null,
  p_on_to    date default null,
  p_at       timestamptz default null)
returns boolean
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare
  v_now  timestamp := (coalesce(p_at, now()) at time zone 'Asia/Kuala_Lumpur');
  v_date date := v_now::date;
  v_time time := v_now::time;
begin
  if p_on_from is not null and v_date < p_on_from then return false; end if;
  if p_on_to   is not null and v_date > p_on_to   then return false; end if;

  -- ISO: Monday is 1, Sunday is 7. `extract(dow)` makes Sunday 0,
  -- which is the off-by-one every weekday filter is written around.
  if p_weekdays is not null and array_length(p_weekdays, 1) is not null
     and not (extract(isodow from v_now)::smallint = any (p_weekdays)) then
    return false;
  end if;

  if p_from is null or p_to is null then
    return true;
  end if;
  if p_from <= p_to then
    return v_time >= p_from and v_time <= p_to;
  end if;
  -- Crosses midnight: open after the start OR before the end.
  return v_time >= p_from or v_time <= p_to;
end;
$$;

revoke all on function app.pos_window_open(
  smallint[], time, time, date, date, timestamptz) from public, anon;
grant execute on function app.pos_window_open(
  smallint[], time, time, date, date, timestamptz) to authenticated;

comment on function app.pos_window_open(smallint[], time, time, date, date, timestamptz) is
  'Whether a recurring window is open, in Asia/Kuala_Lumpur. Nulls mean always. A start later than the end crosses midnight, which is what a late bar means by "ten till two".';

-- ---------------------------------------------------------------------
-- The schedules themselves
-- ---------------------------------------------------------------------
create table if not exists public.pos_menu_schedules (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  name       text not null,

  -- Every one of these is null-means-always, so "the breakfast menu"
  -- is a name and two times.
  weekdays   smallint[],
  starts_at  time,
  ends_at    time,
  starts_on  date,
  ends_on    date,

  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint pos_menu_schedules_window_ck check (
    (starts_at is null) = (ends_at is null))
);

create index if not exists pos_menu_schedules_org_idx
  on public.pos_menu_schedules (org_id, is_active);

create table if not exists public.pos_menu_schedule_items (
  schedule_id uuid not null references public.pos_menu_schedules (id) on delete cascade,
  item_id     uuid not null references public.items (id) on delete cascade,
  primary key (schedule_id, item_id)
);

create index if not exists pos_menu_schedule_items_item_idx
  on public.pos_menu_schedule_items (item_id);

comment on table public.pos_menu_schedules is
  'When a group of dishes is offered. Named rather than typed onto each item, so moving breakfast to half past eleven moves forty dishes together.';

-- ---------------------------------------------------------------------
-- Eighty-sixing a dish
-- ---------------------------------------------------------------------
--
-- Per outlet and per trading day, because the branch running out of
-- ayam is not the same shop as the one that has plenty, and because
-- tomorrow it is back. No end date to forget to clear: the row belongs
-- to today and today ends.
create table if not exists public.pos_item_stops (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,
  item_id    uuid not null references public.items (id) on delete cascade,
  on_date    date not null,
  reason     text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (outlet_id, item_id, on_date)
);

create index if not exists pos_item_stops_today_idx
  on public.pos_item_stops (outlet_id, on_date);

comment on table public.pos_item_stops is
  'Dishes the kitchen has run out of, per outlet per trading day. No end date to forget to clear — the row belongs to today, and today ends.';

-- ---------------------------------------------------------------------
-- Why a dish is off, or null when it is on
-- ---------------------------------------------------------------------
--
-- A sentence rather than a boolean, for the same reason
-- `pos_promo_blocked` returns one: the counter has to say it out loud.
-- "Sold out" and "from 07:00" are different answers to the customer.
create or replace function app.pos_item_off(
  p_item   uuid,
  p_outlet uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_stop text;
  v_n    integer;
  v_when text;
begin
  -- The kitchen's answer beats the timetable's: a dish that is both
  -- out of season and sold out is sold out, which is the more useful
  -- half to hear.
  select coalesce(nullif(btrim(coalesce(s.reason, '')), ''), 'Sold out')
    into v_stop
    from public.pos_item_stops s
   where s.outlet_id = p_outlet and s.item_id = p_item and s.on_date = v_date;
  if v_stop is not null then
    return v_stop;
  end if;

  select count(*)::integer into v_n
    from public.pos_menu_schedule_items si
    join public.pos_menu_schedules sc on sc.id = si.schedule_id
   where si.item_id = p_item and sc.is_active;

  -- On no schedule at all is always on. Empty means always, the same
  -- rule the promotions use.
  if v_n = 0 then
    return null;
  end if;

  if exists (
    select 1
      from public.pos_menu_schedule_items si
      join public.pos_menu_schedules sc on sc.id = si.schedule_id
     where si.item_id = p_item
       and sc.is_active
       and app.pos_window_open(sc.weekdays, sc.starts_at, sc.ends_at,
                               sc.starts_on, sc.ends_on)
  ) then
    return null;
  end if;

  -- Off, so say when it comes back. The earliest start among the
  -- schedules it is on, which is the answer to "what time do you do
  -- breakfast" even when there are two breakfast schedules.
  select to_char(min(sc.starts_at), 'HH24:MI') into v_when
    from public.pos_menu_schedule_items si
    join public.pos_menu_schedules sc on sc.id = si.schedule_id
   where si.item_id = p_item and sc.is_active and sc.starts_at is not null;

  return case when v_when is null then 'Not on the menu today'
              else 'From ' || v_when end;
end;
$$;

revoke all on function app.pos_item_off(uuid, uuid) from public, anon;
grant execute on function app.pos_item_off(uuid, uuid) to authenticated;

comment on function app.pos_item_off(uuid, uuid) is
  'Why a dish is not being offered at this outlet right now, or null when it is. A sentence, because the counter has to say it out loud — "Sold out" and "From 07:00" are different answers to a customer.';

-- ---------------------------------------------------------------------
-- The menu, now that it knows what time it is
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0224 for two columns. Nothing is filtered out:
-- see the header — a dish that vanishes reads as a broken menu, and a
-- greyed tile saying "From 07:00" is the only version a cashier can
-- answer a customer from.
--
-- Dropped first, not `create or replace`. Postgres refuses to replace a
-- function whose OUT parameters have changed —
--
--     42P13: cannot change return type of existing function
--     DETAIL: Row type defined by OUT parameters is different.
--
-- — and two new columns is exactly that. The drop takes the grants with
-- it, so they are restated underneath rather than inherited.
drop function if exists public.pos_menu(uuid);

create function public.pos_menu(p_outlet uuid)
returns table (
  item_id     uuid,
  code        text,
  name        text,
  unit_price  numeric,
  uom_code    text,
  category_id uuid,
  category    text,
  variant_attributes jsonb,
  on_hand     numeric,
  tracks_stock boolean,
  available   boolean,
  off_reason  text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with outlet as (
    select o.org_id, o.warehouse_id
      from public.pos_outlets o
     where o.id = p_outlet
       and app.can_read_module(o.org_id, 'pos')
  )
  select i.id, i.code, i.name, i.unit_price, i.uom_code,
         i.category_id,
         -- Named rather than left null, because the client groups on
         -- this and a null heading reads as a bug rather than as a
         -- shop that never set its categories up.
         coalesce(c.name, 'Uncategorised'),
         i.variant_attributes,
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = i.id
                      and sl.warehouse_id = (select o.warehouse_id from outlet o)), 0),
         i.track_inventory,
         app.pos_item_off(i.id, p_outlet) is null,
         app.pos_item_off(i.id, p_outlet)
    from public.items i
    join outlet o on o.org_id = i.org_id
    left join public.item_categories c on c.id = i.category_id
   where i.deleted_at is null
     and i.is_active
     and i.is_sold
     -- The rule `pos_sale_line_sellable` enforces. A style with
     -- variants is not a thing you can put in a bag, so it is not a
     -- thing this screen may offer.
     and not exists (select 1 from public.items v
                      where v.parent_item_id = i.id and v.deleted_at is null)
   order by coalesce(c.name, 'Uncategorised'), i.name;
$$;

revoke all on function public.pos_menu(uuid) from public, anon;
grant execute on function public.pos_menu(uuid) to authenticated;

comment on function public.pos_menu(uuid) is
  'Everything an outlet can sell, with whether it is being offered right now and why not. Nothing is filtered out: a dish that vanishes reads as a broken menu, and a greyed tile saying "From 07:00" is the only version a cashier can answer a customer from.';

-- ---------------------------------------------------------------------
-- Writing a schedule down
-- ---------------------------------------------------------------------
--
-- The rule and the dishes on it in one call, for the reason 0256 gives:
-- a shop that saved "breakfast, 7 till 11" and then failed to save
-- which dishes would have published a schedule governing nothing, and
-- would have found out at eleven o'clock.
create or replace function public.upsert_pos_menu_schedule(
  p_org       uuid,
  p_name      text,
  p_weekdays  smallint[] default null,
  p_starts_at time    default null,
  p_ends_at   time    default null,
  p_starts_on date    default null,
  p_ends_on   date    default null,
  p_items     uuid[]  default null,
  p_id        uuid    default null,
  p_is_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A schedule needs a name. "Breakfast" will do.'
      using errcode = '23514';
  end if;
  if (p_starts_at is null) <> (p_ends_at is null) then
    raise exception 'An hours window needs both a start and an end.'
      using errcode = '23514';
  end if;
  if p_weekdays is not null
     and exists (select 1 from unnest(p_weekdays) d where d < 1 or d > 7) then
    raise exception 'Weekdays run from 1 (Monday) to 7 (Sunday).'
      using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.pos_menu_schedules
      (org_id, name, weekdays, starts_at, ends_at, starts_on, ends_on, is_active)
    values (p_org, btrim(p_name), p_weekdays, p_starts_at, p_ends_at,
            p_starts_on, p_ends_on, coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.pos_menu_schedules s
       set name = btrim(p_name),
           weekdays = p_weekdays,
           starts_at = p_starts_at,
           ends_at = p_ends_at,
           starts_on = p_starts_on,
           ends_on = p_ends_on,
           is_active = coalesce(p_is_active, true),
           updated_at = now()
     where s.id = p_id and s.org_id = p_org;
    if not found then
      raise exception 'No such schedule.' using errcode = 'P0002';
    end if;
    v_id := p_id;
  end if;

  -- Null leaves the list alone; an empty array clears it, which is how
  -- a schedule is emptied without deleting it.
  if p_items is not null then
    delete from public.pos_menu_schedule_items where schedule_id = v_id;
    insert into public.pos_menu_schedule_items (schedule_id, item_id)
    select v_id, i from unnest(p_items) i
    on conflict do nothing;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time, time, date, date, uuid[], uuid, boolean)
  from public, anon;
grant execute on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time, time, date, date, uuid[], uuid, boolean)
  to authenticated;

create or replace function public.retire_pos_menu_schedule(p_schedule uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select s.org_id into v_org from public.pos_menu_schedules s where s.id = p_schedule;
  if v_org is null then
    raise exception 'No such schedule.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  -- Switched off rather than deleted, so the dishes on it go back to
  -- always-on rather than losing their grouping.
  update public.pos_menu_schedules s
     set is_active = false, updated_at = now() where s.id = p_schedule;
  return p_schedule;
end;
$$;

revoke all on function public.retire_pos_menu_schedule(uuid) from public, anon;
grant execute on function public.retire_pos_menu_schedule(uuid) to authenticated;

create or replace function public.pos_menu_schedules_admin(p_org uuid)
returns table (
  id         uuid,
  name       text,
  weekdays   smallint[],
  starts_at  time,
  ends_at    time,
  starts_on  date,
  ends_on    date,
  is_active  boolean,
  item_ids   uuid[],
  dishes     integer,
  open_now   boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id, s.name, s.weekdays, s.starts_at, s.ends_at,
         s.starts_on, s.ends_on, s.is_active,
         coalesce((select array_agg(si.item_id)
                     from public.pos_menu_schedule_items si
                    where si.schedule_id = s.id), '{}'::uuid[]),
         coalesce((select count(*)::integer
                     from public.pos_menu_schedule_items si
                    where si.schedule_id = s.id), 0),
         -- Said on the row, because "is breakfast on right now" is the
         -- question somebody opens this screen to answer.
         s.is_active and app.pos_window_open(
           s.weekdays, s.starts_at, s.ends_at, s.starts_on, s.ends_on)
    from public.pos_menu_schedules s
   where s.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by s.is_active desc, s.starts_at nulls first, s.name;
$$;

grant execute on function public.pos_menu_schedules_admin(uuid) to authenticated;

comment on function public.pos_menu_schedules_admin(uuid) is
  'Every schedule a company has written, with how many dishes are on it and whether it is open right now — which is the question somebody opens the screen to answer.';

-- ---------------------------------------------------------------------
-- Eighty-six, and putting it back
-- ---------------------------------------------------------------------
create or replace function public.stop_pos_item(
  p_outlet uuid,
  p_item   uuid,
  p_reason text default null)
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
  -- Working the till, not configuring the company: the person who
  -- notices the ayam has run out is the person on the counter.
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;
  if not exists (select 1 from public.items i
                  where i.id = p_item and i.org_id = v_org
                    and i.deleted_at is null) then
    raise exception 'That is not a dish on this company''s list.'
      using errcode = 'P0002';
  end if;

  insert into public.pos_item_stops
    (org_id, outlet_id, item_id, on_date, reason, created_by)
  values (v_org, p_outlet, p_item,
          (now() at time zone 'Asia/Kuala_Lumpur')::date,
          nullif(btrim(coalesce(p_reason, '')), ''), auth.uid())
  on conflict (outlet_id, item_id, on_date) do update
    set reason = excluded.reason, created_by = excluded.created_by
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.stop_pos_item(uuid, uuid, text) from public, anon;
grant execute on function public.stop_pos_item(uuid, uuid, text) to authenticated;

comment on function public.stop_pos_item(uuid, uuid, text) is
  'Takes a dish off today at one outlet. Guarded on writing the till rather than configuring the company: the person who notices the ayam has run out is the person on the counter.';

create or replace function public.resume_pos_item(
  p_outlet uuid,
  p_item   uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_n integer;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;

  delete from public.pos_item_stops s
   where s.outlet_id = p_outlet and s.item_id = p_item
     and s.on_date = (now() at time zone 'Asia/Kuala_Lumpur')::date;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

revoke all on function public.resume_pos_item(uuid, uuid) from public, anon;
grant execute on function public.resume_pos_item(uuid, uuid) to authenticated;

create or replace function public.pos_stopped_items(p_outlet uuid)
returns table (
  item_id    uuid,
  code       text,
  name       text,
  reason     text,
  stopped_by text,
  stopped_at timestamptz)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select i.id, i.code, i.name,
         coalesce(nullif(btrim(coalesce(s.reason, '')), ''), 'Sold out'),
         coalesce(p.full_name, 'Somebody who has left'),
         s.created_at
    from public.pos_item_stops s
    join public.items i on i.id = s.item_id
    left join public.profiles p on p.id = s.created_by
   where s.outlet_id = p_outlet
     and s.on_date = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and app.can_read_module(s.org_id, 'pos')
   order by i.name;
$$;

grant execute on function public.pos_stopped_items(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_menu_schedules      enable row level security;
alter table public.pos_menu_schedule_items enable row level security;
alter table public.pos_item_stops          enable row level security;

create policy pos_menu_schedules_read on public.pos_menu_schedules for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy pos_menu_schedules_write on public.pos_menu_schedules for all
  to authenticated using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Guarded through the parent, which carries the org. Inventing one
-- here would be a second answer to a question already answered.
create policy pos_menu_schedule_items_all on public.pos_menu_schedule_items for all
  to authenticated
  using (exists (select 1 from public.pos_menu_schedules s
                  where s.id = schedule_id
                    and app.can_write_module(s.org_id, 'pos')))
  with check (exists (select 1 from public.pos_menu_schedules s
                       where s.id = schedule_id
                         and app.can_write_module(s.org_id, 'pos')));

create policy pos_item_stops_read on public.pos_item_stops for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policy: a stop carries the trading day and the name of who
-- called it, and both are the function's to decide.
grant select, insert, update, delete on public.pos_menu_schedules to authenticated;
grant select, insert, update, delete on public.pos_menu_schedule_items to authenticated;
grant select on public.pos_item_stops to authenticated;

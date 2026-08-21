-- =====================================================================
-- The questions a shop asks
--
-- 0214 built modifiers: the group is the question ("Pedas"), the
-- modifier is an answer ("kurang pedas", +0.00), and the till asks
-- whichever questions are attached to the dish. 0221 seeded two groups
-- for the demo warung.
--
-- Nothing else has ever written those tables. There is no function that
-- creates a group, adds an answer, or attaches a question to a dish, so
-- the only shop with modifiers is the one a migration seeded and the
-- only way to add "extra cheese" is to open a SQL console. A feature
-- reachable only by its author is not a feature.
--
-- The RLS write policies are already correct -- anyone with
-- `can_write_module(org, 'pos')` may write all three tables -- so a
-- client could in principle insert directly. Three things go wrong if
-- it does, and they are what this migration is for.
--
-- ---------------------------------------------------------------------
-- A default has to fit inside the maximum
--
-- `ModifierSheet` starts every `is_default` answer selected, which is
-- the point of a default: a "regular spice" that must be tapped every
-- time is a default in name only. Two defaults in a choose-one group
-- therefore open the sheet with two answers already chosen, and
-- `pos_modifier_max` refuses the second one at the counter, mid
-- service, to somebody who did not configure anything.
--
-- So the configuration refuses it instead. In a choose-one group,
-- making an answer the default clears the previous one in the same
-- transaction -- the same rule 0228 applies to the default counter,
-- for the same reason. In a group that takes several, a default beyond
-- the maximum is refused outright and says what the maximum is.
--
-- ---------------------------------------------------------------------
-- Retired, never deleted
--
-- `pos_sale_line_modifiers` snapshots the name and the price, so a bill
-- survives its modifier being deleted. What does not survive is
-- `modifier_id`, which is `on delete set null` -- and that column is
-- how anybody asks how many extra eggs a month sells. Deleting an
-- answer to tidy a list silently erases the history of what was
-- ordered, so nothing here deletes: `is_active` goes false, which is
-- what `item_modifier_options` already filters on.
--
-- Retiring a group leaves its `item_modifier_groups` rows alone.
-- Bringing the question back should bring back the dishes it was asked
-- about, not leave somebody to re-attach thirty of them.
--
-- ---------------------------------------------------------------------
-- Attaching states the order, not just the set
--
-- `item_modifier_groups.sort_order` decides which question is asked
-- first, and a screen handing over a list has already decided that. So
-- the attach function takes an array and writes the position, rather
-- than taking one group at a time and leaving the order to insertion
-- luck.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The question
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_modifier_group(
  p_org        uuid,
  p_code       text,
  p_name       text,
  p_min_select integer default 0,
  p_max_select integer default null,
  p_id         uuid    default null,
  p_sort_order integer default 0,
  p_is_active  boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id       uuid;
  v_defaults integer;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_code, '')), '') is null
     or nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A question needs a code and a name.'
      using errcode = '23514';
  end if;
  if coalesce(p_min_select, 0) < 0 then
    raise exception 'A question cannot ask for fewer than none.'
      using errcode = '23514';
  end if;
  if p_max_select is not null and p_max_select < 1 then
    raise exception
      'A maximum of none is a question nobody can answer. Leave it '
      'empty for "as many as you like".'
      using errcode = '23514';
  end if;
  if p_max_select is not null and p_max_select < coalesce(p_min_select, 0) then
    raise exception 'At least % but at most % is not a rule.',
      p_min_select, p_max_select using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.pos_modifier_groups
      (org_id, code, name, min_select, max_select, sort_order, is_active)
    values (p_org, btrim(p_code), btrim(p_name),
            coalesce(p_min_select, 0), p_max_select,
            coalesce(p_sort_order, 0), coalesce(p_is_active, true))
    returning id into v_id;
    return v_id;
  end if;

  -- Tightening the maximum below the answers already ticked by default
  -- would leave every plate opening the sheet over the limit. Said
  -- here, where somebody can fix it, rather than at the counter.
  if p_max_select is not null then
    select count(*) into v_defaults
      from public.pos_modifiers m
     where m.group_id = p_id and m.is_default and m.is_active;
    if v_defaults > p_max_select then
      raise exception
        'That question has % answers ticked by default and you are '
        'capping it at %. Untick one first.',
        v_defaults, p_max_select
        using errcode = '23514';
    end if;
  end if;

  update public.pos_modifier_groups g
     set code       = btrim(p_code),
         name       = btrim(p_name),
         min_select = coalesce(p_min_select, g.min_select),
         max_select = p_max_select,
         sort_order = coalesce(p_sort_order, g.sort_order),
         is_active  = coalesce(p_is_active, g.is_active)
   where g.id = p_id and g.org_id = p_org;
  if not found then
    raise exception 'No such question.' using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;

revoke all on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean)
  from public, anon;
grant execute on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean)
  to authenticated;

comment on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean) is
  'Creates or renames a modifier group -- the question a dish comes with. Refuses a maximum below the number of answers already ticked by default, because the till starts those selected.';

-- ---------------------------------------------------------------------
-- Stop asking it
-- ---------------------------------------------------------------------
--
-- Returns how many dishes stop being asked, so the confirmation can say
-- what it is about to do rather than "are you sure".
create or replace function public.retire_pos_modifier_group(p_group uuid)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_group public.pos_modifier_groups;
  v_items integer;
begin
  select * into v_group from public.pos_modifier_groups where id = p_group;
  if v_group.id is null then
    raise exception 'No such question.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_group.org_id, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  select count(*) into v_items
    from public.item_modifier_groups img where img.group_id = p_group;

  -- The attachments stay. Bringing a question back should bring back
  -- the dishes it was asked about; re-attaching thirty by hand is not
  -- an undo.
  update public.pos_modifier_groups g
     set is_active = false
   where g.id = p_group;
  return v_items;
end;
$$;

revoke all on function public.retire_pos_modifier_group(uuid) from public, anon;
grant execute on function public.retire_pos_modifier_group(uuid) to authenticated;

comment on function public.retire_pos_modifier_group(uuid) is
  'Stops a question being asked, and says how many dishes that affects. The attachments are kept so bringing it back brings the menu wiring with it.';

-- ---------------------------------------------------------------------
-- One answer
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_modifier(
  p_group       uuid,
  p_code        text,
  p_name        text,
  p_price_delta numeric default 0,
  p_id          uuid    default null,
  p_is_default  boolean default false,
  p_sort_order  integer default 0,
  p_is_active   boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_group    public.pos_modifier_groups;
  v_id       uuid;
  v_defaults integer;
begin
  select * into v_group from public.pos_modifier_groups where id = p_group;
  if v_group.id is null then
    raise exception 'No such question.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_group.org_id, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_code, '')), '') is null
     or nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'An answer needs a code and a name.'
      using errcode = '23514';
  end if;

  if coalesce(p_is_default, false) and coalesce(p_is_active, true) then
    if v_group.max_select = 1 then
      -- Choose-one: making this the default is saying the other one is
      -- not, and doing it in two calls leaves a moment with two.
      update public.pos_modifiers m
         set is_default = false
       where m.group_id = p_group
         and m.is_default
         and m.id is distinct from p_id;
    elsif v_group.max_select is not null then
      select count(*) into v_defaults
        from public.pos_modifiers m
       where m.group_id = p_group and m.is_default and m.is_active
         and m.id is distinct from p_id;
      if v_defaults + 1 > v_group.max_select then
        raise exception
          '% takes at most % and already has % ticked by default.',
          v_group.name, v_group.max_select, v_defaults
          using errcode = '23514';
      end if;
    end if;
  end if;

  if p_id is null then
    insert into public.pos_modifiers
      (org_id, group_id, code, name, price_delta, is_default, sort_order,
       is_active)
    values (v_group.org_id, p_group, btrim(p_code), btrim(p_name),
            coalesce(p_price_delta, 0), coalesce(p_is_default, false),
            coalesce(p_sort_order, 0), coalesce(p_is_active, true))
    returning id into v_id;
    return v_id;
  end if;

  update public.pos_modifiers m
     set code        = btrim(p_code),
         name        = btrim(p_name),
         price_delta = coalesce(p_price_delta, m.price_delta),
         is_default  = coalesce(p_is_default, m.is_default),
         sort_order  = coalesce(p_sort_order, m.sort_order),
         is_active   = coalesce(p_is_active, m.is_active)
   where m.id = p_id and m.group_id = p_group;
  if not found then
    raise exception 'No such answer to that question.'
      using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;

revoke all on function public.upsert_pos_modifier(
  uuid, text, text, numeric, uuid, boolean, integer, boolean)
  from public, anon;
grant execute on function public.upsert_pos_modifier(
  uuid, text, text, numeric, uuid, boolean, integer, boolean)
  to authenticated;

comment on function public.upsert_pos_modifier(
  uuid, text, text, numeric, uuid, boolean, integer, boolean) is
  'Creates or edits one answer to a modifier group. The price is signed: extra egg is positive, no cucumber is nought, a smaller portion is negative.';

-- ---------------------------------------------------------------------
-- Take an answer off the menu
-- ---------------------------------------------------------------------
create or replace function public.retire_pos_modifier(p_modifier uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_mod public.pos_modifiers;
begin
  select * into v_mod from public.pos_modifiers where id = p_modifier;
  if v_mod.id is null then
    raise exception 'No such answer.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_mod.org_id, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- Not deleted. See the header: the bill keeps its snapshot either
  -- way, but `modifier_id` is what "how many extra eggs" reads, and
  -- deleting nulls it.
  update public.pos_modifiers m
     set is_active = false, is_default = false
   where m.id = p_modifier;
  return p_modifier;
end;
$$;

revoke all on function public.retire_pos_modifier(uuid) from public, anon;
grant execute on function public.retire_pos_modifier(uuid) to authenticated;

comment on function public.retire_pos_modifier(uuid) is
  'Takes one answer off the menu without deleting it, so what was ordered on it stays answerable.';

-- ---------------------------------------------------------------------
-- Which questions this dish comes with
-- ---------------------------------------------------------------------
--
-- The whole set at once, in the order given. Returns how many are now
-- attached.
create or replace function public.set_item_modifier_groups(
  p_item   uuid,
  p_groups uuid[] default '{}')
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org  uuid;
  v_list uuid[];
  v_bad  integer;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- Duplicates collapse rather than raise: a list is a set here, and a
  -- screen that sends the same group twice meant it once.
  select coalesce(array_agg(distinct g), '{}') into v_list
    from unnest(coalesce(p_groups, '{}'::uuid[])) g
   where g is not null;

  select count(*) into v_bad
    from unnest(v_list) g
   where not exists (select 1 from public.pos_modifier_groups mg
                      where mg.id = g and mg.org_id = v_org);
  if v_bad > 0 then
    raise exception 'That question belongs to another company.'
      using errcode = '23514';
  end if;

  delete from public.item_modifier_groups img
   where img.item_id = p_item
     and not (img.group_id = any (coalesce(p_groups, '{}'::uuid[])));

  insert into public.item_modifier_groups (org_id, item_id, group_id, sort_order)
  select v_org, p_item, g.id, g.ord
    from unnest(coalesce(p_groups, '{}'::uuid[])) with ordinality as g(id, ord)
   where g.id is not null
  on conflict (item_id, group_id)
    do update set sort_order = excluded.sort_order;

  return coalesce(array_length(v_list, 1), 0);
end;
$$;

revoke all on function public.set_item_modifier_groups(uuid, uuid[])
  from public, anon;
grant execute on function public.set_item_modifier_groups(uuid, uuid[])
  to authenticated;

comment on function public.set_item_modifier_groups(uuid, uuid[]) is
  'Sets which questions a dish is sold with, in the order they will be asked. The array is the whole answer: anything not in it is detached.';

-- ---------------------------------------------------------------------
-- What a shop has
-- ---------------------------------------------------------------------
--
-- Retired groups are included. A list that hid them would leave
-- somebody re-creating a question that already exists under a code they
-- cannot use, and there is no way back from a retirement you cannot
-- see.
create or replace function public.pos_modifier_groups_admin(p_org uuid)
returns table (
  id           uuid,
  code         text,
  name         text,
  min_select   integer,
  max_select   integer,
  sort_order   integer,
  is_active    boolean,
  option_count integer,
  item_count   integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select g.id, g.code, g.name, g.min_select, g.max_select, g.sort_order,
         g.is_active,
         (select count(*)::integer from public.pos_modifiers m
           where m.group_id = g.id and m.is_active),
         (select count(*)::integer from public.item_modifier_groups img
           where img.group_id = g.id)
    from public.pos_modifier_groups g
   where g.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by g.is_active desc, g.sort_order, g.name;
$$;

grant execute on function public.pos_modifier_groups_admin(uuid) to authenticated;

comment on function public.pos_modifier_groups_admin(uuid) is
  'Every modifier group a company has, retired ones included, with how many answers it holds and how many dishes ask it.';

create or replace function public.pos_modifier_options_admin(p_group uuid)
returns table (
  id          uuid,
  code        text,
  name        text,
  price_delta numeric,
  is_default  boolean,
  sort_order  integer,
  is_active   boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select m.id, m.code, m.name, m.price_delta, m.is_default, m.sort_order,
         m.is_active
    from public.pos_modifiers m
    join public.pos_modifier_groups g on g.id = m.group_id
   where m.group_id = p_group
     and app.can_read_module(g.org_id, 'pos')
   order by m.is_active desc, m.sort_order, m.name;
$$;

grant execute on function public.pos_modifier_options_admin(uuid) to authenticated;

comment on function public.pos_modifier_options_admin(uuid) is
  'The answers to one modifier group, retired ones last, for the screen that edits them.';

-- The attachments for one dish, in the order they are asked. Separate
-- from `item_modifier_options`, which is the till's question and
-- returns only what is live and answerable.
create or replace function public.item_modifier_group_ids(p_item uuid)
returns table (group_id uuid, group_name text, is_active boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select g.id, g.name, g.is_active
    from public.item_modifier_groups img
    join public.pos_modifier_groups g on g.id = img.group_id
   where img.item_id = p_item
     and app.can_read_module(img.org_id, 'pos')
   order by img.sort_order, g.name;
$$;

grant execute on function public.item_modifier_group_ids(uuid) to authenticated;

comment on function public.item_modifier_group_ids(uuid) is
  'Which questions a dish is currently sold with, retired ones included, so the editor shows what is actually attached.';

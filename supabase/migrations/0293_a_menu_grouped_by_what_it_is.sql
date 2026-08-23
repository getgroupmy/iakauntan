-- ---------------------------------------------------------------------
-- The menu, grouped by module, and the names on it
--
-- The side menu is one flat list of every door a company holds. With
-- three modules that is a menu; with fifteen it is a wall, and the
-- ordering — which is the order the destinations happen to be declared
-- in — means nothing to the person reading it.
--
-- Two things were missing to fix that, and neither is a screen.
--
-- ## What a module is called, and what it sits under
--
-- `platform_modules.name` has always been editable in principle and
-- never in practice: 0292 gave it a saver, and this adds `nav_group`
-- beside it. The group is a label, not a foreign key, because the
-- grouping a platform wants is a marketing decision that changes more
-- often than a schema should — "Sell", "Buy", "People", "Money" today
-- and something else after the next positioning exercise.
--
-- A module with no group falls under its own name, which is what the
-- menu did before this and is a reasonable thing for it to keep doing.
--
-- ## Whether to group at all
--
-- A platform setting rather than a per-company one. It is a decision
-- about how the product presents itself, the same kind of decision as
-- the colours and the wordmark, and a company that could choose would
-- have to be told what the choice meant.
--
-- It lives in `platform_settings`, which already exists for exactly
-- this and is already readable by any signed-in user — which is the
-- right audience, because only somebody signed in has a menu. The
-- landing page's singleton would have been the wrong home: that row is
-- what an unauthenticated visitor may read, and how the menu behind the
-- sign-in is arranged is none of a stranger's business.
-- ---------------------------------------------------------------------

alter table public.platform_modules
  add column if not exists nav_group text;

comment on column public.platform_modules.nav_group is
  'Heading the module''s destinations sit under when the menu is grouped. '
  'A label rather than a key: the grouping is a presentation decision.';

insert into public.platform_settings (key, value, description)
values (
  'nav_grouping',
  jsonb_build_object('mode', 'flat'),
  'How the side menu is arranged: "flat" for one list of every '
  'destination, "by_module" to gather them under module headings.')
on conflict (key) do nothing;

-- 0292's saver, extended by one field. Same rule as the rest of it:
-- null leaves what is stored alone, so renaming a module cannot blank
-- the group it sits under.
create or replace function public.platform_save_module(
  p_code text,
  p_name text default null,
  p_description text default null,
  p_monthly_price numeric default null,
  p_is_core boolean default null,
  p_sort_order integer default null,
  p_is_active boolean default null,
  p_nav_group text default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_code text := lower(btrim(coalesce(p_code, '')));
begin
  if not app.is_platform_admin() then
    raise exception 'Module prices are what every organization is billed and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'A module needs a code' using errcode = '23514';
  end if;
  if p_monthly_price is not null and p_monthly_price < 0 then
    raise exception 'A module cannot cost less than nothing, got %',
      p_monthly_price using errcode = '23514';
  end if;

  if not exists (select 1 from public.platform_modules where code = v_code) then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A new module needs a name' using errcode = '23514';
    end if;
    insert into public.platform_modules
      (code, name, description, monthly_price, is_core, sort_order, is_active,
       nav_group)
    values (v_code, btrim(p_name), p_description,
            coalesce(p_monthly_price, 0), coalesce(p_is_core, false),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.platform_modules)),
            coalesce(p_is_active, true), nullif(btrim(p_nav_group), ''));
    return v_code;
  end if;

  update public.platform_modules m set
    name          = coalesce(nullif(btrim(p_name), ''), m.name),
    description   = coalesce(p_description, m.description),
    monthly_price = coalesce(p_monthly_price, m.monthly_price),
    is_core       = coalesce(p_is_core, m.is_core),
    sort_order    = coalesce(p_sort_order, m.sort_order),
    is_active     = coalesce(p_is_active, m.is_active),
    nav_group     = coalesce(nullif(btrim(p_nav_group), ''), m.nav_group)
   where m.code = v_code;

  return v_code;
end;
$$;

-- The old signature would otherwise sit beside the new one, and a
-- caller passing seven arguments would reach a function that knows
-- nothing about groups.
drop function if exists public.platform_save_module(
  text, text, text, numeric, boolean, integer, boolean);

grant execute on function public.platform_save_module(
  text, text, text, numeric, boolean, integer, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- 0234  A company that only does one thing
-- ---------------------------------------------------------------------
--
-- A firm that bought Service Desk and nothing else signs in and is shown
-- Sales, Expenses, Collections, Receipts & payments, Reconcile, Fixed
-- assets, Journals, Recurring journals, Recurring invoices, Withholding
-- tax, Salespeople, Exchange rates and Reports -- nineteen destinations
-- that carry no `module` tag at all and so are shown to everybody -- and
-- a dashboard whose four figures are revenue, expenses, receivables and
-- bank balance, all of them zero. The one screen they pay for is the
-- twentieth item in the list.
--
-- Nineteen of those are fixed by tagging the destination, which is
-- client work. The interesting half is the three that cannot be tagged
-- away: `sales`, `accounting` and `contacts` are `is_core`, and 0232
-- makes core mean "reachable, always, without a row". Tagging Sales with
-- `sales` changes nothing while `sales` is core.
--
-- ## Hiding is a preference, and must never be mistaken for a permission
--
-- So this migration adds a second, weaker idea alongside entitlement.
--
--   * **Entitled** -- the company holds the module. `app.has_module`,
--     unchanged: core, or a live `org_modules` row. This is what the
--     policies and the `app.can_*_module` guards ask, and it is the only
--     thing that decides whether a call succeeds.
--   * **Visible** -- entitled, and the company has not put it away.
--     A preference about the shape of the workspace. Nothing reads it
--     except the navigation and the dashboard.
--
-- The distinction is the whole point, and it runs one way only: hiding
-- can take a door off the wall, it can never open one. A company that
-- hides `accounting` still has its ledger, tickets still post to it, and
-- the API still answers. A company that has not bought `payroll` still
-- cannot call `post_payroll_run`, however its preferences read. That is
-- why `set_module_hidden` writes `is_hidden` and never `is_enabled`.
--
-- ## Why a core module gets a row that says is_enabled = false
--
-- 0232's header says core modules "have no rows and never will", and for
-- entitlement that stays true: `app.has_module` and `app.module_access`
-- both answer core on the flag in `platform_modules` and never look for
-- a row. But a preference has to be written down somewhere, and the
-- natural place is the table that already holds one row per company per
-- module. So hiding a core module inserts one, with `is_enabled = false`
-- -- which is exactly what a core module's row has always meant: nothing
-- at all. Entitlement is unaffected because nothing asks the row.
--
-- ## What the dashboard does instead
--
-- `public.module_dashboard` returns one JSON object per visible module
-- that has figures worth a card, and omits the rest. A service desk
-- company gets `ticketing`; a warung gets `pos`; a company with books
-- gets neither and keeps the accounting dashboard it already had. The
-- client renders a card for each key it recognises and ignores the rest,
-- so a module added here needs no client release to stop being wrong --
-- it just needs one to start being shown.

-- ---------------------------------------------------------------------
-- The preference
-- ---------------------------------------------------------------------
alter table public.org_modules
  add column if not exists is_hidden boolean not null default false;

comment on column public.org_modules.is_hidden is
  'A preference, not a permission. True means this company has asked not '
  'to see the module in its navigation or dashboard. Entitlement is '
  'unaffected: app.has_module and app.module_access never read this '
  'column, so hiding a module cannot block an API call and un-hiding one '
  'cannot grant access to a module the company never bought.';

-- ---------------------------------------------------------------------
-- Visible = entitled, and not put away
-- ---------------------------------------------------------------------
create or replace function app.module_visible(p_org_id uuid, p_module text)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select app.has_module(p_org_id, p_module)
     and not coalesce(
           (select om.is_hidden
              from public.org_modules om
             where om.org_id = p_org_id
               and om.module_code = p_module),
           false);
$$;

grant execute on function app.module_visible(uuid, text) to authenticated;

comment on function app.module_visible(uuid, text) is
  'Whether a module belongs on this company''s navigation. Entitlement '
  'and preference together. Never used as a guard -- app.can_read_module '
  'and app.can_write_module remain the only things that decide access.';

-- ---------------------------------------------------------------------
-- Everything the settings screen and the navigation need, in one call
-- ---------------------------------------------------------------------
create or replace function public.org_module_surface(p_org_id uuid)
returns table (
  module_code   text,
  name          text,
  description   text,
  is_core       boolean,
  monthly_price numeric,
  sort_order    integer,
  entitled      boolean,
  hidden        boolean,
  visible       boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if p_org_id is null or not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  return query
    select pm.code,
           pm.name,
           pm.description,
           pm.is_core,
           pm.monthly_price,
           pm.sort_order,
           app.has_module(p_org_id, pm.code),
           coalesce(om.is_hidden, false),
           app.module_visible(p_org_id, pm.code)
      from public.platform_modules pm
      left join public.org_modules om
             on om.org_id = p_org_id
            and om.module_code = pm.code
     where pm.is_active
     order by pm.sort_order, pm.code;
end;
$$;

grant execute on function public.org_module_surface(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Putting a module away, and taking it out again
-- ---------------------------------------------------------------------
create or replace function public.set_module_hidden(
  p_org_id uuid,
  p_module text,
  p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_known boolean;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or an admin can change what this company uses'
      using errcode = '42501';
  end if;

  select true into v_known
    from public.platform_modules pm
   where pm.code = p_module and pm.is_active;

  if v_known is null then
    raise exception 'No such module: %', p_module using errcode = '22023';
  end if;

  -- You cannot put away something you were never given. The test has to
  -- be entitlement rather than whether a row happens to exist: 0233's
  -- backfill left `is_enabled = false` rows on companies that do not
  -- hold the module, and a "no row" test let those straight through --
  -- which is exactly what the production probe caught.
  if not app.has_module(p_org_id, p_module) then
    raise exception 'This company does not have %', p_module
      using errcode = '42501';
  end if;

  -- Only the preference moves. `is_enabled` is entitlement and is not
  -- this function's to write, which is what keeps hiding from ever
  -- becoming a grant.
  update public.org_modules
     set is_hidden = p_hidden
   where org_id = p_org_id
     and module_code = p_module;

  if not found then
    -- Entitled with no row at all, which only a core module can be. It
    -- gets one now, purely to carry the preference: `is_enabled = false`
    -- is what a core module's row has always meant, and entitlement goes
    -- on reading platform_modules.is_core.
    insert into public.org_modules (org_id, module_code, is_enabled, is_hidden)
    values (p_org_id, p_module, false, p_hidden);
  end if;
end;
$$;

grant execute on function public.set_module_hidden(uuid, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- A dashboard made of the modules this company actually uses
-- ---------------------------------------------------------------------
create or replace function public.module_dashboard(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_out   jsonb := '{}'::jsonb;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if p_org_id is null or not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  -- Service desk. "Breaching" is the queue somebody has to look at
  -- before lunch: already past its resolution deadline, or inside the
  -- last four hours of it.
  if app.module_visible(p_org_id, 'ticketing')
     and app.can_read_module(p_org_id, 'ticketing')
  then
    v_out := v_out || jsonb_build_object('ticketing', (
      select jsonb_build_object(
        'open',        count(*) filter (
                         where t.status in ('new','open','pending','on_hold')),
        'unassigned',  count(*) filter (
                         where t.assignee_id is null
                           and t.status in ('new','open')),
        'breaching',   count(*) filter (
                         where t.status in ('new','open','pending','on_hold')
                           and t.resolution_due_at is not null
                           and t.resolution_due_at < now() + interval '4 hours'),
        'breached',    count(*) filter (
                         where t.status in ('new','open','pending','on_hold')
                           and t.resolution_breached),
        'resolved_today', count(*) filter (
                         where t.resolved_at is not null
                           and (t.resolved_at at time zone 'Asia/Kuala_Lumpur')::date
                               = v_today))
        from public.tickets t
       where t.org_id = p_org_id
         and t.deleted_at is null));
  end if;

  -- Point of sale. Today's takings as rung up, plus what is still open
  -- on a table somewhere.
  if app.module_visible(p_org_id, 'pos')
     and app.can_read_module(p_org_id, 'pos')
  then
    v_out := v_out || jsonb_build_object('pos', (
      select jsonb_build_object(
        'takings_today', coalesce(sum(s.total_amount) filter (
                           where s.status = 'completed'
                             and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
                                 = v_today), 0),
        'sales_today',   count(*) filter (
                           where s.status = 'completed'
                             and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
                                 = v_today),
        'open_bills',    count(*) filter (where s.status = 'parked'),
        'open_shifts',   (select count(*) from public.pos_shifts sh
                           where sh.org_id = p_org_id and sh.status = 'open'))
        from public.pos_sales s
       where s.org_id = p_org_id));
  end if;

  return v_out;
end;
$$;

grant execute on function public.module_dashboard(uuid) to authenticated;

comment on function public.module_dashboard(uuid) is
  'One object per visible module that has figures worth a card. A key is '
  'present only when the company holds the module, has not hidden it, and '
  'the person asking may read it -- so an empty object is a company whose '
  'dashboard is the accounting one.';

-- =====================================================================
-- iAkauntan :: what a company sees, and what it may do
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/module_surface.sql
--
-- 0234 puts a second, weaker idea next to entitlement, and the whole
-- value of it is that the two never get mixed up:
--
--   * **entitled** -- the company holds the module. Decides what the API
--     answers. `app.has_module`, `app.module_access`, every policy.
--   * **visible**  -- entitled, and not put away. Decides what the
--     navigation and the dashboard show, and nothing else.
--
-- A preference that could block a call would be a permission with a
-- friendly name, and a preference that could unblock one would be a
-- licence somebody gave themselves. So the assertions below are mostly
-- about what hiding does *not* do: after a company hides `sales`, the
-- module is gone from its rail and `app.module_access` still says
-- `write`, because tickets and payroll and everything else still post to
-- the ledger.
--
-- The refusals are asserted as well as the permissions. A
-- `set_module_hidden` that accepts everything passes any test that only
-- tries the legal calls -- and the production probe for this migration
-- caught exactly that: the first version tested "is there a row" rather
-- than "is the company entitled", and 0233's backfill had left
-- `is_enabled = false` rows on companies that hold nothing of the sort,
-- so a company could put away a module it had never been sold.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A company that bought the service desk and nothing else
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid;
  v_owner    uuid;
  v_visible  int;
  v_entitled int;
begin
  v_owner := pg_temp.test_user();
  v_org   := pg_temp.test_org('Meja Bantuan Sdn Bhd', array['ticketing']);

  -- `app.seed_org_modules` hands every new company einvoice, purchases,
  -- inventory and crm switched on, so "a company that bought the service
  -- desk and nothing else" has to say so explicitly. Asserting the
  -- number without this would have been asserting the sign-up default.
  update public.org_modules set is_enabled = false
   where org_id = v_org
     and module_code in ('einvoice', 'purchases', 'inventory', 'crm');

  -- Core plus the one module bought. `sales`, `accounting` and
  -- `contacts` are core and come without a row, which is the case that
  -- makes the rest of this file worth writing.
  select count(*) filter (where entitled), count(*) filter (where visible)
    into v_entitled, v_visible
    from public.org_module_surface(v_org);

  perform pg_temp.check_eq('service desk company is entitled to 4 modules',
    v_entitled, 4);
  perform pg_temp.check_eq('and all 4 are visible to begin with',
    v_visible, 4);

  perform pg_temp.check_true('ticketing is entitled',
    (select entitled from public.org_module_surface(v_org)
      where module_code = 'ticketing'));
  perform pg_temp.check_true('payroll is not',
    not (select entitled from public.org_module_surface(v_org)
          where module_code = 'payroll'));

  -- The positive control: a count of what is absent passes vacuously if
  -- the function returned nothing at all.
  perform pg_temp.check_eq('every active module was considered',
    (select count(*)::int from public.org_module_surface(v_org)),
    (select count(*)::int from public.platform_modules where is_active));
end;
$$;

-- ---------------------------------------------------------------------
-- Putting a core module away takes it off the rail and nothing else
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid;
begin
  v_owner := pg_temp.test_user();
  v_org   := pg_temp.test_org('Meja Bantuan Dua Sdn Bhd', array['ticketing']);

  perform pg_temp.check_true('sales starts visible',
    app.module_visible(v_org, 'sales'));

  perform public.set_module_hidden(v_org, 'sales', true);

  perform pg_temp.check_true('sales is off the rail',
    not app.module_visible(v_org, 'sales'));

  -- The four assertions this file exists for.
  perform pg_temp.check_true('...but the company still holds it',
    app.has_module(v_org, 'sales'));
  perform pg_temp.check_eq('...and the API still answers',
    app.module_access(v_org, 'sales')::text, 'write');
  perform pg_temp.check_true('...and it still reads',
    app.can_read_module(v_org, 'sales'));
  perform pg_temp.check_true('...and it still writes',
    app.can_write_module(v_org, 'sales'));

  -- A core module has no row until a preference needs one. The row that
  -- appears says `is_enabled = false`, which is what a core module's row
  -- has always meant, and entitlement is unmoved by it.
  perform pg_temp.check_eq('the row written for the preference is not an entitlement',
    (select is_enabled::text from public.org_modules
      where org_id = v_org and module_code = 'sales'), 'false');

  perform public.set_module_hidden(v_org, 'sales', false);
  perform pg_temp.check_true('and it comes back',
    app.module_visible(v_org, 'sales'));
end;
$$;

-- ---------------------------------------------------------------------
-- Hiding is not a grant, and cannot be turned into one
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_failed boolean;
begin
  v_org := pg_temp.test_org('Meja Bantuan Tiga Sdn Bhd', array['ticketing']);

  -- 0233's backfill leaves is_enabled = false rows about, so the test
  -- inside set_module_hidden has to be entitlement rather than the
  -- presence of a row. Plant one and prove it changes nothing.
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'payroll', false)
  on conflict (org_id, module_code) do update set is_enabled = false;

  v_failed := false;
  begin
    perform public.set_module_hidden(v_org, 'payroll', true);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('a module the company never bought cannot be hidden',
    v_failed);

  -- And the row it did not write is still not an entitlement.
  perform pg_temp.check_true('payroll is still not held',
    not app.has_module(v_org, 'payroll'));
  perform pg_temp.check_eq('payroll still answers none',
    app.module_access(v_org, 'payroll')::text, 'none');

  v_failed := false;
  begin
    perform public.set_module_hidden(v_org, 'no_such_module', true);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('an invented module code is refused', v_failed);

  -- Somebody else's company.
  v_other := pg_temp.another_user('outsider-modules@iakauntan.test');
  perform pg_temp.sign_in_as(v_other);

  v_failed := false;
  begin
    perform public.org_module_surface(v_org);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('an outsider cannot read the surface', v_failed);

  v_failed := false;
  begin
    perform public.set_module_hidden(v_org, 'ticketing', true);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('an outsider cannot hide anything', v_failed);

  v_failed := false;
  begin
    perform public.module_dashboard(v_org);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('an outsider gets no dashboard', v_failed);
end;
$$;

-- ---------------------------------------------------------------------
-- A dashboard made of the modules the company actually uses
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_team uuid;
  v_cat  uuid;
  v_open uuid;
  v_done uuid;
  v_dash jsonb;
begin
  v_org := pg_temp.test_org('Meja Bantuan Empat Sdn Bhd', array['ticketing']);

  insert into public.ticket_teams (org_id, code, name, is_default)
  values (v_org, 'SVC', 'Service Desk', true) returning id into v_team;
  insert into public.ticket_categories (org_id, code, name, team_id)
  values (v_org, 'GEN', 'General', v_team) returning id into v_cat;

  -- Raised through the real entry point rather than inserted. `tickets`
  -- has a not-null `ticket_no` that only `create_ticket` fills, and the
  -- SLA clock, the routing and the event history all hang off it -- a
  -- hand-written row would be a ticket in no state the application can
  -- produce.
  v_open := public.create_ticket(v_org, 'Printer down', null, 'GEN', 'p2', 'incident');
  perform public.transition_ticket(v_open, 'open');

  perform public.create_ticket(v_org, 'New starter', null, 'GEN', 'p3', 'service_request');

  v_done := public.create_ticket(v_org, 'Password', null, 'GEN', 'p3', 'service_request');
  perform public.transition_ticket(v_done, 'open');
  perform public.transition_ticket(v_done, 'resolved', 'Reset it');

  v_dash := public.module_dashboard(v_org);

  perform pg_temp.check_true('a service desk company gets a service desk card',
    v_dash ? 'ticketing');
  perform pg_temp.check_true('and not a till it does not own',
    not (v_dash ? 'pos'));
  perform pg_temp.check_eq('two tickets are open',
    (v_dash -> 'ticketing' ->> 'open')::numeric, 2);
  perform pg_temp.check_eq('both of them unassigned',
    (v_dash -> 'ticketing' ->> 'unassigned')::numeric, 2);
  perform pg_temp.check_eq('one resolved today',
    (v_dash -> 'ticketing' ->> 'resolved_today')::numeric, 1);

  -- Put the module away and the card goes with it. The tickets are
  -- untouched -- this is a preference, so the figures come straight back.
  perform public.set_module_hidden(v_org, 'ticketing', true);
  perform pg_temp.check_true('a hidden module has no card',
    not (public.module_dashboard(v_org) ? 'ticketing'));
  perform pg_temp.check_true('and the tickets are still there',
    app.can_read_module(v_org, 'ticketing'));

  perform public.set_module_hidden(v_org, 'ticketing', false);
  perform pg_temp.check_eq('and the card comes back with the same figures',
    (public.module_dashboard(v_org) -> 'ticketing' ->> 'open')::numeric, 2);
end;
$$;

-- ---------------------------------------------------------------------
-- A company with books gets neither card, and keeps its own dashboard
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org('Kedai Buku Sdn Bhd', array['purchases']);
  perform pg_temp.check_eq('no module card for a company that bought neither',
    public.module_dashboard(v_org)::text, '{}');
end;
$$;

rollback;

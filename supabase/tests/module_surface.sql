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
-- A company gets the cards its modules make, and no others
--
-- This asserted an empty object until 0300, on a company that bought
-- purchases and therefore had neither a service desk nor a till. That
-- was right about the two and wrong as a statement about the whole
-- answer: `app.seed_org_modules` hands every new company inventory
-- switched on, so the moment stock got figures this company had a stock
-- card coming — correctly, and with zeros in it, because that is what
-- it holds and what it has.
--
-- Narrowed to what it was actually saying rather than deleted. The
-- zeros are asserted too: a company entitled to a module and holding
-- nothing should get the card and four noughts, not a missing key. The
-- tab is the promise that the module is theirs; an absent one would say
-- it is not.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_dash jsonb;
begin
  v_org := pg_temp.test_org('Kedai Buku Sdn Bhd', array['purchases']);
  v_dash := public.module_dashboard(v_org);

  perform pg_temp.check_true('no service desk card for a company without one',
    not (v_dash ? 'ticketing'));
  perform pg_temp.check_true('nor a till',
    not (v_dash ? 'pos'));
  perform pg_temp.check_true('but the stock card it is entitled to',
    v_dash ? 'inventory');
  perform pg_temp.check_eq('holding nothing, and saying so',
    (v_dash -> 'inventory' ->> 'stock_value')::numeric, 0);
  perform pg_temp.check_eq('with nothing to reorder',
    (v_dash -> 'inventory' ->> 'to_reorder')::numeric, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- What the stock is worth, and what has run out
--
-- 0300's inventory figures. Three of them are counts and the fourth is
-- money, and the counts are the ones worth being careful about: the
-- view underneath has a row per item per warehouse, so a naive count
-- says the same shirt twice for being low in two places.
--
-- The fixture is built to catch exactly that. One item is low in both
-- warehouses; one is empty in one and stocked in the other; one is
-- gone from everywhere.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_wh_a  uuid;
  v_wh_b  uuid;
  v_shirt uuid;
  v_shoe  uuid;
  v_hat   uuid;
  v_dash  jsonb;
begin
  v_org := pg_temp.test_org('Kedai Stok Sdn Bhd', array['inventory']);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'A', 'Gudang A') returning id into v_wh_a;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'B', 'Gudang B') returning id into v_wh_b;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, reorder_level)
  values (v_org, 'SHIRT', 'Kemeja', 'stock', true, 'C62', 50, 20, 10)
  returning id into v_shirt;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, reorder_level)
  values (v_org, 'SHOE', 'Kasut', 'stock', true, 'C62', 90, 40, 5)
  returning id into v_shoe;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, reorder_level)
  values (v_org, 'HAT', 'Topi', 'stock', true, 'C62', 30, 10, 4)
  returning id into v_hat;

  -- The shirt is low in both warehouses: one item to reorder, not two.
  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, average_cost, value)
  values (v_org, v_shirt, v_wh_a, 3, 20, 60),
         (v_org, v_shirt, v_wh_b, 2, 20, 40),
  -- The shoe is empty in A and well stocked in B: not out of stock,
  -- because there are forty of them one warehouse over.
         (v_org, v_shoe,  v_wh_a, 0, 40, 0),
         (v_org, v_shoe,  v_wh_b, 40, 40, 1600),
  -- The hat is gone from everywhere. This is the one that is out.
         (v_org, v_hat,   v_wh_a, 0, 10, 0),
         (v_org, v_hat,   v_wh_b, 0, 10, 0);

  v_dash := public.module_dashboard(v_org);

  perform pg_temp.check_true('a company holding stock gets a stock card',
    v_dash ? 'inventory');
  perform pg_temp.check_eq('the stock is worth what the ledger carries it at',
    (v_dash -> 'inventory' ->> 'stock_value')::numeric, 1700);

  -- The two assertions this block exists for.
  --
  -- The shirt holds 5 against a level of 10 and wants reordering once,
  -- not once per warehouse. The hat holds nothing at all and wants
  -- reordering too. The shoe is the one that matters: empty in warehouse
  -- A, forty in warehouse B, and a buyer must not be sent to order it —
  -- which the view's own per-warehouse `needs_reorder` would have done,
  -- and did, until the first draft of 0300 was corrected.
  perform pg_temp.check_eq('items are pooled across warehouses to reorder',
    (v_dash -> 'inventory' ->> 'to_reorder')::numeric, 2);
  perform pg_temp.check_eq('and one is out of stock, counted the same way',
    (v_dash -> 'inventory' ->> 'out_of_stock')::numeric, 1);
  perform pg_temp.check_eq('two items are actually held',
    (v_dash -> 'inventory' ->> 'items_held')::numeric, 2);

  -- The shoe again, named on its own, because it is the whole reason
  -- the two counts pool rather than trusting the view.
  perform pg_temp.check_eq(
    'an empty shelf with a full pallet next door is not a reorder',
    (select count(*) from public.v_stock_valuation v
      where v.org_id = v_org and v.item_id = v_shoe and v.needs_reorder), 1);

  -- An item whose total sits exactly on its level is at it, and wants
  -- more. The boundary, because `<=` and `<` are one character apart and
  -- the wrong one leaves somebody short.
  update public.stock_levels set quantity = 5, value = 200
   where item_id = v_shoe and warehouse_id = v_wh_b;
  perform pg_temp.check_eq('an item sitting exactly on its level wants more',
    (public.module_dashboard(v_org) -> 'inventory' ->> 'to_reorder')::numeric, 3);

  -- A reorder level of nought means nobody set one, not "reorder always".
  update public.items set reorder_level = 0 where id = v_shirt;
  perform pg_temp.check_eq('and an item with no level set is not chased',
    (public.module_dashboard(v_org) -> 'inventory' ->> 'to_reorder')::numeric, 2);

  -- The shirt above proves nothing on its own: it holds five, so
  -- `5 <= 0` is false and it drops out whether the guard exists or not.
  -- Dropping `reorder_level > 0` from 0300 left every assertion here
  -- green until this one was added. The case that needs the guard is an
  -- item holding nothing with no level set — without it, `0 <= 0` is
  -- true and every unstocked item nobody has a level for turns up on
  -- somebody's list to reorder.
  update public.items set reorder_level = 0 where id = v_hat;
  perform pg_temp.check_eq(
    'nor an item holding nothing that nobody set a level for',
    (public.module_dashboard(v_org) -> 'inventory' ->> 'to_reorder')::numeric, 1);

  -- The same gate every other block has.
  perform public.set_module_hidden(v_org, 'inventory', true);
  perform pg_temp.check_true('a company that put stock away gets no card',
    not (public.module_dashboard(v_org) ? 'inventory'));
  perform public.set_module_hidden(v_org, 'inventory', false);
  perform pg_temp.check_true('and it comes back',
    public.module_dashboard(v_org) ? 'inventory');
end;
$$;

-- ---------------------------------------------------------------------
-- The people, and the payroll they are on
--
-- 0301. Two modules, so two blocks, and a company holding one without
-- the other is the case that says they really are separate.
--
-- The headcount boundary is the one worth the fixture: somebody serving
-- notice is employed and is about to be paid, and a dashboard that
-- dropped them would disagree with the payroll run.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_away  uuid;
  v_here  uuid;
  v_notice uuid;
  v_gone  uuid;
  v_dash  jsonb;
begin
  v_org := pg_temp.test_org('Kilang Orang Sdn Bhd', array['hr', 'payroll']);

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E1', 'Aminah', date '2020-01-01', 5000,
          date '1990-01-01', 'citizen', 'active')
  returning id into v_away;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E2', 'Bakri', date '2021-01-01', 4000,
          date '1992-01-01', 'citizen', 'probation')
  returning id into v_here;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E3', 'Chandra', date '2019-01-01', 6000,
          date '1988-01-01', 'citizen', 'notice')
  returning id into v_notice;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E4', 'Devi', date '2018-01-01', 7000,
          date '1985-01-01', 'citizen', 'resigned')
  returning id into v_gone;

  v_dash := public.module_dashboard(v_org);

  -- Three on the books: active, probation and notice. Devi has left.
  perform pg_temp.check_eq(
    'probation and notice are employment, and resignation is not',
    (v_dash -> 'hr' ->> 'headcount')::numeric, 3);

  perform pg_temp.check_eq('nobody is away yet',
    (v_dash -> 'hr' ->> 'on_leave_today')::numeric, 0);
  perform pg_temp.check_eq('and nothing is waiting to be approved',
    (v_dash -> 'hr' ->> 'leave_to_approve')::numeric, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- Who is away today, counted as people
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_p1 uuid; v_p2 uuid; v_type uuid; v_today date;
begin
  v_org := pg_temp.test_org('Kilang Cuti Sdn Bhd', array['hr']);
  v_today := (now() at time zone 'Asia/Kuala_Lumpur')::date;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E1', 'Farah', date '2020-01-01', 5000,
          date '1990-01-01', 'citizen', 'active')
  returning id into v_p1;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E2', 'Ghani', date '2020-01-01', 5000,
          date '1991-01-01', 'citizen', 'active')
  returning id into v_p2;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'AL', 'Annual leave', true) returning id into v_type;

  -- `submit_leave_request` refuses a request the balance will not
  -- cover, which is right and is why the fixture has to grant one.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (v_org, v_p1, v_type,
          extract(year from v_today)::integer, 20),
         (v_org, v_p2, v_type,
          extract(year from v_today)::integer, 20);

  -- Through the real RPC rather than by hand: `request_no` is required
  -- and has no default, and a fixture that invents its own rows is a
  -- fixture that stops resembling the thing it is testing.
  perform public.submit_leave_request(
    v_org, v_type, v_today - 2, v_today, 3, 'Balik kampung',
    false, null, v_p1);
  perform public.submit_leave_request(
    v_org, v_type, v_today, v_today + 2, 3, 'Balik kampung lagi',
    false, null, v_p1);
  perform public.submit_leave_request(
    v_org, v_type, v_today, v_today, 1, 'Demam', false, null, v_p2);
  perform public.submit_leave_request(
    v_org, v_type, v_today, v_today, 1, 'Ditolak', false, null, v_p2);

  -- Farah's two are approved and meet across today: one person away,
  -- not two, which is the whole reason the figure counts employees
  -- rather than rows. Ghani has one still asking and one refused, and
  -- is at their desk either way.
  update public.leave_requests set status = 'approved'
   where org_id = v_org and employee_id = v_p1;
  update public.leave_requests set status = 'rejected'
   where org_id = v_org and employee_id = v_p2 and reason = 'Ditolak';

  perform pg_temp.check_eq('two approved requests are one person away',
    (public.module_dashboard(v_org) -> 'hr' ->> 'on_leave_today')::numeric, 1);
  perform pg_temp.check_eq('and the one still asking is waiting',
    (public.module_dashboard(v_org) -> 'hr' ->> 'leave_to_approve')::numeric, 1);

  -- Leave that ended yesterday is somebody back at work.
  update public.leave_requests set start_date = v_today - 5,
         end_date = v_today - 1
   where employee_id = v_p1;
  perform pg_temp.check_eq('leave that has ended is not leave today',
    (public.module_dashboard(v_org) -> 'hr' ->> 'on_leave_today')::numeric, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- A run on its way through, and two modules that come apart
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_period uuid; v_run uuid; v_dash jsonb;
begin
  v_org := pg_temp.test_org('Kilang Gaji Sdn Bhd', array['hr', 'payroll']);
  -- Posting a run reaches the ledger, and the ledger will not take a
  -- date no fiscal period covers.
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Hafiz', date '2020-01-01', 5000,
          date '1990-01-01', 'citizen');

  v_period := public.ensure_pay_period(v_org, 2026, 1);
  v_run := public.create_payroll_run(v_org, v_period, 'January');

  perform pg_temp.check_eq('a draft run is open',
    (public.module_dashboard(v_org) -> 'payroll' ->> 'open_runs')::numeric, 1);
  perform pg_temp.check_eq('and is not yet anybody''s to approve',
    (public.module_dashboard(v_org) -> 'payroll' ->> 'to_approve')::numeric, 0);

  perform public.calculate_payroll_run(v_run);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('once calculated it is waiting for approval',
    (v_dash -> 'payroll' ->> 'to_approve')::numeric, 1);
  perform pg_temp.check_eq('and still open',
    (v_dash -> 'payroll' ->> 'open_runs')::numeric, 1);
  perform pg_temp.check_eq('with nothing to pay yet',
    (v_dash -> 'payroll' ->> 'to_pay')::numeric, 0);

  -- Posted, which moves it off the approver's desk and onto the one
  -- that pays. Without this the run never leaves `calculated`, and
  -- widening `to_approve` to count approved runs as well changed
  -- nothing and the mutant lived.
  perform public.post_payroll_run(v_run);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('a posted run is nobody''s to approve',
    (v_dash -> 'payroll' ->> 'to_approve')::numeric, 0);
  perform pg_temp.check_eq('a posted run is waiting to be paid',
    (v_dash -> 'payroll' ->> 'to_pay')::numeric, 1);
  perform pg_temp.check_eq('and is still open until it is',
    (v_dash -> 'payroll' ->> 'open_runs')::numeric, 1);

  -- `approved` sits between calculated and posted in the enum and no
  -- RPC produces it: `create_payroll_run` writes draft,
  -- `calculate_payroll_run` writes calculated, and the only other
  -- writers set posted and paid. 0301 handles the state anyway, and
  -- this is the only way to reach it — set directly, because the point
  -- is to pin which side of the line it falls on rather than to pretend
  -- somebody can get there.
  --
  -- Without this the state is untestable and a mutant that counted an
  -- approved run as still needing approval lived through everything
  -- above.
  update public.payroll_runs set status = 'approved' where id = v_run;
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('an approved run is past the approver',
    (v_dash -> 'payroll' ->> 'to_approve')::numeric, 0);
  perform pg_temp.check_eq('and is waiting to be paid',
    (v_dash -> 'payroll' ->> 'to_pay')::numeric, 1);

  -- Paid is finished, and void never happened. Neither is open.
  update public.payroll_runs set status = 'paid' where id = v_run;
  perform pg_temp.check_eq('a paid run is closed',
    (public.module_dashboard(v_org) -> 'payroll' ->> 'open_runs')::numeric, 0);
  update public.payroll_runs set status = 'void' where id = v_run;
  perform pg_temp.check_eq('and a voided one was never open',
    (public.module_dashboard(v_org) -> 'payroll' ->> 'open_runs')::numeric, 0);

  -- The two modules are priced apart and shown apart. A company that
  -- keeps its people here and its payroll elsewhere gets one tab.
  perform public.set_module_hidden(v_org, 'payroll', true);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('putting payroll away leaves HR standing',
    v_dash ? 'hr' and not (v_dash ? 'payroll'));
  perform public.set_module_hidden(v_org, 'payroll', false);
  perform public.set_module_hidden(v_org, 'hr', true);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('and putting HR away leaves payroll',
    v_dash ? 'payroll' and not (v_dash ? 'hr'));
end;
$$;

rollback;

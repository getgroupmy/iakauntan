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

-- ---------------------------------------------------------------------
-- The pipeline, and the follow-ups nobody has made
--
-- 0303 gave CRM its own figures. Four of them, and three carry a
-- decision that would pass unnoticed if it were wrong:
--
--   * the value is not summed across currencies, because
--     `app.exchange_rate_for` raises when there is no rate and this
--     function assembles every module's figures into one object — one
--     unconvertible deal would empty the whole dashboard;
--   * "overdue" is read off the clock, not off `activities.status`,
--     which accepts the value `overdue` that nothing in this database
--     ever writes;
--   * the month is Kuala Lumpur's, and a won deal is dated by
--     `actual_close_date` rather than by when somebody recorded it.
--
-- The fixture builds its own pipeline: `pg_temp.test_org` inserts the
-- organization directly rather than through `create_organization`, so
-- the default pipeline 0012 seeds is not there.
--
-- Nine mutants were run against these. Seven died at the assertion they
-- were aimed at, and an eighth — replacing `open_value` with the
-- obvious converting version, `sum(amount * app.exchange_rate_for(...))`
-- — did not merely fail an assertion but aborted the whole call with
-- "No exchange rate for USD to MYR". That is the concrete failure the
-- design avoids, and the USD deal above is here to produce it: there is
-- no USD rate anywhere in this database, which is what makes the
-- assertion load-bearing rather than merely true.
--
-- Two survived, recorded rather than papered over:
--
--   * dropping `a.due_date is not null` changes nothing, because
--     `null <= now()` is null and an unfiltered null is not counted
--     either way. The clause is redundant against this schema. It stays
--     because it says out loud that an activity with no date is not
--     overdue, which is the question a reader asks;
--   * computing the month in UTC rather than in Kuala Lumpur survives
--     on every day but two per month, and on those two only during the
--     eight hours the dates differ. A test that dies to it only in
--     those hours is a test that fails at random, so this is left
--     unasserted and the choice is argued in 0303's header instead.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_pipe uuid; v_stage uuid; v_deal uuid;
  v_today date; v_dash jsonb;
begin
  v_org := pg_temp.test_org('Jualan Maju Sdn Bhd', array['crm']);
  v_today := (now() at time zone 'Asia/Kuala_Lumpur')::date;

  insert into public.pipelines (org_id, name, is_default)
  values (v_org, 'Standard', true) returning id into v_pipe;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, sort_order)
  values (v_org, v_pipe, 'Qualified', 50, 1) returning id into v_stage;

  -- The control, first. Every refusal below is also satisfied by a
  -- block that returns nothing at all.
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('a CRM company gets a CRM block',
    v_dash ? 'crm');
  perform pg_temp.check_eq('with no deals in it yet',
    (v_dash -> 'crm' ->> 'open_deals')::numeric, 0);
  perform pg_temp.check_eq('and nothing in the pipeline',
    (v_dash -> 'crm' ->> 'open_value')::numeric, 0);
  perform pg_temp.check_eq('and nobody owed a call',
    (v_dash -> 'crm' ->> 'overdue_activities')::numeric, 0);

  -- Four deals in ringgit. One open, one won this month, one lost, one
  -- abandoned — so `open_deals` has three ways to be wrong.
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount,
     currency, status, expected_close_date)
  values (v_org, 'OPP-1', 'Sistem baharu', v_pipe, v_stage, 10000,
          'MYR', 'open', v_today)
  returning id into v_deal;
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount,
     currency, status, actual_close_date)
  values (v_org, 'OPP-2', 'Sudah menang', v_pipe, v_stage, 7000,
          'MYR', 'won', v_today),
         (v_org, 'OPP-3', 'Kalah', v_pipe, v_stage, 5000,
          'MYR', 'lost', v_today),
         (v_org, 'OPP-4', 'Ditinggalkan', v_pipe, v_stage, 3000,
          'MYR', 'abandoned', v_today);

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('only the open deal is open',
    (v_dash -> 'crm' ->> 'open_deals')::numeric, 1);
  perform pg_temp.check_eq('and only its money is in the pipeline',
    (v_dash -> 'crm' ->> 'open_value')::numeric, 10000);
  perform pg_temp.check_eq('the deal won this month is counted as won',
    (v_dash -> 'crm' ->> 'won_this_month')::numeric, 1);

  -- ---- the currency the total is honest about ----
  --
  -- A deal in dollars, with no exchange rate anywhere in this database
  -- for it. If the figure converted, this is the row that would take
  -- the whole dashboard down with it.
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount,
     currency, status, expected_close_date)
  values (v_org, 'OPP-5', 'Pelanggan luar negara', v_pipe, v_stage,
          99000, 'USD', 'open', v_today);

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true(
    'a deal in a currency with no rate does not empty the dashboard',
    v_dash ? 'crm');
  perform pg_temp.check_eq('it is counted as an open deal',
    (v_dash -> 'crm' ->> 'open_deals')::numeric, 2);
  perform pg_temp.check_eq(
    'but its money is left out of a ringgit total',
    (v_dash -> 'crm' ->> 'open_value')::numeric, 10000);
  perform pg_temp.check_eq(
    'and the total says so rather than being quietly short',
    (v_dash -> 'crm' ->> 'other_currency')::numeric, 1);

  -- ---- the month, in Kuala Lumpur ----
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount,
     currency, status, expected_close_date)
  values (v_org, 'OPP-6', 'Bulan depan', v_pipe, v_stage, 1000, 'MYR',
          'open', (date_trunc('month', v_today)
                    + interval '1 month')::date),
         (v_org, 'OPP-7', 'Hujung bulan', v_pipe, v_stage, 1000, 'MYR',
          'open', (date_trunc('month', v_today)
                    + interval '1 month' - interval '1 day')::date),
         (v_org, 'OPP-8', 'Tiada tarikh', v_pipe, v_stage, 1000, 'MYR',
          'open', null);

  v_dash := public.module_dashboard(v_org);
  -- OPP-1 (today) and OPP-7 (the last day of this month). Not OPP-6,
  -- which is the first of next; not OPP-5, whose date is today but
  -- which is here to prove currency does not exclude a deal from a
  -- count; not OPP-8, which has no date at all.
  perform pg_temp.check_eq('closing this month is bounded at both ends',
    (v_dash -> 'crm' ->> 'closing_this_month')::numeric, 3);

  -- A deal won last month is not this month's, however recently
  -- somebody got round to marking it.
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount,
     currency, status, actual_close_date)
  values (v_org, 'OPP-9', 'Menang bulan lalu', v_pipe, v_stage, 4000,
          'MYR', 'won', (date_trunc('month', v_today)
                          - interval '1 day')::date);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq(
    'a deal won last month stays in last month',
    (v_dash -> 'crm' ->> 'won_this_month')::numeric, 1);

  -- ---- overdue is a clock ----
  --
  -- Six activities against the one deal. Only the first two are owed to
  -- anybody now.
  insert into public.activities
    (org_id, activity_type, subject, opportunity_id, status, due_date)
  values (v_org, 'call', 'Telefon semula', v_deal, 'pending',
          now() - interval '2 days'),
         -- The status nothing writes. In the set anyway, so that if
         -- anything ever starts writing it the figure keeps working
         -- rather than silently halving.
         (v_org, 'call', 'Sudah lewat', v_deal, 'overdue',
          now() - interval '1 day'),
         (v_org, 'meeting', 'Minggu depan', v_deal, 'pending',
          now() + interval '7 days'),
         (v_org, 'call', 'Sudah dibuat', v_deal, 'completed',
          now() - interval '3 days'),
         (v_org, 'call', 'Dibatalkan', v_deal, 'cancelled',
          now() - interval '3 days'),
         (v_org, 'note', 'Tiada tarikh', v_deal, 'pending', null);

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq(
    'overdue counts what is still owed and past due, and only that',
    (v_dash -> 'crm' ->> 'overdue_activities')::numeric, 2);

  -- ---- and the module gate ----
  perform public.set_module_hidden(v_org, 'crm', true);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('a company that puts CRM away loses the block',
    not (v_dash ? 'crm'));
  perform public.set_module_hidden(v_org, 'crm', false);
  perform pg_temp.check_true('and gets it back when it comes out again',
    public.module_dashboard(v_org) ? 'crm');
end;
$$;

-- ---------------------------------------------------------------------
-- What the practice owes the Registrar
--
-- 0304 gave corporate secretarial its figures. The deadline arithmetic
-- is *not* re-asserted here — `supabase/tests/secretarial.sql` already
-- holds the anniversary rule, the leap-day case, 180 + 30 for financial
-- statements and no AGM for a private company, and a second copy would
-- be a second thing to keep in step with the Act. What is asserted here
-- is what the dashboard does with those dates.
--
-- Three things, and each is a way the tile could be quietly wrong:
--
--   * it counts obligations, not rows. The filing that gets missed is
--     the one nobody opened a row for, so counting `corp_filings` would
--     report nothing for exactly the practice in trouble;
--   * a filing due today is not late. Telling a secretary it is sends
--     them to argue with SSM about a deadline they have not missed;
--   * lodging one takes it off the count.
--
-- ## The fixture is built to produce exactly two filings
--
-- Every date is relative to `current_date` — the clock
-- `corp_upcoming_filings` windows on, which 0304's header argues for —
-- so it cannot go stale. And both entities are left with no financial
-- year end, because an entity that has one also generates a financial
-- statements filing whose distance from today drifts with the real
-- calendar: it would wander in and out of the window and make this fail
-- on dates nobody chose. A company whose year end has not been recorded
-- yet is an ordinary state, and it leaves only the anniversary rule in
-- play.
--
-- Each entity is incorporated a year and a few days ago, so exactly one
-- Annual Return anniversary falls inside the window: the second is a
-- year out and the incorporation date itself is excluded by the engine.
-- One filing each, one of them ten days late and the other due today,
-- and a third client added later whose deadline falls a day outside the
-- month.
--
-- Six mutants, all dead at the assertion they were aimed at: counting
-- today as late, letting `due_soon` swallow the overdue one, letting
-- `next_due` look backwards, counting off `corp_filings` instead of the
-- deadline engine, keeping a dissolved company on the client count, and
-- stretching the month to ninety days. The fourth is the one that
-- matters most — it reports nothing owed for the practice in trouble.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_late uuid; v_today_ent uuid; v_filing uuid;
  v_dash jsonb; v_sec jsonb;
begin
  v_org := pg_temp.test_org('Setiausaha Tepat Sdn Bhd', array['secretarial']);

  -- The control, before there is anything to owe.
  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_true('a corp-sec practice gets a corp-sec block',
    v_sec is not null);
  perform pg_temp.check_eq('with nothing overdue',
    (v_sec ->> 'overdue')::numeric, 0);
  perform pg_temp.check_eq('and no clients yet',
    (v_sec ->> 'entities')::numeric, 0);
  perform pg_temp.check_true('and no next deadline to name',
    (v_sec ->> 'next_due') is null);

  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, status)
  values (v_org, 'Sudah Lewat Sdn Bhd', 'sdn_bhd',
          (current_date - interval '1 year' - interval '40 days')::date,
          'incorporated')
  returning id into v_late;
  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, status)
  values (v_org, 'Hari Ini Sdn Bhd', 'sdn_bhd',
          (current_date - interval '1 year' - interval '30 days')::date,
          'incorporated')
  returning id into v_today_ent;

  -- Nobody has opened a filing row for either of these. That is the
  -- headline: the obligation exists because the Act says so, and a
  -- figure counted off `corp_filings` would report nothing at all.
  perform pg_temp.check_eq('no filing row has been opened',
    (select count(*) from public.corp_filings
      where org_id = v_org)::numeric, 0);

  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_eq(
    'a filing nobody opened a row for is still counted as overdue',
    (v_sec ->> 'overdue')::numeric, 1);
  -- And the one due today is in the other count, not this one. A
  -- deadline is missed the day after it falls, not on it.
  perform pg_temp.check_eq('a filing due today is not counted late',
    (v_sec ->> 'due_soon')::numeric, 1);
  -- `next_due` looks forward only. Were it the minimum of everything
  -- open it would name the ten-days-late one, presenting a deadline
  -- already missed as the next one coming.
  perform pg_temp.check_eq('and the next one due is today',
    (v_sec ->> 'next_due')::text, current_date::text);
  perform pg_temp.check_eq('both clients are counted',
    (v_sec ->> 'entities')::numeric, 2);

  -- ---- the far edge of "soon" ----
  --
  -- A third client whose Annual Return falls thirty-one days out: one
  -- day past the window. Without it, widening `due_soon` to ninety days
  -- changes nothing and the boundary is asserted only on the near side.
  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, status)
  values (v_org, 'Bulan Depan Sdn Bhd', 'sdn_bhd',
          (current_date + interval '1 day' - interval '1 year')::date,
          'incorporated');

  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_eq(
    'a deadline a day outside the month is not due soon',
    (v_sec ->> 'due_soon')::numeric, 1);
  -- But it is still the practice's client, and still not overdue.
  perform pg_temp.check_eq('though it is still a client',
    (v_sec ->> 'entities')::numeric, 3);
  perform pg_temp.check_eq('and nothing new is late',
    (v_sec ->> 'overdue')::numeric, 1);

  -- ---- lodging one takes it off ----
  --
  -- Through `corp_open_filing`, so the row is the shape the application
  -- makes rather than one this fixture invented.
  v_filing := public.corp_open_filing(
    v_late, 'annual_return',
    (select f.trigger_date from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_late and f.filing_type = 'annual_return'
      order by f.due_date limit 1));
  -- Opening one changes nothing: it is the same obligation, now with a
  -- row against it. Asserted because a count that moved here would be
  -- counting paperwork rather than what is owed.
  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_eq('opening a row does not change what is owed',
    (v_sec ->> 'overdue')::numeric, 1);

  update public.corp_filings set status = 'lodged', lodged_on = current_date
   where id = v_filing;
  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_eq('lodging it takes it off the overdue count',
    (v_sec ->> 'overdue')::numeric, 0);
  perform pg_temp.check_eq('and leaves the one due today alone',
    (v_sec ->> 'due_soon')::numeric, 1);

  -- ---- a company that has been struck off owes nothing ----
  update public.corp_entities set status = 'dissolved' where id = v_today_ent;
  v_sec := public.module_dashboard(v_org) -> 'secretarial';
  perform pg_temp.check_eq('a dissolved company is not a live client',
    (v_sec ->> 'entities')::numeric, 2);
  perform pg_temp.check_eq('and owes the Registrar nothing further',
    (v_sec ->> 'due_soon')::numeric, 0);

  -- ---- and the module gate ----
  perform public.set_module_hidden(v_org, 'secretarial', true);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true(
    'a company that puts the practice away loses the block',
    not (v_dash ? 'secretarial'));
  perform public.set_module_hidden(v_org, 'secretarial', false);
  perform pg_temp.check_true('and gets it back',
    public.module_dashboard(v_org) ? 'secretarial');
end;
$$;

rollback;

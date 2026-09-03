-- =====================================================================
-- iAkauntan :: price levels, analysis dimensions, recurring journals
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pricing_and_dimensions.sql
--
-- Three capabilities that were in the schema and reachable from nothing.
-- The pricing rules are the ones worth asserting: a wholesale customer
-- quoted the retail price is not an error anybody notices until the
-- invoice has been sent.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.pl_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- Which price a customer gets
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.pl_org('Pricing Sdn Bhd');
  v_item uuid; v_std uuid; v_whl uuid; v_list uuid; v_trade uuid;
begin
  insert into public.price_levels (org_id, code, name, is_default, adjustment_percent)
  values (v_org, 'STD', 'Standard', true, 0) returning id into v_std;
  insert into public.price_levels (org_id, code, name, adjustment_percent)
  values (v_org, 'WHL', 'Wholesale', -20) returning id into v_whl;

  insert into public.items (org_id, code, name, item_type, uom_code, unit_price)
  values (v_org, 'ITM-1', 'Widget', 'stock', 'C62', 100) returning id into v_item;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-STD', 'List Buyer', 'customer') returning id into v_list;
  insert into public.contacts (org_id, code, name, contact_type, price_level_id)
  values (v_org, 'C-WHL', 'Trade Buyer', 'customer', v_whl) returning id into v_trade;

  perform pg_temp.check_eq('no customer named is the list price',
    public.item_price(v_item, null, 1), 100);
  perform pg_temp.check_eq('and so is a customer on the standard level',
    public.item_price(v_item, v_list, 1), 100);
  perform pg_temp.check_eq('wholesale takes its percentage off',
    public.item_price(v_item, v_trade, 1), 80);

  -- A named price beats the percentage: somebody typed it deliberately.
  insert into public.item_prices
    (org_id, item_id, price_level_id, unit_price, min_quantity)
  values (v_org, v_item, v_whl, 75, 0);
  perform pg_temp.check_eq('a named price wins over the adjustment',
    public.item_price(v_item, v_trade, 1), 75);

  -- And a quantity break beats that, once the quantity reaches it.
  insert into public.item_prices
    (org_id, item_id, price_level_id, unit_price, min_quantity)
  values (v_org, v_item, v_whl, 70, 100);
  perform pg_temp.check_eq('below the break', public.item_price(v_item, v_trade, 50), 75);
  perform pg_temp.check_eq('at the break', public.item_price(v_item, v_trade, 100), 70);
  perform pg_temp.check_eq('and above it', public.item_price(v_item, v_trade, 500), 70);
end $$;

-- ---------------------------------------------------------------------
-- Profit and loss for one job
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.pl_org('Dimensions Sdn Bhd');
  v_ar uuid; v_rev uuid; r record; v_total numeric;
begin
  select id into v_ar  from public.accounts where org_id = v_org and code = '1210';
  select id into v_rev from public.accounts where org_id = v_org and code = '4100';

  perform public.create_gl_entry(v_org, date '2026-03-10', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 1000, 'credit', 0,
                         'project_code', 'JOB-1'),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 1000,
                         'project_code', 'JOB-1')), 'job one');
  perform public.create_gl_entry(v_org, date '2026-03-11', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 400, 'credit', 0,
                         'project_code', 'JOB-2'),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 400,
                         'project_code', 'JOB-2')), 'job two');
  perform public.create_gl_entry(v_org, date '2026-03-12', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 250, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 250)),
    'no project');

  select coalesce(sum(amount), 0) into v_total
    from public.report_profit_loss_by_dimension(
      v_org, date '2026-01-01', date '2026-12-31', 'JOB-1', null);
  perform pg_temp.check_eq('one job only', v_total, 1000);

  -- Unfiltered still means everything, including the lines that carry no
  -- dimension at all.
  select coalesce(sum(amount), 0) into v_total
    from public.report_profit_loss_by_dimension(
      v_org, date '2026-01-01', date '2026-12-31', null, null);
  perform pg_temp.check_eq('unfiltered is the whole company', v_total, 1650);

  select * into r from public.ledger_dimensions(v_org) where code = 'JOB-1';
  perform pg_temp.check_eq('and the dimension can be found', r.entries, 2);
end $$;

-- ---------------------------------------------------------------------
-- Recurring journals, run for one organization
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.pl_org('Recurring Sdn Bhd');
  v_exp uuid; v_ap uuid; v_rj uuid;
begin
  select id into v_exp from public.accounts where org_id = v_org and code = '6100';
  select id into v_ap  from public.accounts where org_id = v_org and code = '2110';

  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date, next_run_date,
     auto_post, is_active, template)
  values (v_org, 'Monthly rent', 'monthly', 1, date '2026-03-01',
          date '2026-03-01', true, true,
          jsonb_build_object('lines', jsonb_build_array(
            jsonb_build_object('account_id', v_exp, 'debit', 3000, 'credit', 0),
            jsonb_build_object('account_id', v_ap, 'debit', 0, 'credit', 3000))))
  returning id into v_rj;

  perform pg_temp.check_eq('one template ran',
    public.run_recurring_journals_for(v_org, date '2026-03-15'), 1);
  perform pg_temp.check_eq('and posted a journal',
    (select count(*) from public.gl_entries
      where org_id = v_org and source = 'recurring'), 1);
  perform pg_temp.check_true('the schedule moved on a month',
    (select next_run_date = date '2026-04-01'
       from public.recurring_journals where id = v_rj));

  -- The next run is in the future now, so asking again does nothing.
  perform pg_temp.check_eq('running it again is a no-op',
    public.run_recurring_journals_for(v_org, date '2026-03-15'), 0);
end $$;

-- ---------------------------------------------------------------------
-- A standing journal keeps the day it was set on
-- ---------------------------------------------------------------------
-- The block above starts on the first of the month, where there is no
-- day to lose. Rent is usually the last day, and the last day is where
-- every recurrence scheme goes wrong: February has no 31st, so a
-- schedule that advances from its own last run lands on the 28th and
-- never climbs back. `app.advance_schedule` takes an anchor for exactly
-- this, and `0503` is here because the nightly job passed it and the
-- button a person presses did not — so the same journal drifted or did
-- not depending on which one ran the month, and they share a column.
do $$
declare
  v_org uuid := pg_temp.pl_org('Sewa Bulanan Sdn Bhd');
  v_exp uuid; v_ap uuid; v_rj uuid;
begin
  select id into v_exp from public.accounts where org_id = v_org and code = '6100';
  select id into v_ap  from public.accounts where org_id = v_org and code = '2110';

  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date, next_run_date,
     auto_post, is_active, template)
  values (v_org, 'Rent, last day', 'monthly', 1, date '2026-01-31',
          date '2026-01-31', true, true,
          jsonb_build_object('lines', jsonb_build_array(
            jsonb_build_object('account_id', v_exp, 'debit', 5000, 'credit', 0),
            jsonb_build_object('account_id', v_ap, 'debit', 0, 'credit', 5000))))
  returning id into v_rj;

  perform pg_temp.check_eq('January runs',
    public.run_recurring_journals_for(v_org, date '2026-01-31'), 1);
  perform pg_temp.check_true('and February has no 31st to offer',
    (select next_run_date = date '2026-02-28'
       from public.recurring_journals where id = v_rj));

  -- The one that matters. Advanced from the 28th alone this is the
  -- 28th of March, and the 28th of every month after it.
  perform pg_temp.check_eq('February runs',
    public.run_recurring_journals_for(v_org, date '2026-02-28'), 1);
  perform pg_temp.check_true('and March gives the day back',
    (select next_run_date = date '2026-03-31'
       from public.recurring_journals where id = v_rj));

  perform pg_temp.check_eq('both months posted',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and source = 'recurring'), 2);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('pricing is closed to anon',
    not has_function_privilege('anon',
      'public.item_price(uuid, uuid, numeric)', 'execute'));
  perform pg_temp.check_true('and so is the runner',
    not has_function_privilege('anon',
      'public.run_recurring_journals_for(uuid, date)', 'execute'));
end $$;

rollback;

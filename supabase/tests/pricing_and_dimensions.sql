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

-- ---------------------------------------------------------------------
-- A hand-written journal can name a department
--
-- `gl_lines.department_code` has existed as long as the dimensions
-- have, and `app.create_gl_entry_internal` has always read
-- `department_code` off each line's JSON. Nothing ever sent it: the
-- journal editor offered a project per line and no department, so
-- every cost a bookkeeper moved by hand arrived with a null.
--
-- That is the worst shape for a reporting gap. The P&L's department
-- filter answered confidently, summing only the costs that came in
-- through documents, and a department whose spending was journalled
-- looked like a department that had underspent. A missing figure that
-- reads as a small figure is not reported by anybody.
--
-- The fix was a picker and a key in a map -- no schema change at all --
-- which is exactly why it is worth asserting here: nothing in the
-- database changed, so nothing in the database would notice if the app
-- stopped sending it again.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.pl_org('Departments Sdn Bhd');
  v_admin uuid; v_sales uuid; v_entry uuid;
  v_dept text;
begin
  select id into v_admin from public.accounts
   where org_id = v_org and code = '6100';
  select id into v_sales from public.accounts
   where org_id = v_org and code = '4100';

  insert into public.departments (org_id, code, name)
  values (v_org, 'OPS', 'Operations'), (v_org, 'MKT', 'Marketing');

  -- What the journal editor now sends: `department_code` beside
  -- `project_code`, per line.
  v_entry := public.create_gl_entry(
    v_org, date '2026-04-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_admin, 'debit', 300, 'credit', 0,
                         'department_code', 'OPS'),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 300,
                         'department_code', 'MKT')),
    'a cost moved by hand');

  select department_code into v_dept from public.gl_lines
   where entry_id = v_entry and account_id = v_admin;
  perform pg_temp.check_eq('the debit keeps its department', v_dept, 'OPS');

  select department_code into v_dept from public.gl_lines
   where entry_id = v_entry and account_id = v_sales;
  perform pg_temp.check_eq('and the credit keeps its own', v_dept, 'MKT');

  -- PER LINE and not per journal, which is the whole reason it is on
  -- the line: the journal that moves a cost from one department to
  -- another touches both, and a header field could not say so.
  perform pg_temp.check_eq('so one journal names two departments',
    (select count(distinct department_code)::int from public.gl_lines
      where entry_id = v_entry), 2);

  -- A line with no department is still a line. Most journals have no
  -- departmental meaning at all, and a required dimension would be a
  -- dimension people type anything into.
  v_entry := public.create_gl_entry(
    v_org, date '2026-04-02', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_admin, 'debit', 50, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 50)),
    'no department');
  perform pg_temp.check_eq('and a journal may name none',
    (select count(*)::int from public.gl_lines
      where entry_id = v_entry and department_code is null), 2);

  -- Both dimensions at once, because they are independent: a job run
  -- by one department is a normal thing to post.
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-9', 'Job nine');
  v_entry := public.create_gl_entry(
    v_org, date '2026-04-03', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_admin, 'debit', 80, 'credit', 0,
                         'project_code', 'JOB-9',
                         'department_code', 'OPS'),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 80)),
    'a job run by a department');
  perform pg_temp.check_eq('a line carries both dimensions',
    (select project_code || '/' || department_code from public.gl_lines
      where entry_id = v_entry and account_id = v_admin),
    'JOB-9/OPS');
end $$;

-- ---------------------------------------------------------------------
-- 0640: an empty dimension is no dimension
--
-- `app.create_gl_entry_internal` read `contact_id`, `item_id` and
-- `tax_code_id` through `nullif(..., '')` and the two dimension codes
-- without it. The three with a `::uuid` cast NEEDED it -- `''::uuid` is
-- an error, so the mistake announced itself -- and the two text ones
-- did not.
--
-- An empty string is not null, so it becomes a DIMENSION: a P&L
-- grouped by department reports a nameless one beside the real ones.
-- Filtering for "no department" misses those costs because they have
-- one; filtering for any named department misses them too. They are
-- attributed to a department that does not exist and cannot be picked.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.pl_org('Blank Dimensions Sdn Bhd');
  v_ar uuid; v_rev uuid; v_entry uuid;
begin
  select id into v_ar  from public.accounts where org_id = v_org and code = '1210';
  select id into v_rev from public.accounts where org_id = v_org and code = '4100';

  -- What a spreadsheet cell that is present and empty looks like by the
  -- time it reaches here. `0610`'s importer is the reachable caller.
  v_entry := public.create_gl_entry(
    v_org, date '2026-05-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 10, 'credit', 0,
                         'project_code', '', 'department_code', ''),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 10)),
    'blank dimensions');

  perform pg_temp.check_eq('a blank project code stores as no project',
    (select count(*)::int from public.gl_lines
      where entry_id = v_entry and project_code is not null), 0);
  perform pg_temp.check_eq('and a blank department as no department',
    (select count(*)::int from public.gl_lines
      where entry_id = v_entry and department_code is not null), 0);

  -- The assertion with teeth, and the one a `coalesce` would pass while
  -- a `nullif` is what is wanted: NO line groups under the empty
  -- string. Counting nulls alone would hold if the value were stored
  -- as `''` and the count happened to be taken on a different column.
  perform pg_temp.check_eq('so nothing groups under a nameless one',
    (select count(*)::int from public.gl_lines
      where entry_id = v_entry
        and (project_code = '' or department_code = '')), 0);

  -- A real code is untouched by any of this. The fix must not turn a
  -- dimension somebody chose into no dimension.
  v_entry := public.create_gl_entry(
    v_org, date '2026-05-02', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 20, 'credit', 0,
                         'project_code', 'JOB-X',
                         'department_code', 'DEPT-X'),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 20)),
    'real dimensions');
  perform pg_temp.check_eq('a chosen code still arrives',
    (select project_code || '/' || department_code from public.gl_lines
      where entry_id = v_entry and debit = 20),
    'JOB-X/DEPT-X');

  -- And a code that names nothing is STILL accepted, which is the
  -- decision 0640's header explains rather than an oversight: an
  -- import writes the codes the old system used, and the masters can
  -- legitimately arrive in a later batch or never. 'JOB-X' above is
  -- not a row in `projects` and the posting went through.
  perform pg_temp.check_true(
    'and an unknown code is accepted, deliberately',
    not exists (select 1 from public.projects
                 where org_id = v_org and code = 'JOB-X'));
end $$;

rollback;

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

-- ---------------------------------------------------------------------
-- 0641: a price that already contains the tax
--
-- `app.calc_document_line` could always compute an inclusive line, and
-- `tax_codes.is_inclusive` has existed since `0003`. Nothing joined
-- them: the client never sent `is_tax_inclusive` as true, and no
-- function ever read the code's flag, so the inclusive branch of the
-- trigger was unreachable from the product.
--
-- The arithmetic on that branch was already asserted in Dart
-- (`compute_line_test.dart`). What is asserted here is the part that
-- was missing -- that choosing an inclusive CODE is what puts a line on
-- that branch -- and the part it would be easy to get wrong: the flag
-- is a snapshot of the moment the code was chosen, not a live read of
-- the code, for exactly the reason `tax_rate` is kept on the line.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pl_org('Harga Termasuk Sdn Bhd');
  v_cust uuid;
  v_incl uuid; v_excl uuid; v_sen uuid;
  v_doc  uuid; v_line uuid;
  r      record;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-INCL', 'Pembeli', 'customer') returning id into v_cust;

  -- Two codes at the same rate, differing only in whether the price
  -- quoted against them already contains it. Same rate deliberately:
  -- an assertion that passed because one rate was 8 and the other 0
  -- would prove nothing about `is_inclusive`.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'ST8I', 'Service Tax 8% inclusive', '02', 8, true)
  returning id into v_incl;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'ST8X', 'Service Tax 8% on top', '02', 8, false)
  returning id into v_excl;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-INCL-1', date '2026-03-01', v_cust, 'MYR',
          1, 'draft')
  returning id into v_doc;

  -- RM 108 quoted against an inclusive code is RM 100 and RM 8 of tax,
  -- and the invoice still totals the 108 that was quoted. The client
  -- sends no `is_tax_inclusive` at all here -- that is the point: the
  -- resolution is the trigger's, not the caller's.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Perkhidmatan', 1, 108, v_incl, 8)
  returning id into v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true('an inclusive code sets the flag on the line',
    r.is_tax_inclusive);
  perform pg_temp.check_eq('so RM 108 at 8% inclusive is RM 100 net',
    r.line_subtotal, 100);
  perform pg_temp.check_eq('and RM 8 of tax', r.tax_amount, 8);
  perform pg_temp.check_eq('and the line still totals what was quoted',
    r.line_total, 108);

  -- The same price against the exclusive code, on the same document.
  -- This is the assertion that fails if the trigger ignores the code
  -- and just believes the row: both lines would compute identically.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 2, 'Perkhidmatan lain', 1, 108, v_excl, 8)
  returning id into v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true('an exclusive code leaves the flag off',
    not r.is_tax_inclusive);
  perform pg_temp.check_eq('so the same RM 108 is RM 108 net',
    r.line_subtotal, 108);
  perform pg_temp.check_eq('with the tax added on top', r.tax_amount, 8.64);
  perform pg_temp.check_eq('and the line totals more than was quoted',
    r.line_total, 116.64);

  -- A caller that stamps the flag itself is believed, even against a
  -- code that says nothing. This is the POS, and it is not a
  -- hypothetical: `add_pos_sale_line_internal` stamps the line from the
  -- OUTLET's `prices_include_tax`, and `complete_pos_sale` carries that
  -- line onto an invoice. Resolving the code over the top of it charged
  -- 8.64 of tax on a plate the till took 108.00 in cash for, and
  -- `pos.sql` failed with a journal that does not balance.
  --
  -- So the code may turn this on and may not turn it off. The code
  -- knows how the business quotes; the till knows what the shop
  -- charged.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate, is_tax_inclusive)
  values (v_org, v_doc, 3, 'Daripada kaunter', 1, 108, v_excl, 8, true)
  returning id into v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true('a caller that stamps the flag is believed',
    r.is_tax_inclusive);
  perform pg_temp.check_eq('and the line computes the caller''s way',
    r.line_subtotal, 100);

  -- A line with NO code keeps what it arrived with. There is nothing to
  -- resolve from, and this is the one path where the caller still
  -- decides.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_rate, is_tax_inclusive)
  values (v_org, v_doc, 4, 'Tanpa kod', 1, 108, 8, true)
  returning id into v_line;

  select * into r from public.sales_document_lines where id = v_line;
  -- The guard is `tax_code_id is not null`, and a mutant that removes
  -- it survives this assertion -- deliberately. With no code the
  -- lookup finds no row, `v_incl` stays null, and the `coalesce` falls
  -- through to the line's own flag, which is the same answer. The guard
  -- says what is meant and saves a query; it is not what makes this
  -- line keep its flag.
  perform pg_temp.check_true('with no tax code the line keeps its own flag',
    r.is_tax_inclusive);
  perform pg_temp.check_eq('and computes inclusively', r.line_subtotal, 100);

  -- The tax on the inclusive branch is what is LEFT of the price after
  -- the net is taken out of it, not the rate applied to that net a
  -- second time.
  --
  -- Every price above is a round number of cents that divides exactly,
  -- and there the two agree -- a mutant that recomputed the tax from
  -- the net survived this whole block on that alone. 26 sen at 6% is
  -- where they part: round(0.26 / 1.06, 2) is 0.25, so a single sen is
  -- left over; recomputing gives round(0.25 * 6 / 100, 2) = 0.02 and a
  -- line that totals 27 sen against a price somebody typed as 26.
  --
  -- `compute_line_test.dart` asserts the same sen in Dart, on the same
  -- numbers, because the editor shows this total before the row exists.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'SR6I', 'Sales Tax 6% inclusive', '01', 6, true)
  returning id into v_sen;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 5, 'Sesen', 1, 0.26, v_sen, 6)
  returning id into v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_eq('26 sen at 6% inclusive is 25 sen net',
    r.line_subtotal, 0.25);
  perform pg_temp.check_eq('and a sen of tax, because a sen is what is left',
    r.tax_amount, 0.01);
  perform pg_temp.check_eq('so the line totals the 26 sen that was quoted',
    r.line_total, 0.26);
end $$;

-- ---------------------------------------------------------------------
-- The flag is a snapshot, like the rate beside it
--
-- `sst_taxable_period.sql` records why the RATE lives on the line: a
-- rate that moves must not restate every invoice that used the code.
-- The same has to hold for whether the price included it, or marking a
-- code inclusive today would re-compute tomorrow any draft line
-- somebody so much as retypes the quantity on.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pl_org('Snapshot Sdn Bhd');
  v_cust uuid; v_code uuid; v_doc uuid; v_other uuid; v_plain uuid;
  v_line uuid;
  r      record;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-SNAP', 'Pembeli', 'customer') returning id into v_cust;

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'SR6', 'Sales Tax 6% on top', '01', 6, false)
  returning id into v_code;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'SR6I', 'Sales Tax 6% inclusive', '01', 6, true)
  returning id into v_other;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_inclusive)
  values (v_org, 'SR6X', 'Sales Tax 6% on top', '01', 6, false)
  returning id into v_plain;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-SNAP-1', date '2026-03-02', v_cust, 'MYR',
          1, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Barang', 1, 100, v_code, 6)
  returning id into v_line;

  perform pg_temp.check_eq('quoted exclusive, the tax goes on top',
    (select tax_amount from public.sales_document_lines where id = v_line), 6);

  -- The company is told to quote inclusive from now on.
  update public.tax_codes set is_inclusive = true where id = v_code;

  -- And somebody edits the quantity on the draft that was quoted the
  -- old way. Re-reading the code here would turn RM 100 exclusive into
  -- RM 100 inclusive -- a price cut nobody agreed to, on a line whose
  -- own rate is still the one it was quoted at.
  update public.sales_document_lines set quantity = 2 where id = v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true('editing the line does not re-read the code',
    not r.is_tax_inclusive);
  perform pg_temp.check_eq('so the price quoted still excludes the tax',
    r.line_subtotal, 200);
  perform pg_temp.check_eq('and the tax is still added on top',
    r.tax_amount, 12);

  -- Choosing a DIFFERENT code is a new choice, and resolves again. This
  -- is what a plain `tg_op = 'INSERT'` guard would get wrong: the line
  -- would keep computing exclusively against a code that says
  -- otherwise.
  update public.sales_document_lines
     set tax_code_id = v_other where id = v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true('but changing the code resolves it again',
    r.is_tax_inclusive);
  perform pg_temp.check_eq('and the price now contains the tax',
    r.line_subtotal, 188.68);
  perform pg_temp.check_eq('with the rest of it taken by subtraction',
    r.tax_amount, 11.32);

  -- And back. This is the only place the code's answer is taken
  -- outright rather than OR-ed with the line's, and it has to be: a
  -- line that went on computing inclusively against a code saying
  -- otherwise could never be put right from a document screen.
  -- `v_plain`, not `v_code`: the code the line started on was marked
  -- inclusive halfway through this block, which is the whole point of
  -- the assertions above it.
  update public.sales_document_lines
     set tax_code_id = v_plain where id = v_line;

  select * into r from public.sales_document_lines where id = v_line;
  perform pg_temp.check_true(
    'and a code that says otherwise turns it back off',
    not r.is_tax_inclusive);
  perform pg_temp.check_eq('so the tax goes on top again',
    r.line_subtotal, 200);
end $$;

rollback;

-- =====================================================================
-- The number the board agreed
--
-- One assertion matters more than the rest, and it is `favourable`.
-- Spending five thousand less than budgeted is good news; earning five
-- thousand less is not, and both are a variance of minus five thousand.
-- If the report gets that backwards every management account it feeds
-- is confidently wrong in the column a director reads first.
--
-- The rest: the variance itself, an account budgeted and not spent
-- appearing beside one spent and not budgeted, a budget built from last
-- year's actuals keeping the shape of the year, a departmental budget
-- seeing only its own department, and an approved budget refusing to be
-- edited.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_year   uuid;
  v_prior  uuid;
  v_cust   uuid;
  v_item   uuid;
  v_sales  uuid;
  v_rent   uuid;
  v_tel    uuid;
  v_p1     uuid;
  v_p2     uuid;

  v_bud    uuid;
  v_dept   uuid;
  v_inv    uuid;
  v_msg    text;
  v_n      integer;
  v_row    record;
begin
  v_org := pg_temp.test_org('Kilang Roti Sinar Sdn Bhd');
  -- Last year, and this one.
  v_prior := public.create_fiscal_year(
    v_org, (date_trunc('year', current_date) - interval '1 year')::date);
  v_year  := public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['accounting','sales','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  select id into v_sales from public.accounts where org_id = v_org and code = '4100';
  select id into v_rent  from public.accounts where org_id = v_org and code = '6200';
  select id into v_tel   from public.accounts where org_id = v_org and code = '6220';
  select id into v_p1 from public.fiscal_periods
   where fiscal_year_id = v_year and period_no = 1;
  select id into v_p2 from public.fiscal_periods
   where fiscal_year_id = v_year and period_no = 2;

  -- ------------------------------------------------------------------
  -- 1. A budget, per account per period
  -- ------------------------------------------------------------------
  v_bud := public.upsert_budget(null, v_org, v_year, 'Board plan');
  v_n := public.set_budget_lines(v_bud, jsonb_build_array(
    jsonb_build_object('account', v_sales, 'period', v_p1, 'amount', 50000),
    jsonb_build_object('account', v_sales, 'period', v_p2, 'amount', 60000),
    jsonb_build_object('account', v_rent,  'period', v_p1, 'amount', 20000),
    jsonb_build_object('account', v_rent,  'period', v_p2, 'amount', 20000),
    -- A zero is not a budget line: storing it would fill the grid with
    -- rows that say nothing.
    jsonb_build_object('account', v_tel,   'period', v_p1, 'amount', 0)));
  perform pg_temp.check_eq('four lines, and the zero was not one of them',
    v_n::numeric, 4::numeric);

  -- Actuals: forty thousand of sales and twenty-five of rent in the
  -- first period. Behind on sales, over on rent — both bad news, and
  -- one of them is a positive variance.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A baker', 'customer') returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'ROTI', 'Bread', 'service', false, 1)
  returning id into v_item;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1',
          (select start_date from public.fiscal_periods where id = v_p1),
          current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Bread', 40000, 1);
  perform public.post_sales_document(v_inv);

  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods where id = v_p1),
    jsonb_build_array(
      jsonb_build_object('account_id', v_rent, 'debit', 25000, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 25000)),
    'January rent');

  -- ------------------------------------------------------------------
  -- 2. The assertion this migration is built around
  -- ------------------------------------------------------------------
  select * into v_row from public.report_budget_vs_actual(v_bud, 1, 1)
   where code = '4100';
  perform pg_temp.check_eq('sales were budgeted at fifty', v_row.budget, 50000::numeric);
  perform pg_temp.check_eq('and came in at forty', v_row.actual, 40000::numeric);
  perform pg_temp.check_eq('ten thousand behind', v_row.variance, -10000::numeric);
  perform pg_temp.check_true('which is not good news', v_row.favourable = false);
  perform pg_temp.check_eq('and twenty per cent of the plan',
    v_row.variance_pct, -20::numeric);

  select * into v_row from public.report_budget_vs_actual(v_bud, 1, 1)
   where code = '6200';
  perform pg_temp.check_eq('rent was budgeted at twenty', v_row.budget, 20000::numeric);
  perform pg_temp.check_eq('and cost twenty-five', v_row.actual, 25000::numeric);
  perform pg_temp.check_eq('five thousand over', v_row.variance, 5000::numeric);
  perform pg_temp.check_true(
    'and a positive variance on an expense is not good news either',
    v_row.favourable = false);

  -- The two together are the whole point: minus ten thousand and plus
  -- five thousand, and both are bad. A report that called the negative
  -- one bad and the positive one good would be wrong twice.
  perform pg_temp.check_eq('nothing in this period went to plan',
    (select count(*) from public.report_budget_vs_actual(v_bud, 1, 1)
      where favourable), 0::numeric);

  -- ------------------------------------------------------------------
  -- 3. Under budget on an expense is good news
  -- ------------------------------------------------------------------
  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods where id = v_p2),
    jsonb_build_array(
      jsonb_build_object('account_id', v_rent, 'debit', 18000, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 18000)),
    'February rent');

  select * into v_row from public.report_budget_vs_actual(v_bud, 2, 2)
   where code = '6200';
  perform pg_temp.check_eq('two thousand under', v_row.variance, -2000::numeric);
  perform pg_temp.check_true('and that is good news', v_row.favourable);

  -- ------------------------------------------------------------------
  -- 4. Budgeted and unspent, spent and unbudgeted
  -- ------------------------------------------------------------------
  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods where id = v_p1),
    jsonb_build_array(
      jsonb_build_object('account_id', v_tel, 'debit', 900, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 900)),
    'A phone bill nobody planned');

  select * into v_row from public.report_budget_vs_actual(v_bud, 1, 1)
   where code = '6220';
  perform pg_temp.check_eq('money nobody planned to spend still shows up',
    v_row.actual, 900::numeric);
  perform pg_temp.check_eq('against a budget of nothing', v_row.budget, 0::numeric);
  perform pg_temp.check_true('with no percentage, because nothing has no percentage',
    v_row.variance_pct is null);

  -- And the reverse: budgeted in period two, nothing spent yet.
  select * into v_row from public.report_budget_vs_actual(v_bud, 2, 2)
   where code = '4100';
  perform pg_temp.check_eq('sales budgeted for February', v_row.budget, 60000::numeric);
  perform pg_temp.check_eq('with nothing against it yet', v_row.actual, 0::numeric);

  -- ------------------------------------------------------------------
  -- 5. The whole year, and part of it
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the year to date adds both periods of rent',
    (select r.actual from public.report_budget_vs_actual(v_bud, 1, 2) r
      where r.code = '6200'), 43000::numeric);
  perform pg_temp.check_eq('against both periods of budget',
    (select r.budget from public.report_budget_vs_actual(v_bud, 1, 2) r
      where r.code = '6200'), 40000::numeric);

  -- ------------------------------------------------------------------
  -- 6. Built from last year, keeping the shape of it
  -- ------------------------------------------------------------------
  --
  -- Ten thousand in the prior year's first period and thirty in its
  -- second. A ten per cent uplift has to carry the shape across, not
  -- average it.
  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods
      where fiscal_year_id = v_prior and period_no = 1),
    jsonb_build_array(
      jsonb_build_object('account_id', v_tel, 'debit', 10000, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 10000)),
    'Last year, quiet month');
  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods
      where fiscal_year_id = v_prior and period_no = 2),
    jsonb_build_array(
      jsonb_build_object('account_id', v_tel, 'debit', 30000, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 30000)),
    'Last year, busy month');

  v_bud := public.upsert_budget(null, v_org, v_year, 'Last year plus ten');
  v_n := public.build_budget_from_actual(v_bud, v_prior, 10);
  perform pg_temp.check_true('it filled something', v_n > 0);
  perform pg_temp.check_eq('the quiet month comes across as eleven thousand',
    (select l.amount from public.budget_lines_for(v_bud) l
      where l.code = '6220' and l.period_no = 1), 11000::numeric);
  perform pg_temp.check_eq('and the busy one as thirty-three',
    (select l.amount from public.budget_lines_for(v_bud) l
      where l.code = '6220' and l.period_no = 2), 33000::numeric);

  -- ------------------------------------------------------------------
  -- 7. A departmental budget sees only its own department
  -- ------------------------------------------------------------------
  perform public.post_manual_journal(
    v_org,
    (select start_date from public.fiscal_periods where id = v_p1),
    jsonb_build_array(
      jsonb_build_object('account_id', v_tel, 'debit', 300, 'credit', 0,
                         'department_code', 'BAKERY'),
      jsonb_build_object('account_id',
        (select id from public.accounts where org_id = v_org and code = '1120'),
        'debit', 0, 'credit', 300)),
    'The bakery phone');

  v_dept := public.upsert_budget(null, v_org, v_year, 'Bakery', 'BAKERY');
  perform public.set_budget_lines(v_dept, jsonb_build_array(
    jsonb_build_object('account', v_tel, 'period', v_p1, 'amount', 250)));
  perform pg_temp.check_eq(
    'the bakery budget sees the bakery phone bill and not the company one',
    (select r.actual from public.report_budget_vs_actual(v_dept, 1, 1) r
      where r.code = '6220'), 300::numeric);
  perform pg_temp.check_eq('while the company budget sees both',
    (select r.actual from public.report_budget_vs_actual(v_bud, 1, 1) r
      where r.code = '6220'), 1200::numeric);

  -- ------------------------------------------------------------------
  -- 8. What it refuses
  -- ------------------------------------------------------------------
  begin
    perform public.approve_budget(
      public.upsert_budget(null, v_org, v_year, 'Nothing in it'));
    perform pg_temp.check_true('an empty budget can be agreed to', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an empty budget is not something to agree to',
      v_msg like '%not something to agree to%');
  end;

  perform public.approve_budget(v_dept);
  begin
    perform public.set_budget_lines(v_dept, jsonb_build_array(
      jsonb_build_object('account', v_tel, 'period', v_p1, 'amount', 400)));
    perform pg_temp.check_true('an agreed number can be moved afterwards', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'an approved budget is not edited after the actuals are in',
      v_msg like '%not edited afterwards%');
  end;

  begin
    perform public.upsert_budget(v_dept, v_org, v_year, 'Renamed');
    perform pg_temp.check_true('an approved budget can be renamed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nor renamed — it is superseded instead',
      v_msg like '%Supersede it%');
  end;

  -- A period from a different year is not this budget's period.
  begin
    perform public.set_budget_lines(
      public.upsert_budget(null, v_org, v_year, 'Wrong year'),
      jsonb_build_array(jsonb_build_object(
        'account', v_tel,
        'period', (select id from public.fiscal_periods
                    where fiscal_year_id = v_prior and period_no = 1),
        'amount', 100)));
    perform pg_temp.check_true('a budget can hold last year''s periods', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a budget line belongs to its own financial year',
      v_msg like '%not in the budget%');
  end;

  -- A heading is not something to budget against.
  begin
    perform public.set_budget_lines(
      public.upsert_budget(null, v_org, v_year, 'Against a heading'),
      jsonb_build_array(jsonb_build_object(
        'account', (select id from public.accounts
                     where org_id = v_org and code = '6000'),
        'period', v_p1, 'amount', 100)));
    perform pg_temp.check_true('a heading can carry a budget', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a heading cannot carry one',
      v_msg like '%it is a heading%');
  end;

  -- Archived rather than deleted, so last quarter's report can still be
  -- reproduced.
  perform public.archive_budget(v_dept);
  perform pg_temp.check_eq('an archived budget is still there',
    (select l.status from public.budgets_list(v_org) l where l.id = v_dept),
    'archived');
  perform pg_temp.check_eq('and its lines with it',
    (select count(*) from public.budget_lines_for(v_dept)), 1::numeric);

  raise notice 'ok   budgets';
end $$;

rollback;

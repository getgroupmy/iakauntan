-- =====================================================================
-- iAkauntan :: a budget's actuals are the ledger's (0857)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/budget_actuals_need_ledger.sql
--
-- `0855` gave the reports built from the ledger `app.can_read_ledger`.
-- Three readers of the ledger's actuals asked something else: the
-- budget against actual and the budget built from last year, which ask
-- the accounting module -- open to every member without a custom access
-- type, a salesman included -- and the project budget, which asked only
-- membership and still answers every member, its actuals blank to one
-- who does not read the ledger. Asked with the role `authenticated`, as
-- the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ba (org uuid, sales uuid, clerk uuid, fy uuid,
  bud uuid, project uuid);
grant select on t_ba to authenticated;

do $$
declare r t_ba; a_exp uuid; a_eq uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Bajet Sebenar Sdn Bhd');
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  r.sales := pg_temp.another_user('sales@bajetsebenar.test');
  r.clerk := pg_temp.another_user('clerk@bajetsebenar.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  insert into public.projects (org_id, code, name, budget_amount)
  values (r.org, 'P-9', 'Pejabat baru', 10000) returning id into r.project;

  select id into a_exp from public.accounts where org_id = r.org and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into a_eq from public.accounts where org_id = r.org and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(r.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', a_exp, 'debit', 4321.09, 'credit', 0,
                         'project_code', 'P-9'),
      jsonb_build_object('account_id', a_eq, 'debit', 0, 'credit', 4321.09)),
    'Renovation');

  select id into r.fy from public.fiscal_years
   where org_id = r.org and pg_temp.today() between start_date and end_date;
  r.bud := public.upsert_budget(null, r.org, r.fy, 'Board plan');
  insert into t_ba select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_ba), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ba; v_msg constant text := 'Insufficient privileges to read the ledger';
begin
  select * into d from t_ba;
  perform pg_temp.check_eq('the premise: the salesman holds the accounting module, and not the ledger',
    app.module_access(d.org, 'accounting')::text || ' / ' || app.can_read_ledger(d.org)::text,
    'write / false');
  perform pg_temp.check_eq('and still reads the budget itself',
    (select count(*) from public.budgets where id = d.bud)::int, 1);

  -- What was measured.
  perform pg_temp.check_refused('the budget against actual is refused',
    format('select * from public.report_budget_vs_actual(%L)', d.bud), v_msg, '42501');
  perform pg_temp.check_refused('and a budget built from the actuals',
    format('select public.build_budget_from_actual(%L, %L, 10)', d.bud, d.fy), v_msg, '42501');
  perform pg_temp.check_eq('which wrote nothing into it',
    (select count(*) from public.budget_lines where budget_id = d.bud)::int, 0);
end $$;

-- The project budget is the projects' front door, so the salesman is
-- answered -- every project, without what the ledger has against it.
do $$
declare d t_ba; r record;
begin
  select * into d from t_ba;
  select * into r from public.report_project_budget(d.org) where code = 'P-9';
  perform pg_temp.check_eq('the salesman is still given the project and its budget',
    r.name || ' / ' || r.budget_amount::text, 'Pejabat baru / 10000.00');
  perform pg_temp.check_true('but not its cost to date', r.cost_to_date is null);
  perform pg_temp.check_true('nor its revenue to date', r.revenue_to_date is null);
  perform pg_temp.check_true('nor what is left of the budget', r.variance is null);
  perform pg_temp.check_true('nor how much of it is spent', r.percent_spent is null);
  perform pg_temp.check_eq('while the unbilled time, from the timesheets, is still there',
    r.unbilled_time, 0);
end $$;

reset role;

-- The clerk reads the ledger, and is answered by all three: the
-- refusals above are about the role, not three broken functions.
select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_ba), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ba;
begin
  select * into d from t_ba;
  perform pg_temp.check_eq('the clerk sees the actual beside the budget',
    (select sum(actual) from public.report_budget_vs_actual(d.bud)), 4321.09);
  perform pg_temp.check_true('and builds the budget from it, ten per cent up',
    public.build_budget_from_actual(d.bud, d.fy, 10) > 0);
  perform pg_temp.check_eq('to the sen',
    (select sum(amount) from public.budget_lines where budget_id = d.bud), 4753.20);
  perform pg_temp.check_eq('and sees the project''s cost against its budget',
    (select cost_to_date || ' / ' || variance || ' / ' || percent_spent
       from public.report_project_budget(d.org) where code = 'P-9'),
    '4321.09 / 5678.91 / 43.2');
end $$;

reset role;

-- The owner holds the module and the ledger; the module question still
-- refuses a stranger in its own words, as before.
do $$
declare d t_ba; v_outsider uuid := pg_temp.another_user('outsider@bajetsebenar.test');
begin
  select * into d from t_ba;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.check_refused('a stranger is refused by the module, as before',
    format('select * from public.report_budget_vs_actual(%L)', d.bud),
    'not permitted to read this organization', '42501');
  perform pg_temp.check_refused('and by membership on the project budget',
    format('select * from public.report_project_budget(%L)', d.org),
    'Not your company', '42501');
  reset role;
end $$;

rollback;

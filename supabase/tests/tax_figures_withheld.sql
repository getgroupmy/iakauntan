-- =====================================================================
-- iAkauntan :: the company's tax is the ledger's (0860)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_figures_withheld.sql
--
-- `0855` gave the tax computation `app.can_read_ledger`. The tables
-- under it, the CP204 estimate's schedule and its payment summary still
-- answered every member. The deadlines are everybody's -- the
-- dashboard's tax tile counts the instalments behind for every member --
-- and stay so; the figures are the ledger's. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tx (org uuid, sales uuid, clerk uuid, comp uuid, est uuid);
grant select on t_tx to authenticated;

-- What the salesman and the clerk are each told, compared afterwards.
create temporary table t_seen (who text, overdue integer, next_due date,
  instalments integer, paid integer);
grant select, insert on t_seen to authenticated;

do $$
declare r t_tx; v_fy uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Cukai Rahsia Sdn Bhd');
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  r.sales := pg_temp.another_user('sales@cukai.test');
  r.clerk := pg_temp.another_user('clerk@cukai.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  select id into v_fy from public.fiscal_years
   where org_id = r.org and pg_temp.today() between start_date and end_date;

  -- One row in each of the seven tables, written as the database: what
  -- is asserted is who reads them, not how they were made.
  insert into public.tax_computations (org_id, fiscal_year_id, year_of_assessment,
    gross_business_income, loss_bf)
  values (r.org, v_fy, extract(year from pg_temp.today())::int, 2345678.90, 120000)
  returning id into r.comp;
  insert into public.tax_adjustments (org_id, computation_id, kind, label, amount)
  values (r.org, r.comp, 'add_back', 'Entertainment', 45000);
  insert into public.tax_other_income (org_id, computation_id, kind, label, amount)
  values (r.org, r.comp, 'rental', 'Shoplot rent', 36000);
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (r.org, r.comp, 'R1', 'Self', 9000);
  insert into public.tax_partners (org_id, computation_id, name, share_percent, salary)
  values (r.org, r.comp, 'Encik Rahman', 60, 84000);
  insert into public.tax_estimates (org_id, fiscal_year_id, year_of_assessment, estimated_tax)
  values (r.org, v_fy, extract(year from pg_temp.today())::int, 456000)
  returning id into r.est;
  -- The first instalment paid, through the function the app calls.
  perform public.record_tax_instalment(r.est, 1, null, 38000, 'CP207-1', null);
  insert into t_tx select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_tx), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_tx; s record; v_msg constant text := 'Insufficient privileges to read the ledger';
begin
  select * into d from t_tx;
  perform pg_temp.check_true('the premise: the salesman does not read the ledger',
    not app.can_read_ledger(d.org));

  -- What was measured: a row in each table, and none of them read.
  perform pg_temp.check_eq('no tax computation, so no income or loss brought forward',
    (select count(*) from public.tax_computations where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no adjustment',
    (select count(*) from public.tax_adjustments where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no other income',
    (select count(*) from public.tax_other_income where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no relief claimed',
    (select count(*) from public.tax_relief_claims where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no partner''s share',
    (select count(*) from public.tax_partners where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no estimate of the tax',
    (select count(*) from public.tax_estimates where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('no instalment paid',
    (select count(*) from public.tax_estimate_payments where org_id = d.org)::int, 0);
  perform pg_temp.check_refused('the schedule of instalments is refused',
    format('select * from public.tax_estimate_schedule(%L)', d.est), v_msg, '42501');
  perform pg_temp.check_refused('nor is its arithmetic a door of its own',
    format('select * from app.tax_estimate_schedule_of(%L)', d.est),
    'permission denied for function tax_estimate_schedule_of', '42501');

  -- The deadlines stay: the summary answers, with every sum blank.
  select * into s from public.tax_estimate_payment_summary(d.est);
  perform pg_temp.check_eq('the salesman is still told how many instalments there are',
    s.instalments, 12);
  perform pg_temp.check_true('and when the next falls due', s.next_due_on is not null);
  perform pg_temp.check_true('but not what any of it comes to',
    s.scheduled_total is null and s.paid_total is null and s.outstanding_total is null
    and s.overdue_total is null and s.late_penalty is null and s.next_due_amount is null);
  insert into t_seen values ('sales', s.overdue_count, s.next_due_on, s.instalments, s.instalments_paid);

  perform pg_temp.check_true('and the dashboard''s tax tile is still drawn for them',
    public.module_dashboard(d.org) -> 'tax' ? 'instalment_next_due');
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_tx), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_tx; s record;
begin
  select * into d from t_tx;
  perform pg_temp.check_eq('the clerk reads the computation',
    (select gross_business_income || ' / ' || loss_bf from public.tax_computations
      where id = d.comp), '2345678.90 / 120000.00');
  perform pg_temp.check_eq('and every row under it',
    (select count(*) from public.tax_adjustments where computation_id = d.comp)::int
    + (select count(*) from public.tax_other_income where computation_id = d.comp)::int
    + (select count(*) from public.tax_relief_claims where computation_id = d.comp)::int
    + (select count(*) from public.tax_partners where computation_id = d.comp)::int, 4);
  perform pg_temp.check_eq('and the estimate and what was paid on it',
    (select estimated_tax from public.tax_estimates where id = d.est)
      || ' / ' || (select sum(amount) from public.tax_estimate_payments where org_id = d.org),
    '456000.00 / 38000.00');
  perform pg_temp.check_eq('the schedule adds up to the estimate',
    (select sum(amount) from public.tax_estimate_schedule(d.est)), 456000.00);

  select * into s from public.tax_estimate_payment_summary(d.est);
  perform pg_temp.check_eq('and the summary carries the money',
    s.scheduled_total || ' / ' || s.paid_total || ' / ' || s.outstanding_total,
    '456000.00 / 38000.00 / 418000.00');
  insert into t_seen values ('clerk', s.overdue_count, s.next_due_on, s.instalments, s.instalments_paid);
end $$;

reset role;

do $$
begin
  -- The same deadlines for both, so the salesman's were not invented.
  perform pg_temp.check_eq('the salesman and the clerk are told the same dates and counts',
    (select overdue || '/' || next_due || '/' || instalments || '/' || paid
       from t_seen where who = 'sales'),
    (select overdue || '/' || next_due || '/' || instalments || '/' || paid
       from t_seen where who = 'clerk'));
  perform pg_temp.check_eq('one of twelve paid',
    (select paid from t_seen where who = 'clerk'), 1);
  perform pg_temp.check_true('anon calls neither function',
    not has_function_privilege('anon', 'public.tax_estimate_schedule(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.tax_estimate_payment_summary(uuid)', 'execute'));
end $$;

rollback;

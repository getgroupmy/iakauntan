-- =====================================================================
-- iAkauntan :: a payroll run is kept as it was posted (0817)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_records.sql
--
-- A posted run's payslips are what the statutory submissions, the EA
-- form and the bank file are built from, and the guard that keeps them
-- asks the run's status. Before `0817` a client could write that status:
-- January set back to calculated, its net pay raised RM1,000 and its PCB
-- set to nought, and set posted again -- the bank file paid RM7,569.35
-- and the EA form said no tax was deducted, under a journal that said
-- otherwise. Asked as the owner, with the role `authenticated`; the
-- payroll functions are asked to go on writing all four tables.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pr (
  org uuid, owner uuid, emp uuid, period uuid, run uuid, slip uuid, line uuid);
grant select on t_pr to authenticated;

do $$
declare
  r t_pr;
begin
  r.org := pg_temp.test_org('Gaji Terkunci Sdn Bhd', array['hr', 'payroll']);
  r.owner := (select user_id from public.org_members
               where org_id = r.org and role = 'owner' limit 1);
  perform pg_temp.sign_in_as(r.owner);
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, bank_name, bank_account_no)
  values (r.org, 'S1', 'Sapu Satu', date '2020-01-01', 8000,
          date '1990-01-01', 'citizen', 'Maybank', '1234567890')
  returning id into r.emp;

  r.period := public.ensure_pay_period(r.org, 2026, 1);
  r.run := public.create_payroll_run(r.org, r.period, 'January');
  perform public.calculate_payroll_run(r.run);
  perform public.post_payroll_run(r.run);
  select id into r.slip from public.payslips where run_id = r.run;
  select id into r.line from public.payslip_lines
   where payslip_id = r.slip order by line_no limit 1;

  insert into t_pr select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_pr), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The posted run is read, and not written
-- =====================================================================
do $$
declare
  d t_pr;
begin
  select * into d from t_pr;
  perform pg_temp.check_eq('the owner runs payroll as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('January is posted: RM6,569.35 net and RM508.65 PCB',
    (select r.status || '/' || s.net_pay || '/' || s.pcb
       from public.payroll_runs r join public.payslips s on s.run_id = r.id
      where r.id = d.run), 'posted/6569.35/508.65');

  -- What was measured: the run set back, so its payslip could be edited.
  perform pg_temp.check_refused('a posted run is not set back to calculated',
    format($q$update public.payroll_runs set status = 'calculated' where id = %L$q$, d.run),
    'permission denied for table payroll_runs', '42501');
  perform pg_temp.check_refused('nor deleted, payslips and all',
    format('delete from public.payroll_runs where id = %L', d.run),
    'permission denied for table payroll_runs', '42501');
  perform pg_temp.check_refused('nor one typed in',
    format($q$insert into public.payroll_runs (org_id, run_no, period_id, status)
              values (%L, 'PYR-BY-HAND', %L, 'posted')$q$, d.org, d.period),
    'permission denied for table payroll_runs', '42501');

  perform pg_temp.check_refused('a payslip''s net pay is not raised by hand',
    format('update public.payslips set net_pay = net_pay + 1000, pcb = 0 where id = %L', d.slip),
    'permission denied for table payslips', '42501');
  perform pg_temp.check_refused('nor a payslip deleted',
    format('delete from public.payslips where id = %L', d.slip),
    'permission denied for table payslips', '42501');
  perform pg_temp.check_refused('nor one typed in',
    format($q$insert into public.payslips (org_id, run_id, employee_id, employee_no, employee_name)
              values (%L, %L, %L, 'S1', 'Sapu Satu')$q$, d.org, d.run, d.emp),
    'permission denied for table payslips', '42501');

  perform pg_temp.check_refused('a payslip''s line is not changed',
    format('update public.payslip_lines set amount = amount + 1000 where id = %L', d.line),
    'permission denied for table payslip_lines', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.payslip_lines where id = %L', d.line),
    'permission denied for table payslip_lines', '42501');
  perform pg_temp.check_refused('nor one added to a posted payslip',
    format($q$insert into public.payslip_lines (org_id, payslip_id, line_no, kind, code, description, amount)
              values (%L, %L, 99, 'earning', 'BONUS', 'By hand', 1000)$q$, d.org, d.slip),
    'permission denied for table payslip_lines', '42501');

  perform pg_temp.check_refused('a period''s pay date is not moved under its run',
    format($q$update public.pay_periods set pay_date = date '2026-01-31' where id = %L$q$, d.period),
    'permission denied for table pay_periods', '42501');
  perform pg_temp.check_refused('nor a period deleted',
    format('delete from public.pay_periods where id = %L', d.period),
    'permission denied for table pay_periods', '42501');
  perform pg_temp.check_refused('nor one typed in',
    format($q$insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
              values (%L, '2027-12', date '2027-12-01', date '2027-12-31', date '2027-12-25')$q$, d.org),
    'permission denied for table pay_periods', '42501');

  -- So what January's run was built from is what it still says.
  perform pg_temp.check_eq('the bank instruction still pays RM6,569.35',
    (select amount from public.payroll_payment_instruction(d.run)), 6569.35::numeric);
  perform pg_temp.check_eq('and the EA form still says RM508.65 was deducted',
    (public.ea_statement(d.emp, 2026) -> 'deductions' ->> 'mtd')::numeric, 508.65::numeric);
end $$;

-- =====================================================================
-- The road: February, through the functions, by the same client
-- =====================================================================
do $$
declare
  d   t_pr;
  v_p uuid;
  v_r uuid;
begin
  select * into d from t_pr;
  v_p := public.ensure_pay_period(d.org, 2026, 2);
  v_r := public.create_payroll_run(d.org, v_p, 'February');
  perform public.calculate_payroll_run(v_r);
  perform pg_temp.check_eq('February is calculated through its function',
    (select status::text from public.payroll_runs where id = v_r), 'calculated');
  perform public.post_payroll_run(v_r);
  perform public.mark_payroll_paid(v_r);
  perform pg_temp.check_true('and posted and paid through theirs',
    (select status = 'paid' and gl_entry_id is not null and paid_at is not null
       from public.payroll_runs where id = v_r));
  perform pg_temp.check_eq('with a payslip the client reads',
    (select count(*)::integer from public.payslips where run_id = v_r), 1);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the four payroll tables',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('payroll_runs', 'payslips', 'payslip_lines', 'pay_periods')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;

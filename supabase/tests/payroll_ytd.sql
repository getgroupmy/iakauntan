-- =====================================================================
-- iAkauntan :: the year to date is what was paid (0807)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_ytd.sql
--
-- `payroll_ytd` is what every later month's PCB is computed against,
-- and `post_payroll_run` is the only thing that writes it. Before
-- `0807` anybody who may run payroll could write it too: the year to
-- date edited by hand took February's PCB from RM508.60 to RM149.55.
-- Asked as the owner, with the role `authenticated`, which is who the
-- app is; the payroll functions are asked to go on writing it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_py (org uuid, owner uuid, emp uuid, jan_pcb numeric);
grant select on t_py to authenticated;

do $$
declare
  r   t_py;
  v_p uuid;
  v_r uuid;
begin
  r.org := pg_temp.test_org('Gaji Setahun Sdn Bhd', array['hr', 'payroll']);
  r.owner := (select user_id from public.org_members
               where org_id = r.org and role = 'owner' limit 1);
  perform pg_temp.sign_in_as(r.owner);
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (r.org, 'S1', 'Sapu Satu', date '2020-01-01', 8000,
          date '1990-01-01', 'citizen')
  returning id into r.emp;

  v_p := public.ensure_pay_period(r.org, 2026, 1);
  v_r := public.create_payroll_run(r.org, v_p, 'January');
  perform public.calculate_payroll_run(v_r);
  perform public.post_payroll_run(v_r);
  r.jan_pcb := (select pcb from public.payslips
                 where run_id = v_r and employee_id = r.emp);

  insert into t_py select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_py), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d    t_py;
  v_p  uuid;
  v_r  uuid;
  v_feb numeric;
begin
  select * into d from t_py;
  perform pg_temp.check_eq('the owner runs payroll as a client', current_user, 'authenticated');
  perform pg_temp.check_true('and January paid some tax, or nothing below asks anything',
    d.jan_pcb > 0);

  -- Read, as before.
  perform pg_temp.check_eq('the year to date is read: January''s tax',
    (select pcb from public.payroll_ytd where employee_id = d.emp and tax_year = 2026),
    d.jan_pcb);

  -- Not written by hand.
  perform pg_temp.check_refused('the year to date takes no insert',
    format($q$insert into public.payroll_ytd (org_id, employee_id, tax_year)
              values (%L, %L, 2025)$q$, d.org, d.emp),
    'permission denied for table payroll_ytd', '42501');
  perform pg_temp.check_refused('nor the edit that was measured: more tax paid, less earned',
    format($q$update public.payroll_ytd
                 set pcb = pcb + 3000, taxable_income = taxable_income - 5000
               where employee_id = %L$q$, d.emp),
    'permission denied for table payroll_ytd', '42501');
  perform pg_temp.check_refused('nor a delete, which would start the year again',
    format('delete from public.payroll_ytd where employee_id = %L', d.emp),
    'permission denied for table payroll_ytd', '42501');

  -- The road: February calculated and posted through the functions, by
  -- the same client, against the year to date January left.
  v_p := public.ensure_pay_period(d.org, 2026, 2);
  v_r := public.create_payroll_run(d.org, v_p, 'February');
  perform public.calculate_payroll_run(v_r);
  v_feb := (select pcb from public.payslips where run_id = v_r and employee_id = d.emp);
  perform pg_temp.check_eq(
    'February''s tax is worked against what January paid, not RM149.55',
    v_feb, 508.60);
  perform public.post_payroll_run(v_r);
  perform pg_temp.check_true('and posting it adds February to the year to date',
    (select months_paid = 2 and pcb = d.jan_pcb + v_feb
       from public.payroll_ytd where employee_id = d.emp and tax_year = 2026));
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the year to date',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'payroll_ytd'
        and cmd <> 'SELECT'), 0);
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: the statutory inputs are in range (0821)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statutory_inputs_in_range.sql
--
-- CP38, zakat, the voluntary EPF rates and a dependant's share of a
-- relief go straight into the payroll engine, and only their screens
-- kept them in range: voluntary rates of -11 and -13 took an RM8,000
-- employee's EPF to RM0.00 and the employer's to -RM80.00, and a
-- child's share of 400 per cent took PCB from RM413.65 to RM318.65.
-- `0821` puts the screens' bounds on the tables. The numbers the engine
-- makes of figures in range are asserted, so that a bound that moved
-- them would show. Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_si (org uuid, owner uuid, emp uuid, run uuid, kid uuid);
grant select on t_si to authenticated;

do $$
declare
  r t_si;
begin
  r.org := pg_temp.test_org('Caruman Sdn Bhd', array['hr', 'payroll']);
  r.owner := (select user_id from public.org_members
               where org_id = r.org and role = 'owner' limit 1);
  perform pg_temp.sign_in_as(r.owner);
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, marital_status)
  values (r.org, 'S1', 'Sapu Satu', date '2020-01-01', 8000,
          date '1990-01-01', 'citizen', 'married')
  returning id into r.emp;
  r.run := public.create_payroll_run(r.org,
    public.ensure_pay_period(r.org, 2026, 1), 'January');
  insert into t_si select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_si), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_si;
begin
  select * into d from t_si;
  perform pg_temp.check_eq('the owner runs payroll as a client', current_user, 'authenticated');

  perform public.calculate_payroll_run(d.run);
  perform pg_temp.check_eq('RM8,000 pays EPF of RM880 and RM960, and PCB of RM445.30',
    (select epf_employee || '/' || epf_employer || '/' || pcb
       from public.payslips where run_id = d.run), '880.00/960.00/445.30');

  -- What was measured: the bounds the screens keep, written past.
  perform pg_temp.check_refused('a voluntary EPF rate below nothing',
    format('update public.employees set epf_voluntary_employee_rate = -11 where id = %L', d.emp),
    '%employees_epf_voluntary_employee_rate_ck%', '23514');
  perform pg_temp.check_refused('nor the employer''s',
    format('update public.employees set epf_voluntary_employer_rate = -13 where id = %L', d.emp),
    '%employees_epf_voluntary_employer_rate_ck%', '23514');
  perform pg_temp.check_refused('nor a rate above a hundred, which is an amount in the rate box',
    format('update public.employees set epf_voluntary_employee_rate = 100.001 where id = %L', d.emp),
    '%employees_epf_voluntary_employee_rate_ck%', '23514');
  perform pg_temp.check_refused('nor the employer''s',
    format('update public.employees set epf_voluntary_employer_rate = 100.001 where id = %L', d.emp),
    '%employees_epf_voluntary_employer_rate_ck%', '23514');
  perform pg_temp.check_refused('a CP38 direction below nothing',
    format('update public.employees set cp38_monthly = -300 where id = %L', d.emp),
    '%employees_cp38_not_negative_ck%', '23514');
  perform pg_temp.check_refused('nor zakat',
    format('update public.employees set zakat_monthly = -0.01 where id = %L', d.emp),
    '%employees_zakat_not_negative_ck%', '23514');
  perform pg_temp.check_refused('nor an employee made with one',
    format($q$insert into public.employees
                (org_id, employee_no, full_name, hire_date, basic_salary,
                 date_of_birth, residency_status, epf_voluntary_employee_rate)
              values (%L, 'S2', 'Dua', date '2020-01-01', 3000,
                      date '1990-01-01', 'citizen', -1)$q$, d.org),
    '%employees_epf_voluntary_employee_rate_ck%', '23514');

  -- Figures in range, and what the engine makes of them.
  update public.employees
     set epf_voluntary_employee_rate = 2, epf_voluntary_employer_rate = 1
   where id = d.emp;
  perform public.calculate_payroll_run(d.run);
  perform pg_temp.check_eq('two and one per cent above the statutory rate: RM1,040 and RM1,040',
    (select epf_employee || '/' || epf_employer from public.payslips where run_id = d.run),
    '1040.00/1040.00');
  update public.employees
     set epf_voluntary_employee_rate = 100, epf_voluntary_employer_rate = 100,
         cp38_monthly = 0, zakat_monthly = 0
   where id = d.emp;
  -- Read as the app reads it: since `0869` these are not columns a
  -- client selects, but what `employee_private_fields` gives back.
  perform pg_temp.check_eq('and a rate of a hundred, the edge, is a rate, either side''s',
    (select (fields ->> 'epf_voluntary_employee_rate')::numeric
            + (fields ->> 'epf_voluntary_employer_rate')::numeric
       from public.employee_private_fields(d.org, d.emp)), 200::numeric);
  update public.employees
     set epf_voluntary_employee_rate = 0, epf_voluntary_employer_rate = 0,
         cp38_monthly = 300
   where id = d.emp;
  perform public.calculate_payroll_run(d.run);
  perform pg_temp.check_eq('a CP38 of RM300 is deducted beside the PCB',
    (select pcb || '/' || cp38 from public.payslips where run_id = d.run), '445.30/300.00');
  update public.employees set cp38_monthly = 0 where id = d.emp;
end $$;

-- =====================================================================
-- A dependant's share of the relief
-- =====================================================================
do $$
declare
  d   t_si;
  v_k uuid;
begin
  select * into d from t_si;
  insert into public.employee_dependants
    (org_id, employee_id, name, relationship, date_of_birth)
  values (d.org, d.emp, 'Anak', 'child', date '2015-01-01')
  returning id into v_k;
  perform public.calculate_payroll_run(d.run);
  perform pg_temp.check_eq('one child, the whole relief: PCB RM413.65',
    (select pcb from public.payslips where run_id = d.run), 413.65::numeric);

  perform pg_temp.check_refused('a share of four hundred per cent',
    format('update public.employee_dependants set relief_claim_percent = 400 where id = %L', v_k),
    '%employee_dependants_relief_claim_percent_ck%', '23514');
  perform pg_temp.check_refused('nor below nothing',
    format('update public.employee_dependants set relief_claim_percent = -50 where id = %L', v_k),
    '%employee_dependants_relief_claim_percent_ck%', '23514');
  perform pg_temp.check_eq('so PCB is still RM413.65',
    (select pcb from public.payslips where run_id = d.run), 413.65::numeric);

  update public.employee_dependants set relief_claim_percent = 0 where id = v_k;
  perform public.calculate_payroll_run(d.run);
  perform pg_temp.check_eq('and none of it, the other edge, is the PCB of no child',
    (select pcb from public.payslips where run_id = d.run), 445.30::numeric);
end $$;

reset role;

rollback;

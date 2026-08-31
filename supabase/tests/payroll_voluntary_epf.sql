-- =====================================================================
-- iAkauntan :: contributing above the statutory EPF rate
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_voluntary_epf.sql
--
-- `employees.epf_voluntary_employee_rate` and its employer twin have
-- been read by the payroll engine since `0031` and asserted by nothing.
-- They are also the one figure on the employee record with a **unit**
-- trap in it: the engine divides by 100, so two points above the
-- statutory rate is `2`. Somebody reading "rate" as a fraction enters
-- `0.02` and contributes a two-hundredth of what they meant, which
-- nothing refuses, looks plausible on every payslip, and is discovered
-- by the employee at retirement.
--
-- The assertion is a difference rather than a figure. Two employees on
-- identical pay, one with voluntary rates and one without, so what is
-- proved is exactly the voluntary part — no rate table is hardcoded
-- here and a change to the statutory schedules moves both sides
-- together.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_plain  uuid;
  v_extra  uuid;
  v_ee     numeric;
  v_er     numeric;
  v_ee2    numeric;
  v_er2    numeric;
  v_wage   numeric;
begin
  v_org := pg_temp.test_org('Simpanan Tambahan Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-01', date '2026-01-01', date '2026-01-31',
          date '2026-01-31')
  returning id into v_period;

  -- The same person twice, except for the two rates. Same salary, same
  -- birthday, same residency — everything the statutory schedules read.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'P1', 'Statutory only', date '2020-01-01', 5000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_plain;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status,
     epf_voluntary_employee_rate, epf_voluntary_employer_rate)
  values (v_org, 'P2', 'Two and four above', date '2020-01-01', 5000,
          date '1992-04-15', 'single', 'citizen', 2, 4)
  returning id into v_extra;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-01') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select p.epf_employee, p.epf_employer, p.epf_wage
    into v_ee, v_er, v_wage
    from public.payslips p
   where p.run_id = v_run and p.employee_id = v_plain;
  select p.epf_employee, p.epf_employer
    into v_ee2, v_er2
    from public.payslips p
   where p.run_id = v_run and p.employee_id = v_extra;

  -- Stated first. Everything below is a difference, and a difference
  -- between two zeroes is zero.
  perform pg_temp.check_eq('the EPF wage is the salary', v_wage, 5000.00);
  perform pg_temp.check_true('and the statutory contribution is real',
    v_ee > 0 and v_er > 0);

  -- Two per cent of five thousand, rounded up to the ringgit the way
  -- `0031` rounds it: EPF contributions go up, never down.
  perform pg_temp.check_eq(
    'two per cent voluntary adds a hundred to the employee''s share',
    v_ee2 - v_ee, 100.00);
  perform pg_temp.check_eq(
    'and four per cent adds two hundred to the employer''s',
    v_er2 - v_er, 200.00);

  -- The trap, stated as an assertion rather than a comment. `2` is two
  -- per cent; if the engine ever read it as a fraction this figure
  -- would be one, and one ringgit a month is exactly the shape of
  -- mistake nobody queries.
  perform pg_temp.check_true(
    'the rate is a percentage and not a fraction — 2 is two per cent, '
    'not two ten-thousandths', v_ee2 - v_ee = 100.00);

  -- And the employee with no rates is untouched by the other one's.
  perform pg_temp.check_eq('a colleague''s voluntary rate is not theirs',
    (select p.epf_employee from public.payslips p
      where p.run_id = v_run and p.employee_id = v_plain), v_ee);

  perform pg_temp.sign_out();
end $$;

rollback;

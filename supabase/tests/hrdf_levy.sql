-- =====================================================================
-- iAkauntan :: the HRD Corp levy is charged on the levy's own wage
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hrdf_levy.sql
--
-- `salary_components.is_hrdf_liable` sat beside its three siblings from
-- `0028` until `0370` and nothing read it: the levy was charged on the
-- EPF wage.
--
-- Those are different wages, and the difference is statutory. The PSMB
-- Act 2001 counts basic salary and fixed allowances; HRD Corp's guidance
-- excludes overtime, commission, bonus and other incentives, service
-- charge, travelling allowance, gratuity, and payments on retirement,
-- retrenchment or termination. EPF is payable on most of those. A bonus
-- is the ordinary case and it is not small: one or two months' salary,
-- once a year, levied at one per cent on wages the Act says are not
-- wages — and the other eleven months agree to the ringgit, which is
-- what kept it hidden.
--
-- Asserted as a difference between two identical employees, so what is
-- proved is the bonus and nothing else. A change to the levy rate moves
-- both sides together and this file still holds.
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
  v_bonus  uuid;
  v_with   uuid;
  v_plain  uuid;
  v_ot     uuid;
  r_with   record;
  r_plain  record;
  r_ot     record;
begin
  v_org := pg_temp.test_org('Bonus Bulan Kedua Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Ten or more Malaysian employees, so one per cent and no opting in.
  insert into public.payroll_settings (org_id, hrdf_category)
  values (v_org, 'mandatory_10plus')
  on conflict (org_id) do update set hrdf_category = excluded.hrdf_category;

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-12', date '2026-12-01', date '2026-12-31',
          date '2026-12-31')
  returning id into v_period;

  -- Two months' salary in December, which is what a Malaysian bonus
  -- usually is. EPF is payable on it; the levy is not.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable)
  values (v_org, 'BONUS', 'Annual bonus', 'earning', 8000,
          true, true, true, true, false)
  returning id into v_bonus;

  -- The same person twice, except for the bonus.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B1', 'Bonused', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_with;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B2', 'Not bonused', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_plain;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_with, v_bonus, date '2020-01-01');

  -- And a third who worked overtime and was reimbursed a claim, so the
  -- other two exclusions are exercised on the same run.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B3', 'Overtime and a claim', date '2020-01-01', 5000,
          25, 8, date '1992-04-15', 'single', 'citizen')
  returning id into v_ot;
  -- Ten hours, so the overtime is RM 375.00 at time and a half.
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_ot, date '2026-12-14', 360),
         (v_org, v_ot, date '2026-12-15', 240);
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-B3-1', v_ot, date '2026-12-15', 'approved',
          300, 300, true);

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-12') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r_with from public.payslips
   where run_id = v_run and employee_id = v_with;
  select * into r_plain from public.payslips
   where run_id = v_run and employee_id = v_plain;
  select * into r_ot from public.payslips
   where run_id = v_run and employee_id = v_ot;

  -- ------------------------------------------------------------------
  -- The bonus reached EPF and not the levy
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the bonus is paid', r_with.gross_pay, 12000.00);
  perform pg_temp.check_eq('and EPF is charged on all of it',
    r_with.epf_wage, 12000.00);
  perform pg_temp.check_eq('while the levy wage is the basic salary',
    r_with.hrdf_wage, 4000.00);
  perform pg_temp.check_eq('so the levy is forty ringgit', r_with.hrdf, 40.00);

  -- The difference, which is the whole assertion. Before 0370 the
  -- bonused employee was levied 120.00 and the colleague 40.00 for the
  -- same wages under the Act.
  perform pg_temp.check_eq('the colleague without a bonus pays the same levy',
    r_with.hrdf - r_plain.hrdf, 0);
  perform pg_temp.check_eq('though EPF sees eight thousand more',
    r_with.epf_wage - r_plain.epf_wage, 8000.00);

  -- Stated so the two cannot both be wrong in the same direction and
  -- still pass: the rate is one per cent, not one.
  perform pg_temp.check_eq('and the levy is one per cent of that wage',
    r_with.hrdf, round(r_with.hrdf_wage / 100, 2));

  -- ------------------------------------------------------------------
  -- Overtime and a reimbursement, which the Act excludes by name
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('overtime and the claim are paid',
    r_ot.gross_pay, 5675.00);
  perform pg_temp.check_eq('the levy wage is the basic salary alone',
    r_ot.hrdf_wage, 5000.00);
  perform pg_temp.check_eq('so the levy is fifty', r_ot.hrdf, 50.00);

  -- Asserted on the lines as well as on the total. Overtime happens to
  -- be outside the EPF wage too, so a levy computed the old way agreed
  -- here by accident — the flag is what makes it a decision.
  perform pg_temp.check_true('the basic line is levy wages',
    (select is_hrdf_liable from public.payslip_lines
      where payslip_id = r_ot.id and code = 'BASIC'));
  perform pg_temp.check_true('the overtime line is not',
    not (select is_hrdf_liable from public.payslip_lines
          where payslip_id = r_ot.id and code = 'OT'));
  perform pg_temp.check_true('nor is money handed back to the employee',
    not (select is_hrdf_liable from public.payslip_lines
          where payslip_id = r_ot.id and code = 'CLAIMS'));
  perform pg_temp.check_true('and the bonus line carries the component''s flag',
    not (select is_hrdf_liable from public.payslip_lines
          where payslip_id = r_with.id and code = 'BONUS'));

  -- The run total is the sum of the three, not of the EPF wages.
  perform pg_temp.check_eq('the run totals the levy it actually charged',
    (select total_hrdf from public.payroll_runs where id = v_run),
    130.00);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A company that never registered
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Tidak Berdaftar Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  -- No hrdf_category: fewer than five employees, or an industry the Act
  -- does not cover. There is no levy to charge and no wage to charge it
  -- on, and the payslip should say nothing rather than say zero of
  -- something.
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-03', date '2026-03-01', date '2026-03-31',
          date '2026-03-31')
  returning id into v_period;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'N1', 'Nobody levied', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_emp;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-03') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_emp;
  perform pg_temp.check_eq('an unregistered company is levied nothing',
    r.hrdf, 0);
  -- The wage is still recorded. It is what the levy would be charged on
  -- the day the company crosses ten employees, and a company working out
  -- whether it is about to owe one needs the figure before it owes it.
  perform pg_temp.check_eq('and the wage it would be charged on is kept',
    r.hrdf_wage, 4000.00);
  perform pg_temp.check_true('no levy line appears on the payslip',
    not exists (select 1 from public.payslip_lines
                 where payslip_id = r.id and code = 'HRDF'));

  perform pg_temp.sign_out();
end $$;

rollback;

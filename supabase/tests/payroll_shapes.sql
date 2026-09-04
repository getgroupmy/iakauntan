-- =====================================================================
-- iAkauntan :: the employee shapes a payroll run has to survive
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_shapes.sql
--
-- `payroll_run.sql` pays three people and asserts every figure on their
-- payslips. It is a good file and it is not enough: a mutation sweep of
-- `calculate_payroll_run` killed 61 of 91 one-line mutants, and almost
-- every survivor was a branch those three employees never walk down.
-- Nobody in that fixture LEAVES. Nobody works a rest day or a public
-- holiday. Every allowance is a flat amount that is active for ever.
-- Nobody is paid a bonus. So a run that pays a leaver to the end of the
-- month, charges holiday overtime at the rest day rate, keeps paying an
-- allowance that ended in March, or annualises a bonus as if it were
-- salary passes that file without a mark on it.
--
-- This file is the other shapes. Each block names the mutant it is here
-- to kill, because an assertion whose reason is not written down is an
-- assertion somebody deletes later.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- =====================================================================
-- 1. Joiners, leavers, and sixty exactly
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_left   uuid;   -- last working day the 10th of a 31 day month
  v_gone   uuid;   -- left in December, before this period began
  v_sixty  uuid;   -- turns sixty ON the pay date
  r        record;
begin
  v_org := pg_temp.test_org('Leavers and Sixty Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-01', date '2026-01-01', date '2026-01-31',
          date '2026-01-31')
  returning id into v_period;

  -- 10/31 of RM3,100 is exactly RM1,000.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, last_working_date,
     basic_salary, working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'L1', 'Left on the tenth', date '2020-01-01',
          date '2026-01-10', 3100, 25, 8, date '1990-02-02', 'citizen')
  returning id into v_left;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, last_working_date,
     basic_salary, date_of_birth, residency_status)
  values (v_org, 'L2', 'Left before Christmas', date '2019-01-01',
          date '2025-12-19', 8000, date '1991-03-03', 'citizen')
  returning id into v_gone;

  -- Born 31 January 1966: sixty years old to the day on the pay date.
  -- SOCSO's Act 800 and EPF's over-sixty rates both begin AT sixty, not
  -- after it, so this is the employee who tells `>= 60` from `> 60` --
  -- and there is exactly one such employee per birthday per company, so
  -- a suite that does not name one will never meet them.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'L3', 'Sixty on the pay date', date '2010-01-01', 3000,
          25, 8, date '1966-01-31', 'citizen')
  returning id into v_sixty;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-01')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  -- MUTANT: `v_to := v_period.period_end` -- a leaver paid the whole
  -- month. RM3,100 instead of RM1,000, every month, for ever.
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_left;
  perform pg_temp.check_eq('a leaver is paid to their last working day',
    r.basic_salary, 1000.00);
  perform pg_temp.check_eq('and the line says which days those were',
    (select description from public.payslip_lines
      where payslip_id = r.id and code = 'BASIC'),
    'Basic salary (10 of 31 days)');

  -- MUTANT: dropping the `last_working_date >= period_start` filter --
  -- somebody who left last year is paid again this year.
  perform pg_temp.check_eq('somebody who left before the period has no payslip',
    (select count(*) from public.payslips
      where run_id = v_run and employee_id = v_gone), 0);
  perform pg_temp.check_eq('so the run pays two people',
    (select employee_count from public.payroll_runs where id = v_run), 2);

  -- MUTANT: `v_age > 60` -- sixty exactly falls back to Act 4 and the
  -- under-sixty EPF rates, which is both a wrong contribution and a
  -- wrong deduction from somebody's pay.
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_sixty;
  perform pg_temp.check_eq('at sixty exactly the employee side of EPF stops',
    r.epf_employee, 0);
  perform pg_temp.check_eq('and the employer side is the over-sixty rate',
    r.epf_employer, 120);        -- 4% of 3,000
  perform pg_temp.check_eq('at sixty exactly SOCSO is Act 800, so no employee side',
    r.socso_employee, 0);
  perform pg_temp.check_eq('and the employer pays the Act 800 rate',
    r.socso_employer, 37.50);    -- 1.25% of 3,000
  perform pg_temp.check_eq('EIS stops at sixty as well', r.eis_employee, 0);

  -- MUTANT: `case when false then v_emp.basic_salary` -- a full month
  -- pro-rated 31/31 comes to the same money and a different sentence,
  -- and the sentence is what the employee reads.
  perform pg_temp.check_eq('a full month does not claim to be pro-rated',
    (select description from public.payslip_lines
      where payslip_id = r.id and code = 'BASIC'), 'Basic salary');

  -- MUTANT: `where true` on the deduction values list -- a payslip that
  -- prints "EPF 0.00, SOCSO 0.00, EIS 0.00, CP38 0.00, Zakat 0.00" to
  -- somebody who owes none of them.
  perform pg_temp.check_eq('nothing that is nil is printed as a line',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and kind = 'deduction'
        and code in ('EPF', 'SOCSO', 'EIS', 'CP38', 'ZAKAT')), 0);
  perform pg_temp.check_eq('nor on the employer side',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and kind = 'employer_contribution'
        and code in ('EIS_ER', 'HRDF')), 0);

  raise notice 'ok   joiners, leavers and sixty exactly';
end $$;

-- =====================================================================
-- 2. Overtime: the three multipliers, and who sets them
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_e      uuid;
  v_no_pat uuid;   -- no working pattern at all
  r        record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Rest Days and Holidays Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-03', date '2026-03-01', date '2026-03-31',
          date '2026-03-31')
  returning id into v_period;

  -- RM5,000 over 25 days of 8 hours is RM25.00 an hour exactly.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'O1', 'Ordinary, rest day and holiday overtime',
          date '2020-01-01', 5000, 25, 8, date '1990-01-01', 'citizen')
  returning id into v_e;

  -- Two hours of each kind, and ninety minutes on top of the ordinary
  -- so the total is not a whole number of hours.
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes,
     ot_restday_minutes, ot_holiday_minutes)
  values (v_org, v_e, date '2026-03-09', 210, 120, 120);

  -- And overtime worked in the month before this one.
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_e, date '2026-02-25', 600);

  -- Somebody paid a salary with no working pattern recorded. The
  -- columns are NOT NULL and default to 26 and 8, so "not recorded"
  -- reaches the database as zero -- and zero is what the guard is
  -- written against, because dividing by it is an error that takes the
  -- whole payroll run down rather than one payslip.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'O2', 'No working pattern', date '2020-01-01', 4000,
          0, 0, date '1990-01-01', 'citizen')
  returning id into v_no_pat;

  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_no_pat, date '2026-03-09', 480);

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-03')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_e;

  -- MUTANT: `/ 60` instead of `/ 60.0` -- integer division, and three
  -- and a half hours of overtime become three.
  perform pg_temp.check_eq('overtime hours keep the half hour',
    r.ot_hours, 7.50);           -- 3.5 + 2 + 2

  -- There is no payroll_settings row for this company, so each
  -- multiplier is the one written into the function itself. Employment
  -- Act 1955 s.60A(3): one and a half times on a normal day, twice on a
  -- rest day, three times on a public holiday.
  --
  -- MUTANTS: 1.5 -> 1.0, 2.0 -> 1.5, 3.0 -> 2.0. Every company in
  -- `payroll_run.sql` HAS a settings row, whose column defaults happen
  -- to carry the same three numbers -- so the fallbacks were never
  -- reached and all three mutants lived. A company that has not opened
  -- the payroll settings screen is not a strange company; it is a new
  -- one.
  perform pg_temp.check_eq('ordinary overtime at time and a half',
    (select amount from public.payslip_lines
      where payslip_id = r.id and code = 'OT'),
    round(25 * (3.5 * 1.5 + 2 * 2.0 + 2 * 3.0), 2));   -- 331.25
  perform pg_temp.check_eq('and the rate on the line is the hourly rate',
    (select rate from public.payslip_lines
      where payslip_id = r.id and code = 'OT'), 25.0000);

  -- MUTANT: dropping the `work_date between` filter -- February's
  -- overtime paid again in March. Ten hours is RM375 of somebody
  -- else's money.
  perform pg_temp.check_true('last month''s overtime stays in last month',
    r.ot_hours = 7.50);

  -- MUTANT: `when true` on the working-pattern guard -- division by a
  -- null gives a null hourly rate, a null overtime amount, and a
  -- payslip with no gross pay on it at all.
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_no_pat;
  perform pg_temp.check_eq('no working pattern means no overtime pay',
    r.ot_amount, 0);
  perform pg_temp.check_eq('but the hours are still recorded', r.ot_hours, 8.00);
  perform pg_temp.check_eq('and the gross is the salary, not a null',
    r.gross_pay, 4000.00);

  -- ------------------------------------------------------------------
  -- The same month again, with the company's own multipliers
  -- ------------------------------------------------------------------
  -- MUTANT: replacing `coalesce(v_set.ot_normal_multiplier, 1.5)` with
  -- the constant `1.5` -- three columns on the payroll settings screen
  -- that the engine reads past. A company that agreed double time for
  -- ordinary overtime in its collective agreement would silently pay
  -- time and a half.
  insert into public.payroll_settings
    (org_id, ot_normal_multiplier, ot_restday_multiplier,
     ot_holiday_multiplier)
  values (v_org, 2.0, 2.5, 4.0)
  on conflict (org_id) do update set
    ot_normal_multiplier = excluded.ot_normal_multiplier,
    ot_restday_multiplier = excluded.ot_restday_multiplier,
    ot_holiday_multiplier = excluded.ot_holiday_multiplier;

  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_e;
  perform pg_temp.check_eq('the company''s own multipliers are the ones used',
    r.ot_amount,
    round(25 * (3.5 * 2.0 + 2 * 2.5 + 2 * 4.0), 2));   -- 500.00

  raise notice 'ok   overtime multipliers and the working pattern';
end $$;

-- =====================================================================
-- 3. Unpaid leave: which requests count, and how much of one
-- =====================================================================
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_e       uuid;
  v_unpaid  uuid;
  v_annual  uuid;
  r         record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Unpaid Leave Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-04', date '2026-04-01', date '2026-04-30',
          date '2026-04-30')
  returning id into v_period;

  -- RM2,600 over 26 working days is RM100 a day.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'U1', 'Four kinds of leave request', date '2019-01-01',
          2600, 26, 8, date '1990-01-01', 'citizen')
  returning id into v_e;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false) returning id into v_unpaid;
  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'ANNUAL', 'Annual leave', true) returning id into v_annual;

  -- (a) Approved and unpaid, wholly inside the month: two days.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-1', v_e, v_unpaid,
          date '2026-04-06', date '2026-04-07', 2, 'approved');

  -- (b) Approved and unpaid, but it runs on into May: six days from the
  -- 28th to the 3rd, of which three -- the 28th, 29th and 30th -- fall
  -- in April. Three sixths of six days.
  --
  -- MUTANTS: `least(lr.end_date, period_end)` -> `lr.end_date`, and
  -- `greatest(...) + 1` -> without the +1. Both change how much of a
  -- straddling request lands in this month, and a request that straddles
  -- a month end is the ordinary case at the end of every month.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-2', v_e, v_unpaid,
          date '2026-04-28', date '2026-05-03', 6, 'approved');

  -- (c) Approved and unpaid, but it began in March: five days from the
  -- 30th to the 3rd, of which three fall in April.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-3', v_e, v_unpaid,
          date '2026-03-30', date '2026-04-03', 5, 'approved');

  -- (d) Unpaid, inside the month, and NOT approved: submitted, and
  -- still sitting in somebody's queue.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-4', v_e, v_unpaid,
          date '2026-04-14', date '2026-04-20', 7, 'submitted');

  -- (e) Approved, inside the month, and PAID. Annual leave is leave
  -- somebody has already earned.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-5', v_e, v_annual,
          date '2026-04-21', date '2026-04-24', 4, 'approved');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-04')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_e;

  -- 2 + (6 * 3/6) + (5 * 3/5) = 2 + 3 + 3 = 8 days.
  --
  -- MUTANTS: dropping `status = 'approved'` adds seven days somebody
  -- never took; dropping `not lt.is_paid` deducts four days of annual
  -- leave the employee had already earned. Either is money taken off
  -- a payslip with no lawful reason, and neither showed up in a suite
  -- whose only leave request was approved, unpaid and inside the month.
  perform pg_temp.check_eq('only approved unpaid leave counts, and only its overlap',
    r.unpaid_leave_days, 8.00);
  perform pg_temp.check_eq('priced at the daily rate from the working pattern',
    r.unpaid_leave_amount, 800.00);
  perform pg_temp.check_eq('and it comes off the pay', r.gross_pay, 1800.00);

  raise notice 'ok   which leave requests reduce a payslip';
end $$;

-- =====================================================================
-- 4. Salary components: when they apply, and what they are worth
-- =====================================================================
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_e       uuid;
  v_pct     uuid;
  v_off     uuid;
  v_later   uuid;
  v_ended   uuid;
  r         record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Allowances Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status)
  values (v_org, 'A1', 'Four allowances, one of them live',
          date '2019-01-01', 4000, 26, 8, date '1990-01-01', 'citizen')
  returning id into v_e;

  -- A percentage of basic, with no flat default. `nullif(default_amount,
  -- 0)` is what lets the percentage through: the column defaults to
  -- zero, not to null, so without the nullif every percentage component
  -- in the product pays nothing.
  --
  -- MUTANTS: dropping the nullif (a zero default wins and the allowance
  -- is nil), and replacing the percentage arm with 0 (same outcome by a
  -- different route). Both were alive because every allowance in the
  -- suite was a flat amount.
  insert into public.salary_components
    (org_id, code, name, kind, percent_of_basic)
  values (v_org, 'HOUSING', 'Housing allowance', 'earning', 12.5)
  returning id into v_pct;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_active)
  values (v_org, 'OLD', 'Discontinued allowance', 'earning', 500, false)
  returning id into v_off;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount)
  values (v_org, 'NEXTYEAR', 'Starts in December', 'earning', 700)
  returning id into v_later;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount)
  values (v_org, 'FINISHED', 'Ended in March', 'earning', 900)
  returning id into v_ended;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from, effective_to)
  values
    (v_org, v_e, v_pct,   date '2019-01-01', null),
    (v_org, v_e, v_off,   date '2019-01-01', null),
    (v_org, v_e, v_later, date '2026-12-01', null),
    (v_org, v_e, v_ended, date '2019-01-01', date '2026-03-31');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_e;

  -- 12.5% of RM4,000 is RM500, and nothing else is payable this month.
  perform pg_temp.check_eq('a percentage of basic is paid as a percentage',
    (select amount from public.payslip_lines
      where payslip_id = r.id and code = 'HOUSING'), 500.00);

  -- MUTANTS: `sc.is_active` -> true, the effective_from filter -> true,
  -- the effective_to filter -> true. Each is an allowance on a payslip
  -- that nobody is entitled to, and each was reachable only by having
  -- one on file.
  perform pg_temp.check_eq('a component switched off is not paid',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and code = 'OLD'), 0);
  perform pg_temp.check_eq('a component that starts in December is not paid in June',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and code = 'NEXTYEAR'), 0);
  perform pg_temp.check_eq('a component that ended in March is not paid in June',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and code = 'FINISHED'), 0);

  perform pg_temp.check_eq('so the gross is the salary and the one live allowance',
    r.gross_pay, 4500.00);
  perform pg_temp.check_eq('and there are two earning lines',
    (select count(*) from public.payslip_lines
      where payslip_id = r.id and kind = 'earning'), 2);

  raise notice 'ok   which salary components reach a payslip';
end $$;

-- =====================================================================
-- 5a. A bonus in June: added to the year once, not annualised
-- =====================================================================
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_e       uuid;
  v_bonus   uuid;
  v_award   uuid;
  v_slip    record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Mid Year Bonus Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'M1', 'Salary and a mid-year bonus', date '2019-01-01',
          6000, 26, 8, date '1985-01-01', 'single', 'citizen')
  returning id into v_e;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_additional_remuneration)
  values (v_org, 'BONUS', 'Mid-year bonus', 'earning', 12000, true)
  returning id into v_bonus;

  -- Flagged additional and NOT taxable: the setup screen offers the two
  -- switches independently, and nothing in the schema pairs them.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable, is_additional_remuneration)
  values (v_org, 'AWARD', 'Long service award', 'earning', 1000,
          false, false, false, false, false, true)
  returning id into v_award;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_e, v_bonus, date '2026-06-01'),
         (v_org, v_e, v_award, date '2026-06-01');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select * into v_slip from public.payslips
   where run_id = v_run and employee_id = v_e;

  perform pg_temp.check_eq('the gross carries all three earnings',
    v_slip.gross_pay, 19000.00);
  perform pg_temp.check_eq('the taxable wage leaves the award out',
    v_slip.taxable_income, 18000.00);

  -- MUTANT: `v_base.taxable` instead of `v_base.taxable -
  -- v_base.additional`. Seven months remain, so a RM12,000 bonus
  -- annualised as ordinary pay adds RM84,000 to the year instead of
  -- RM12,000 -- and the tax on it comes off this one payslip.
  perform pg_temp.check_eq('the bonus is added to the year once, not annualised',
    v_slip.pcb,
    (select c.pcb from app.calc_pcb(v_e, 6000, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-06-30', 12000,
             round(v_slip.epf_employee * 12000 / 18000, 2)) c));
  perform pg_temp.check_true('and it is a real deduction, not zero',
    v_slip.pcb > 0);
  perform pg_temp.check_true('which is not what annualising it would give',
    v_slip.pcb <>
    (select c.pcb from app.calc_pcb(v_e, 18000, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-06-30', 0, 0) c));

  -- MUTANT: `additional` without its `is_taxable` filter -- the untaxed
  -- award joins the bonus arm, so RM1,000 that is not income at all
  -- moves out of the annualised half and into the taxed-once half.
  perform pg_temp.check_true('an untaxed award is not additional remuneration',
    v_slip.pcb <>
    (select c.pcb from app.calc_pcb(v_e, 5000, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-06-30', 13000,
             round(v_slip.epf_employee * 12000 / 18000, 2)) c));

  raise notice 'ok   a mid-year bonus is added to the year once';
end $$;

-- =====================================================================
-- 5b. A bonus in December: the EPF that belongs to it
-- =====================================================================
--
-- Two mutants live in the EPF argument of this one PCB call, and both
-- are about how much of the month's EPF belongs to the bonus:
--
--   * `additional_epf_wage` without its `is_epf_liable` filter
--   * the proportional split replaced by the whole month's EPF
--
-- Both only MOVE anything while the year's EPF relief is under
-- its RM4,000 cap: above the cap `least(v_epf_used + v_add_epf, 4000)`
-- is 4,000 whatever the split is, and the mutants are equivalent
-- BECAUSE OF THE FIGURES rather than by construction. On an ordinary
-- salary that cap is reached by about RM3,000 a month, which is below
-- where PCB starts -- so a payslip that has both a live EPF split and a
-- non-zero PCB has most of its pay OUTSIDE EPF wages.
--
-- That is a commission structure: a small contractual basic, a large
-- taxable allowance that is not EPF wages, and a year-end payment split
-- between something inside EPF and something outside it. It is the
-- shape this block is built on, and it is built on it deliberately.
--
-- In December the projection has one month left in it, so moving a
-- ringgit between ordinary pay and additional remuneration leaves the
-- year unchanged -- which is why the two mutants about WHICH money is
-- additional are killed in 5a, in June, and not here.
-- =====================================================================
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_e       uuid;
  v_allow   uuid;
  v_bonus   uuid;
  v_award   uuid;
  v_share   uuid;
  v_slip    record;
  v_split   numeric;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Bonus Month Co');

  -- December: `calc_pcb` projects the month's EPF over the months that
  -- REMAIN, so in any earlier month the projection alone clears the cap
  -- and nothing about the bonus's own share can be seen. December is
  -- also when bonuses are paid.
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-12', date '2026-12-01', date '2026-12-31',
          date '2026-12-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B1', 'Small basic, large allowance, year-end payment',
          date '2019-01-01', 800, 26, 8, date '1985-01-01', 'single',
          'citizen')
  returning id into v_e;

  -- Taxable, and not wages for any of the four contributions.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable)
  values (v_org, 'COMMS', 'Commission allowance', 'earning', 5000,
          true, false, false, false, false)
  returning id into v_allow;

  -- A contractual bonus: taxable, EPF wages, additional remuneration.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_additional_remuneration)
  values (v_org, 'BONUS', 'Contractual bonus', 'earning', 2000, true)
  returning id into v_bonus;

  -- An ex gratia payment: taxable and additional, and outside EPF
  -- wages, so the bonus's share of the month's EPF is NOT the whole
  -- additional amount's share.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable, is_additional_remuneration)
  values (v_org, 'EXGRATIA', 'Ex gratia payment', 'earning', 10000,
          true, false, false, false, false, true)
  returning id into v_share;

  -- A long service award the company has flagged additional but NOT
  -- taxable. The setup screen offers both switches independently and
  -- nothing in the schema says additional remuneration must be taxable,
  -- so this shape exists whether or not it should.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable, is_additional_remuneration)
  values (v_org, 'AWARD', 'Long service award', 'earning', 1000,
          false, false, false, false, false, true)
  returning id into v_award;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_e, v_allow, date '2019-01-01'),
         (v_org, v_e, v_bonus, date '2026-12-01'),
         (v_org, v_e, v_share, date '2026-12-01'),
         (v_org, v_e, v_award, date '2026-12-01');

  -- Eleven months already paid: RM5,800 a month, and 11% of the RM800
  -- basic each time.
  insert into public.payroll_ytd
    (org_id, employee_id, tax_year, gross_pay, taxable_income,
     epf_employee, net_pay, months_paid)
  values (v_org, v_e, 2026, 63800, 63800, 11 * 88, 63800 - 11 * 88, 11);

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-12')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select * into v_slip from public.payslips
   where run_id = v_run and employee_id = v_e;

  -- 800 + 5,000 + 2,000 + 10,000 + 1,000
  perform pg_temp.check_eq('the gross carries all five earnings',
    v_slip.gross_pay, 18800.00);
  -- The award is not taxable.
  perform pg_temp.check_eq('the taxable wage leaves the award out',
    v_slip.taxable_income, 17800.00);
  -- Only the basic and the contractual bonus are EPF wages.
  perform pg_temp.check_eq('the EPF wage is the basic and the bonus',
    v_slip.epf_wage, 2800.00);

  -- The month splits into RM5,800 of ordinary pay and RM12,000 of
  -- additional remuneration -- the bonus and the ex gratia, and NOT the
  -- award. The bonus's EPF is its share of the month's EPF: 2,000 of
  -- the 2,800 EPF wage.
  v_split := round(v_slip.epf_employee * 2000 / 2800, 2);
  perform pg_temp.check_eq('the bonus is added to the year once, not annualised',
    v_slip.pcb,
    (select c.pcb from app.calc_pcb(v_e, 5800, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-12-31', 12000, v_split) c));
  perform pg_temp.check_true('and it is a real deduction, not zero',
    v_slip.pcb > 0);

  -- The two EPF mutants stated as the difference they make, rather
  -- than as a second copy of the arithmetic.
  --
  -- Drop `is_epf_liable` from the additional_epf_wage filter and the
  -- bonus is credited with the EPF relief of RM12,000 of pay, RM10,000
  -- of which never touched an EPF wage.
  perform pg_temp.check_true('the bonus''s EPF is measured on the EPF wage',
    v_slip.pcb <>
    (select c.pcb from app.calc_pcb(v_e, 5800, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-12-31', 12000,
             round(v_slip.epf_employee * 12000 / 2800, 2)) c));

  -- And hand the bonus arm the whole month's EPF instead of its share,
  -- which relieves the basic salary's contribution twice.
  perform pg_temp.check_true('and it is a share of it, not all of it',
    v_slip.pcb <>
    (select c.pcb from app.calc_pcb(v_e, 5800, v_slip.epf_employee,
             v_slip.socso_employee + v_slip.eis_employee, 0,
             date '2026-12-31', 12000, v_slip.epf_employee) c));

  raise notice 'ok   a bonus, and the EPF that belongs to it';
end $$;

-- =====================================================================
-- 6. Voluntary EPF, and somebody exempt from EIS
-- =====================================================================
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_vol     uuid;
  v_no_eis  uuid;
  r         record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Voluntary EPF Co');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-05', date '2026-05-01', date '2026-05-31',
          date '2026-05-31')
  returning id into v_period;

  -- The employer tops its own share up by four points, which is the
  -- ordinary reason an employer sets this: a benefit, not a statutory
  -- rate. On RM5,000 that is RM200 on top of the 13% band.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status, epf_voluntary_employer_rate)
  values (v_org, 'V1', 'Employer tops up EPF', date '2019-01-01', 5000,
          25, 8, date '1990-01-01', 'citizen', 4)
  returning id into v_vol;

  -- Somebody under sixty who is not an insured person under the
  -- Employment Insurance System Act: a sole proprietor's spouse, for
  -- one, whom the Act names as excluded.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, residency_status, eis_eligible)
  values (v_org, 'V2', 'Not an insured person', date '2019-01-01', 5000,
          25, 8, date '1990-01-01', 'citizen', false)
  returning id into v_no_eis;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-05')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  -- MUTANT: `coalesce(v_emp.epf_voluntary_employer_rate, 0)` -> 0. The
  -- employee side of this was already asserted; the employer side was
  -- not, and it is the side that is actually used -- an employee tops
  -- up through KWSP directly, an employer tops up through payroll.
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_vol;
  perform pg_temp.check_eq('the statutory employer rate is unchanged',
    r.epf_wage, 5000.00);
  perform pg_temp.check_eq('and the voluntary points are added to it',
    r.epf_employer, 650 + 200);
  perform pg_temp.check_eq('the employee side is untouched by it',
    r.epf_employee, 550);
  perform pg_temp.check_eq('and the employer''s line on the payslip says so',
    (select amount from public.payslip_lines
      where payslip_id = r.id and code = 'EPF_ER'), 850.00);

  -- MUTANT: dropping `v_emp.eis_eligible` from the EIS guard. Under
  -- sixty the age gate does not fire, so the flag is the only thing
  -- stopping the contribution -- and `payroll_run.sql`'s only
  -- ineligible employee was ineligible by AGE, which the other half of
  -- the same `if` already catches.
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_no_eis;
  perform pg_temp.check_eq('somebody not insured under the EIS Act pays nothing',
    r.eis_employee, 0);
  perform pg_temp.check_eq('and the employer pays nothing for them either',
    r.eis_employer, 0);
  perform pg_temp.check_true('though they are under sixty',
    app.age_at((select date_of_birth from public.employees where id = v_no_eis),
               date '2026-05-31') < 60);
  perform pg_temp.check_eq('while SOCSO, which is a different Act, is charged',
    r.socso_employee, 25.00);

  raise notice 'ok   voluntary EPF and an EIS exemption';
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: what the payroll engine was never asked
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/payroll_engine_sweep.sql
--
-- `calculate_payroll_run` and `post_payroll_run` were swept: one hundred
-- and forty-five one-line mutants installed over the live definitions,
-- the fifteen files that exercise payroll run against each, the
-- definition restored between every one. A hundred and thirty-one died.
-- This file is the fourteen that did not.
--
-- Four of them are equivalent, and an equivalent mutant is a finding
-- too -- it names a line that cannot be wrong, or one whose correctness
-- is held up by something else:
--
--   * `v_worked >= v_days` -> `>`. On a full month the else branch
--     computes `basic * days / days`, which IS basic. The branch is
--     there for the description, not the amount, and the description's
--     own copy of the test dies.
--
--   * The gross aggregate's `l.kind = 'earning'` -> `is not null`. The
--     aggregate runs BEFORE the deduction and employer lines are
--     inserted, so at that moment the two sets are the same rows. The
--     filter is load-bearing only against a future reordering, which is
--     not a thing a mutant can express.
--
--   * The HRD levy's verification guard `and v_set.hrdf_category is not
--     null` -> dropped. `v_hrdf_ver` is declared `true` and, unlike its
--     four siblings, is NOT reset per employee -- so with no category
--     it is still `true` from the initialiser and the guard changes
--     nothing. A masking pair: the guard leans on a declaration forty
--     lines above it. Section 6 asserts the behaviour the pair produces
--     so that breaking EITHER half is caught.
--
--   * `insured_wage('socso', v_soc_cat, ...)` -> `'act4'`. Act 4 and
--     Act 800 are seeded with the same RM 6,000 ceiling, so the
--     category cannot change the answer. Section 9 is a tripwire on
--     that fact rather than on the code.
--
-- The other ten are gaps, and they are asserted below -- except that
-- one of them turned out not to be a gap at all. `and v_base.epf_wage >
-- 0` -> `>= 0` survived, and chasing WHY is what found `0544`: on a
-- zero wage the three statutory calls were skipped entirely, so
-- `calc_statutory`'s zero-wage branch was never reached and the
-- caller's `v_ver` stayed at its reset value of `true`. A full month of
-- unpaid leave reported an unverified EPF table as checked. The mutant
-- was the fix; section 8 asserts the fixed behaviour.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1. December worked, January paid
--
-- The one that matters most. A pay period ending 31 December and paid
-- on 5 January belongs to the NEW year -- income tax is charged on what
-- was received in the year of assessment, so the EA form, the YTD row
-- the next month's PCB reads, and the statutory table consulted are all
-- the paying year's. Reading the year off `period_start` gives the
-- previous one and nothing in the suite noticed, because every fixture
-- in it pays inside the month it worked.
--
-- Both halves are here on one run: the year the YTD lands in, and the
-- EPF table the contribution is charged under.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  v_2027   uuid;
  v_slip   record;
begin
  v_org := pg_temp.test_org('Gaji Disember Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2027-01-01');

  -- A new EPF table from the first of January, at a rate nothing else
  -- uses, so the figure names which table answered.
  insert into public.statutory_schedules
    (body, name, method, effective_from, effective_to, result_rounding,
     is_verified)
  values ('epf', 'EPF from 2027', 'percentage', date '2027-01-01', null,
          'up_ringgit', true)
  returning id into v_2027;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employee_rate, employer_rate)
  values (v_2027, 'citizen_under60', 0, 9.0000, 10.0000);

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-12', date '2026-12-01', date '2026-12-31',
          date '2027-01-05')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'D1', 'Dibayar Januari', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_emp;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-12') returning id into v_run;
  perform public.calculate_payroll_run(v_run);
  select * into v_slip from public.payslips where run_id = v_run;

  -- THE TABLE IN FORCE ON THE PAY DATE. 9% of 4,000 is 360; the old
  -- table's 11% would be 440, which is what reading `period_start`
  -- would have charged.
  perform pg_temp.check_eq('EPF is charged under the table in force when paid',
    v_slip.epf_employee, 360.00);
  perform pg_temp.check_eq('and the employer half likewise',
    v_slip.epf_employer, 400.00);
  perform pg_temp.check_true('and the payslip names that table',
    v_slip.epf_schedule_id = v_2027);

  perform public.post_payroll_run(v_run);

  -- THE YEAR IT COUNTS TOWARDS.
  perform pg_temp.check_eq('the year to date is the year it was PAID',
    (select tax_year from public.payroll_ytd
      where employee_id = v_emp), 2027);
  perform pg_temp.check_eq('and nothing landed in the year it was worked',
    (select count(*) from public.payroll_ytd
      where employee_id = v_emp and tax_year = 2026), 0);

  -- THE ENTRY POINTS BACK AT THE RUN. Without this the payroll journal
  -- is a journal nobody can get from the run that raised it, and
  -- "what happened to this payroll" has nothing to follow.
  perform pg_temp.check_eq('the journal names the run it came from',
    (select source_id::text from public.gl_entries
      where org_id = v_org and source = 'payroll'), v_run::text);
  perform pg_temp.check_eq('and says which table that id is in',
    (select source_table from public.gl_entries
      where org_id = v_org and source = 'payroll'), 'payroll_runs');
end $$;

-- ---------------------------------------------------------------------
-- 2. A payslip records which table each figure came from
--
-- Four schedule ids and a verified flag. The flag was asserted; the ids
-- were not, so a payslip could carry the right money and no record of
-- what it was worked out under -- which is precisely the question an
-- auditor asks when a rate changes mid-year.
--
-- And the other side of it: a component the employee is not liable to
-- names no table, because none was consulted.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_full   uuid;
  v_no_epf uuid;
  r_full   record;
  r_none   record;
begin
  v_org := pg_temp.test_org('Jadual Tercatat Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-05', date '2026-05-01', date '2026-05-31',
          date '2026-05-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'S1', 'Semua Caruman', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_full;

  -- Not in EPF at all. SOCSO and EIS still apply, so what is being
  -- tested is one absent id and not an empty payslip.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, epf_eligible)
  values (v_org, 'S2', 'Tiada KWSP', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen', false)
  returning id into v_no_epf;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-05') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r_full from public.payslips
   where run_id = v_run and employee_id = v_full;
  select * into r_none from public.payslips
   where run_id = v_run and employee_id = v_no_epf;

  perform pg_temp.check_true('a payslip names the EPF table it used',
    r_full.epf_schedule_id is not null);
  perform pg_temp.check_true('and the SOCSO table',
    r_full.socso_schedule_id is not null);
  perform pg_temp.check_true('and the EIS table',
    r_full.eis_schedule_id is not null);
  perform pg_temp.check_true('and the PCB table',
    r_full.pcb_schedule_id is not null);

  -- A table nobody looked in is not a table this payslip used.
  perform pg_temp.check_true('a payslip outside EPF names no EPF table',
    r_none.epf_schedule_id is null);
  perform pg_temp.check_eq('and contributes nothing to it',
    r_none.epf_employee, 0.00);
  perform pg_temp.check_true('while still naming the SOCSO table it used',
    r_none.socso_schedule_id is not null);
end $$;

-- ---------------------------------------------------------------------
-- 3. One unverified table is enough
--
-- `schedules_verified` is an AND across five figures, and the mutant
-- that dropped EPF's term from it survived. The reason is worth
-- writing down, because it is not "a fixture was missing" -- it is that
-- THE CHAIN HAS NEVER ONCE BEEN EVALUATED WITH A TRUE BASELINE.
--
-- `0091` seeds every EPF, SOCSO, EIS and PCB schedule with
-- `is_verified = false` on purpose: README says the gazetted KWSP and
-- PERKESO tables must be published and marked verified before real
-- returns are filed, and until somebody does that a payslip says so on
-- its face. Nothing in the suite has ever marked one verified. So every
-- payslip in every fixture comes out `schedules_verified = false`, the
-- AND is false whichever terms it contains, and dropping ANY of the
-- five was invisible.
--
-- Which means the state a firm is actually in when it files -- tables
-- published, checked, and marked -- was the one state never tested.
-- Both halves are here: verified when all four are, and false the
-- moment one is not.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  v_2029   uuid;
  v_slip   record;
begin
  -- The gazette has been checked and the tables marked. This is what a
  -- payroll bureau's database looks like, and what none of these
  -- fixtures has ever looked like.
  update public.statutory_schedules set is_verified = true
   where body in ('epf', 'socso', 'eis', 'pcb');

  v_org := pg_temp.test_org('Sudah Disemak Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2028-01-01');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2028-03', date '2028-03-01', date '2028-03-31',
          date '2028-03-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'U1', 'Semua Disemak', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_emp;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2028-03') returning id into v_run;
  perform public.calculate_payroll_run(v_run);
  select * into v_slip from public.payslips where run_id = v_run;

  perform pg_temp.check_true(
    'with every table checked, the payslip says so',
    v_slip.schedules_verified = true);

  -- Now EPF alone, and only from 2029, so SOCSO, EIS and PCB keep
  -- answering from their own tables. That isolation is the point: what
  -- is proved is EPF's own term in the AND.
  insert into public.statutory_schedules
    (body, name, method, effective_from, effective_to, result_rounding,
     wage_round_up_to, is_verified)
  values ('epf', 'EPF 2029, off the gazette', 'percentage',
          date '2029-01-01', null, 'up_ringgit', 20, false)
  returning id into v_2029;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employee_rate, employer_rate)
  values (v_2029, 'citizen_under60', 0, 11.0000, 13.0000);

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2029-03', date '2029-03-01', date '2029-03-31',
          date '2029-03-31')
  returning id into v_period;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2029-03') returning id into v_run;
  perform public.calculate_payroll_run(v_run);
  select * into v_slip from public.payslips where run_id = v_run;

  perform pg_temp.check_true('and one unchecked table is enough to unsay it',
    v_slip.schedules_verified = false);
  perform pg_temp.check_true('naming the table that was not checked',
    v_slip.epf_schedule_id = v_2029);
  -- And the money is still produced: unverified is a warning, not a
  -- refusal. A firm still has to pay people in March.
  perform pg_temp.check_eq('while the contribution is still worked out',
    v_slip.epf_employee, 440.00);
end $$;

-- ---------------------------------------------------------------------
-- 4. Voluntary EPF rounds UP on both sides
--
-- KWSP takes the next whole ringgit. The employee side was asserted and
-- the employer side was not, so `ceil` -> `floor` on the employer line
-- survived -- a ringgit a month per employee, in the company's favour,
-- for as long as nobody added it up.
--
-- Asserted as the difference between two identical employees, so the
-- statutory arithmetic cancels and what is left is the voluntary part
-- alone. 1% of 3,333 is 33.33, which is 34 rounded up and 33 rounded
-- down -- a figure chosen so the two answers cannot coincide.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_with   uuid;
  v_plain  uuid;
  r_with   record;
  r_plain  record;
begin
  v_org := pg_temp.test_org('Caruman Sukarela Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status,
     epf_voluntary_employer_rate, epf_voluntary_employee_rate)
  values (v_org, 'V1', 'Majikan Tambah', date '2020-01-01', 3333,
          date '1992-04-15', 'single', 'citizen', 1.0000, 1.0000)
  returning id into v_with;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'V2', 'Berkanun Sahaja', date '2020-01-01', 3333,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_plain;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r_with from public.payslips
   where run_id = v_run and employee_id = v_with;
  select * into r_plain from public.payslips
   where run_id = v_run and employee_id = v_plain;

  perform pg_temp.check_eq('a voluntary employee rate rounds up to the ringgit',
    r_with.epf_employee - r_plain.epf_employee, 34.00);
  perform pg_temp.check_eq('and so does the employer''s',
    r_with.epf_employer - r_plain.epf_employer, 34.00);
end $$;

-- ---------------------------------------------------------------------
-- 5. A company that never opened the payroll settings screen
--
-- `app.payroll_gl_line` takes a fallback account CODE for every line,
-- used when the setting names no account. Every fixture in the suite
-- sets the accounts, so the fallbacks were never taken and two mutants
-- that swapped one code for another -- salaries into the EPF expense
-- account, the employee's EPF into the SOCSO payable -- both survived.
--
-- A company with no `payroll_settings` row at all is the ordinary state
-- of one that has just signed up, and it can still run payroll.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_entry  uuid;
begin
  v_org := pg_temp.test_org('Tanpa Tetapan Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  -- Deliberately no insert into payroll_settings.

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-07', date '2026-07-01', date '2026-07-31',
          date '2026-07-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'T1', 'Tiada Akaun Ditetapkan', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-07') returning id into v_run;
  perform public.calculate_payroll_run(v_run);
  v_entry := public.post_payroll_run(v_run);

  perform pg_temp.check_eq('with no account set, salaries fall back to 6100',
    (select a.code from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and l.description = 'Salaries and wages'),
    '6100');
  perform pg_temp.check_eq('and EPF payable to 2150',
    (select a.code from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and l.description = 'EPF payable'),
    '2150');
  perform pg_temp.check_eq('and net salaries to 2145',
    (select a.code from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry
        and l.description = 'Net salaries payable'),
    '2145');
end $$;

-- ---------------------------------------------------------------------
-- 6. Two shapes of employee the engine had never been handed
--
-- An hourly rate with no hours in it, and a levy-eligible employee at a
-- company that owes no levy. Neither is exotic -- the first is every
-- employee whose working pattern was never filled in, and the second is
-- every company under ten employees that has not opted in.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_nohrs  uuid;
  v_levy   uuid;
  r_nohrs  record;
  r_levy   record;
begin
  -- Verified tables again, so that "still verified" is a claim with
  -- something behind it rather than the default false.
  update public.statutory_schedules set is_verified = true
   where body in ('epf', 'socso', 'eis', 'pcb');

  v_org := pg_temp.test_org('Corak Kerja Kosong Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  -- A settings row with NO levy category: the company is under ten and
  -- has not opted in.
  insert into public.payroll_settings (org_id) values (v_org)
  on conflict (org_id) do nothing;

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-08', date '2026-08-01', date '2026-08-31',
          date '2026-08-31')
  returning id into v_period;

  -- Days set, hours not. `basic / days / hours` is a division by zero
  -- unless the guard holds, and an overtime record is what makes the
  -- engine reach for the rate at all.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'H1', 'Tiada Jam Sehari', date '2020-01-01', 4000,
          26, 0, date '1992-04-15', 'single', 'citizen')
  returning id into v_nohrs;
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_nohrs, date '2026-08-12', 180);

  -- Eligible for the levy at a company that owes none.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, hrdf_eligible)
  values (v_org, 'H2', 'Layak Levi', date '2020-01-01', 4000,
          date '1992-04-15', 'single', 'citizen', true)
  returning id into v_levy;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-08') returning id into v_run;
  -- The run completing at all is half the assertion.
  perform public.calculate_payroll_run(v_run);

  select * into r_nohrs from public.payslips
   where run_id = v_run and employee_id = v_nohrs;
  select * into r_levy from public.payslips
   where run_id = v_run and employee_id = v_levy;

  perform pg_temp.check_eq('an employee with no hours a day is still paid',
    r_nohrs.basic_salary, 4000.00);
  perform pg_temp.check_eq('and their overtime is nought, not an error',
    r_nohrs.ot_amount, 0.00);

  -- The masking pair from the header. `v_hrdf_ver` is never reset per
  -- employee, so this holds whether the category guard is there or not
  -- -- and it is asserted so that removing the initialiser is caught by
  -- something even though removing the guard is not.
  perform pg_temp.check_eq('a company owing no levy charges none',
    r_levy.hrdf, 0.00);
  perform pg_temp.check_true(
    'and a levy nobody consulted does not make the payslip unverified',
    r_levy.schedules_verified = true);
end $$;

-- ---------------------------------------------------------------------
-- 8. A month with nothing to contribute on
--
-- `0544`. An employee inside EPF who earned nothing this month --
-- approved unpaid leave for the whole of it, so the basic line and the
-- UNPAID line cancel to exactly zero -- still names the table they
-- would have contributed under, and still inherits whether anybody has
-- checked it.
--
-- Before `0544` the guard skipped the call and left the id null and the
-- flag true, so this payslip said its statutory figures were verified
-- while the EPF table behind it was not. It is the one shape of payslip
-- where the warning matters most and the one that was not getting it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  v_lt     uuid;
  v_2033   uuid;
  v_slip   record;
begin
  update public.statutory_schedules set is_verified = true
   where body in ('epf', 'socso', 'eis', 'pcb');

  -- Everything checked EXCEPT the EPF table this month answers from.
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, wage_round_up_to,
     is_verified)
  values ('epf', 'EPF 2033, off the gazette', 'percentage',
          date '2033-01-01', 'up_ringgit', 20, false)
  returning id into v_2033;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employee_rate, employer_rate)
  values (v_2033, 'citizen_under60', 0, 11.0000, 13.0000);

  v_org := pg_temp.test_org('Cuti Tanpa Gaji Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2033-01-01');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2033-04', date '2033-04-01', date '2033-04-30',
          date '2033-04-30')
  returning id into v_period;

  insert into public.leave_types (org_id, code, name, is_paid, default_days)
  values (v_org, 'UNPAID', 'Unpaid leave', false, 0) returning id into v_lt;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, date_of_birth, marital_status,
     residency_status)
  values (v_org, 'Z1', 'Sebulan Tanpa Gaji', date '2020-01-01', 4000,
          30, date '1992-04-15', 'single', 'citizen')
  returning id into v_emp;

  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-Z1-1', v_emp, v_lt, date '2033-04-01',
          date '2033-04-30', 30, 'approved');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2033-04') returning id into v_run;
  perform public.calculate_payroll_run(v_run);
  select * into v_slip from public.payslips where run_id = v_run;

  -- The fixture is only a fixture if the wage really is nought.
  perform pg_temp.check_eq('a month of unpaid leave leaves no EPF wage',
    v_slip.epf_wage, 0.00);
  perform pg_temp.check_eq('and nothing is contributed on it',
    v_slip.epf_employee, 0.00);
  perform pg_temp.check_eq('nor by the employer',
    v_slip.epf_employer, 0.00);

  -- What `0544` changed.
  perform pg_temp.check_true(
    'but the table it would have contributed under is still named',
    v_slip.epf_schedule_id = v_2033);
  perform pg_temp.check_true(
    'and a zero contribution off an unchecked table is not a checked one',
    v_slip.schedules_verified = false);
end $$;

-- ---------------------------------------------------------------------
-- 7. A tripwire, not an assertion
--
-- `insured_wage` is called with the employee's SOCSO category, and Act
-- 800 -- the scheme for employees over sixty -- is seeded with the same
-- RM 6,000 ceiling as Act 4. So passing the wrong category cannot
-- change the answer today, and a mutant that hard-coded 'act4' survived
-- for that reason and no other.
--
-- The day PERKESO gives the two schemes different ceilings, that line
-- starts to matter and nothing here would say so. This says so: it
-- fails when the ceilings diverge, and its failure means "go and assert
-- the category argument properly, it is now load-bearing".
-- ---------------------------------------------------------------------
do $$
declare
  v_act4  numeric;
  v_800   numeric;
begin
  select r.wage_ceiling into v_act4
    from public.statutory_rates r
    join public.statutory_schedules s on s.id = r.schedule_id
   where s.body = 'socso' and r.category = 'act4'
   order by s.effective_from desc limit 1;
  select r.wage_ceiling into v_800
    from public.statutory_rates r
    join public.statutory_schedules s on s.id = r.schedule_id
   where s.body = 'socso' and r.category = 'act800'
   order by s.effective_from desc limit 1;

  perform pg_temp.check_eq(
    'Act 4 and Act 800 still share a ceiling -- if this fails, '
    'insured_wage''s category argument has become load-bearing and '
    'needs an assertion of its own',
    v_act4, v_800);
end $$;


-- =====================================================================
-- A second sweep, of the same function, from the other end
--
-- Sections 1 to 8 came from asking what `calculate_payroll_run` records
-- and where it posts. Sections 9 to 15 came from asking a mutation
-- sweep: sixty-eight one-line mutants over the function, of which
-- thirty-seven survived the suite as it then stood. The survivors were
-- the EDGES -- the two age boundaries at sixty, the eligibility flags,
-- every date comparison deciding whether somebody is in this period,
-- the guards that stop a zero line printing, and the sen in a part
-- month. Re-armed with the sections below in the list, sixteen of them
-- die.
--
-- Sections 16 and 17 finish the job. Swept again against the whole
-- file: sixty-three mutants, SIXTY-TWO DEAD. The one left standing is
-- equivalent and is shown to be so in section 16's header -- it is not
-- a gap anybody can close, because there is no difference to observe.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 9. Sixty, on both sides
--
-- Two different rules turn at the same age and neither had a fixture
-- standing on it.
--
--   SOCSO   act4 is injury and invalidity; act800 is injury only, for
--           an employee aged sixty and over. `>= 60` -> `> 60` puts a
--           sixty-year-old back on the invalidity scheme and takes a
--           contribution off both sides that PERKESO does not want.
--   EIS     stops at sixty. `< 60` -> `<= 60` keeps deducting from
--           somebody who can no longer claim.
--
-- Age is taken at the PAY DATE, so the fixture is built around it: born
-- on 31 January 1966, paid on 31 January 2026, and sixty that morning.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_sixty  uuid;
  v_under  uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Payroll Sweep Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-01', date '2026-01-01', date '2026-01-31',
          date '2026-01-31')
  returning id into v_period;

  -- Sixty on the pay date, to the day.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'S60', 'Sixty on the day', date '2010-01-01', 3000,
          date '1966-01-31', 'single', 'citizen')
  returning id into v_sixty;

  -- One day short of sixty, so the pair brackets the boundary.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'S59', 'Sixty tomorrow', date '2010-01-01', 3000,
          date '1966-02-01', 'single', 'citizen')
  returning id into v_under;

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  perform pg_temp.check_eq('sixty today is sixty',
    app.age_at(date '1966-01-31', date '2026-01-31')::numeric, 60);
  perform pg_temp.check_eq('and sixty tomorrow is fifty-nine',
    app.age_at(date '1966-02-01', date '2026-01-31')::numeric, 59);

  -- SOCSO: the older one is on act800, which is the employer's side
  -- only. Kills `v_age >= 60` -> `> 60`.
  select socso_employee, socso_employer into r
    from public.payslips where run_id = v_run and employee_no = 'S60';
  perform pg_temp.check_eq(
    'at sixty the employee stops paying SOCSO', r.socso_employee, 0);
  perform pg_temp.check_true(
    'and the employer still does', r.socso_employer > 0);

  select socso_employee into r
    from public.payslips where run_id = v_run and employee_no = 'S59';
  perform pg_temp.check_true(
    'one day younger and both sides pay', r.socso_employee > 0);

  -- EIS: off at sixty, on the day before. Kills `v_age < 60` -> `<= 60`.
  select eis_employee, eis_employer into r
    from public.payslips where run_id = v_run and employee_no = 'S60';
  perform pg_temp.check_eq('EIS stops at sixty', r.eis_employee, 0);
  perform pg_temp.check_eq('on both sides', r.eis_employer, 0);

  select eis_employee into r
    from public.payslips where run_id = v_run and employee_no = 'S59';
  perform pg_temp.check_true(
    'and is still deducted the day before', r.eis_employee > 0);
end $$;

-- ---------------------------------------------------------------------
-- 10. The eligibility flags mean what they say
--
-- Three guards read `<flag> and <wage> > 0`. Turned into `or`, an
-- employee explicitly marked exempt gets the contribution anyway --
-- and nothing failed, because every employee in every other fixture is
-- eligible for all three. A pensionable re-hire, a foreign worker
-- outside EIS and a director outside SOCSO are all real, and all three
-- are one boolean away from being charged.
--
-- Kills `epf_eligible and` -> `or`, `socso_eligible and` -> `or`,
-- `eis_eligible and` -> `or`.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_none   uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Payroll Exempt Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-02', date '2026-02-01', date '2026-02-28',
          date '2026-02-28')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status,
     epf_eligible, socso_eligible, eis_eligible)
  values (v_org, 'X1', 'Exempt from all three', date '2015-01-01', 4000,
          date '1985-06-01', 'single', 'citizen', false, false, false)
  returning id into v_none;

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select epf_employee, epf_employer, socso_employee, socso_employer,
         eis_employee, eis_employer, gross_pay
    into r
    from public.payslips where run_id = v_run and employee_no = 'X1';

  -- The wage is there -- that is the point. The guard is the flag, not
  -- the money, so a fixture paying nothing would prove nothing.
  perform pg_temp.check_eq('there is a wage to contribute on',
                           r.gross_pay, 4000);
  perform pg_temp.check_eq('and no EPF is taken', r.epf_employee, 0);
  perform pg_temp.check_eq('on either side', r.epf_employer, 0);
  perform pg_temp.check_eq('nor SOCSO', r.socso_employee, 0);
  perform pg_temp.check_eq('on either side either', r.socso_employer, 0);
  perform pg_temp.check_eq('nor EIS', r.eis_employee, 0);
  perform pg_temp.check_eq('on either side of that', r.eis_employer, 0);
end $$;

-- ---------------------------------------------------------------------
-- 11. One day either way
--
-- Every date comparison deciding whether something falls IN the period
-- is inclusive, and every one of them survived being made exclusive.
-- The five below are the ones that change somebody's pay:
--
--   hired on the last day of the month     -> one day's pay, not none
--   left on the first day of the month     -> one day's pay, not none
--   unpaid leave ending on the first day   -> deducted, not ignored
--   a component starting on the last day   -> paid, not skipped
--   a claim dated the last day             -> reimbursed, not held
--
-- Kills `e.hire_date <=` -> `<`, `e.last_working_date >=` -> `>`,
-- `lr.end_date >=` -> `>`, `esc.effective_from <=` -> `<`,
-- `c.claim_date <=` -> `<`.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_new    uuid;
  v_gone   uuid;
  v_leaver uuid;
  v_comp   uuid;
  v_claim  uuid;
  v_slip   uuid;
  v_n      integer;
  v_amt    numeric;
  r        record;
begin
  v_org := pg_temp.test_org('Payroll Edges Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-03', date '2026-03-01', date '2026-03-31',
          date '2026-03-31')
  returning id into v_period;

  -- Hired on the last day of the period: one day of thirty-one.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'N1', 'Started on the last day', date '2026-03-31', 3100,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_new;

  -- Left on the first day of the period: likewise one day.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     last_working_date, date_of_birth, marital_status, residency_status)
  values (v_org, 'L1', 'Left on the first day', date '2020-01-01', 3100,
          date '2026-03-01', date '1990-01-01', 'single', 'citizen')
  returning id into v_gone;

  -- And somebody who left the day BEFORE the period opened, who must
  -- not be on the run at all.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     last_working_date, date_of_birth, marital_status, residency_status)
  values (v_org, 'L0', 'Left in February', date '2020-01-01', 3100,
          date '2026-02-28', date '1990-01-01', 'single', 'citizen');

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select count(*) into v_n from public.payslips where run_id = v_run;
  perform pg_temp.check_eq('two of the three are on the run',
                           v_n::numeric, 2);
  perform pg_temp.check_eq('and the one who left in February is not',
    (select count(*) from public.payslips
      where run_id = v_run and employee_no = 'L0')::numeric, 0);

  -- 3100 over 31 days is exactly 100 a day, so one day is a number a
  -- person can check.
  select basic_salary into v_amt
    from public.payslips where run_id = v_run and employee_no = 'N1';
  perform pg_temp.check_eq('a day worked is a day paid', v_amt, 100);
  select basic_salary into v_amt
    from public.payslips where run_id = v_run and employee_no = 'L1';
  perform pg_temp.check_eq('at both ends of the month', v_amt, 100);

  -- The description carries the arithmetic, and it is what somebody
  -- queries when the number looks wrong. Kills the `v_worked >= v_days`
  -- that chooses between the two wordings.
  select description into r
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'N1' and pl.code = 'BASIC';
  perform pg_temp.check_eq('and the line says how much of the month',
                           r.description, 'Basic salary (1 of 31 days)');
end $$;

-- ---------------------------------------------------------------------
-- 12. A line only where there is something on it, and to the sen
--
-- Two guards stop a zero row being printed -- no overtime, no claim --
-- and both survived being relaxed to `>= 0`, because every payslip in
-- every other fixture either has overtime or is never counted. A
-- payslip carrying "Overtime 0.00" is not wrong arithmetic; it is a
-- document going to an employee with a line on it that did not happen.
--
-- And the roundings. `round(x, 2)` -> `round(x, 0)` survived six times
-- over, because the fixtures pay round numbers. A prorated month and an
-- unpaid day are exactly where the sen appear.
--
-- Kills `if v_ot_amt > 0` -> `>= 0`, `if v_claims > 0` -> `>= 0`,
-- and the roundings on prorated basic and on the unpaid deduction.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_plain  uuid;
  v_part   uuid;
  v_type   uuid;
  v_n      integer;
  v_amt    numeric;
begin
  v_org := pg_temp.test_org('Payroll Sen Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-04', date '2026-04-01', date '2026-04-30',
          date '2026-04-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'P0', 'No overtime and no claim', date '2020-01-01', 3000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_plain;

  -- Hired on the 8th: 23 days of 30, and 4000 * 23 / 30 is
  -- 3066.6666..., which rounds to 3066.67 and to 3067 if the scale is
  -- lost.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, date_of_birth, marital_status,
     residency_status)
  values (v_org, 'P1', 'Part of a month, in sen', date '2026-04-08', 4000,
          30, date '1990-01-01', 'single', 'citizen')
  returning id into v_part;

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  -- No overtime line and no claim line on a payslip that has neither.
  select count(*) into v_n
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'P0' and pl.code = 'OT';
  perform pg_temp.check_eq('no overtime, no overtime line', v_n::numeric, 0);

  select count(*) into v_n
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'P0' and pl.code = 'CLAIMS';
  perform pg_temp.check_eq('no claim, no claim line', v_n::numeric, 0);

  -- And the sen survive the proration.
  select basic_salary into v_amt
    from public.payslips where run_id = v_run and employee_no = 'P1';
  perform pg_temp.check_eq('a part month is paid to the sen',
                           v_amt, 3066.67);
end $$;

-- ---------------------------------------------------------------------
-- 13. Unpaid leave that touches the month by a day, and to the sen
--
-- Unpaid leave is prorated across the period it overlaps, so a request
-- running from the last week of one month into the first of the next
-- has to be split. Three mutants lived here:
--
--   `lr.end_date >= period_start` -> `>`   leave ending on the first of
--                                          the month vanishes entirely
--   `lr.start_date <= period_end` -> `<`   leave starting on the last
--                                          day likewise
--   `round(..., 2)` -> `round(..., 0)`     the split lands on a
--                                          fraction of a day, and the
--                                          deduction is in sen
--
-- Six days of leave from 27 March to 1 April: five days fall in March
-- and one in April. Against a 26-day month at 3900 that is 150 a day,
-- so April's share is a day and March's five -- and the proration puts
-- sen into the day count, which is where the rounding shows.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_mar    uuid;
  v_apr    uuid;
  v_run    uuid;
  v_emp    uuid;
  v_type   uuid;
  v_days   numeric;
  v_amt    numeric;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Payroll Unpaid Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-03', date '2026-03-01', date '2026-03-31',
          date '2026-03-31')
  returning id into v_mar;
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-04', date '2026-04-01', date '2026-04-30',
          date '2026-04-30')
  returning id into v_apr;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false)
  returning id into v_type;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, date_of_birth, marital_status,
     residency_status)
  values (v_org, 'U1', 'Away over the month end', date '2020-01-01', 3900,
          26, date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-0001', v_emp, v_type, date '2026-03-27',
          date '2026-04-01', 6, 'approved');

  -- April: one day of the six, which is the day the `>=` decides.
  v_run := public.create_payroll_run(v_org, v_apr);
  perform public.calculate_payroll_run(v_run);
  select unpaid_leave_days, unpaid_leave_amount into v_days, v_amt
    from public.payslips where run_id = v_run and employee_no = 'U1';
  perform pg_temp.check_eq('a day of leave in the new month counts',
                           v_days, 1);
  perform pg_temp.check_eq('and comes off the pay', v_amt, 150);

  -- March: the other five.
  v_run := public.create_payroll_run(v_org, v_mar);
  perform public.calculate_payroll_run(v_run);
  select unpaid_leave_days, unpaid_leave_amount into v_days, v_amt
    from public.payslips where run_id = v_run and employee_no = 'U1';
  perform pg_temp.check_eq('and the five before it stay in the old one',
                           v_days, 5);
  perform pg_temp.check_eq('at the same rate a day', v_amt, 750);

  -- The deduction is a line, negative, and it carries the day count.
  select count(*) into v_n
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'U1' and pl.code = 'UNPAID';
  perform pg_temp.check_eq('the deduction is on the payslip',
                           v_n::numeric, 1);
  select amount into v_amt
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'U1' and pl.code = 'UNPAID';
  perform pg_temp.check_eq('and it comes off, not on', v_amt, -750);
end $$;

-- ---------------------------------------------------------------------
-- 14. A full month says so
--
-- The BASIC line reads either "Basic salary" or "Basic salary (n of m
-- days)", and the choice is `v_worked >= v_days`. Section 3 asserted
-- the prorated wording; the mutant `>` survives that, because one day
-- of thirty-one is short of the month either way. What it does not
-- survive is somebody who worked the WHOLE month: `>=` says plain
-- "Basic salary" and `>` says "(30 of 30 days)", which is a payslip
-- telling an employee their full month was a part month.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_desc   text;
begin
  v_org := pg_temp.test_org('Payroll Whole Month Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'F1', 'Here all month', date '2019-01-01', 3000,
          date '1990-01-01', 'single', 'citizen');

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select pl.description into v_desc
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'F1' and pl.code = 'BASIC';
  perform pg_temp.check_eq('a whole month is not a part month',
                           v_desc, 'Basic salary');
end $$;

-- ---------------------------------------------------------------------
-- 15. A component and a claim that arrive on the last day
--
-- Two more inclusive comparisons, both of which decide whether money
-- reaches this month's payslip or waits for next:
--
--   `esc.effective_from <= period_end` -> `<`  an allowance starting on
--                                              the last day is skipped
--   `c.claim_date <= period_end`       -> `<`  a claim dated the last
--                                              day is held over
--
-- A month-end starter and a month-end receipt are both ordinary, and
-- both are one character from being paid a month late.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  v_comp   uuid;
  v_amt    numeric;
begin
  v_org := pg_temp.test_org('Payroll Last Day Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-07', date '2026-07-01', date '2026-07-31',
          date '2026-07-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'D1', 'Paid on the last day', date '2020-01-01', 3000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_taxable, is_epf_liable,
     is_socso_liable, is_eis_liable, is_hrdf_liable)
  values (v_org, 'PHONE', 'Phone allowance', 'earning', 120,
          true, true, true, true, true)
  returning id into v_comp;

  -- Effective from the last day of the period, and not a day earlier.
  insert into public.employee_salary_components
    (org_id, employee_id, component_id, amount, effective_from)
  values (v_org, v_emp, v_comp, 120, date '2026-07-31');

  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status, approved_amount,
     pay_with_payroll)
  values (v_org, 'CL-0001', v_emp, date '2026-07-31', 'approved', 88, true);

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select amount into v_amt
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'D1' and pl.code = 'PHONE';
  perform pg_temp.check_eq(
    'an allowance starting on the last day is paid this month',
    v_amt, 120);

  select claims_amount into v_amt
    from public.payslips where run_id = v_run and employee_no = 'D1';
  perform pg_temp.check_eq(
    'and a claim dated the last day is reimbursed with it', v_amt, 88);
end $$;

-- ---------------------------------------------------------------------
-- 16. The last eleven, and the nine of them that were real
--
-- Re-swept against the whole of this file: sixty-three mutants, fifty-
-- two dead, eleven alive. Nine of the eleven are here and one is in
-- section 17. They are the same shape as the rest: a boundary date, a
-- rounding, and a divisor nobody had set to zero.
--
-- The sixty-third is EQUIVALENT, and provably so rather than
-- apparently: `v_worked >= v_days` -> `>` in the line that picks the
-- basic AMOUNT. When the whole month is worked the else branch is
-- `round(basic * days / days, 2)`, which is `round(basic, 2)`, and
-- `employees.basic_salary` is `numeric(18,2)` -- so the rounding
-- cannot move it. There is no fixture that separates the two, because
-- there is nothing to separate. The half that DOES differ is the
-- wording, and section 14 kills that.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_sched  uuid;
  v_emp    uuid;
  v_amt    numeric;
  v_days   numeric;
  v_rate   numeric;
  v_qty    numeric;
begin
  v_org := pg_temp.test_org('Payroll Last Eleven Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-09', date '2026-09-01', date '2026-09-30',
          date '2026-09-30')
  returning id into v_period;

  insert into public.payroll_settings (org_id, hrdf_category)
  values (v_org, 'mandatory_10plus')
  on conflict (org_id) do update set hrdf_category = excluded.hrdf_category;

  -- ------------------------------------------------------------------
  -- (a) A levy table that opens ON the pay date, and one that closes on
  -- it. `effective_from <= pay_date` and `effective_to >= pay_date` are
  -- both inclusive, and a rate gazetted to start on the last day of the
  -- month is exactly the case a `<` gets wrong -- the levy comes out
  -- nought and the employer under-declares to HRD Corp.
  --
  -- The seeded table runs from 2021 with no end, so it is closed on the
  -- day before and a new one opened on the pay date itself. Ordered by
  -- `effective_from desc`, the new one wins, and it charges 2% where
  -- the old charged 1% -- so the levy says which table answered.
  -- ------------------------------------------------------------------
  update public.statutory_schedules
     set effective_to = date '2026-09-29'
   where body = 'hrdf' and effective_to is null;

  insert into public.statutory_schedules
    (body, name, method, effective_from, effective_to, source, is_verified)
  values ('hrdf', 'HRD Corp levy, from the pay date', 'percentage',
          date '2026-09-30', null, 'test fixture', true)
  returning id into v_sched;
  insert into public.statutory_rates
    (schedule_id, category, employer_rate)
  values (v_sched, 'mandatory_10plus', 2.0000);

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'H1', 'On the new levy table', date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen');

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select hrdf into v_amt
    from public.payslips where run_id = v_run and employee_no = 'H1';
  perform pg_temp.check_eq(
    'a levy table opening on the pay date is the one in force',
    v_amt, 100);

  -- And the one that closed on the day before is not. Closed ON the pay
  -- date instead, it would be -- which is the other half of the pair.
  update public.statutory_schedules
     set effective_from = date '2026-10-01'
   where id = v_sched;
  update public.statutory_schedules
     set effective_to = date '2026-09-30'
   where body = 'hrdf' and id <> v_sched;

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);
  select hrdf into v_amt
    from public.payslips where run_id = v_run and employee_no = 'H1';
  perform pg_temp.check_eq(
    'and one closing on it is still in force that day', v_amt, 50);
end $$;

do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  v_type   uuid;
  v_comp   uuid;
  v_amt    numeric;
  v_days   numeric;
  v_rate   numeric;
begin
  v_org := pg_temp.test_org('Payroll Edges Two Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-10', date '2026-10-01', date '2026-10-31',
          date '2026-10-31')
  returning id into v_period;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false)
  returning id into v_type;

  -- ------------------------------------------------------------------
  -- (b) and (d). Leave starting on the LAST day of the month -- section
  -- 13 covered leave ending on the first, which is the other end of the
  -- same pair -- and a split that does not land on a whole day.
  --
  -- Seven days from 31 October to 6 November. One of the seven falls in
  -- October, so the deduction is 7 * 1/7 = 1 day exactly; to put sen
  -- into it the request is FIVE days over those seven dates, which is
  -- 5 * 1/7 = 0.714285..., and rounds to 0.71. Against 22 working days
  -- at 3300 that is 150 a day, so the money is 0.714285... * 150 =
  -- 107.14 -- and 107 if the scale is lost.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, date_of_birth, marital_status,
     residency_status)
  values (v_org, 'E1', 'Away from the last day', date '2020-01-01', 3300,
          22, date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-9001', v_emp, v_type, date '2026-10-31',
          date '2026-11-06', 5, 'approved');

  -- ------------------------------------------------------------------
  -- (c) A component whose last day is the FIRST day of the period. The
  -- allowance stopped on the 1st, so the month it stopped in is the
  -- month it is still paid for; `>=` made `>` drops it a month early.
  -- ------------------------------------------------------------------
  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_taxable, is_epf_liable,
     is_socso_liable, is_eis_liable, is_hrdf_liable)
  values (v_org, 'TRAVEL', 'Travel allowance', 'earning', 250,
          true, true, true, true, true)
  returning id into v_comp;
  insert into public.employee_salary_components
    (org_id, employee_id, component_id, amount, effective_from,
     effective_to)
  values (v_org, v_emp, v_comp, 250, date '2024-01-01',
          date '2026-10-01');

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select unpaid_leave_days, unpaid_leave_amount into v_days, v_amt
    from public.payslips where run_id = v_run and employee_no = 'E1';
  perform pg_temp.check_eq('leave starting on the last day is deducted',
                           v_days, 0.71);
  perform pg_temp.check_eq('and the deduction carries its sen',
                           v_amt, 107.14);

  -- The line shows the same day count, to the same scale.
  select quantity, amount into v_days, v_amt
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'E1' and pl.code = 'UNPAID';
  perform pg_temp.check_eq('the line agrees with the payslip', v_days, 0.71);
  perform pg_temp.check_eq('and comes off, to the sen', v_amt, -107.14);

  select amount into v_amt
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'E1' and pl.code = 'TRAVEL';
  perform pg_temp.check_eq(
    'an allowance ending on the first day is paid that month', v_amt, 250);
end $$;

do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_paid   uuid;
  v_nodays uuid;
  v_rate   numeric;
  v_amt    numeric;
begin
  v_org := pg_temp.test_org('Payroll Hourly Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-11', date '2026-11-01', date '2026-11-30',
          date '2026-11-30')
  returning id into v_period;

  -- ------------------------------------------------------------------
  -- (e) The overtime rate, to four places. 3000 over 22 days of 7.5
  -- hours is 18.181818... an hour, and the payslip carries four places
  -- because two would lose a sen on a long month of overtime. Rounded
  -- to nought it reads 18, which is a rate no arithmetic on the payslip
  -- produces.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'R1', 'An hourly rate with a tail', date '2020-01-01',
          3000, 22, 7.5, date '1990-01-01', 'single', 'citizen')
  returning id into v_paid;

  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_paid, date '2026-11-10', 120);

  -- ------------------------------------------------------------------
  -- (f) And nobody's month is zero days. `working_days_per_month > 0`
  -- guards a division, and set to zero the guard is the only thing
  -- between the run and a division by zero -- which is not a wrong
  -- number on a payslip, it is a payroll that will not close. The
  -- column defaults to 26, so this is somebody who cleared the field.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, date_of_birth, marital_status,
     residency_status)
  values (v_org, 'Z1', 'No days a month recorded', date '2020-01-01',
          2400, 0, date '1990-01-01', 'single', 'citizen')
  returning id into v_nodays;

  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_nodays, date '2026-11-11', 90);

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);

  select rate into v_rate
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'R1' and pl.code = 'OT';
  perform pg_temp.check_eq('the overtime rate keeps four places',
                           v_rate, 18.1818);

  -- 2 hours at 1.5 times 18.181818... is 54.5454..., which is 54.55.
  select amount into v_amt
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'R1' and pl.code = 'OT';
  perform pg_temp.check_eq('and the overtime itself is to the sen',
                           v_amt, 54.55);

  select basic_salary into v_amt
    from public.payslips where run_id = v_run and employee_no = 'Z1';
  perform pg_temp.check_eq('no days a month is still a month''s pay',
                           v_amt, 2400);
  select count(*) into v_rate
    from public.payslip_lines pl
    join public.payslips p on p.id = pl.payslip_id
   where p.run_id = v_run and p.employee_no = 'Z1' and pl.code = 'OT';
  perform pg_temp.check_eq(
    'and their overtime is nothing rather than an error', v_rate, 0);
end $$;

-- ---------------------------------------------------------------------
-- 17. What a posted run says when somebody recalculates it
--
-- The last mutant but one, and the smallest: the word "and" inside the
-- refusal. `payroll_run.sql` asserts that a posted run REFUSES to be
-- recalculated; nothing asserts what it says while refusing, so the
-- sentence could be reworded into nonsense and the suite would pass.
--
-- It is worth a line because it is the sentence somebody reads at the
-- moment they are told they cannot do the thing they came to do, and
-- because it names the status -- "This run is posted", not "This run
-- cannot be recalculated" -- which is the difference between an answer
-- and a wall.
-- ---------------------------------------------------------------------
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
begin
  v_org := pg_temp.test_org('Payroll Refusal Sdn Bhd');

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-12', date '2026-12-01', date '2026-12-31',
          date '2026-12-31')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'Q1', 'On a run that is done', date '2020-01-01', 3000,
          date '1990-01-01', 'single', 'citizen');

  v_run := public.create_payroll_run(v_org, v_period);
  perform public.calculate_payroll_run(v_run);
  update public.payroll_runs set status = 'posted' where id = v_run;

  perform pg_temp.check_refused(
    'a posted run says what it is, not merely that it refuses',
    format('select public.calculate_payroll_run(%L)', v_run),
    '%This run is posted and can no longer be recalculated%',
    '22023');
end $$;

rollback;

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

rollback;

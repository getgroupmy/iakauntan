-- =====================================================================
-- iAkauntan :: taking somebody off the payroll
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/departures.sql
--
-- The editor has offered Resigned, Terminated and Retired since it was
-- written, and `calculate_payroll_run` has never read
-- `employment_status`. It picks who to pay by `last_working_date`, which
-- nothing could set. So a leaver marked in the dropdown kept drawing a
-- full salary, kept having EPF and PCB remitted against their file, and
-- kept being paid by the bank file — every month, silently.
--
-- The first assertion here is the one that matters: after a departure
-- is recorded, the next run does not pay them. It is written as a run
-- either side of the last working day, because "is not on the run" and
-- "is paid for the days they worked" are both required and each one
-- alone is satisfiable by a wrong answer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.dep_run(p_org uuid, p_code text,
  p_from date, p_to date, out run_id uuid)
language plpgsql as $$
declare v_period uuid;
begin
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (p_org, p_code, p_from, p_to, p_to)
  returning id into v_period;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (p_org, v_period, 'PAY-' || p_code) returning id into run_id;
  perform public.calculate_payroll_run(run_id);
end $$;

-- ---------------------------------------------------------------------
-- The month they left, and the month after
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_emp   uuid;
  v_stay  uuid;
  v_run   uuid;
  v_paid  numeric;
begin
  v_org := pg_temp.test_org('Berhenti Kerja Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'L1', 'Leaving on the fifteenth', date '2020-01-01', 3100,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_emp;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'L2', 'Staying', date '2020-01-01', 3100,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_stay;

  perform public.record_departure(
    v_emp, date '2026-04-15', 'resigned', 'Moving to Singapore',
    date '2026-03-01');

  perform pg_temp.check_eq('the last working day is recorded',
    (select last_working_date from public.employees where id = v_emp)::text,
    '2026-04-15');
  perform pg_temp.check_eq('and the day they gave notice, which is not it',
    (select resignation_date from public.employees where id = v_emp)::text,
    '2026-03-01');
  perform pg_temp.check_eq('with the reason',
    (select termination_reason from public.employees where id = v_emp),
    'Moving to Singapore');
  -- The last working day is in the past relative to nothing here — the
  -- status is derived from today, so this asserts the branch that is
  -- true whenever this file is run after April 2026 and the other one
  -- is covered below with a date that is always in the future.
  perform pg_temp.check_true('and a leaving status',
    (select employment_status in ('resigned', 'notice')
       from public.employees where id = v_emp));

  -- April: they worked half of it and are paid for half of it.
  v_run := pg_temp.dep_run(v_org, '2026-04', date '2026-04-01', date '2026-04-30');
  select basic_salary into v_paid from public.payslips
   where run_id = v_run and employee_id = v_emp;
  perform pg_temp.check_eq('paid for the days they worked in their last month',
    v_paid, round(3100 * 15 / 30.0, 2));
  perform pg_temp.check_eq('while the colleague gets a full month',
    (select basic_salary from public.payslips
      where run_id = v_run and employee_id = v_stay), 3100.00);

  -- May: this is the failure the whole thing is about. Before `0371` the
  -- leaver appeared here at 3,100.00, with EPF and PCB on it, and the
  -- bank file paid them.
  v_run := pg_temp.dep_run(v_org, '2026-05', date '2026-05-01', date '2026-05-31');
  perform pg_temp.check_eq('the month after, they are not on the run at all',
    (select count(*) from public.payslips
      where run_id = v_run and employee_id = v_emp), 0);
  perform pg_temp.check_eq('and the colleague still is',
    (select count(*) from public.payslips
      where run_id = v_run and employee_id = v_stay), 1);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Serving notice, which is derived rather than typed
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_emp uuid;
begin
  v_org := pg_temp.test_org('Notis Sebulan Sdn Bhd');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'N1', 'Working out their notice', date '2020-01-01', 4000,
          date '1990-01-01', 'citizen')
  returning id into v_emp;

  -- A year out, so this holds whenever the file is run.
  perform public.record_departure(
    v_emp, (current_date + 365), 'resigned', 'Better offer');
  perform pg_temp.check_eq(
    'a last working day still to come reads as serving notice',
    (select employment_status::text from public.employees where id = v_emp),
    'notice');
  -- `notice` had been in the enum since 0025 and was a thing somebody
  -- chose from a list. It now says something no other value says.
  perform pg_temp.check_eq('and the resignation date defaults to today',
    (select resignation_date from public.employees where id = v_emp)::text,
    ((now() at time zone 'Asia/Kuala_Lumpur')::date)::text);

  -- Once it has passed, the same call reads as the departure it is.
  perform public.record_departure(v_emp, (current_date - 1), 'resigned');
  perform pg_temp.check_eq('and once it has passed, as resigned',
    (select employment_status::text from public.employees where id = v_emp),
    'resigned');

  -- Terminated and retired carry no resignation date: nobody resigned.
  perform public.record_departure(
    v_emp, date '2026-06-30', 'terminated', 'Redundancy');
  perform pg_temp.check_true('a termination has no resignation date',
    (select resignation_date is null from public.employees where id = v_emp));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What it refuses, and how it is undone
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_emp  uuid;
  v_said text;
begin
  v_org := pg_temp.test_org('Menolak Sdn Bhd');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, confirmation_date)
  values (v_org, 'R1', 'Confirmed staff', date '2020-01-01', 4000,
          date '1990-01-01', 'citizen', date '2020-07-01')
  returning id into v_emp;

  -- The hole the trigger closes: a leaving status with no last day is
  -- somebody the payroll run still pays.
  begin
    update public.employees set employment_status = 'resigned'
     where id = v_emp;
    raise exception 'FAIL: a leaver was declared with no last working day';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the status alone is refused',
    v_said like '%last working day%');
  perform pg_temp.check_true('and the message says why it matters',
    v_said like '%goes by the date%');

  -- Judging the change, not the row: an unrelated edit to somebody
  -- already in that state is not the moment to ask. Written straight
  -- into the table because that state can no longer be created.
  update public.employees set employment_status = 'resigned',
         last_working_date = date '2026-02-28' where id = v_emp;
  perform pg_temp.check_true('a leaver with a date saves',
    (select last_working_date is not null from public.employees
      where id = v_emp));
  update public.employees set phone = '012-3456789' where id = v_emp;
  perform pg_temp.check_eq('and an unrelated edit to them still saves',
    (select phone from public.employees where id = v_emp), '012-3456789');

  -- Before they joined.
  begin
    perform public.record_departure(v_emp, date '2019-01-01', 'resigned');
    raise exception 'FAIL: a departure before the hire date was accepted';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('leaving before joining is refused',
    v_said like '%before the day they joined%');

  -- Not a departure at all.
  begin
    perform public.record_departure(v_emp, current_date, 'suspended');
    raise exception 'FAIL: suspension was recorded as a departure';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a suspension is not a departure',
    v_said like '%resigned, terminated or retired%');

  -- Undone. A confirmed employee goes back to active, not to probation.
  perform public.reinstate_employee(v_emp);
  perform pg_temp.check_eq('reinstating returns a confirmed employee to active',
    (select employment_status::text from public.employees where id = v_emp),
    'active');
  perform pg_temp.check_true('and clears all three fields',
    (select last_working_date is null and resignation_date is null
        and termination_reason is null
       from public.employees where id = v_emp));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A month that has already been paid
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_emp  uuid;
  v_run  uuid;
  v_said text;
begin
  v_org := pg_temp.test_org('Sudah Dibayar Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'P1', 'Paid for June', date '2020-01-01', 4000,
          date '1990-01-01', 'citizen')
  returning id into v_emp;

  v_run := pg_temp.dep_run(v_org, '2026-06', date '2026-06-01', date '2026-06-30');
  update public.payroll_runs set status = 'posted', posted_at = now()
   where id = v_run;

  begin
    perform public.record_departure(v_emp, date '2026-05-31', 'resigned');
    raise exception 'FAIL: a posted month was restated by a departure';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a posted month after the last day refuses',
    v_said like '%PAY-2026-06%');
  perform pg_temp.check_true('and says what to do about it',
    v_said like '%Void it first%');

  -- A last working day inside that month is fine: they were there for
  -- part of it and the run paid them for part of it.
  perform public.record_departure(v_emp, date '2026-06-20', 'resigned');
  perform pg_temp.check_eq('a departure within the paid month is allowed',
    (select last_working_date from public.employees where id = v_emp)::text,
    '2026-06-20');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('recording a departure is closed to anon',
    not has_function_privilege('anon',
      'public.record_departure(uuid, date, text, text, date)', 'execute'));
  perform pg_temp.check_true('and so is undoing one',
    not has_function_privilege('anon',
      'public.reinstate_employee(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may try',
    has_function_privilege('authenticated',
      'public.record_departure(uuid, date, text, text, date)', 'execute'));
end $$;

rollback;

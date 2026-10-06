-- =====================================================================
-- iAkauntan :: correcting a day that was never closed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attendance_adjust.sql
--
-- `0360` made `incomplete` reachable and in doing so created a state
-- with no way out of it: `clock_out` only touches today's record, so
-- last Tuesday's forgotten punch-out was marked and then nobody could
-- do anything about it. `0027` had anticipated the fix and got as far
-- as three columns — `is_adjusted`, `adjusted_by`, `adjustment_reason`
-- — that nothing has ever written.
--
-- The three refusals are the interesting half, and each is about
-- somebody other than the person making the change:
--
--   * only HR, because a timesheet is what somebody is paid from;
--   * a reason, because the employee is the one who will be asked
--     about the changed number;
--   * not inside a closed pay period, because that overtime has been
--     paid and the payslip is what was remitted against.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_other  uuid;
  v_shift  uuid;
  v_emp    uuid;
  v_rec    uuid;
  v_day    date := date '2026-06-02';   -- a Tuesday
  v_out    jsonb;
  v_refused boolean;
  v_msg    text;
begin
  v_org := pg_temp.test_org('Kilang Betulkan Sdn Bhd');
  perform pg_temp.check_eq('2026-06-02 is a Tuesday', to_char(v_day, 'Dy'), 'Tue');

  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, break_minutes,
     grace_minutes, work_days, is_default)
  values (v_org, 'DAY', 'Nine to six', '09:00', '18:00', 60, 10,
          array[1,2,3,4,5], true)
  returning id into v_shift;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti', v_day - 90, 'active') returning id into v_emp;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (v_org, v_emp, v_shift, v_day - 90);

  -- She arrived on time and went home without punching out; 0360's
  -- nightly pass marked it.
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status)
  values (v_org, v_emp, v_day, v_shift,
          (v_day + time '09:05') at time zone 'Asia/Kuala_Lumpur',
          'incomplete')
  returning id into v_rec;

  -- ------------------------------------------------------------------
  -- HR closes it at the time she actually left
  -- ------------------------------------------------------------------
  v_out := public.adjust_attendance(
    v_rec,
    (v_day + time '09:05') at time zone 'Asia/Kuala_Lumpur',
    (v_day + time '19:00') at time zone 'Asia/Kuala_Lumpur',
    'Forgot to clock out; confirmed with her supervisor');

  -- Nine hours fifty-five, less the hour's break, against a scheduled
  -- eight: a hundred and fifteen minutes of overtime on an ordinary
  -- weekday.
  perform pg_temp.check_eq('the day is worked out from the corrected times',
    (v_out ->> 'worked_minutes')::integer, 535);
  perform pg_temp.check_eq('and the overtime with it',
    (v_out ->> 'overtime_minutes')::integer, 55);
  perform pg_temp.check_eq('it is an ordinary present day again',
    (v_out ->> 'status'), 'present');
  -- Five minutes past nine against a ten-minute grace is not late.
  perform pg_temp.check_eq('and the grace period still applies',
    (v_out ->> 'late_minutes')::integer, 0);

  -- What an auditor asks is not what it says now.
  perform pg_temp.check_true('the record says it was corrected',
    (select r.is_adjusted from public.attendance_records r where r.id = v_rec));
  perform pg_temp.check_eq('by whom',
    (select r.adjusted_by from public.attendance_records r where r.id = v_rec),
    v_owner);
  perform pg_temp.check_true('and why',
    (select r.adjustment_reason like '%supervisor%'
       from public.attendance_records r where r.id = v_rec));

  -- ------------------------------------------------------------------
  -- A correction that makes her late says so
  -- ------------------------------------------------------------------
  -- Unlike clocking out, which must never make somebody retrospectively
  -- late, a correction is a change to the arrival time itself.
  v_out := public.adjust_attendance(
    v_rec,
    (v_day + time '10:30') at time zone 'Asia/Kuala_Lumpur',
    (v_day + time '19:00') at time zone 'Asia/Kuala_Lumpur',
    'Card reader was down; she signed the book at half ten');
  perform pg_temp.check_eq('a corrected arrival is measured for lateness',
    (v_out ->> 'late_minutes')::integer, 80);
  perform pg_temp.check_eq('and the day reads as late', v_out ->> 'status', 'late');

  -- ------------------------------------------------------------------
  -- The three refusals
  -- ------------------------------------------------------------------
  v_refused := false;
  begin
    perform public.adjust_attendance(
      v_rec,
      (v_day + time '09:00') at time zone 'Asia/Kuala_Lumpur',
      (v_day + time '18:00') at time zone 'Asia/Kuala_Lumpur',
      '   ');
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('a correction with no reason is refused', v_refused);

  v_refused := false;
  begin
    perform public.adjust_attendance(
      v_rec,
      (v_day + time '18:00') at time zone 'Asia/Kuala_Lumpur',
      (v_day + time '09:00') at time zone 'Asia/Kuala_Lumpur',
      'Typed the wrong way round');
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('and a day that ends before it starts', v_refused);

  -- A closed pay period. The overtime above has been paid.
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date, is_closed)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-25', true);
  v_refused := false;
  begin
    perform public.adjust_attendance(
      v_rec,
      (v_day + time '09:00') at time zone 'Asia/Kuala_Lumpur',
      (v_day + time '18:00') at time zone 'Asia/Kuala_Lumpur',
      'Second thoughts');
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'a day inside a closed pay period is not quietly rewritten', v_refused);
  -- The period is named, so somebody can decide to reopen it
  -- deliberately rather than discovering the disagreement at an audit.
  perform pg_temp.check_true('and the period is named: ' || coalesce(v_msg, ''),
    v_msg like '%2026-06%');

  -- Reopening it lets the correction through, which is the control: the
  -- refusal is about the period rather than about the record.
  update public.pay_periods set is_closed = false
   where org_id = v_org and code = '2026-06';
  perform public.adjust_attendance(
    v_rec,
    (v_day + time '09:00') at time zone 'Asia/Kuala_Lumpur',
    (v_day + time '18:00') at time zone 'Asia/Kuala_Lumpur',
    'Second thoughts');
  perform pg_temp.check_eq('reopening the period lets it through',
    (select r.worked_minutes from public.attendance_records r where r.id = v_rec),
    480);

  -- ------------------------------------------------------------------
  -- And not by somebody who is not HR
  -- ------------------------------------------------------------------
  v_other := pg_temp.another_user('clerk@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_other, 'accounts_clerk', 'active');
  perform pg_temp.sign_in_as(v_other);
  v_refused := false;
  begin
    perform public.adjust_attendance(
      v_rec,
      (v_day + time '09:00') at time zone 'Asia/Kuala_Lumpur',
      (v_day + time '20:00') at time zone 'Asia/Kuala_Lumpur',
      'Giving myself two hours');
  exception when sqlstate '42501' then v_refused := true;
  end;
  perform pg_temp.check_true(
    'a timesheet is not everybody''s to correct', v_refused);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- adjust_attendance and recompute_attendance, rule by rule
--
-- A sweep of `0363`'s two functions over this file, `clock_out.sql` and
-- `attendance.sql` left fourteen mutants alive. Every corrected day in
-- this file was an ordinary weekday in a company with no holidays, no
-- night shift and no closed pay period except the one the refusal used;
-- so nothing said whose holiday or closed period counts, nor that a
-- night shift's eight hours are eight hours and not a negative number,
-- nor what lateness a rest day or a holiday carries. And four of the
-- refusals were tried only where another guard refused first, or not
-- at all.
-- ---------------------------------------------------------------------
create or replace function pg_temp.a_day(
  p_org uuid, p_emp uuid, p_shift uuid, p_on date,
  p_status text default 'present', p_worked integer default 0)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status, worked_minutes)
  values (p_org, p_emp, p_on, p_shift,
          (p_on + time '09:00') at time zone 'Asia/Kuala_Lumpur',
          p_status::app.attendance_status, p_worked)
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.kl(p_on date, p_at time)
returns timestamptz language sql immutable as $$
  select (p_on + p_at) at time zone 'Asia/Kuala_Lumpur';
$$;

do $$
declare
  v_tue date := date '2026-06-02';
  v_wed date := date '2026-06-03';   -- this company's holiday
  v_thu date := date '2026-06-04';   -- the neighbour's holiday
  v_sat date := date '2026-06-06';   -- a rest day
  v_a uuid; v_b uuid; v_day uuid; v_night uuid; v_emp uuid; v_owl uuid;
  v_rec uuid; v_out jsonb; v_period uuid;
begin
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.test_org('Betulkan Peraturan Sdn Bhd');
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, break_minutes,
     grace_minutes, work_days)
  values (v_a, 'DAY', 'Nine to six', '09:00', '18:00', 60, 10, array[1,2,3,4,5])
  returning id into v_day;
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, break_minutes,
     grace_minutes, work_days, crosses_midnight)
  values (v_a, 'NIGHT', 'Ten to six', '22:00', '06:00', 60, 10,
          array[1,2,3,4,5], true)
  returning id into v_night;
  insert into public.employees (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_a, 'E-1', 'Siti', v_tue - 90, 'active') returning id into v_emp;
  insert into public.employees (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_a, 'E-2', 'Burung Hantu', v_tue - 90, 'active') returning id into v_owl;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (v_a, v_emp, v_day, v_tue - 90), (v_a, v_owl, v_night, v_tue - 90);
  insert into public.public_holidays (org_id, holiday_date, name)
  values (v_a, v_wed, 'Hari Keputeraan');
  -- May is closed here; June, the month every day below is in, is not.
  v_period := public.ensure_pay_period(v_a, 2026, 5);
  update public.pay_periods set is_closed = true where id = v_period;

  -- The neighbour: a holiday on Thursday, and June closed.
  v_b := pg_temp.test_org('Betulkan Jiran Sdn Bhd');
  insert into public.public_holidays (org_id, holiday_date, name)
  values (v_b, v_thu, 'Their holiday');
  v_period := public.ensure_pay_period(v_b, 2026, 6);
  update public.pay_periods set is_closed = true where id = v_period;
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- REFUSALS, by what they say.
  perform pg_temp.check_refused('a record that is not there says so',
    format('select public.adjust_attendance(%L, now(), null, %L)',
           gen_random_uuid(), 'Fixing it'),
    '%No such attendance record%', 'P0002');
  perform pg_temp.check_refused('and the arithmetic says so too',
    format('select app.recompute_attendance(%L)', gen_random_uuid()),
    '%No such attendance record%', 'P0002');
  v_rec := pg_temp.a_day(v_a, v_emp, v_day, v_tue);
  perform pg_temp.check_refused('a corrected day still needs a start',
    format('select public.adjust_attendance(%L, null, null, %L)', v_rec, 'Fixing it'),
    '%still needs a time somebody started%', '23514');
  perform pg_temp.check_refused('a day that ends the instant it starts is refused',
    format('select public.adjust_attendance(%L, %L, %L, %L)', v_rec,
           pg_temp.kl(v_tue, '09:00'), pg_temp.kl(v_tue, '09:00'), 'Fixing it'),
    '%cannot end before it started%', '23514');

  -- WHOSE CLOSED PERIOD. May closed here and June closed next door; a
  -- June day here is open. And the reason is kept as said.
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_tue, '09:00'),
    pg_temp.kl(v_tue, '18:00'), '  Card reader was down  ');
  perform pg_temp.check_eq('a day in an open month is corrected, whatever else is closed',
    v_out ->> 'status', 'present');
  perform pg_temp.check_eq('with the reason kept trimmed',
    (select adjustment_reason from public.attendance_records where id = v_rec),
    'Card reader was down');

  -- AN OPEN DAY. Corrected to a start and no end: incomplete, and its
  -- old minutes do not survive.
  update public.attendance_records set worked_minutes = 300, status = 'present'
   where id = v_rec;
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_tue, '09:00'), null,
    'He did not clock out; nobody knows when he left');
  perform pg_temp.check_eq('a corrected day with no end is incomplete',
    v_out ->> 'status', 'incomplete');
  perform pg_temp.check_eq('and is not credited with the minutes it had',
    (v_out ->> 'worked_minutes')::integer, 0);

  -- A REST DAY. Saturday, half ten to half nine: not late, it
  -- was not a working day, and every minute past the eight scheduled is
  -- overtime of the rest-day kind -- which the reported total includes.
  v_rec := pg_temp.a_day(v_a, v_emp, v_day, v_sat);
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_sat, '10:30'),
    pg_temp.kl(v_sat, '21:30'), 'Came in for the stock take');
  perform pg_temp.check_eq('nobody is late on a rest day', v_out ->> 'status', 'rest_day');
  perform pg_temp.check_eq('so no lateness', (v_out ->> 'late_minutes')::integer, 0);
  perform pg_temp.check_eq('and the overtime reported is the rest-day overtime',
    (v_out ->> 'overtime_minutes')::integer,
    (select ot_restday_minutes from public.attendance_records where id = v_rec));
  perform pg_temp.check_eq('two hours of it: eleven, less the break, less eight',
    (v_out ->> 'overtime_minutes')::integer, 120);

  -- THIS COMPANY'S HOLIDAY, and the neighbour's.
  v_rec := pg_temp.a_day(v_a, v_emp, v_day, v_wed);
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_wed, '10:30'),
    pg_temp.kl(v_wed, '18:00'), 'Worked the holiday');
  perform pg_temp.check_eq('a holiday worked is a holiday', v_out ->> 'status', 'public_holiday');
  perform pg_temp.check_eq('and nobody is late on one', (v_out ->> 'late_minutes')::integer, 0);
  v_rec := pg_temp.a_day(v_a, v_emp, v_day, v_thu);
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_thu, '09:00'),
    pg_temp.kl(v_thu, '18:00'), 'Card reader');
  perform pg_temp.check_eq('the neighbour''s holiday is an ordinary day here',
    v_out ->> 'status', 'present');

  -- A NIGHT SHIFT. Ten at night to six in the morning, an hour's break:
  -- seven hours scheduled and seven worked, so no overtime -- not a
  -- negative schedule that makes every minute overtime.
  v_rec := pg_temp.a_day(v_a, v_owl, v_night, v_tue);
  v_out := public.adjust_attendance(v_rec, pg_temp.kl(v_tue, '22:00'),
    pg_temp.kl(v_tue + 1, '06:00'), 'Night shift, reader offline');
  perform pg_temp.check_eq('a night shift''s hours are its hours',
    (v_out ->> 'worked_minutes')::integer, 420);
  perform pg_temp.check_eq('and a full night is no overtime',
    (v_out ->> 'overtime_minutes')::integer, 0);
  perform pg_temp.sign_out();
end $$;

rollback;

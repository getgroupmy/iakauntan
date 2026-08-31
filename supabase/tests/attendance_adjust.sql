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

rollback;

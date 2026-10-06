-- =====================================================================
-- iAkauntan :: closing a day's attendance
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attendance_close.sql
--
-- `app.attendance_status` has seven values and `clock_out` writes four.
-- The three it never wrote are the three about somebody who was not at
-- work, and they fail in two different ways.
--
-- `incomplete` is a falsehood. A row with a clock-in and no clock-out
-- keeps `status = 'present'` and `worked_minutes = 0`, so a register
-- grouped by status counts a forgotten punch-out as a normal day. The
-- assertion below is that it stops saying that.
--
-- `absent` and `on_leave` are absences, and the shape of an absence
-- here is that there is no row at all: "who was away yesterday" had no
-- answer, because the register only held the days people turned up.
--
-- The refusals matter more than the marks. Nobody without a roster is
-- marked absent — their working pattern is unknown and a red mark
-- against every employee in a company that has not filled the roster in
-- is worse than no mark at all — and neither is anybody on a rest day,
-- a public holiday, or a day they clocked in for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_user   uuid := pg_temp.test_user();
  v_shift  uuid;
  v_worker uuid;   -- rostered, away, no explanation
  v_leaver uuid;   -- rostered, away, on approved leave
  v_open   uuid;   -- clocked in, never out
  v_free   uuid;   -- on no roster at all
  v_denied uuid;   -- rostered, away, asked for leave and was refused
  v_type   uuid;
  v_mon    date := date '2026-06-01';  -- a Monday
  v_sun    date := date '2026-06-07';  -- the Sunday after it
  v_n      integer;
begin
  v_org := pg_temp.test_org('Kilang Kehadiran Sdn Bhd');

  -- Stated rather than assumed. Every claim below depends on which
  -- weekday these are, and a wrong assumption should fail here rather
  -- than surface as a confusing status three checks later.
  perform pg_temp.check_eq('2026-06-01 is a Monday',
    to_char(v_mon, 'Dy'), 'Mon');
  perform pg_temp.check_eq('and 2026-06-07 a Sunday',
    to_char(v_sun, 'Dy'), 'Sun');

  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, work_days, is_default)
  values (v_org, 'DAY', 'Office hours', '09:00', '18:00',
          array[1,2,3,4,5], true)
  returning id into v_shift;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti', v_mon - 90, 'active') returning id into v_worker;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-2', 'Rahim', v_mon - 90, 'active') returning id into v_leaver;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-3', 'Mei Ling', v_mon - 90, 'active') returning id into v_open;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-4', 'Kumar', v_mon - 90, 'active') returning id into v_free;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-5', 'Fatimah', v_mon - 90, 'active') returning id into v_denied;

  -- Everybody but Kumar is on the roster. His pattern is unknown.
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  select v_org, e, v_shift, v_mon - 90
    from unnest(array[v_worker, v_leaver, v_open, v_denied]) e;

  -- Rahim is on approved leave that Monday.
  insert into public.leave_types (org_id, code, name, default_days)
  values (v_org, 'AL', 'Annual', 8) returning id into v_type;
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-1', v_leaver, v_type, v_mon, v_mon, 1, 'approved');
  -- Fatimah asked for the same day and was refused, and did not come in
  -- anyway. The mutation run found this gap: with only an approved
  -- request in the fixture, dropping the `status = 'approved'` check
  -- broke nothing, and a rejected request would have excused the
  -- absence it was refused for.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-2', v_denied, v_type, v_mon, v_mon, 1, 'rejected');

  -- Mei Ling punched in and went home without punching out.
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status)
  values (v_org, v_open, v_mon, v_shift,
          v_mon + time '09:02', 'present');

  -- ------------------------------------------------------------------
  -- The day is closed
  -- ------------------------------------------------------------------
  v_n := app.close_attendance_day(v_org, v_mon);

  perform pg_temp.check_eq(
    'a clock-in with no clock-out stops reading as a normal day',
    (select r.status::text from public.attendance_records r
      where r.employee_id = v_open and r.work_date = v_mon), 'incomplete');
  -- And is not closed. What time they left is not knowable, and writing
  -- one would put hours on a payslip nobody worked.
  perform pg_temp.check_true('without inventing a time they left',
    (select r.clock_out is null and coalesce(r.worked_minutes, 0) = 0
       from public.attendance_records r
      where r.employee_id = v_open and r.work_date = v_mon));

  perform pg_temp.check_eq('somebody rostered and away is absent',
    (select r.status::text from public.attendance_records r
      where r.employee_id = v_worker and r.work_date = v_mon), 'absent');
  perform pg_temp.check_eq(
    'and away with an approved request is on leave, not absent',
    (select r.status::text from public.attendance_records r
      where r.employee_id = v_leaver and r.work_date = v_mon), 'on_leave');

  -- The refusal that matters most. A company that has not filled in its
  -- roster would otherwise get a red mark against every employee.
  perform pg_temp.check_true('nobody on no roster is marked at all',
    not exists (select 1 from public.attendance_records r
                 where r.employee_id = v_free and r.work_date = v_mon));

  perform pg_temp.check_eq(
    'a request that was refused does not excuse the day it was refused for',
    (select r.status::text from public.attendance_records r
      where r.employee_id = v_denied and r.work_date = v_mon), 'absent');

  perform pg_temp.check_eq('four rows accounted for', v_n, 4);

  -- Running it again finds nothing new. A sweep that re-marks what it
  -- marked yesterday fills the register with duplicates.
  perform pg_temp.check_eq('and running it again changes nothing',
    app.close_attendance_day(v_org, v_mon), 0);

  -- ------------------------------------------------------------------
  -- A Sunday is not a day anybody failed to turn up for
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a rest day marks nobody',
    app.close_attendance_day(v_org, v_sun), 0);
  perform pg_temp.check_true('and writes no rows for it',
    not exists (select 1 from public.attendance_records r
                 where r.org_id = v_org and r.work_date = v_sun));

  -- ------------------------------------------------------------------
  -- Nor is a public holiday
  -- ------------------------------------------------------------------
  insert into public.public_holidays (org_id, holiday_date, name)
  values (v_org, v_mon + 1, 'Hari Raya');
  perform pg_temp.check_eq('a public holiday marks nobody either',
    app.close_attendance_day(v_org, v_mon + 1), 0);

  -- The control: the Tuesday after it is an ordinary working day, and
  -- everybody rostered is marked. Without this the two zeroes above
  -- would be satisfied by a function that does nothing at all.
  perform pg_temp.check_eq('but the next working day is',
    app.close_attendance_day(v_org, v_mon + 2), 4);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- close_attendance_day, rule by rule
--
-- A sweep of `0360`'s definition over this file and `scheduled_work.sql`
-- left fifteen mutants alive. The fixture above was one company of five
-- people, all active, all hired months before, with one open clock-in on
-- the day being closed and one leave request in each state that day. So
-- nothing said which COMPANY a holiday, a clock-in or an employee had to
-- belong to; nothing pressed the edges of employment -- somebody who has
-- left, or retired, or not yet started, or is on their first or last
-- day; an open clock-in was never on another day nor a finished one on
-- this; and `dow` against ISO weekdays differ only on a Sunday, which no
-- roster here worked.
--
-- One person per rule, closing a Wednesday, beside a second company that
-- has a holiday that day, an open clock-in, and staff of its own.
-- ---------------------------------------------------------------------
create or replace function pg_temp.rostered(
  p_org uuid, p_no text, p_shift uuid, p_hired date,
  p_status text default 'active', p_last date default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status,
     resignation_date, last_working_date)
  values (p_org, p_no, p_no, p_hired, p_status::app.employment_status,
          case when p_status in ('resigned', 'terminated', 'retired')
               then p_hired + 1 end,
          p_last)
  returning id into v;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (p_org, v, p_shift, least(p_hired, date '2026-01-01'));
  return v;
end $$;

create or replace function pg_temp.day_status(p_emp uuid, p_on date)
returns text language sql stable as $$
  select coalesce((select status::text from public.attendance_records
                    where employee_id = p_emp and work_date = p_on), 'no row');
$$;

do $$
declare
  v_wed date := date '2026-06-10';
  v_sun date := date '2026-06-14';
  v_a uuid; v_b uuid; v_day uuid; v_wknd uuid; v_b_day uuid; v_type uuid;
  v_base uuid; v_res uuid; v_ret uuid; v_new uuid; v_day1 uuid;
  v_gone uuid; v_last uuid; v_sub uuid; v_later uuid; v_openy uuid;
  v_done uuid; v_weekend uuid; v_b_open uuid; v_b_away uuid;
begin
  perform pg_temp.check_eq('2026-06-10 is a Wednesday', to_char(v_wed, 'Dy'), 'Wed');
  perform pg_temp.check_eq('and 2026-06-14 a Sunday', to_char(v_sun, 'Dy'), 'Sun');
  perform pg_temp.allow_many_companies();

  v_a := pg_temp.test_org('Kehadiran Peraturan Sdn Bhd');
  insert into public.work_shifts (org_id, code, name, start_time, end_time, work_days)
  values (v_a, 'DAY', 'Office hours', '09:00', '18:00', array[1,2,3,4,5])
  returning id into v_day;
  -- Saturday and Sunday, written in `dow`: 6 and 0.
  insert into public.work_shifts (org_id, code, name, start_time, end_time, work_days)
  values (v_a, 'WKND', 'Weekend', '09:00', '18:00', array[0,6])
  returning id into v_wknd;

  v_base  := pg_temp.rostered(v_a, 'BASE',  v_day, v_wed - 90);
  v_res   := pg_temp.rostered(v_a, 'RES',   v_day, v_wed - 90, 'resigned', v_wed + 30);
  v_ret   := pg_temp.rostered(v_a, 'RET',   v_day, v_wed - 90, 'retired',  v_wed + 30);
  v_new   := pg_temp.rostered(v_a, 'NEW',   v_day, v_wed + 10);
  v_day1  := pg_temp.rostered(v_a, 'DAY1',  v_day, v_wed);
  v_gone  := pg_temp.rostered(v_a, 'GONE',  v_day, v_wed - 90, 'notice', v_wed - 1);
  v_last  := pg_temp.rostered(v_a, 'LAST',  v_day, v_wed - 90, 'notice', v_wed);
  v_sub   := pg_temp.rostered(v_a, 'SUB',   v_day, v_wed - 90);
  v_later := pg_temp.rostered(v_a, 'LATER', v_day, v_wed - 90);
  v_openy := pg_temp.rostered(v_a, 'OPENY', v_day, v_wed - 90);
  v_done  := pg_temp.rostered(v_a, 'DONE',  v_day, v_wed - 90);
  v_weekend := pg_temp.rostered(v_a, 'WKND', v_wknd, v_wed - 90);

  insert into public.leave_types (org_id, code, name, default_days)
  values (v_a, 'AL', 'Annual', 8) returning id into v_type;
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_a, 'LV-SUB', v_sub, v_type, v_wed, v_wed, 1, 'submitted'),
         (v_a, 'LV-LATER', v_later, v_type, v_wed + 5, v_wed + 5, 1, 'approved');

  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, clock_out, status)
  values (v_a, v_openy, v_wed - 1, v_day, (v_wed - 1) + time '09:00', null, 'present'),
         (v_a, v_done,  v_wed,     v_day, v_wed + time '09:00', v_wed + time '18:00', 'present');
  -- A holiday that is worked is a working day.
  insert into public.public_holidays (org_id, holiday_date, name, is_working)
  values (v_a, v_wed, 'Company anniversary (worked)', true);

  -- The company next door: a holiday that day, an open clock-in, and
  -- somebody rostered who did not come.
  v_b := pg_temp.test_org('Kehadiran Jiran Sdn Bhd');
  insert into public.work_shifts (org_id, code, name, start_time, end_time, work_days)
  values (v_b, 'DAY', 'Office hours', '09:00', '18:00', array[1,2,3,4,5])
  returning id into v_b_day;
  v_b_open := pg_temp.rostered(v_b, 'B-OPEN', v_b_day, v_wed - 90);
  v_b_away := pg_temp.rostered(v_b, 'B-AWAY', v_b_day, v_wed - 90);
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status)
  values (v_b, v_b_open, v_wed, v_b_day, v_wed + time '09:00', 'present');
  insert into public.public_holidays (org_id, holiday_date, name)
  values (v_b, v_wed, 'Their state holiday');

  perform app.close_attendance_day(v_a, v_wed);

  perform pg_temp.check_eq('a worked holiday, and the neighbour''s holiday, close as a working day',
    pg_temp.day_status(v_base, v_wed), 'absent');
  perform pg_temp.check_eq('somebody who has resigned is not marked',
    pg_temp.day_status(v_res, v_wed), 'no row');
  perform pg_temp.check_eq('nor somebody who has retired',
    pg_temp.day_status(v_ret, v_wed), 'no row');
  perform pg_temp.check_eq('nor somebody not yet started',
    pg_temp.day_status(v_new, v_wed), 'no row');
  perform pg_temp.check_eq('while their first day is a working day',
    pg_temp.day_status(v_day1, v_wed), 'absent');
  perform pg_temp.check_eq('somebody past their last day is not marked',
    pg_temp.day_status(v_gone, v_wed), 'no row');
  perform pg_temp.check_eq('while their last day is a working day',
    pg_temp.day_status(v_last, v_wed), 'absent');
  perform pg_temp.check_eq('a request still waiting does not excuse the day',
    pg_temp.day_status(v_sub, v_wed), 'absent');
  perform pg_temp.check_eq('nor does leave approved for another day',
    pg_temp.day_status(v_later, v_wed), 'absent');
  perform pg_temp.check_eq('an open clock-in on another day is left for its own night',
    pg_temp.day_status(v_openy, v_wed - 1), 'present');
  perform pg_temp.check_eq('a finished day is not incomplete',
    pg_temp.day_status(v_done, v_wed), 'present');
  perform pg_temp.check_eq('a weekend roster is not marked on a Wednesday',
    pg_temp.day_status(v_weekend, v_wed), 'no row');
  perform pg_temp.check_eq('the neighbour''s open clock-in is theirs to close',
    pg_temp.day_status(v_b_open, v_wed), 'present');
  perform pg_temp.check_eq('and their staff are not marked by this company''s night',
    pg_temp.day_status(v_b_away, v_wed), 'no row');

  -- SUNDAY, which `dow` writes as 0 and ISO as 7.
  perform pg_temp.check_eq('a Sunday closes for the weekend roster alone',
    app.close_attendance_day(v_a, v_sun), 1);
  perform pg_temp.check_eq('who is absent on it',
    pg_temp.day_status(v_weekend, v_sun), 'absent');
end $$;

rollback;

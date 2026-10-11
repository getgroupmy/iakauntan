-- =====================================================================
-- iAkauntan :: 0811 a timesheet is corrected with a reason
--
-- `attendance_records` is each employee's day: when they clocked in and
-- out, the minutes worked, late and early, and the overtime minutes
-- `calculate_payroll_run` pays at the company's multipliers. `clock_in`
-- and `clock_out`, the terminal punch, the day's close and
-- `adjust_attendance` write it, all SECURITY DEFINER; the app only reads
-- it. `adjust_attendance` is how HR corrects a day: it asks why ("It
-- goes on the record beside the change"), refuses a day in a pay period
-- already closed, recomputes the minutes from the times, and marks the
-- record adjusted and by whom. But `attendance_records_write`, an `ALL`
-- policy asking `app.can_manage_hr`, let HR write the table directly
-- and skip every part of that.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: `adjust_attendance` refused a correction with no
-- reason; 3,000 overtime minutes written straight into the same day --
-- not marked adjusted, no reason -- were paid on January's payslip of a
-- RM2,600 employee as 50 hours, RM937.50.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0810`: the
-- grants are revoked and the write policy dropped. Reading stays, by
-- `attendance_records_select`: HR, the employee their own, and their
-- manager.
--
-- Production held no attendance record on 11 October.
-- =====================================================================

revoke insert, update, delete on public.attendance_records from authenticated, anon;
drop policy if exists attendance_records_write on public.attendance_records;

comment on table public.attendance_records is
  'Each employee''s working day, and the overtime minutes payroll pays. '
  'WRITTEN ONLY BY FUNCTION -- 0811 revoked insert, update and delete '
  'from clients and dropped the write policy: clock_in, clock_out, the '
  'terminal punch and the day''s close write it, and HR corrects a day '
  'through adjust_attendance, which records why.';

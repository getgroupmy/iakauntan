-- =====================================================================
-- iAkauntan :: 0024 HRMS access types
--
-- Postgres will not let a new enum value be used in the same transaction
-- that adds it, so these arrive on their own and are wired into the
-- permission functions by the next migrations.
--
--   hr_manager  runs the HR module: employee records, leave, payroll
--   employee    self-service only — their own record, payslips, leave
-- =====================================================================

alter type app.member_role add value if not exists 'hr_manager' after 'accountant';
alter type app.member_role add value if not exists 'employee' after 'viewer';

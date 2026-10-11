-- =====================================================================
-- iAkauntan :: 0807 the year to date is what was paid
--
-- `payroll_ytd` holds each employee's year to date: gross, taxable
-- income, EPF, SOCSO, EIS, PCB and zakat paid, months paid.
-- `post_payroll_run` adds each posted month to it, and `app.calc_pcb`
-- reads it to work out every later month's PCB under the MTD formula
-- -- "THE YEAR TO DATE IS THE ONE THAT COMPOUNDS", as
-- `payroll_run.sql` says. The EA form reads the payslips themselves. A
-- previous employer's figures go in `employee_ytd_opening`, which the
-- app writes; `payroll_ytd` the app never touches. But its `ALL` policy
-- let anybody who may run payroll insert, update and delete it.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: January posted at RM8,000 with PCB RM508.65.
-- February then computes RM508.60; with the year to date edited by
-- hand -- RM3,000 more tax paid, RM5,000 less taxable income -- it
-- computed RM149.55. RM359 a month under-deducted for the rest of the
-- year, on payslips and an EA form that each look right.
--
-- Answered "read-only to clients", as `0740`, `0804` and `0806`: the
-- grants are revoked and the write policy dropped. Reading stays, by
-- `payroll_ytd_select`, which already lets a payroll runner read every
-- employee's and an employee their own. `post_payroll_run` is a
-- definer.
--
-- Production held four year-to-date rows from nine posted runs, each
-- agreeing with its payslips, on 11 October.
-- =====================================================================

revoke insert, update, delete on public.payroll_ytd from authenticated, anon;
drop policy if exists payroll_ytd_write on public.payroll_ytd;

comment on table public.payroll_ytd is
  'Each employee''s year to date, as posted payroll runs paid it; what '
  'app.calc_pcb reads for every later month''s PCB. WRITTEN ONLY BY '
  'FUNCTION -- 0807 revoked insert, update and delete from clients and '
  'dropped the write policy; post_payroll_run writes it. A previous '
  'employer''s figures go in employee_ytd_opening.';

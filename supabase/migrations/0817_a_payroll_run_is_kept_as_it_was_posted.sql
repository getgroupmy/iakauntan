-- =====================================================================
-- iAkauntan :: 0817 a payroll run is kept as it was posted
--
-- A payroll run is raised, calculated, posted and marked paid by five
-- definers -- `ensure_pay_period`, `create_payroll_run`,
-- `calculate_payroll_run`, `post_payroll_run` and `mark_payroll_paid`
-- -- and the app reads the four tables they write and writes none of
-- them. A posted run's payslips are what the EPF, SOCSO and LHDN
-- submissions, the EA form and the bank file are built from, and
-- `app.refuse_posted_payslip_change` refuses changing one -- by asking
-- the run's `status`. But `authenticated` held insert, update and
-- delete on all four, behind `ALL` policies asking `app.can_run_payroll`,
-- and the status is a column like any other.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: January posted -- RM8,000 gross, RM6,569.35 net,
-- RM508.65 PCB, a journal of RM9,077. The payslip edited directly was
-- refused, as it should be. Then the run set back to `calculated`, the
-- payslip's net pay raised by RM1,000 and its PCB set to nought, and
-- the run set back to `posted`: all three accepted. The bank instruction
-- paid RM7,569.35, the EA form said no tax was deducted, and the journal
-- still said what had been posted. A posted run could be deleted, and
-- its payslips went with it. And a period's pay date -- which
-- `ensure_pay_period` refuses to move, because "moving it underneath
-- would change every statutory figure the run computed" -- could be
-- moved by hand.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0816`: the
-- grants are revoked on `payroll_runs`, `payslips`, `payslip_lines` and
-- `pay_periods`, and their write policies dropped, the restrictive
-- `module_gate_` ones with them. Reading stays, by each table's select
-- policy. A posted run is corrected the way the trigger says: void it
-- and raise another -- for which there is no function yet, and there was
-- never one the app could reach. `pay_periods.is_closed` was set by
-- nothing before this and is set by nothing after it.
--
-- Production held nine runs, all paid, thirty-six payslips, 325 lines
-- and nine periods on 11 October.
-- =====================================================================

revoke insert, update, delete on public.payroll_runs from authenticated, anon;
drop policy if exists payroll_runs_write on public.payroll_runs;
drop policy if exists module_gate_insert on public.payroll_runs;
drop policy if exists module_gate_update on public.payroll_runs;
drop policy if exists module_gate_delete on public.payroll_runs;

revoke insert, update, delete on public.payslips from authenticated, anon;
drop policy if exists payslips_write on public.payslips;
drop policy if exists module_gate_insert on public.payslips;
drop policy if exists module_gate_update on public.payslips;
drop policy if exists module_gate_delete on public.payslips;

revoke insert, update, delete on public.payslip_lines from authenticated, anon;
drop policy if exists payslip_lines_write on public.payslip_lines;

revoke insert, update, delete on public.pay_periods from authenticated, anon;
drop policy if exists pay_periods_write on public.pay_periods;

comment on table public.payroll_runs is
  'A month''s payroll: its state and its totals. WRITTEN ONLY BY '
  'FUNCTION -- 0817 revoked insert, update and delete from clients and '
  'dropped the write policies; create_payroll_run raises it, '
  'calculate_payroll_run works it out, post_payroll_run posts it and '
  'mark_payroll_paid records the bank took it. The posted-payslip '
  'guard reads its status, so the status is not a client''s to write.';

comment on table public.payslips is
  'One employee''s pay in a run, and the figures the EPF, SOCSO and '
  'LHDN submissions, the EA form and the bank file are built from. '
  'WRITTEN ONLY BY FUNCTION -- 0817 revoked insert, update and delete '
  'from clients and dropped the write policies; calculate_payroll_run '
  'writes it.';

comment on table public.payslip_lines is
  'The earnings and deductions on a payslip. WRITTEN ONLY BY FUNCTION '
  '-- 0817 revoked insert, update and delete from clients and dropped '
  'the write policy; calculate_payroll_run writes it.';

comment on table public.pay_periods is
  'A payroll month and its pay date, which picks the statutory schedules '
  'a run is worked out under. WRITTEN ONLY BY FUNCTION -- 0817 revoked '
  'insert, update and delete from clients and dropped the write policy; '
  'ensure_pay_period raises it and does not move it.';

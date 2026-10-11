-- =====================================================================
-- iAkauntan :: 0821 the statutory inputs are in range
--
-- Four standing figures on an employee are read by
-- `calculate_payroll_run` every month: `cp38_monthly`, which LHDN has
-- directed be deducted on top of PCB and which `post_payroll_run`
-- remits with it; `zakat_monthly`, a rebate against PCB; and the
-- voluntary EPF rates, employee and employer, added to the statutory
-- contribution as `ceil(wage * rate / 100)`. And a dependant's
-- `relief_claim_percent` scales a child's relief straight into PCB.
-- The screens refuse a negative amount, a rate above 100 and a share
-- outside 0 to 100 -- `standing_deductions.dart` and
-- `employee_records.dart`, which says of the share that "the database
-- will take 150, or -50, without a word". It would: none of the five
-- has a check.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`, on an RM8,000 employee: voluntary rates of -11 and
-- -13 written to the row and accepted -- EPF employee RM880 became
-- RM0.00 and EPF employer RM960 became -RM80.00. A CP38 of -RM300
-- accepted onto the payslip. A child's share set to 400 per cent,
-- and PCB fell from RM413.65 to RM318.65.
--
-- Answered "check constraints": the screens' hard bounds, on the
-- tables. The screen's other warning -- a rate between 0 and 1 is
-- probably a fraction typed for a percentage -- stays the screen's: a
-- voluntary rate under one per cent can be meant.
--
-- Production held four employees and no dependant on 11 October, none
-- out of range.
-- =====================================================================

alter table public.employees
  add constraint employees_cp38_not_negative_ck
    check (cp38_monthly >= 0),
  add constraint employees_zakat_not_negative_ck
    check (zakat_monthly >= 0),
  add constraint employees_epf_voluntary_employee_rate_ck
    check (epf_voluntary_employee_rate between 0 and 100),
  add constraint employees_epf_voluntary_employer_rate_ck
    check (epf_voluntary_employer_rate between 0 and 100);

alter table public.employee_dependants
  add constraint employee_dependants_relief_claim_percent_ck
    check (relief_claim_percent between 0 and 100);

comment on constraint employees_cp38_not_negative_ck on public.employees is
  'A CP38 direction is a deduction, remitted with PCB; it is not a refund. 0821.';
comment on constraint employees_zakat_not_negative_ck on public.employees is
  'Zakat paid is a rebate against PCB, and nobody pays less than none. 0821.';
comment on constraint employees_epf_voluntary_employee_rate_ck on public.employees is
  'A voluntary EPF rate is added to the statutory one, in per cent: 0 to 100. 0821.';
comment on constraint employees_epf_voluntary_employer_rate_ck on public.employees is
  'A voluntary EPF rate is added to the statutory one, in per cent: 0 to 100. 0821.';
comment on constraint employee_dependants_relief_claim_percent_ck on public.employee_dependants is
  'The share of a dependant''s relief this employee claims: none to all of it. 0821.';

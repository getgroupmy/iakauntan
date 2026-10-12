-- =====================================================================
-- iAkauntan :: 0834 the year an employee brings with them
--
-- `employee_ytd_opening` holds what somebody earned and paid elsewhere
-- earlier in the tax year -- a joiner's previous employer, or the months
-- before a company moved its payroll here. `app.calc_pcb` reads it as
-- it stands: gross pay and benefits in kind are added to the projected
-- income, EPF to the relief, PCB and zakat taken off the tax still to
-- deduct. The table carried no check at all, and the HR screen's fields
-- parse a typed minus sign.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`, for somebody on RM5,000 a month who joined in July:
-- with the previous employer's figures -- gross RM30,000, EPF RM3,300,
-- PCB RM600 -- July's PCB is RM117.90. With the PCB typed as -600 it
-- was RM317.90, RM200 a month withheld that is not owed; with the gross
-- typed as -30,000, RM0; with the year typed as 26 the opening was never
-- read and PCB was RM0. Every one was accepted.
--
-- Answered "check constraints", in `0821`'s manner: each figure at
-- least zero, and the tax year between 2000 and 2100. The screen shows
-- the constraint's refusal, which names the figure. Production held no
-- opening rows on 12 October, so nothing had to be put right first.
-- =====================================================================

alter table public.employee_ytd_opening
  add constraint employee_ytd_opening_gross_pay_not_negative_ck
    check (gross_pay >= 0),
  add constraint employee_ytd_opening_epf_employee_not_negative_ck
    check (epf_employee >= 0),
  add constraint employee_ytd_opening_pcb_paid_not_negative_ck
    check (pcb_paid >= 0),
  add constraint employee_ytd_opening_zakat_paid_not_negative_ck
    check (zakat_paid >= 0),
  add constraint employee_ytd_opening_benefits_in_kind_not_negative_ck
    check (benefits_in_kind >= 0),
  add constraint employee_ytd_opening_tax_year_ck
    check (tax_year between 2000 and 2100);

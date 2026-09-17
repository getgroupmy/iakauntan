-- =====================================================================
-- 0502  A pay period belongs to one company, and the rows that hang off
--       it say which
--
-- `report_statutory_remittances` joins a company's recorded payments to
-- its posted runs on `sr.org_id = p_org_id and sr.period_id = ...`, and
-- `record_statutory_remittance` refuses a period that belongs to
-- somebody else. Both are right, and both were the only thing holding
-- the invariant up: `statutory_remittances` and `payroll_runs` each
-- carry `org_id` and `period_id` with no constraint saying the two
-- agree.
--
-- That is the shape this schema already fixes elsewhere -- see
-- `bank_transactions_bank_account_same_org` -- and it is worth fixing
-- here for the same reason. What a company owes KWSP, PERKESO and LHDN
-- is derived by adding up rows filtered on `org_id`. A row whose
-- `period_id` points into another company's payroll would put another
-- company's wages into this one's return, and the only reason none can
-- exist today is that the two functions that write these tables both
-- check. A composite key makes it the database's answer rather than a
-- property of the current callers.
--
-- Checked against the live data before writing: no row in either table
-- disagrees with its period today.
-- =====================================================================

alter table public.pay_periods
  add constraint pay_periods_org_id_id_key unique (org_id, id);

alter table public.payroll_runs
  add constraint payroll_runs_period_same_org
  foreign key (org_id, period_id)
  references public.pay_periods (org_id, id) on delete restrict;

alter table public.statutory_remittances
  add constraint statutory_remittances_period_same_org
  foreign key (org_id, period_id)
  references public.pay_periods (org_id, id) on delete cascade;

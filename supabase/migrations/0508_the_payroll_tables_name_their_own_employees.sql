-- =====================================================================
-- 0508 :: the payroll tables name their own company's employees
--
-- 0507 found that `leave_requests.employee_id` had only a plain key to
-- `employees(id)` while carrying its own `org_id`, so one company's row
-- could name another company's employee. It fixed the two tables
-- `submit_leave_request` writes and added the `unique (org_id, id)` on
-- `employees` that the composite keys need.
--
-- Twenty-four tables were left in that state. This is the first batch:
-- the eight where a wrong employee would be a payroll or a tax figure
-- rather than a listing. A payslip, a year-to-date total, an opening
-- balance or a salary component attached to somebody else's employee is
-- a number that reaches the EA form and the monthly remittance.
--
-- These are constraints only. No function changes, because none of the
-- writers takes an employee id from the caller the way
-- `submit_leave_request` did -- they read it from a payroll run or a
-- claim. The keys are here so that stays true.
--
-- Checked on the hosted project before writing: none of the eight has a
-- row that would violate. `scripts/check_embeds.py` is run against this
-- migration -- every added foreign key is an API change, and 0502 made
-- every `pay_periods` embed ambiguous exactly this way.
-- =====================================================================

alter table public.payslips
  add constraint payslips_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.payroll_ytd
  add constraint payroll_ytd_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.employee_ytd_opening
  add constraint employee_ytd_opening_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.employee_salary_components
  add constraint employee_salary_components_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.employee_tax_reliefs
  add constraint employee_tax_reliefs_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.employee_dependants
  add constraint employee_dependants_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.attendance_records
  add constraint attendance_records_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.expense_claims
  add constraint expense_claims_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

-- =====================================================================
-- 0509 :: the rest of the employee references
--
-- 0507 added the `unique (org_id, id)` on `employees` and closed the two
-- tables `submit_leave_request` writes. 0508 closed the eight where a
-- wrong employee is a payroll or a tax figure. This closes the last
-- sixteen columns, which finishes the set: every table that carries its
-- own `org_id` and names an employee now says which company's employee.
--
-- Most of these are the "who did it" columns rather than the subject of
-- the row -- the reviewer on an appraisal, the approver on a claim, the
-- head of a department, the interviewer, the hiring manager, the person
-- who referred an applicant, an employee's own manager. They are
-- nullable, and a composite key with MATCH SIMPLE is not enforced when
-- any column is null, so a row that names nobody is unaffected. A row
-- that names somebody now has to name somebody here.
--
-- `employees.manager_id` is a self-reference: the composite points at
-- the same table, which is what makes a reporting line unable to cross
-- a company.
--
-- Checked on the hosted project before writing: none of the sixteen has
-- a row that would violate. `scripts/check_embeds.py` is run against
-- this migration -- adding a foreign key is an API change, and 0508
-- made three embeds in repository.dart ambiguous exactly this way.
-- =====================================================================

alter table public.applicants
  add constraint applicants_hired_employee_same_org
  foreign key (org_id, hired_employee_id)
  references public.employees (org_id, id) on delete set null;

alter table public.applicants
  add constraint applicants_referred_by_same_org
  foreign key (org_id, referred_by)
  references public.employees (org_id, id) on delete set null;

alter table public.appraisals
  add constraint appraisals_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.appraisals
  add constraint appraisals_reviewer_same_org
  foreign key (org_id, reviewer_id)
  references public.employees (org_id, id) on delete set null;

alter table public.claim_approvals
  add constraint claim_approvals_approver_same_org
  foreign key (org_id, approver_employee_id)
  references public.employees (org_id, id) on delete set null;

alter table public.departments
  add constraint departments_head_same_org
  foreign key (org_id, head_employee_id)
  references public.employees (org_id, id) on delete set null;

alter table public.employee_documents
  add constraint employee_documents_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.employee_shifts
  add constraint employee_shifts_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

-- A reporting line cannot cross a company.
alter table public.employees
  add constraint employees_manager_same_org
  foreign key (org_id, manager_id)
  references public.employees (org_id, id) on delete set null;

alter table public.interviews
  add constraint interviews_interviewer_same_org
  foreign key (org_id, interviewer_id)
  references public.employees (org_id, id) on delete set null;

alter table public.job_requisitions
  add constraint job_requisitions_hiring_manager_same_org
  foreign key (org_id, hiring_manager_id)
  references public.employees (org_id, id) on delete set null;

alter table public.onboarding_checklists
  add constraint onboarding_checklists_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.onboarding_tasks
  add constraint onboarding_tasks_owner_same_org
  foreign key (org_id, owner_employee_id)
  references public.employees (org_id, id) on delete set null;

alter table public.payslip_access_requests
  add constraint payslip_access_requests_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.pos_service_providers
  add constraint pos_service_providers_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete set null;

alter table public.salespeople
  add constraint salespeople_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete set null;

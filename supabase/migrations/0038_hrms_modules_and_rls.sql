-- =====================================================================
-- iAkauntan :: 0038 hrms modules and rls
-- Applied as project migration 20260810055425.
-- =====================================================================

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order)
values
  ('hr', 'Human Resources',
   'Employee records, attendance, leave, claims and talent management', false, 59, 9),
  ('payroll', 'Payroll & Statutory',
   'Malaysian payroll with EPF, SOCSO, EIS, PCB and HRD Corp', false, 89, 10)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
do $do$
declare
  t text;

  -- Company-wide settings and lists: any member may read them, HR owns
  -- the changes.
  hr_reference constant text[] := array[
    'departments', 'positions', 'work_shifts', 'public_holidays',
    'leave_types', 'claim_types', 'onboarding_templates',
    'onboarding_template_items', 'appraisal_cycles'];

  -- Personal records: HR, or the person themselves.
  hr_personal constant text[] := array[
    'employee_dependants', 'employee_documents', 'employee_tax_reliefs',
    'employee_ytd_opening'];

  -- Talent: HR only. Applicant data is not company reading material.
  hr_private constant text[] := array[
    'job_requisitions', 'applicants', 'applicant_stage_history',
    'interviews'];

  -- Pay: the finance and HR tier only.
  payroll_private constant text[] := array[
    'salary_components', 'employee_salary_components', 'pay_periods',
    'payroll_runs', 'payroll_settings'];
begin
  foreach t in array (hr_reference || hr_personal || hr_private
                      || payroll_private
                      || array['employees', 'employee_shifts',
                               'attendance_records', 'leave_entitlement_bands',
                               'leave_balances', 'leave_requests',
                               'expense_claims', 'expense_claim_lines',
                               'payslips', 'payslip_lines', 'payroll_ytd',
                               'onboarding_checklists', 'onboarding_tasks',
                               'appraisals', 'appraisal_goals'])
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;

  -- Reference lists ---------------------------------------------------
  foreach t in array hr_reference loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (app.can_manage_hr(org_id))
         with check (app.can_manage_hr(org_id) and app.has_module(org_id, ''hr''))',
      t || '_write', t);
  end loop;

  -- Personal records --------------------------------------------------
  foreach t in array hr_personal loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.can_manage_hr(org_id)
                or employee_id = app.my_employee_id(org_id))',
      t || '_select', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (app.can_manage_hr(org_id))
         with check (app.can_manage_hr(org_id) and app.has_module(org_id, ''hr''))',
      t || '_write', t);
  end loop;

  -- Talent ------------------------------------------------------------
  foreach t in array hr_private loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.can_manage_hr(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (app.can_manage_hr(org_id))
         with check (app.can_manage_hr(org_id) and app.has_module(org_id, ''hr''))',
      t || '_write', t);
  end loop;

  -- Payroll configuration and runs ------------------------------------
  foreach t in array payroll_private loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.can_run_payroll(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (app.can_run_payroll(org_id))
         with check (app.can_run_payroll(org_id) and app.has_module(org_id, ''payroll''))',
      t || '_write', t);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------
-- The employee record itself
--
-- Salary sits on this row, so it is not company reading material. HR see
-- everyone, a manager sees their own reporting line, and everybody sees
-- themselves. A directory view below carries the harmless columns for
-- the rest of the company.
-- ---------------------------------------------------------------------
create policy employees_select on public.employees
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or app.can_run_payroll(org_id)
         or user_id = auth.uid()
         or app.manages_employee(id));

create policy employees_write on public.employees
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy employee_shifts_select on public.employee_shifts
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy employee_shifts_write on public.employee_shifts
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy leave_entitlement_bands_select on public.leave_entitlement_bands
  for select to authenticated using (
    exists (select 1 from public.leave_types lt
             where lt.id = leave_type_id and app.is_org_member(lt.org_id)));
create policy leave_entitlement_bands_write on public.leave_entitlement_bands
  for all to authenticated using (
    exists (select 1 from public.leave_types lt
             where lt.id = leave_type_id and app.can_manage_hr(lt.org_id)))
  with check (
    exists (select 1 from public.leave_types lt
             where lt.id = leave_type_id and app.can_manage_hr(lt.org_id)));

-- Attendance, leave and claims: mine, my team's, or all of them if HR.
create policy attendance_records_select on public.attendance_records
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy attendance_records_write on public.attendance_records
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy leave_balances_select on public.leave_balances
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy leave_balances_write on public.leave_balances
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy leave_requests_select on public.leave_requests
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy leave_requests_insert on public.leave_requests
  for insert to authenticated
  with check (app.has_module(org_id, 'hr')
              and (app.can_manage_hr(org_id)
                   or employee_id = app.my_employee_id(org_id)));
-- A submitted request is out of the employee's hands; only HR or the
-- manager can change it after that, and they do it through the RPC.
create policy leave_requests_update on public.leave_requests
  for update to authenticated
  using (app.can_manage_hr(org_id)
         or app.manages_employee(employee_id)
         or (employee_id = app.my_employee_id(org_id) and status = 'draft'))
  with check (app.has_module(org_id, 'hr'));
create policy leave_requests_delete on public.leave_requests
  for delete to authenticated
  using (app.can_manage_hr(org_id)
         or (employee_id = app.my_employee_id(org_id) and status = 'draft'));

create policy expense_claims_select on public.expense_claims
  for select to authenticated
  using (app.can_manage_hr(org_id) or app.can_post(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy expense_claims_insert on public.expense_claims
  for insert to authenticated
  with check (app.has_module(org_id, 'hr')
              and (app.can_manage_hr(org_id)
                   or employee_id = app.my_employee_id(org_id)));
create policy expense_claims_update on public.expense_claims
  for update to authenticated
  using (app.can_manage_hr(org_id) or app.can_post(org_id)
         or app.manages_employee(employee_id)
         or (employee_id = app.my_employee_id(org_id) and status = 'draft'))
  with check (app.has_module(org_id, 'hr'));
create policy expense_claims_delete on public.expense_claims
  for delete to authenticated
  using (app.can_manage_hr(org_id)
         or (employee_id = app.my_employee_id(org_id) and status = 'draft'));

create policy expense_claim_lines_all on public.expense_claim_lines
  for all to authenticated
  using (exists (select 1 from public.expense_claims c
                  where c.id = claim_id
                    and (app.can_manage_hr(c.org_id) or app.can_post(c.org_id)
                         or c.employee_id = app.my_employee_id(c.org_id))))
  with check (exists (select 1 from public.expense_claims c
                       where c.id = claim_id
                         and app.has_module(c.org_id, 'hr')
                         and (app.can_manage_hr(c.org_id)
                              or c.employee_id = app.my_employee_id(c.org_id))));

-- Payslips: mine, or everyone's if payroll is your job. A manager does
-- not get to see what their reports are paid.
create policy payslips_select on public.payslips
  for select to authenticated
  using (app.can_run_payroll(org_id)
         or employee_id = app.my_employee_id(org_id));
create policy payslips_write on public.payslips
  for all to authenticated
  using (app.can_run_payroll(org_id))
  with check (app.can_run_payroll(org_id) and app.has_module(org_id, 'payroll'));

create policy payslip_lines_select on public.payslip_lines
  for select to authenticated
  using (exists (select 1 from public.payslips p
                  where p.id = payslip_id
                    and (app.can_run_payroll(p.org_id)
                         or p.employee_id = app.my_employee_id(p.org_id))));
create policy payslip_lines_write on public.payslip_lines
  for all to authenticated
  using (app.can_run_payroll(org_id))
  with check (app.can_run_payroll(org_id) and app.has_module(org_id, 'payroll'));

create policy payroll_ytd_select on public.payroll_ytd
  for select to authenticated
  using (app.can_run_payroll(org_id)
         or employee_id = app.my_employee_id(org_id));
create policy payroll_ytd_write on public.payroll_ytd
  for all to authenticated
  using (app.can_run_payroll(org_id))
  with check (app.can_run_payroll(org_id) and app.has_module(org_id, 'payroll'));

-- Onboarding: HR, the new joiner, and whoever owns a task.
create policy onboarding_checklists_select on public.onboarding_checklists
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy onboarding_checklists_write on public.onboarding_checklists
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy onboarding_tasks_select on public.onboarding_tasks
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or owner_employee_id = app.my_employee_id(org_id)
         or exists (select 1 from public.onboarding_checklists c
                     where c.id = checklist_id
                       and c.employee_id = app.my_employee_id(org_id)));
create policy onboarding_tasks_update on public.onboarding_tasks
  for update to authenticated
  using (app.can_manage_hr(org_id)
         or owner_employee_id = app.my_employee_id(org_id))
  with check (app.has_module(org_id, 'hr'));
create policy onboarding_tasks_write on public.onboarding_tasks
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

-- Appraisals: mine, my reports', or all of them if HR.
create policy appraisals_select on public.appraisals
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or reviewer_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));
create policy appraisals_update on public.appraisals
  for update to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or reviewer_id = app.my_employee_id(org_id))
  with check (app.has_module(org_id, 'hr'));
create policy appraisals_write on public.appraisals
  for all to authenticated
  using (app.can_manage_hr(org_id))
  with check (app.can_manage_hr(org_id) and app.has_module(org_id, 'hr'));

create policy appraisal_goals_all on public.appraisal_goals
  for all to authenticated
  using (exists (select 1 from public.appraisals a
                  where a.id = appraisal_id
                    and (app.can_manage_hr(a.org_id)
                         or a.employee_id = app.my_employee_id(a.org_id)
                         or a.reviewer_id = app.my_employee_id(a.org_id))))
  with check (exists (select 1 from public.appraisals a
                       where a.id = appraisal_id
                         and app.has_module(a.org_id, 'hr')
                         and (app.can_manage_hr(a.org_id)
                              or a.employee_id = app.my_employee_id(a.org_id)
                              or a.reviewer_id = app.my_employee_id(a.org_id))));

-- ---------------------------------------------------------------------
-- Statutory schedules are shared reference data: readable by everyone
-- signed in, writable only by the service role, so a tenant cannot
-- quietly change the EPF rate it contributes at.
-- ---------------------------------------------------------------------
alter table public.statutory_schedules enable row level security;
alter table public.statutory_rates enable row level security;
alter table public.tax_brackets enable row level security;
alter table public.tax_reliefs enable row level security;

create policy statutory_schedules_read on public.statutory_schedules
  for select to authenticated using (true);
create policy statutory_rates_read on public.statutory_rates
  for select to authenticated using (true);
create policy tax_brackets_read on public.tax_brackets
  for select to authenticated using (true);
create policy tax_reliefs_read on public.tax_reliefs
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- Directory: the columns colleagues may see about each other. A view
-- with security_invoker off would leak; this one relies on its own
-- policy-free base being filtered by what it selects, so it is defined
-- as a security definer view over safe columns only.
-- ---------------------------------------------------------------------
create or replace view public.v_employee_directory
with (security_invoker = off) as
select e.id, e.org_id, e.employee_no, e.full_name, e.preferred_name,
       e.email, e.phone, e.photo_url, e.employment_status,
       e.department_id, d.name as department_name,
       e.position_id, p.title as position_title,
       e.manager_id, e.hire_date
  from public.employees e
  left join public.departments d on d.id = e.department_id
  left join public.positions p on p.id = e.position_id
 where app.is_org_member(e.org_id);

comment on view public.v_employee_directory is
  'Who works here: name, department, role and contact. Deliberately excludes salary, identifiers and everything else on the employee row.';

grant select on public.v_employee_directory to authenticated;

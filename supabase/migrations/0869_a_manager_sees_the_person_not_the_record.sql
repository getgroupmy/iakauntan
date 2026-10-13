-- =====================================================================
-- iAkauntan :: 0869 a manager sees the person, not the record
--
-- `0038` let three people read an employee's row -- HR (and payroll),
-- the employee, and "a manager ... their own reporting line" -- on the
-- understanding that "salary sits on this row, so it is not company
-- reading material" and that "a directory view below carries the
-- harmless columns for the rest of the company". `0044` dropped the
-- view. The manager kept the row, and the row is everything: salary,
-- NRIC and passport, date of birth, home address, the bank account,
-- EPF, SOCSO and tax numbers, zakat and CP38, marital and disability
-- status, the emergency contact, the notes.
--
-- Measured on 13 October 2026, locally, as a `sales` member who is an
-- employee's manager -- neither HR nor payroll -- with the role
-- `authenticated`: Aminah's salary of 3,800.00, her NRIC, her Maybank
-- account number, her home address and her date of birth.
--
-- Production held 4 employees and none with a manager on 13 October.
--
-- Answered "managers see the person, not the record", as `0856` did for
-- an account's balance and `0863` for a pay band:
--
--   * `authenticated` reads the columns that say who somebody is and
--     where they sit -- name, number, contact, department, position,
--     manager, employment type and status, and the dates of joining and
--     leaving -- and no other. Which rows stays the policy's business,
--     unchanged: a manager still sees their reporting line, so every
--     approval screen still names the person asking.
--   * `employee_private_fields(org, employee)`, a definer, gives every
--     other column back, as one object per employee, to HR, to payroll
--     and to the employee themselves, past the same HR module gate the
--     table has. `can_run_payroll` is the one test for the first two: it
--     admits the owner, an admin and the HR manager as `can_manage_hr`
--     does, and the accountant besides. It is written as "everything but the public columns",
--     so a column added to `employees` later is private until somebody
--     says otherwise -- on both sides of the line.
--
-- Writes are untouched: `employees_write` asks `can_manage_hr`, and
-- neither an update nor an insert is a select.
-- =====================================================================

revoke select on public.employees from authenticated;
grant select (id, org_id, employee_no, user_id, full_name, preferred_name,
              email, phone, photo_url, department_id, position_id,
              manager_id, branch_id, employment_type, employment_status,
              hire_date, confirmation_date, resignation_date,
              last_working_date, created_by, created_at, updated_at,
              import_source, import_ref, import_batch_id, imported_at)
  on public.employees to authenticated;

create or replace function public.employee_private_fields(
  p_org_id uuid, p_employee_id uuid default null)
returns table (employee_id uuid, fields jsonb)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select e.id,
         to_jsonb(e) - array[
           'id', 'org_id', 'employee_no', 'user_id', 'full_name',
           'preferred_name', 'email', 'phone', 'photo_url',
           'department_id', 'position_id', 'manager_id', 'branch_id',
           'employment_type', 'employment_status', 'hire_date',
           'confirmation_date', 'resignation_date', 'last_working_date',
           'created_by', 'created_at', 'updated_at', 'import_source',
           'import_ref', 'import_batch_id', 'imported_at']
    from public.employees e
   where e.org_id = p_org_id
     and (p_employee_id is null or e.id = p_employee_id)
     and app.can_read_module(p_org_id, 'hr')
     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid())
   order by e.employee_no;
$$;

revoke all on function public.employee_private_fields(uuid, uuid)
  from public, anon;
grant execute on function public.employee_private_fields(uuid, uuid)
  to authenticated, service_role;

comment on function public.employee_private_fields(uuid, uuid) is
  'Every column of an employee''s record that authenticated cannot '
  'select -- pay, identity, bank, family, statutory numbers -- for HR, '
  'payroll and the employee themselves; nothing for a manager or '
  'anybody else.';

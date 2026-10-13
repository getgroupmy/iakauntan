# Mutants for 0869 -- a manager sees the person, not the record: the
# private columns of an employee come back only to HR, payroll and the
# employee themselves.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0869_a_manager_sees_the_person_not_the_record.sql \
#       supabase/tests/employee_record_withheld.sql \
#       supabase/tests/mutants/employee_record.py
#
# The column grant is not a function, so this cannot break it; it was
# swept by hand -- the whole table granted back, and `basic_salary`
# added to the list -- and each was caught.

m('payroll is not let in',
  'employee_private_fields',
  '     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid())\n',
  '     and (app.can_manage_hr(p_org_id) or e.user_id = auth.uid())  -- hr only\n',
  '-- hr only')

m('a manager is let in',
  'employee_private_fields',
  '     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid())\n',
  '     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid()\n'
  '          or app.manages_employee(e.id))  -- managers\n',
  '-- managers')

m('the employee is not let in',
  'employee_private_fields',
  '     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid())\n',
  '     and app.can_run_payroll(p_org_id)  -- no self\n',
  '-- no self')

m('every member is let in',
  'employee_private_fields',
  '     and (app.can_run_payroll(p_org_id) or e.user_id = auth.uid())\n',
  '     and true  -- anybody\n',
  '-- anybody')

m('another company is read',
  'employee_private_fields',
  '   where e.org_id = p_org_id\n',
  '   where true  -- any company\n',
  '-- any company')

m('the employee asked for is not the one given',
  'employee_private_fields',
  '     and (p_employee_id is null or e.id = p_employee_id)\n',
  '     and true  -- any employee\n',
  '-- any employee')

m('HR switched off is not asked',
  'employee_private_fields',
  "     and app.can_read_module(p_org_id, 'hr')\n",
  '     and true  -- no gate\n',
  '-- no gate')

m('a column anybody reads comes back as well',
  'employee_private_fields',
  "           'id', 'org_id', 'employee_no', 'user_id', 'full_name',\n",
  "           'id', 'org_id', 'employee_no', 'user_id',  -- full_name kept\n",
  '-- full_name kept')

m('CONTROL',
  'employee_private_fields',
  '   order by e.employee_no;\n',
  '   order by e.employee_no;  -- control\n',
  '-- control')

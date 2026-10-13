# Mutants for 0871 -- an employee with no access type is self-service:
# write in hr, read in payroll, none elsewhere.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0871_an_employee_is_self_service.sql \
#       supabase/tests/employee_self_service.sql \
#       supabase/tests/mutants/employee_self_service.py

m('an employee is anybody else',
  'module_access',
  "    if v_role = 'employee' then\n",
  "    if false then  -- no employee\n",
  '-- no employee')

m('a View Only member is confined as well',
  'module_access',
  "    if v_role = 'employee' then\n",
  "    if v_role in ('employee', 'viewer') then  -- viewers too\n",
  '-- viewers too')

m('she reads HR and cannot file in it',
  'module_access',
  "               when 'hr'      then 'write'\n",
  "               when 'hr'      then 'read'  -- hr read\n",
  '-- hr read')

m('she cannot read her payslips',
  'module_access',
  "               when 'payroll' then 'read'\n",
  "               when 'payroll' then 'none'  -- no payroll\n",
  '-- no payroll')

m('she may run payroll',
  'module_access',
  "               when 'payroll' then 'read'\n",
  "               when 'payroll' then 'write'  -- payroll write\n",
  '-- payroll write')

m('every other module is hers to read',
  'module_access',
  "               else 'none'\n",
  "               else 'read'  -- reads the rest\n",
  '-- reads the rest')

m('an access type does not widen her',
  'module_access',
  "  if v_type is null then\n",
  "  if v_type is null or v_role = 'employee' then  -- type ignored\n",
  '-- type ignored')

m('she is let into a module the company does not hold',
  'module_access',
  "  if p_org_id is null or auth.uid() is null then return 'none'; end if;\n",
  "  if p_org_id is null or auth.uid() is null then return 'none'; end if;\n"
  "  if p_module in ('hr', 'payroll') and exists (select 1 from public.org_members m\n"
  "      where m.org_id = p_org_id and m.user_id = auth.uid() and m.role = 'employee'\n"
  "        and m.access_type_id is null)\n"
  "  then return case p_module when 'hr' then 'write' else 'read' end; end if;  -- before the holding\n",
  '-- before the holding')

m('CONTROL',
  'module_access',
  "  return coalesce(v_access, 'none');\n",
  "  return coalesce(v_access, 'none');  -- control\n",
  '-- control')

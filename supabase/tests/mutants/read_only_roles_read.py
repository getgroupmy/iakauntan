# Mutants for 0882 -- with no access type, a View Only member and an
# auditor are answered `read` on every module, the HR Manager `write` on
# hr and payroll and `read` on the rest.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0882_read_only_roles_read.sql \
#       supabase/tests/read_only_roles_read.sql \
#       supabase/tests/mutants/read_only_roles_read.py

m('a View Only member writes again',
  'module_access',
  "    if v_role in ('viewer', 'auditor') then\n",
  "    if v_role in ('auditor') then  -- viewer writes\n",
  '-- viewer writes')

m('an auditor writes again',
  'module_access',
  "    if v_role in ('viewer', 'auditor') then\n",
  "    if v_role in ('viewer') then  -- auditor writes\n",
  '-- auditor writes')

m('read-only roles read nothing at all',
  'module_access',
  "    if v_role in ('viewer', 'auditor') then\n      return 'read';\n",
  "    if v_role in ('viewer', 'auditor') then\n      return 'none';  -- nothing at all\n",
  '-- nothing at all')

m('the HR Manager writes everywhere',
  'module_access',
  "      return case when p_module in ('hr', 'payroll') then 'write'\n",
  "      return case when true then 'write'  -- hr writes all\n",
  '-- hr writes all')

m('the HR Manager reads payroll',
  'module_access',
  "      return case when p_module in ('hr', 'payroll') then 'write'\n",
  "      return case when p_module in ('hr') then 'write'  -- payroll read\n",
  '-- payroll read')

m('the HR Manager reads HR',
  'module_access',
  "      return case when p_module in ('hr', 'payroll') then 'write'\n",
  "      return case when false then 'write'  -- hr reads hr\n",
  '-- hr reads hr')

m('CONTROL: a comment inside the branch',
  'module_access',
  "    if v_role in ('viewer', 'auditor') then\n",
  "    if v_role in ('viewer', 'auditor') then  -- control\n",
  '-- control')

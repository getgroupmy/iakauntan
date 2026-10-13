# Mutants for 0872 -- the company's records are refused to a member
# whose only standing is an employee with no access type.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0872_an_employee_reads_her_own.sql \
#       supabase/tests/employee_reads_her_own.sql \
#       supabase/tests/mutants/employee_reads_her_own.py
#
# The policies are not functions, so this cannot break them; the one
# with a clause of its own -- her own row on `org_members` -- was swept
# by hand, and the last block of the test refuses a table that lost its
# policy.

m('nobody is self-service',
  'is_self_service_only',
  "  select exists (\n",
  "  select false and exists (  -- nobody\n",
  '-- nobody')

m('a View Only member is held to it instead',
  'is_self_service_only',
  "       and m.role = 'employee'\n",
  "       and m.role = 'viewer'  -- viewers\n",
  '-- viewers')

m('a View Only member is held to it as well',
  'is_self_service_only',
  "       and m.role = 'employee'\n",
  "       and m.role in ('employee', 'viewer')  -- both\n",
  '-- both')

m('an access type does not widen her',
  'is_self_service_only',
  "       and m.access_type_id is null);\n",
  "       and true);  -- type ignored\n",
  '-- type ignored')

m('an employee here is one everywhere',
  'is_self_service_only',
  "     where m.org_id = p_org_id\n",
  "     where true  -- any company\n",
  '-- any company')

m('one employee in the company holds everybody to it',
  'is_self_service_only',
  "       and m.user_id = auth.uid()\n",
  "       and true  -- anybody\n",
  '-- anybody')

m('CONTROL',
  'is_self_service_only',
  "       and m.access_type_id is null);\n",
  "       and m.access_type_id is null);  -- control\n",
  '-- control')

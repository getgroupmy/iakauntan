# Mutants for 0873 -- a definer that answers the company's records asks
# `app.is_staff_member`, which a self-service-only employee is not.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0873_the_companys_reports_are_its_staffs.sql \
#       supabase/tests/employee_definers.sql \
#       supabase/tests/mutants/employee_definers.py
#
# The 38 re-created functions differ from what was live only in the
# name of the check; one put back as it was is caught by the test's
# last block, which was swept by hand.

m('an employee is staff',
  'is_staff_member',
  "  select app.is_org_member(p_org_id)\n     and not app.is_self_service_only(p_org_id);\n",
  "  select app.is_org_member(p_org_id);  -- members\n",
  '-- members')

m('nobody is staff',
  'is_staff_member',
  "  select app.is_org_member(p_org_id)\n     and not app.is_self_service_only(p_org_id);\n",
  "  select false and app.is_org_member(p_org_id);  -- nobody\n",
  '-- nobody')

m('anybody is staff',
  'is_staff_member',
  "  select app.is_org_member(p_org_id)\n     and not app.is_self_service_only(p_org_id);\n",
  "  select not app.is_self_service_only(p_org_id);  -- strangers\n",
  '-- strangers')

m('CONTROL',
  'is_staff_member',
  "     and not app.is_self_service_only(p_org_id);\n",
  "     and not app.is_self_service_only(p_org_id);  -- control\n",
  '-- control')

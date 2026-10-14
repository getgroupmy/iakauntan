# Mutants for app.a_company_is_billed_as_the_platform_says() (0826) -- a
# company may not set its own status, demonstration mark or accounting
# firm, on an update or when it is made; the settings screen's
# own columns stay its own and the owner at the top is let through.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0826_a_company_is_billed_as_the_platform_says.sql \
#       supabase/tests/company_billing_columns.sql \
#       supabase/tests/mutants/a_company_is_billed_as_the_platform_says.py
#
# RESULT: 12 of 13 mutants killed by `company_billing_columns.sql`, the
# control surviving. The survivor, `a nested statement is a client's
# too`, is equivalent -- every writer of these columns is a definer --
# and the file says so. `firm_member_role` was first asked with 'owner',
# which `firm_role_is_not_owner` refuses anyway, so its mutant died for
# the wrong reason; the file asks with 'admin' now, which only the guard
# refuses.
#
# Since `0879` the four insert mutants survive, and are equivalent: no
# client holds insert on `organizations`, so no client statement reaches
# the insert branch, and every company is made by a definer, which the
# guard lets through. The file asks for the privilege's refusal now.
# Re-run on 14 October after `0879`: 8 of 13 killed, the control
# surviving; the five survivors are the four insert mutants and the
# nested statement, all equivalent.

m('the guard is never asked',
  'a_company_is_billed_as_the_platform_says',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'a_company_is_billed_as_the_platform_says',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'a_company_is_billed_as_the_platform_says',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m("a new company's status is not asked",
  'a_company_is_billed_as_the_platform_says',
  "    if new.status is distinct from 'active'\n",
  '    if false  -- insert status unasked\n',
  'insert status unasked')

m("a new company's demonstration mark is not asked",
  'a_company_is_billed_as_the_platform_says',
  '       or new.is_demo\n',
  '       or false  -- insert demo unasked\n',
  'insert demo unasked')

m("a new company's firm is not asked",
  'a_company_is_billed_as_the_platform_says',
  '       or new.firm_id is not null\n',
  '       or false  -- insert firm unasked\n',
  'insert firm unasked')

m("a new company's firm role is not asked",
  'a_company_is_billed_as_the_platform_says',
  "       or new.firm_member_role is distinct from 'accountant' then",
  '       or false then  -- insert role unasked',
  'insert role unasked')

m('an update is not asked',
  'a_company_is_billed_as_the_platform_says',
  '  foreach v_col in array c_platform loop',
  '  foreach v_col in array array[]::text[] loop  -- nothing asked',
  '-- nothing asked')

m('status is not asked on an update',
  'a_company_is_billed_as_the_platform_says',
  "'status',",
  "'website',",
  "'website'")

m('is_demo is not asked on an update',
  'a_company_is_billed_as_the_platform_says',
  "'is_demo',",
  "'website',",
  "'website'")

m('firm_id is not asked on an update',
  'a_company_is_billed_as_the_platform_says',
  "'firm_id',",
  "'website',",
  "'website'")

m('firm_member_role is not asked on an update',
  'a_company_is_billed_as_the_platform_says',
  "'firm_member_role']",
  "'website']",
  "'website'")

m('the refusal is a different kind',
  'a_company_is_billed_as_the_platform_says',
  "        v_col, old.name\n        using errcode = '42501';",
  "        v_col, old.name\n        using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'a_company_is_billed_as_the_platform_says',
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  '(control)')

# Mutants for 0919 -- a payroll_settings account fits the line payroll
# posts to it, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0919_a_payroll_account_fits_its_line.sql \
#       supabase/tests/a_payroll_account_fits_its_line.sql \
#       supabase/tests/mutants/a_payroll_account_fits_its_line.py

F = 'a_payroll_account_fits_its_line'

m('only the app is asked',
  F,
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n",
  '-- app only')

m('settings first written are not asked',
  F,
  "    continue when v_id is null;\n",
  "    continue when v_id is null;\n"
  "    continue when tg_op = 'INSERT';  -- insert is free\n",
  '-- insert is free')

m('settings already written are never asked again',
  F,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    continue when tg_op = 'UPDATE';  -- update is free\n",
  '-- update is free')

m('every write is asked, not only an account set or changed',
  F,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    -- every write\n",
  '-- every write')

m('a heading passes',
  F,
  "    if v_acct.is_group or not v_acct.is_active\n",
  "    if false /* heading */ or not v_acct.is_active\n",
  '/* heading */')

m('a retired account passes',
  F,
  "    if v_acct.is_group or not v_acct.is_active\n",
  "    if v_acct.is_group or false /* retired */\n",
  '/* retired */')

m('the kind of account is not asked',
  F,
  "       or v_acct.account_type::text is distinct from v_kind then\n",
  "       or false /* any kind */ then\n",
  '/* any kind */')

m("another company's account is looked up and described",
  F,
  "     where a.id = v_id and a.org_id = new.org_id;\n",
  "     where a.id = v_id;  -- any company\n",
  '-- any company')

m('an account that is not found is refused here, not by the key',
  F,
  "    continue when v_acct.id is null;\n",
  "    -- not found falls through\n",
  '-- not found falls through')

m('every kind is "a", never "an"',
  F,
  "        when left(v_acct.account_type::text, 1) in ('a', 'e', 'i', 'o', 'u')\n",
  "        when false /* no an */\n",
  '/* no an */')

# Each line asked for the other half's kind: an expense line that takes
# a liability account, a payable line that takes an expense account.
for col, kind, other, pad in [
    ('salary_expense_account_id', 'expense', 'liability', ' '),
    ('epf_expense_account_id', 'expense', 'liability', '    '),
    ('socso_expense_account_id', 'expense', 'liability', '  '),
    ('eis_expense_account_id', 'expense', 'liability', '    '),
    ('hrdf_expense_account_id', 'expense', 'liability', '   '),
    ('salary_payable_account_id', 'liability', 'expense', ' '),
    ('epf_payable_account_id', 'liability', 'expense', '    '),
    ('socso_payable_account_id', 'liability', 'expense', '  '),
    ('eis_payable_account_id', 'liability', 'expense', '    '),
    ('pcb_payable_account_id', 'liability', 'expense', '    '),
    ('zakat_payable_account_id', 'liability', 'expense', '  '),
]:
    old = "    ['%s',%s'%s'," % (col, pad, kind)
    new = "    ['%s',%s'%s' /* %s swapped */," % (col, pad, other, col)
    m('%s asks for %s' % (col, other), F, old, new, '/* %s swapped */' % col)

m('the EPF payable is called the SOCSO payable',
  F,
  "'liability', 'The EPF payable'],\n",
  "'liability', 'The SOCSO payable' /* misnamed */],\n",
  '/* misnamed */')

m('CONTROL: a comment inside the function',
  F,
  "  -- column, the kind of account its line posts to, what the line is.\n",
  "  -- column, the kind of account its line posts to, what the line is. (control)\n",
  '(control)')

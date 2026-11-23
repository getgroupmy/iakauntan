# Mutants for 0923 -- nothing new names an account that is already
# closed, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0923_a_closed_account_takes_no_new_name.sql \
#       supabase/tests/a_closed_account_takes_no_new_name.sql \
#       supabase/tests/mutants/a_closed_account_takes_no_new_name.py

C = 'a_closed_account_takes_no_new_name'
R = 'a_recurring_template_names_no_closed_account'

# --- a column that names an account -----------------------------------
m('column: only the app is asked',
  C,
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  '-- app only')

m('column: a new row is not asked',
  C,
  "    continue when v_id is null;\n",
  "    continue when v_id is null;\n    continue when tg_op = 'INSERT';  -- insert is free\n",
  '-- insert is free')

m('column: a row already there is never asked',
  C,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    continue when tg_op = 'UPDATE';  -- update is free\n",
  '-- update is free')

m('column: every write is asked, not only an account set or changed',
  C,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    -- every write\n",
  '-- every write')

m("column: another company's account is looked up and described",
  C,
  "     where a.id = v_id and a.org_id = new.org_id;\n",
  "     where a.id = v_id;  -- any company\n",
  '-- any company')

m('column: an account that is not found is refused here, not by the key',
  C,
  "    continue when v_acct.id is null;\n",
  "    -- not found falls through\n",
  '-- not found falls through')

m('column: an account switched off and never closed by date passes',
  C,
  "    continue when v_acct.deleted_at is null and v_acct.is_active;\n",
  "    continue when v_acct.deleted_at is null;  -- dormant passes\n",
  '-- dormant passes')

m('column: a closed account passes',
  C,
  "    continue when v_acct.deleted_at is null and v_acct.is_active;\n",
  "    continue when true;  -- closed passes\n",
  '-- closed passes')

m('column: a carried line is asked like any other',
  C,
  "      continue when v_parent is not distinct from v_id;\n",
  "      -- carried is asked\n",
  '-- carried is asked')

m('column: a line citing a source names whatever it likes',
  C,
  "      continue when v_parent is not distinct from v_id;\n",
  "      continue when true;  -- any carried\n",
  '-- any carried')

m('column: the refusal is a permission error, not a rule',
  C,
  "      v_label, v_acct.code, v_acct.name\n      using errcode = '23514';\n",
  "      v_label, v_acct.code, v_acct.name\n      using errcode = '42501';  -- permission\n",
  '-- permission')

m('CONTROL: column, a comment inside the function',
  C,
  "  -- Each argument is `column:what it is called`.\n",
  "  -- Each argument is `column:what it is called`. (control)\n",
  '(control)')

# --- a template --------------------------------------------------------
m('template: only the app is asked',
  R,
  "  if tg_op = 'UPDATE' then\n    v_all := new.is_active and not old.is_active;\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if tg_op = 'UPDATE' then\n    v_all := new.is_active and not old.is_active;\n",
  '-- app only')

m('template: a new one is not asked',
  R,
  "  if tg_op = 'UPDATE' then\n    v_all := new.is_active and not old.is_active;\n",
  "  if tg_op = 'INSERT' then return new; end if;  -- insert is free\n"
  "  if tg_op = 'UPDATE' then\n    v_all := new.is_active and not old.is_active;\n",
  '-- insert is free')

m('template: one rewritten is not asked, only one switched on',
  R,
  "    if not v_all and new.template is not distinct from old.template then\n",
  "    if not v_all then  -- rewrite is free\n",
  '-- rewrite is free')

m('template: one switched back on is not asked',
  R,
  "    v_all := new.is_active and not old.is_active;\n",
  "    v_all := false;  -- switching on is free\n",
  '-- switching on is free')

m('template: one rewritten is asked for every account, named before or not',
  R,
  "    if not v_all and jsonb_typeof(old.template -> 'lines') = 'array' then\n"
  "      v_before := old.template -> 'lines';\n",
  "    if false and jsonb_typeof(old.template -> 'lines') = 'array' then  -- nothing before\n"
  "      v_before := old.template -> 'lines';\n",
  '-- nothing before')

m("template: another company's account is looked up and described",
  R,
  "      on a.id::text = l ->> 'account_id' and a.org_id = new.org_id\n",
  "      on a.id::text = l ->> 'account_id'  -- any company\n",
  '-- any company')

m('template: an account switched off and never closed by date passes',
  R,
  "   where (a.deleted_at is not null or not a.is_active)\n",
  "   where (a.deleted_at is not null)  -- dormant passes\n",
  '-- dormant passes')

m('template: a closed account passes',
  R,
  "   where (a.deleted_at is not null or not a.is_active)\n",
  "   where (false)  -- closed passes\n",
  '-- closed passes')

m('template: the refusal is a permission error, not a rule',
  R,
  "      v_what, v_acct.code, v_acct.name\n      using errcode = '23514';\n",
  "      v_what, v_acct.code, v_acct.name\n      using errcode = '42501';  -- permission\n",
  '-- permission')

m('CONTROL: template, a comment inside the function',
  R,
  "  -- Asked when the template changes, for the accounts it did not name\n",
  "  -- Asked when the template changes, for the accounts it did not name (control)\n",
  '(control)')

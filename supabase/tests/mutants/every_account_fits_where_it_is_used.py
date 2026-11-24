# Mutants for 0926 -- the account a posting takes the other side from is
# not the stock it posts, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0926_every_account_fits_where_it_is_used.sql \
#       supabase/tests/every_account_fits_where_it_is_used.sql \
#       supabase/tests/mutants/every_account_fits_where_it_is_used.py
#
# The ten attachments of `0912`'s function and the one of `0923`'s are
# triggers, which this harness does not mutate; each is dropped in turn
# by the sweep recorded in the handoff for 0926.

S = 'the_stock_is_not_its_own_other_side'

m('only the app is asked',
  S,
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  '-- app only')

m('a new row is not asked',
  S,
  "    continue when v_id is null;\n",
  "    continue when v_id is null;\n    continue when tg_op = 'INSERT';  -- insert is free\n",
  '-- insert is free')

m('a row already there is never asked',
  S,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    continue when tg_op = 'UPDATE';  -- update is free\n",
  '-- update is free')

m('every write is asked, not only an account set or changed',
  S,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    -- every write\n",
  '-- every write')

m("another company's 1310 is looked up and described",
  S,
  "     where a.id = v_id and a.org_id = new.org_id\n",
  "     where a.id = v_id  -- any company\n",
  '-- any company')

m('any account at all is the stock',
  S,
  "       and a.code = '1310' and not a.is_group;\n",
  "       and not a.is_group;  -- any code\n",
  '-- any code')

m('the stock is never recognised',
  S,
  "       and a.code = '1310' and not a.is_group;\n",
  "       and a.code = '1311' and not a.is_group;  -- wrong code\n",
  '-- wrong code')

m('the refusal is a permission error, not a rule',
  S,
  "      v_label, v_acct.code, v_acct.name\n      using errcode = '23514';\n",
  "      v_label, v_acct.code, v_acct.name\n      using errcode = '42501';  -- permission\n",
  '-- permission')

m('the refusal names the wrong account',
  S,
  "      v_label, v_acct.code, v_acct.name\n",
  "      v_label, v_acct.code, v_acct.code  -- code twice\n",
  '-- code twice')

m('the refusal says what it is about, but not where',
  S,
  "    v_label := split_part(v_arg, ':', 2);\n",
  "    v_label := 'An account';  -- no label\n",
  '-- no label')

m('CONTROL: a comment inside the function',
  S,
  "  -- Each argument is `column:what it is called`.\n",
  "  -- Each argument is `column:what it is called`. (control)\n",
  '(control)')

# Mutants for 0844 -- app.accounts_opening_balance_is_not_writable, the
# two refusals 0844 adds for `current_balance`. The opening-balance
# branches are 0643's and are asked by `chart_of_accounts.sql`.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0844_an_accounts_balance_is_its_ledgers.sql \
#       supabase/tests/account_balance_is_the_ledgers.sql \
#       supabase/tests/mutants/an_accounts_balance_is_its_ledgers.py
#
# RESULT: 4 of 6 killed, the control surviving. The two survivors are
# the `pg_trigger_depth() = 1` clauses, and they are equivalent today:
# `app.apply_account_balance` is not a definer, but no road to
# `gl_lines` runs as a client -- clients hold no write on it, and every
# posting function is a definer. Said in the test beside the owner
# assertion.

m('nobody is asked',
  'accounts_opening_balance_is_not_writable',
  "  if current_user not in ('authenticated', 'anon') then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a balance may be typed',
  'accounts_opening_balance_is_not_writable',
  '  if new.current_balance is distinct from old.current_balance\n     and pg_trigger_depth() = 1 then',
  '  if false then  -- balances free',
  '-- balances free')

m('a balance typed one level down is a client too',
  'accounts_opening_balance_is_not_writable',
  '  if new.current_balance is distinct from old.current_balance\n     and pg_trigger_depth() = 1 then',
  '  if new.current_balance is distinct from old.current_balance then  -- any depth',
  '-- any depth')

m('an account may be made with a balance',
  'accounts_opening_balance_is_not_writable',
  '    if coalesce(new.current_balance, 0) <> 0\n       and pg_trigger_depth() = 1 then',
  '    if false then  -- born with one',
  '-- born with one')

m('every new account is refused',
  'accounts_opening_balance_is_not_writable',
  '    if coalesce(new.current_balance, 0) <> 0\n       and pg_trigger_depth() = 1 then',
  '    if pg_trigger_depth() = 1 then  -- none made',
  '-- none made')

m('an account made one level down is a client too',
  'accounts_opening_balance_is_not_writable',
  '    if coalesce(new.current_balance, 0) <> 0\n       and pg_trigger_depth() = 1 then',
  '    if coalesce(new.current_balance, 0) <> 0 then  -- any depth made',
  '-- any depth made')

m('CONTROL: a comment inside accounts_opening_balance_is_not_writable',
  'accounts_opening_balance_is_not_writable',
  '  return new;\nend;\n$function$;',
  '  return new;  -- (control)\nend;\n$function$;',
  '(control)')

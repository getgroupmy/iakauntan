# Mutants for 0856 -- public.account_balances serves an account's
# running balance to a reader app.can_read_ledger admits, now that the
# column itself is withheld from `authenticated`.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0856_an_accounts_balance_is_the_ledgers_to_show.sql \
#       supabase/tests/account_balance_withheld.sql \
#       supabase/tests/mutants/account_balances.py
#
# RESULT: 5 of 5 killed, the control surviving.
#
# The column grant is not a function and has no mutant here. Swept by
# hand: the table-wide select put back, "the salesman does not read an
# account's balance" fails.

m('any member is given the balances',
  'account_balances',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and app.is_org_member(p_org_id)  -- any member\n',
  '-- any member')

m('nobody is asked',
  'account_balances',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and true  -- nobody asked\n',
  '-- nobody asked')

m("every company's accounts",
  'account_balances',
  '   where a.org_id = p_org_id\n',
  '   where true  -- every company\n',
  '-- every company')

m('the retired accounts too',
  'account_balances',
  '     and a.deleted_at is null\n',
  '     and true  -- retired too\n',
  '-- retired too')

m('the opening balance served for the running one',
  'account_balances',
  '  select a.id, a.current_balance\n',
  '  select a.id, a.opening_balance  -- opening\n',
  '-- opening')

m('CONTROL: a comment inside account_balances',
  'account_balances',
  '   order by a.code;\n',
  '   order by a.code;  -- (control)\n',
  '(control)')

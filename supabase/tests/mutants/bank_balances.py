# Mutants for 0858 -- the bank's balance goes only to a reader the
# ledger's app.can_read_ledger admits: through bank_balances, on the
# dashboard, and as the cash forecast's opening figure.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0858_the_banks_balance_is_the_ledgers.sql \
#       supabase/tests/bank_balance_withheld.sql \
#       supabase/tests/mutants/bank_balances.py
#
# RESULT: 5 of 5 killed, the control surviving.
#
# The column grant is not a function and has no mutant here. Swept by
# hand: the table-wide select put back, "the salesman does not read the
# bank's balance off the table" fails.

m('any member is given the balances',
  'bank_balances',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and app.is_org_member(p_org_id)  -- any member\n',
  '-- any member')

m("every company's banks",
  'bank_balances',
  '   where b.org_id = p_org_id\n',
  '   where true  -- every company\n',
  '-- every company')

m('the dashboard gives anybody the bank',
  'dashboard_summary',
  "    'bank_balance', case when app.can_read_ledger(p_org_id) then (\n",
  "    'bank_balance', case when true then (  -- anybody\n",
  '-- anybody')

m('the dashboard gives nobody the bank',
  'dashboard_summary',
  "    'bank_balance', case when app.can_read_ledger(p_org_id) then (\n",
  "    'bank_balance', case when false then (  -- nobody\n",
  '-- nobody')

m('the forecast asks the module only',
  'report_cash_forecast',
  '  if not app.can_read_ledger(p_org) then\n',
  '  if false then  -- module only\n',
  '-- module only')

m('CONTROL: a comment inside bank_balances',
  'bank_balances',
  '   order by b.name;\n',
  '   order by b.name;  -- (control)\n',
  '(control)')

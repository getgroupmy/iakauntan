# Mutants for 0862 -- client money goes to a current member of the
# matter's company who reads the ledger, or who is that matter's fee
# earner; the balance and the summary's figure are blank to anybody
# else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0862_client_money_is_the_ledgers_and_the_fee_earners.sql \
#       supabase/tests/client_money_withheld.sql \
#       supabase/tests/mutants/client_money.py
#
# The select policy calls can_read_client_money and is swept through it.

m('a member who has been suspended is still told',
  'can_read_client_money',
  '       and app.is_org_member(m.org_id)\n',
  '       and true  -- suspended too\n',
  '-- suspended too')

m('the ledger roles are not told',
  'can_read_client_money',
  '       and (app.can_read_ledger(m.org_id) or m.fee_earner = auth.uid()));\n',
  '       and (false or m.fee_earner = auth.uid()));  -- no ledger\n',
  '-- no ledger')

m('the fee earner is not told',
  'can_read_client_money',
  '       and (app.can_read_ledger(m.org_id) or m.fee_earner = auth.uid()));\n',
  '       and (app.can_read_ledger(m.org_id) or false));  -- no earner\n',
  '-- no earner')

m('any member is a fee earner',
  'can_read_client_money',
  '       and (app.can_read_ledger(m.org_id) or m.fee_earner = auth.uid()));\n',
  '       and (app.can_read_ledger(m.org_id) or true));  -- anybody\n',
  '-- anybody')

m('the balance given to anybody',
  'matter_client_balance',
  '  select case when app.can_read_client_money(p_matter) then (\n',
  '  select case when true then (  -- balance to anybody\n',
  '-- balance to anybody')

m('the summary gives anybody the money held',
  'report_matter_summary',
  '         case when app.can_read_client_money(m.id) then\n',
  '         case when true then  -- funds to anybody\n',
  '-- funds to anybody')

m('the summary gives nobody the money held',
  'report_matter_summary',
  '         case when app.can_read_client_money(m.id) then\n',
  '         case when false then  -- funds to nobody\n',
  '-- funds to nobody')

m('CONTROL: a comment inside the rule',
  'can_read_client_money',
  '    select 1 from public.matters m\n',
  '    select 1 from public.matters m  -- (control)\n',
  '(control)')

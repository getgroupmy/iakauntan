# Mutants for 0860 -- the company's tax figures go only to a reader
# app.can_read_ledger admits: the schedule refuses anybody else, and the
# payment summary answers everybody with the money blank.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0860_the_companys_tax_is_the_ledgers.sql \
#       supabase/tests/tax_figures_withheld.sql \
#       supabase/tests/mutants/tax_figures.py
#
# The seven select policies are no function and have no mutant here;
# they were swept by hand, each put back to app.is_org_member in turn.

m('the schedule answers any member',
  'tax_estimate_schedule',
  '  if not app.can_read_ledger(v_org) then\n',
  '  if false then  -- any member\n',
  '-- any member')

m('the summary gives every member the money',
  'tax_estimate_payment_summary',
  '  v_ledger := app.can_read_ledger(e.org_id);\n',
  '  v_ledger := true;  -- every member\n',
  '-- every member')

m('the summary gives nobody the money',
  'tax_estimate_payment_summary',
  '  v_ledger := app.can_read_ledger(e.org_id);\n',
  '  v_ledger := false;  -- nobody\n',
  '-- nobody')

m('the summary refuses, and the dashboard tile with it',
  'tax_estimate_payment_summary',
  '  v_ledger := app.can_read_ledger(e.org_id);\n',
  "  if not app.can_read_ledger(e.org_id) then raise exception 'no' using errcode = '42501'; end if; v_ledger := true;  -- refuses\n",
  '-- refuses')

m('the summary reads the schedule that refuses',
  'tax_estimate_payment_summary',
  '  with s as (select * from app.tax_estimate_schedule_of(p_estimate_id))\n',
  '  with s as (select * from public.tax_estimate_schedule(p_estimate_id))  -- public\n',
  '-- public')

m('what the next instalment comes to is shown',
  'tax_estimate_payment_summary',
  '    case when v_ledger then (array_agg(s.outstanding order by s.due_on)\n',
  '    case when true then (array_agg(s.outstanding order by s.due_on)  -- next amount\n',
  '-- next amount')

m('what is overdue is shown',
  'tax_estimate_payment_summary',
  '    case when v_ledger then coalesce(sum(s.outstanding) filter (\n',
  '    case when true then coalesce(sum(s.outstanding) filter (  -- overdue sum\n',
  '-- overdue sum')

m('the late penalty is shown',
  'tax_estimate_payment_summary',
  '    case when v_ledger then\n',
  '    case when true then  -- penalty\n',
  '-- penalty')

m('what was paid is shown',
  'tax_estimate_payment_summary',
  '    case when v_ledger then coalesce(sum(s.paid_amount), 0) end,\n',
  '    case when true then coalesce(sum(s.paid_amount), 0) end,  -- paid\n',
  '-- paid')

m('CONTROL: the schedule read through an alias',
  'tax_estimate_schedule',
  '  return query select * from app.tax_estimate_schedule_of(p_estimate_id);\n',
  '  return query select q.* from app.tax_estimate_schedule_of(p_estimate_id) q;  -- (control)\n',
  '(control)')

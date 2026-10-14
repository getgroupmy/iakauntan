# Mutants for 0893 -- withholding tax is paid over no earlier than the
# certificate's date.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0893_the_tax_is_paid_over_after_it_was_withheld.sql \
#       supabase/tests/tax_paid_over_after_withheld.sql \
#       supabase/tests/mutants/tax_paid_over_after_withheld.py

m('paid over before it was withheld again',
  'remit_withholding',
  "  if p_paid_on < c.cert_date then\n",
  "  if false and p_paid_on < c.cert_date then  -- any day\n",
  '-- any day')

m('not on the day it was withheld either',
  'remit_withholding',
  "  if p_paid_on < c.cert_date then\n",
  "  if p_paid_on <= c.cert_date then  -- not that day\n",
  '-- not that day')

m('not before the remittance is due',
  'remit_withholding',
  "  if p_paid_on < c.cert_date then\n",
  "  if p_paid_on < c.due_date then  -- due date instead\n",
  '-- due date instead')

m("today's date is asked, not the remittance's",
  'remit_withholding',
  "  if p_paid_on < c.cert_date then\n",
  "  if app.today() < c.cert_date then  -- today instead\n",
  '-- today instead')

m('CONTROL: a comment inside the function',
  'remit_withholding',
  "  -- 0893: the tax is paid over no earlier than it was withheld. The\n",
  "  -- 0893: the tax is paid over no earlier than it was withheld. The\n  -- control\n",
  '-- control')

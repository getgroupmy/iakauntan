# Mutants for 0924 -- a credit note's line carries the account of the
# line it credits, unless that account has been closed since.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0924_a_credit_note_goes_back_where_the_sale_was_booked.sql \
#       supabase/tests/a_credit_note_goes_back_where_the_sale_was_booked.sql \
#       supabase/tests/mutants/a_credit_note_goes_back_where_the_sale_was_booked.py

S = 'credit_sales_invoice'
P = 'credit_purchase_bill'

CARRY = ("           (select a.id from public.accounts a\n"
         "             where a.id = l.account_id\n"
         "               and a.deleted_at is null and a.is_active)\n")

m("sales: the invoice line's account is not carried",
  S, CARRY,
  "           null::uuid  -- no account\n",
  '-- no account')

m('sales: an account closed since is carried all the same',
  S, CARRY,
  "           l.account_id  -- closed or not\n",
  '-- closed or not')

m('sales: an account only switched off is carried all the same',
  S,
  "               and a.deleted_at is null and a.is_active)\n",
  "               and a.deleted_at is null)  -- dormant carried\n",
  '-- dormant carried')

m('CONTROL: sales, a comment inside the function',
  S,
  "    -- 0924: with the account the invoice's line was booked to, so the\n",
  "    -- 0924: with the account the invoice's line was booked to, so the (control)\n",
  '(control)')

m("purchase: the bill line's account is not carried",
  P, CARRY,
  "           null::uuid  -- no account\n",
  '-- no account')

m('purchase: an account closed since is carried all the same',
  P, CARRY,
  "           l.account_id  -- closed or not\n",
  '-- closed or not')

m('CONTROL: purchase, a comment inside the function',
  P,
  "    -- 0924: an account closed since the bill posted is not named\n",
  "    -- 0924: an account closed since the bill posted is not named (control)\n",
  '(control)')

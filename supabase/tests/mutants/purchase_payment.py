# Mutants for public.post_purchase_payment -- paying a supplier: the
# payable cleared, the bank charges expensed, the bank credited, and the
# realised exchange difference struck.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0728_the_rest_of_the_money_that_went_to_the_heading.sql \
#       supabase/tests/payment_methods.sql \
#       supabase/tests/mutants/purchase_payment.py
#
# then again against the thirteen other files that reach it.
#
# RESULT, 5 October: 38 mutants (37 plus a control). 34 of 37 killed
# across the fourteen files, with THREE proven EQUIVALENT -- and all
# three settled by the SCHEMA rather than by the code. The control
# lived.
#
#   first run, per file: payment_methods 6, multicurrency 11,
#   money_names 6, aged_balances 5, group_payment 5,
#   bank_reconciliation 6, and 3 each from settlement_discount,
#   financial_statements, group_payment_shapes, statutory_charges,
#   aging_shapes, demo_modules.
#
#   UNION OF ALL FOURTEEN ON THE FIRST RUN: 19. EIGHTEEN SURVIVED
#   EVERY FILE.
#
# THAT IS THE SHARPEST VERSION OF THIS SWEEP'S CENTRAL FINDING. Fourteen
# files reach the most-used money mover in the schema, and between them
# they assert THREE things: the journal balances, the payable clears,
# and the bank moves. Those three are exactly the three a BALANCE CHECK
# kills -- the payable credited instead of debited, the bank debited
# instead of credited, a null account -- and eleven of the fourteen
# files killed only those. Adding a file added another copy of the same
# three.
#
# What eighteen files' worth of coverage never touched: both guards at
# the top, the supplier's own payable account, the contact on either
# money leg, every FX rule but one, `base_amount`, the reference, the
# status, and `posted_at`/`posted_by` -- the last two flagged
# mechanically by `scripts/state_write_coverage.py` before this sweep
# ran, which is its third real hit.
#
# The FX half needed the other direction. Everything in
# `multicurrency.sql` was a GAIN, so `app.fx_account(org, false)` was
# never chosen on the purchase side and swapping the two accounts put
# the right number in the wrong one for a loss with nothing noticing --
# the failure that file's own comment warns about, in the half it did
# not build. And a bank charge is in the payment's CURRENCY: every
# charge in the suite was on a ringgit payment at rate 1, where
# `round(bank_charges * v_rate, 2)` and `bank_charges` are one number.
#
# The most-reached money mover swept so far -- FOURTEEN files -- which
# on the evidence of this sweep predicts a high score and a specific
# kind of survivor: everything that balances. Three legs are ordinary
# and two more appear only on a foreign payment, and the FX pair's
# sides are mirrored, so a gain posted as a loss balances exactly.
#
# `scripts/state_write_coverage.py` flagged `posted_at` and `posted_by`
# here.
#
# ONE THING IS DELIBERATELY NOT MUTATED, and the function's own comment
# says why: the bank lookup is not org-scoped, because
# `0160`'s `purchase_payments_bank_account_same_org` already makes the
# pair agree -- "an id on this row is this company's or the insert never
# happened". That is a constraint settling the question, the third time
# in this sweep, and it is recorded rather than mutated because there is
# no conjunct there to remove.

m("anybody can pay a supplier",
  "post_purchase_payment",
  "  if not app.can_post(v_pay.org_id) then",
  "  if false then  -- payment post guard dropped",
  "-- payment post guard dropped")

m("a payment already posted is posted again",
  "post_purchase_payment",
  "  if v_pay.gl_entry_id is not null then",
  "  if false then  -- payment repost guard dropped",
  "-- payment repost guard dropped")

# EQUIVALENT, settled by the TABLE. `purchase_payments.exchange_rate`
# is NOT NULL with DEFAULT 1, so `coalesce(v_pay.exchange_rate, 1)` can
# never fire. No fixture can build the state it guards.
m("a payment with no rate is converted at nothing",
  "post_purchase_payment",
  "  v_rate := coalesce(v_pay.exchange_rate, 1);",
  "  v_rate := v_pay.exchange_rate;  -- payment rate fallback dropped",
  "-- payment rate fallback dropped")

m("the payment's own rate is ignored",
  "post_purchase_payment",
  "  v_rate := coalesce(v_pay.exchange_rate, 1);",
  "  v_rate := 1;  -- payment rate forced to one",
  "-- payment rate forced to one")

m("a payment that names no account is posted anyway",
  "post_purchase_payment",
  "  if v_pay.bank_account_id is null then",
  "  if false then  -- bankless payment accepted",
  "-- bankless payment accepted")

# EQUIVALENT, settled by the SCHEMA. `bank_accounts.account_id` is NOT
# NULL with a foreign key to `accounts`, so the join behind that lookup
# cannot come back empty for a bank account that exists -- and
# `purchase_payments_bank_account_same_org` guarantees the id on the row
# is one of this company's. The first attempt at a fixture nulled
# `account_id` and the not-null constraint refused it. The function's
# own comment relies on the same constraint to skip the org scope: "an
# id on this row is this company's or the insert never happened".
m("a bank account not on the chart is posted against",
  "post_purchase_payment",
  "  if v_bank_acct is null then",
  "  if false then  -- missing chart account no longer refused",
  "-- missing chart account no longer refused")

m("the supplier's OWN payable account is ignored for the chart's 2110",
  "post_purchase_payment",
  "  select coalesce(c.payable_account_id,",
  "  select coalesce(null::uuid,  -- own payable account ignored",
  "-- own payable account ignored")

m("ANOTHER COMPANY's payable account is credited",
  "post_purchase_payment",
  "                  (select id from public.accounts where org_id = v_pay.org_id and code = '2110'))",
  "                  (select id from public.accounts where org_id <> v_pay.org_id and code = '2110'))"
  "  -- payable org scope inverted",
  "-- payable org scope inverted")

m("the bank is credited with the payment and NOT the charges",
  "post_purchase_payment",
  "  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);",
  "  v_total := round(v_pay.amount * v_rate, 2);"
  "  -- charges left out of the bank total",
  "-- charges left out of the bank total")

# EQUIVALENT, settled by the TABLE. `purchase_payments.bank_charges`
# is NOT NULL with DEFAULT 0, so `coalesce(v_pay.bank_charges, 0)` can
# never fire either. The first version of the fixture asserted
# `bank_charges is null` on a payment that left the column out, and it
# came back 0.
m("a payment with no charges recorded converts nothing",
  "post_purchase_payment",
  "  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);",
  "  v_total := round((v_pay.amount + v_pay.bank_charges) * v_rate, 2);"
  "  -- charges fallback dropped",
  "-- charges fallback dropped")

m("the bank total is not converted at the payment's rate",
  "post_purchase_payment",
  "  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);",
  "  v_total := round(v_pay.amount + coalesce(v_pay.bank_charges, 0), 2);"
  "  -- bank total not converted",
  "-- bank total not converted")

m("the payable is cleared by the payment AND the charges",
  "post_purchase_payment",
  "    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);",
  "    'debit', v_total, 'credit', 0, 'contact_id', v_pay.contact_id);"
  "  -- charges cleared off the payable",
  "-- charges cleared off the payable")

m("the payable is CREDITED, so paying a supplier owes them more",
  "post_purchase_payment",
  "    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);",
  "    'debit', 0, 'credit', round(v_pay.amount * v_rate, 2), 'contact_id', v_pay.contact_id);"
  "  -- payable side swapped",
  "-- payable side swapped")

m("the payment is not recorded against the supplier it paid",
  "post_purchase_payment",
  "    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);",
  "    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', null);"
  "  -- payable leg contact dropped",
  "-- payable leg contact dropped")

m("a payment with NO charges posts a charge line of nothing",
  "post_purchase_payment",
  "  if coalesce(v_pay.bank_charges, 0) > 0 then",
  "  if coalesce(v_pay.bank_charges, 0) >= 0 then  -- nil charge line posted",
  "-- nil charge line posted")

m("the bank charges are expensed to the wrong account",
  "post_purchase_payment",
  "      'account_id', app.bank_charge_account(v_pay.org_id, v_pay.payment_method_id),",
  "      'account_id', v_bank_acct,  -- charges expensed to the bank",
  "-- charges expensed to the bank")

m("the bank charges are not converted at the payment's rate",
  "post_purchase_payment",
  "      'debit', round(v_pay.bank_charges * v_rate, 2), 'credit', 0);",
  "      'debit', round(v_pay.bank_charges, 2), 'credit', 0);"
  "  -- charges not converted",
  "-- charges not converted")

m("the bank is DEBITED, so paying a supplier fills the account",
  "post_purchase_payment",
  "    'debit', 0, 'credit', v_total, 'contact_id', v_pay.contact_id);",
  "    'debit', v_total, 'credit', 0, 'contact_id', v_pay.contact_id);"
  "  -- bank side swapped",
  "-- bank side swapped")

m("the bank leg does not say who was paid",
  "post_purchase_payment",
  "    'debit', 0, 'credit', v_total, 'contact_id', v_pay.contact_id);",
  "    'debit', 0, 'credit', v_total, 'contact_id', null);"
  "  -- bank leg contact dropped",
  "-- bank leg contact dropped")

m("the realised exchange difference is measured as a RECEIPT's",
  "post_purchase_payment",
  "  v_fx := app.realised_fx_on_settlement(p_id, false, v_pay.currency, v_rate);",
  "  v_fx := app.realised_fx_on_settlement(p_id, true, v_pay.currency, v_rate);"
  "  -- settlement measured as a receipt",
  "-- settlement measured as a receipt")

m("no realised exchange difference is struck at all",
  "post_purchase_payment",
  "  v_fx := app.realised_fx_on_settlement(p_id, false, v_pay.currency, v_rate);",
  "  v_fx := 0;  -- realised fx not struck",
  "-- realised fx not struck")

m("a payment settled at exactly the booked rate posts a gain of nothing",
  "post_purchase_payment",
  "  if v_fx > 0 then",
  "  if v_fx >= 0 then  -- nil fx gain lines posted",
  "-- nil fx gain lines posted")

m("an exchange GAIN is taken to the LOSS account",
  "post_purchase_payment",
  "      'account_id', app.fx_account(v_pay.org_id, true),",
  "      'account_id', app.fx_account(v_pay.org_id, false),"
  "  -- fx gain account swapped",
  "-- fx gain account swapped")

m("an exchange LOSS is taken to the GAIN account",
  "post_purchase_payment",
  "      'account_id', app.fx_account(v_pay.org_id, false),",
  "      'account_id', app.fx_account(v_pay.org_id, true),"
  "  -- fx loss account swapped",
  "-- fx loss account swapped")

m("an exchange gain is taken off the payable the wrong way",
  "post_purchase_payment",
  "      'account_id', v_ap_acct, 'description', 'Exchange gain on ' || v_pay.payment_no,\n"
  "      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,",
  "      'account_id', v_ap_acct, 'description', 'Exchange gain on ' || v_pay.payment_no,\n"
  "      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0,"
  "  -- fx gain payable side swapped",
  "-- fx gain payable side swapped")

m("an exchange gain is not attributed to the supplier it arose on",
  "post_purchase_payment",
  "      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,\n"
  "      'contact_id', v_pay.contact_id);",
  "      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,\n"
  "      'contact_id', null);  -- fx gain contact dropped",
  "-- fx gain contact dropped")

m("the journal is dated the day it was typed, not the day of payment",
  "post_purchase_payment",
  "    v_pay.org_id, v_pay.payment_date, 'payment'::app.journal_source, v_entries,",
  "    v_pay.org_id, app.today(), 'payment'::app.journal_source, v_entries,"
  "  -- payment journal date forced to today",
  "-- payment journal date forced to today")

m("the journal does not point back at the payment",
  "post_purchase_payment",
  "    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, v_pay.reference,",
  "    'Payment ' || v_pay.payment_no, 'purchase_payments', null, v_pay.reference,"
  "  -- source payment forgotten",
  "-- source payment forgotten")

m("the payment's reference is not carried onto the journal",
  "post_purchase_payment",
  "    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, v_pay.reference,",
  "    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, null,"
  "  -- payment reference dropped",
  "-- payment reference dropped")

m("the payment does not remember the journal it posted",
  "post_purchase_payment",
  "     set gl_entry_id = v_entry_id, status = 'posted',",
  "     set status = 'posted',  -- payment entry not linked",
  "-- payment entry not linked")

m("a posted payment still reads as a draft",
  "post_purchase_payment",
  "     set gl_entry_id = v_entry_id, status = 'posted',",
  "     set gl_entry_id = v_entry_id,  -- payment status not advanced",
  "-- payment status not advanced")

m("the payment's value in the company's own money is not stored",
  "post_purchase_payment",
  "         base_amount = round(v_pay.amount * v_rate, 2),",
  "         base_amount = v_pay.amount,  -- base amount not converted",
  "-- base amount not converted")

m("the realised exchange difference is not stored on the payment",
  "post_purchase_payment",
  "         fx_gain_loss = v_fx,",
  "         fx_gain_loss = 0,  -- fx not stored on the payment",
  "-- fx not stored on the payment")

m("WHEN the payment was posted is not recorded",
  "post_purchase_payment",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_by = auth.uid()  -- payment posted_at not recorded",
  "-- payment posted_at not recorded")

m("WHO posted the payment is not recorded",
  "post_purchase_payment",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_at = now()  -- payment posted_by not recorded",
  "-- payment posted_by not recorded")

m("the bank balance is not reduced by what left it",
  "post_purchase_payment",
  "     set current_balance = current_balance - v_total",
  "     set current_balance = current_balance"
  "  -- payment bank balance not moved",
  "-- payment bank balance not moved")

m("paying a supplier RAISES the bank balance",
  "post_purchase_payment",
  "     set current_balance = current_balance - v_total",
  "     set current_balance = current_balance + v_total"
  "  -- payment bank balance raised",
  "-- payment bank balance raised")

m("CONTROL -- a comment beside the rate",
  "post_purchase_payment",
  "  v_rate := coalesce(v_pay.exchange_rate, 1);",
  "  v_rate := coalesce(v_pay.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a rate.",
  "-- CONTROL: this cannot change a rate.")

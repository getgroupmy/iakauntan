# Mutants for public.settle_shared_payment -- the acquirer's callback,
# which turns a customer's card payment on a shared invoice link into a
# receipt in the tenant's own ledger.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/shared_invoice_payment.sql \
#       supabase/tests/mutants/settle_shared_payment.py
#
# `function_grants.sql` is the only other file naming it, and names it
# only to assert its grant, so it cannot kill anything here.
#
# RESULT, 5 October: 30 mutants plus a control. 13 killed on the first
# run, 17 survived; 28 of 30 after the work, with the last two proven
# EQUIVALENT (each said where it belongs, below and in the test file).
# The control lived throughout.
#
# ALMOST EVERY SURVIVOR NEEDED A SECOND OF SOMETHING. That is the
# single sentence worth taking from this one. The file had one company,
# one bank account, one acquirer, one mode, one currency and one rate --
# and seventeen mutants lived in the gaps between the one and the two:
#
#   a second acquirer      which account the takings land in, and under
#                          which mode code
#   a second bank account  the same, observably
#   a second company       whether the config lookup is org-scoped
#   a second currency      the receipt's currency and rate
#   a short/absent amount  `coalesce(p_paid_amount, 0)`
#   an absent `paid`       `coalesce(p_paid, false)`
#   a padded reference     `btrim`
#   a mixed-case gateway   `lower`
#
# THE MODE CODE IS THE TWELFTH TRAP, verbatim.
# `coalesce(v_cfg.payment_mode_code, '03')` falls back to '03', and the
# fixture configured its settlement with '03'. "Under the mode the shop
# chose" could not fail: the value read and the value invented were one
# string. The second acquirer is given '06', which is the only reason
# the assertion means anything.
#
# AND ONE SURVIVOR WAS NOT A MISSING ASSERTION AT ALL -- it was another
# function's fallback hiding the defect. "The takings are banked
# nowhere" (settlement account dropped from the receipt insert)
# survived because app.post_receipt_internal resolves a receipt with no
# bank account to the settlement account of the FIRST gateway by
# created_at, else the default active account, else the oldest, AND
# WRITES THE ANSWER BACK ONTO THE ROW. With one bank account and one
# gateway, the resolved answer and the dropped one are the same row. So
# the assertion was reading a value that a different function had
# repaired. Two gateways settling into two accounts, and a payment
# through the second, is what makes the repair visible as a repair.
#
# This one has no permission guard to mutate, and that is deliberate
# rather than an omission: it is called by an edge function holding the
# service key, on behalf of a customer who has no account at all. Its
# guards are the PROVIDER REFERENCE and the state machine -- a
# confirmation for a reference nobody started returns 'unknown' without
# saying why, because an answer that distinguishes a wrong guess from a
# right one is an oracle for guessing references.
#
# So the families look different here. The one that matters most is the
# third: `coalesce(v_cfg.payment_mode_code, '03')` has a FALLBACK of
# '03', and the fixture configures the settlement with '03'. The value
# the shop chose and the value the code invents when it finds nothing
# are the same string, so "under the mode the shop chose" is an
# assertion that cannot fail. That is the twelfth trap in
# docs/widget-tests.md, in a different module.

m("the acquirer's code is matched case-sensitively",
  "settle_shared_payment",
  "   where gateway_code = lower(btrim(coalesce(p_gateway, '')))",
  "   where gateway_code = btrim(coalesce(p_gateway, ''))"
  "  -- case no longer folded",
  "-- case no longer folded")

m("a reference arriving with whitespace is not found",
  "settle_shared_payment",
  "     and provider_ref = btrim(coalesce(p_provider_ref, ''));",
  "     and provider_ref = coalesce(p_provider_ref, '');"
  "  -- reference no longer trimmed",
  "-- reference no longer trimmed")

m("a reference nobody started is treated as a payment",
  "settle_shared_payment",
  "  if v_pay.id is null then\n    return 'unknown';",
  "  if false then\n    return 'unknown';  -- unknown reference accepted",
  "-- unknown reference accepted")

m("an acquirer's RETRY is receipted a second time",
  "settle_shared_payment",
  "  if v_pay.state = 'paid' then",
  "  if false then  -- retry guard dropped",
  "-- retry guard dropped")

m("a callback that says nothing about paying is taken as paid",
  "settle_shared_payment",
  "  if not coalesce(p_paid, false) then",
  "  if not coalesce(p_paid, true) then  -- silence means paid",
  "-- silence means paid")

m("a declined card is not recorded as declined",
  "settle_shared_payment",
  "       set state = 'failed', provider_payload = v_payload",
  "       set state = 'pending', provider_payload = v_payload"
  "  -- decline not recorded",
  "-- decline not recorded")

m("what the acquirer said about a decline is thrown away",
  "settle_shared_payment",
  "       set state = 'failed', provider_payload = v_payload",
  "       set state = 'failed', provider_payload = null"
  "  -- decline payload dropped",
  "-- decline payload dropped")

m("a short payment settles the invoice",
  "settle_shared_payment",
  "  if coalesce(p_paid_amount, 0) < v_pay.amount then",
  "  if false then  -- short-payment guard dropped",
  "-- short-payment guard dropped")

m("paying EXACTLY what was owed is refused as short",
  "settle_shared_payment",
  "  if coalesce(p_paid_amount, 0) < v_pay.amount then",
  "  if coalesce(p_paid_amount, 0) <= v_pay.amount then"
  "  -- exact payment refused",
  "-- exact payment refused")

m("a callback with no amount at all settles the invoice",
  "settle_shared_payment",
  "  if coalesce(p_paid_amount, 0) < v_pay.amount then",
  "  if coalesce(p_paid_amount, v_pay.amount) < v_pay.amount then"
  "  -- missing amount means full",
  "-- missing amount means full")

m("how much actually arrived on a short payment is not recorded",
  "settle_shared_payment",
  "       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),",
  "       set state = 'underpaid', paid_amount = null,"
  "  -- short amount not recorded",
  "-- short amount not recorded")

m("what the acquirer said about a short payment is thrown away",
  "settle_shared_payment",
  "       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),\n"
  "           provider_payload = v_payload",
  "       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),\n"
  "           provider_payload = null  -- short payload dropped",
  "-- short payload dropped")

# The two config-lookup conjuncts are INVERTED rather than dropped, and
# that is a deliberate choice about determinism. `select * into v_cfg`
# over two matching rows takes whichever the planner scans first and
# raises nothing, so a "scope dropped" mutant on a fixture holding two
# candidate configs is a coin flip -- it dies or lives by physical row
# order, which is the trap `client_money_crossing.sql` already paid for
# once. Inverted, each conjunct's mutant has exactly one answer.
m("the settlement config of ANOTHER COMPANY is used",
  "settle_shared_payment",
  "   where org_id = v_pay.org_id and gateway_code = v_pay.gateway_code",
  "   where org_id <> v_pay.org_id and gateway_code = v_pay.gateway_code"
  "  -- config org scope inverted",
  "-- config org scope inverted")

m("a SANDBOX payment looks for a PRODUCTION settlement config",
  "settle_shared_payment",
  "     and mode = v_pay.mode;",
  "     and mode = 'production';  -- mode no longer matched",
  "-- mode no longer matched")

m("more is receipted than is still owed, leaving the invoice in credit",
  "settle_shared_payment",
  "  v_take := least(v_pay.amount, coalesce(v_doc.balance_amount, 0));",
  "  v_take := v_pay.amount;  -- balance no longer capped",
  "-- balance no longer capped")

# EQUIVALENT, and proven by shape from the guard four statements above
# it rather than reasoned loosely. The chain:
#
#   1. the short-payment guard has already returned unless
#      coalesce(p_paid_amount, 0) >= v_pay.amount;
#   2. v_pay.amount is the invoice's balance at the moment
#      begin_shared_payment ran, and a POSTED invoice's balance never
#      rises -- there is no unallocate, no amend-upward, and
#      void_sales_document refuses a document with paid_amount > 0 and
#      never touches an allocation;
#   3. so coalesce(p_paid_amount, 0) >= v_pay.amount >= balance_amount;
#   4. so least(p_paid_amount, balance) = balance
#      = least(v_pay.amount, balance).
#
# The finding is therefore about the CODE, not the test: the balance cap
# alone does all the work, and `v_pay.amount` inside the `least` is
# belt-and-braces against a state this schema cannot reach. Worth
# keeping as belt-and-braces; not worth a fixture that can only be
# built by writing a row no function would write.
m("an OVERPAYMENT is receipted in full rather than what was billed",
  "settle_shared_payment",
  "  v_take := least(v_pay.amount, coalesce(v_doc.balance_amount, 0));",
  "  v_take := least(coalesce(p_paid_amount, 0),\n"
  "                  coalesce(v_doc.balance_amount, 0));"
  "  -- overpayment receipted",
  "-- overpayment receipted")

m("a receipt for nothing is raised when nothing is owed",
  "settle_shared_payment",
  "  if v_take > 0 then",
  "  if v_take >= 0 then  -- nil receipt raised",
  "-- nil receipt raised")

m("the mode the shop chose is ignored for the one the code invents",
  "settle_shared_payment",
  "      coalesce(v_cfg.payment_mode_code, '03'),",
  "      '03',  -- configured mode ignored",
  "-- configured mode ignored")

m("the takings are banked nowhere",
  "settle_shared_payment",
  "      v_cfg.settlement_bank_account_id,",
  "      null,  -- settlement account dropped",
  "-- settlement account dropped")

m("a receipt for a FOREIGN-currency invoice is raised in ringgit",
  "settle_shared_payment",
  "      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, v_take,",
  "      'MYR', coalesce(v_doc.exchange_rate, 1), v_take, v_take,"
  "  -- currency forced to MYR",
  "-- currency forced to MYR")

m("the invoice's exchange rate is replaced with one",
  "settle_shared_payment",
  "      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, v_take,",
  "      v_doc.currency, 1, v_take, v_take,  -- rate forced to one",
  "-- rate forced to one")

# EQUIVALENT, and proven by shape rather than reasoned. The insert
# writes `v_take, v_take` into (amount, base_amount), and
# app.post_receipt_internal -- called unconditionally two statements
# later, inside the same `if v_take > 0` branch -- overwrites the column
# with `round(v_rcp.amount * v_rate, 2)` on the same row. No observer
# can see what was inserted. Kept in the list because the equivalence is
# the finding: base_amount on this path is decorative, and an assertion
# on the INSERTED value would have been an assertion on nothing.
# `shared_invoice_payment.sql` asserts the surviving figure (420.00 on a
# USD 100 invoice at 4.2) instead.
m("the receipt's base amount is not converted",
  "settle_shared_payment",
  "      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, v_take,",
  "      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, 0,"
  "  -- base amount zeroed",
  "-- base amount zeroed")

m("the acquirer's reference is not carried onto the receipt",
  "settle_shared_payment",
  "      'draft', v_pay.provider_ref,",
  "      'draft', null,  -- reference not carried",
  "-- reference not carried")

m("the receipt is never posted to the ledger",
  "settle_shared_payment",
  "    perform app.post_receipt_internal(v_rcp);",
  "    -- not posted: perform app.post_receipt_internal(v_rcp);",
  "-- not posted")

m("a settled payment is left waiting",
  "settle_shared_payment",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),",
  "     set state = 'pending', paid_amount = p_paid_amount, paid_at = now(),"
  "  -- state not advanced",
  "-- state not advanced")

m("how much was paid is not recorded",
  "settle_shared_payment",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),",
  "     set state = 'paid', paid_amount = null, paid_at = now(),"
  "  -- paid amount not recorded",
  "-- paid amount not recorded")

m("WHEN it was paid is not recorded",
  "settle_shared_payment",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = null,"
  "  -- paid_at not recorded",
  "-- paid_at not recorded")

m("the receipt it raised is not linked to the payment",
  "settle_shared_payment",
  "         receipt_id = v_rcp, provider_payload = v_payload",
  "         receipt_id = null, provider_payload = v_payload"
  "  -- receipt not linked",
  "-- receipt not linked")

m("the acquirer's SIGNING SECRET is stored with the payload",
  "settle_shared_payment",
  "  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';",
  "  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);"
  "  -- signature kept",
  "-- signature kept")

m("CONTROL -- a comment beside the receipt insert",
  "settle_shared_payment",
  "    insert into public.payment_allocations",
  "    -- CONTROL: this cannot change an allocation.\n"
  "    insert into public.payment_allocations",
  "-- CONTROL: this cannot change an allocation.")

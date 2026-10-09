# Mutants for public.begin_shared_payment (0413) -- a customer holding a
# share link starts paying the invoice with the company's own acquirer
# (service role only: the edge function calls it): only a way of paying
# the link actually offers; the acquirer's reference is required; the
# row carries the company, the document, the gateway, its mode, the
# reference trimmed, the amount and currency the INTENT worked out --
# never the caller's -- and the checkout URL; the same reference again
# refreshes the URL and returns the same row.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0413_the_customer_can_pay_the_invoice_they_were_sent.sql \
#       supabase/tests/shared_invoice_payment.sql \
#       supabase/tests/mutants/begin_shared_payment.py
#
# RESULT: 10 mutants and a control, all killed by
# `shared_invoice_payment.sql`; three before its rule-by-rule block.
# Every company in the file ran its acquirers in sandbox, every
# reference was clean, every balance whole ringgit, no start had a
# checkout page -- and the USD invoice read the receipt's currency but
# not the payment's, which is what the acquirer is asked to charge.
#
# Found on the way, and raised rather than fixed: nothing stops a
# company having the same acquirer active in sandbox AND production.
# `shared_payment_intent` then returns both, the share link offers the
# acquirer twice, `pay-invoice` builds the bill from `rows[0]` and this
# function records its own first row -- in no stated order either time.

m("a way of paying that is not offered is used",
  "begin_shared_payment",
  "  if i.org_id is null then",
  "  if false then  -- not offered",
  "-- not offered")

m("a blank reference will do",
  "begin_shared_payment",
  "  if coalesce(btrim(p_provider_ref), '') = '' then",
  "  if p_provider_ref is null then  -- blank will do",
  "-- blank will do")

m("the reference is kept untrimmed",
  "begin_shared_payment",
  "          btrim(p_provider_ref), i.amount, i.currency, p_checkout_url)",
  "          p_provider_ref, i.amount, i.currency, p_checkout_url)  -- untrimmed",
  "-- untrimmed")

m("the currency is assumed",
  "begin_shared_payment",
  "          btrim(p_provider_ref), i.amount, i.currency, p_checkout_url)",
  "          btrim(p_provider_ref), i.amount, 'MYR', p_checkout_url)  -- assumed",
  "-- assumed")

m("the amount is rounded to the ringgit",
  "begin_shared_payment",
  "          btrim(p_provider_ref), i.amount, i.currency, p_checkout_url)",
  "          btrim(p_provider_ref), round(i.amount), i.currency, p_checkout_url)  -- rounded",
  "-- rounded")

m("the checkout URL is not kept",
  "begin_shared_payment",
  "          btrim(p_provider_ref), i.amount, i.currency, p_checkout_url)",
  "          btrim(p_provider_ref), i.amount, i.currency, null)  -- no url",
  "-- no url")

m("the mode is assumed production",
  "begin_shared_payment",
  "  values (i.org_id, i.document_id, i.gateway_code, i.mode,",
  "  values (i.org_id, i.document_id, i.gateway_code, 'production',  -- production",
  "-- production")

m("the mode is assumed sandbox",
  "begin_shared_payment",
  "  values (i.org_id, i.document_id, i.gateway_code, i.mode,",
  "  values (i.org_id, i.document_id, i.gateway_code, 'sandbox',  -- sandbox",
  "-- sandbox")

m("a retry keeps the old URL",
  "begin_shared_payment",
  "     set checkout_url = excluded.checkout_url,",
  "     set checkout_url = sales_gateway_payments.checkout_url,  -- old url",
  "-- old url")

m("nothing is handed back",
  "begin_shared_payment",
  "  return v_id;",
  "  return null;  -- nothing back",
  "-- nothing back")

m("CONTROL: a comment inside the block",
  "begin_shared_payment",
  "  if i.org_id is null then",
  "  if i.org_id is null then  -- (control)",
  "(control)")

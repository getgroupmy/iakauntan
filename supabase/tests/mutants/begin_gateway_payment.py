# Mutants for public.begin_gateway_payment (0297) -- the platform's own
# invoice put in front of a payment gateway (service role only: the
# edge function calls it): the invoice must exist and still be issued;
# the provider's reference is required; the payment row carries the
# gateway lower-cased and the reference trimmed (so the callback, which
# normalises the same way, finds it), the invoice's TOTAL in its
# currency, the checkout URL and who started it; a retry of the same
# gateway reference refreshes the URL and returns the same row.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0297_a_payment_that_actually_arrives.sql \
#       supabase/tests/gateway_payments.sql \
#       supabase/tests/mutants/begin_gateway_payment.py
#
# RESULT: 11 mutants and a control. 10 killed by `gateway_payments.sql`,
# ONE before its rule-by-rule block (a paid invoice refused): every
# payment the file began was lower-case, trimmed and on an untaxed
# invoice, and nothing read the URL, who started it, the id returned or
# a second start of the same bill. "Kept as typed" now dies to the
# gateway catalogue's foreign key, which is the rule doing its job.
#
# One is EQUIVALENT: "the currency is assumed" writes 'MYR', and so do
# both writers of `platform_invoices` (`bill_org_modules`,
# `platform_topup_credit`); `authenticated` may only read the table.

m("an invoice that does not exist is not said so",
  "begin_gateway_payment",
  "  if v_inv.id is null then\n    raise exception 'No such invoice'",
  "  if false then  -- no such invoice\n    raise exception 'No such invoice'",
  "-- no such invoice")

m("an invoice that is not issued is put up for payment",
  "begin_gateway_payment",
  "  if v_inv.status <> 'issued' then",
  "  if false then  -- any status",
  "-- any status")

m("a blank reference will do",
  "begin_gateway_payment",
  "  if coalesce(btrim(p_provider_ref), '') = '' then",
  "  if p_provider_ref is null then  -- blank will do",
  "-- blank will do")

m("the gateway is kept as typed",
  "begin_gateway_payment",
  "  values (v_inv.id, v_inv.org_id, lower(btrim(p_gateway)),",
  "  values (v_inv.id, v_inv.org_id, p_gateway,  -- as typed",
  "-- as typed")

m("the reference is kept untrimmed",
  "begin_gateway_payment",
  "          btrim(p_provider_ref), v_inv.total_amount, v_inv.currency,",
  "          p_provider_ref, v_inv.total_amount, v_inv.currency,  -- untrimmed",
  "-- untrimmed")

m("the amount is the subtotal, without its tax",
  "begin_gateway_payment",
  "          btrim(p_provider_ref), v_inv.total_amount, v_inv.currency,",
  "          btrim(p_provider_ref), v_inv.subtotal, v_inv.currency,  -- before tax",
  "-- before tax")

m("the currency is assumed",
  "begin_gateway_payment",
  "          btrim(p_provider_ref), v_inv.total_amount, v_inv.currency,",
  "          btrim(p_provider_ref), v_inv.total_amount, 'MYR',  -- assumed",
  "-- assumed")

m("the checkout URL is not kept",
  "begin_gateway_payment",
  "          p_checkout_url, p_created_by)",
  "          null, p_created_by)  -- no url",
  "-- no url")

m("nobody is said to have started it",
  "begin_gateway_payment",
  "          p_checkout_url, p_created_by)",
  "          p_checkout_url, null)  -- by nobody",
  "-- by nobody")

m("a retry keeps the old URL",
  "begin_gateway_payment",
  "    set checkout_url = excluded.checkout_url",
  "    set checkout_url = platform_payments.checkout_url  -- old url",
  "-- old url")

m("nothing is handed back",
  "begin_gateway_payment",
  "  return v_id;",
  "  return null;  -- nothing back",
  "-- nothing back")

m("CONTROL: a comment inside the block",
  "begin_gateway_payment",
  "  if v_inv.status <> 'issued' then",
  "  if v_inv.status <> 'issued' then  -- (control)",
  "(control)")

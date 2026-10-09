# Mutants for public.settle_gateway_payment (0491) -- a gateway's callback
# applied to the platform's own bill: found by gateway and reference
# however they were typed; silent about one it never made; a retry of a
# paid one is not a second payment; not-paid recorded as failed; less
# than owed recorded as underpaid and not settled; paid in full marks the
# payment and an ISSUED invoice paid -- never a void one -- and the
# signature is not kept in the payload.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0491_the_rest_of_the_conversation_about_money.sql \
#       supabase/tests/gateway_payments.sql \
#       supabase/tests/mutants/settle_gateway_payment.py
#
# RESULT: 15 mutants and a control, all killed by `gateway_payments.sql`.
# Four only after it asserted them: the gateway named in capitals and a
# reference padded with spaces finding the bill, a not-paid payment's
# row saying `failed` (only the word returned had been asked), and when
# a paid one was paid. `module_subscription.sql` asserted none of them.

m("the gateway name is matched only as typed",
  "settle_gateway_payment",
  "   where gateway_code = lower(btrim(coalesce(p_gateway, '')))",
  "   where gateway_code = btrim(coalesce(p_gateway, ''))  -- case kept",
  "-- case kept")

m("the reference is matched with its spaces",
  "settle_gateway_payment",
  "     and provider_ref = btrim(coalesce(p_provider_ref, ''));",
  "     and provider_ref = coalesce(p_provider_ref, '');  -- spaces kept",
  "-- spaces kept")

m("a bill never made is not said to be unknown",
  "settle_gateway_payment",
  "  if v_pay.id is null then\n    return 'unknown';",
  "  if false then  -- unknown ignored\n    return 'unknown';",
  "-- unknown ignored")

m("a retry of a paid bill is applied again",
  "settle_gateway_payment",
  "  if v_pay.state = 'paid' then\n    return 'already_paid';",
  "  if false then  -- retry applied\n    return 'already_paid';",
  "-- retry applied")

m("a not-paid callback is not recorded as failed",
  "settle_gateway_payment",
  "       set state = 'failed', provider_payload = v_payload",
  "       set provider_payload = v_payload  -- not failed",
  "-- not failed")

m("a not-paid callback is treated as paid",
  "settle_gateway_payment",
  "  if not coalesce(p_paid, false) then",
  "  if false then  -- unpaid is paid",
  "-- unpaid is paid")

m("exactly what was owed is underpaid",
  "settle_gateway_payment",
  "  if coalesce(p_paid_amount, 0) < v_pay.amount then",
  "  if coalesce(p_paid_amount, 0) <= v_pay.amount then  -- exact is short",
  "-- exact is short")

m("less than owed settles the bill",
  "settle_gateway_payment",
  "  if coalesce(p_paid_amount, 0) < v_pay.amount then",
  "  if false then  -- short accepted",
  "-- short accepted")

m("an underpayment does not record what arrived",
  "settle_gateway_payment",
  "       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),",
  "       set state = 'underpaid', paid_amount = null,  -- nothing recorded",
  "-- nothing recorded")

m("the payment does not record what was paid",
  "settle_gateway_payment",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),",
  "     set state = 'paid', paid_amount = null, paid_at = now(),  -- no amount",
  "-- no amount")

m("the payment does not record when",
  "settle_gateway_payment",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),",
  "     set state = 'paid', paid_amount = p_paid_amount, paid_at = null,  -- no when",
  "-- no when")

m("a void invoice comes back as paid",
  "settle_gateway_payment",
  "   where i.id = v_pay.invoice_id and i.status = 'issued'",
  "   where i.id = v_pay.invoice_id  -- any status",
  "-- any status")

m("the invoice does not say how it was paid",
  "settle_gateway_payment",
  "         paid_note = 'Paid through ' || v_pay.gateway_code\n                     || ' (' || v_pay.provider_ref || ')'",
  "         paid_note = null  -- no note",
  "-- no note")

m("the signature is kept in the payload",
  "settle_gateway_payment",
  "  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';",
  "  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);  -- signature kept",
  "-- signature kept")

m("money against an invoice no longer issued is called plain paid",
  "settle_gateway_payment",
  "  if v_inv.id is null then\n    -- The money arrived against an invoice that is no longer",
  "  if false then  -- quiet\n    -- The money arrived against an invoice that is no longer",
  "-- quiet")

m("CONTROL: a comment inside the block",
  "settle_gateway_payment",
  "  if v_pay.state = 'paid' then",
  "  if v_pay.state = 'paid' then  -- (control)",
  "(control)")

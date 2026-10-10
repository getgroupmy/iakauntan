# Mutants for public.set_org_payment_settlement (0413) -- where a
# company's online takings land: administrators only; the bank account
# must be this company's; an argument left out keeps what was there, a
# payment mode is trimmed; and an acquirer not yet set up is refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0413_the_customer_can_pay_the_invoice_they_were_sent.sql \
#       supabase/tests/shared_invoice_payment.sql \
#       supabase/tests/mutants/set_org_payment_settlement.py
#
# RESULT: 7 mutants and a control, all 7 killed by
# `shared_invoice_payment.sql`; before its assertions, none. The one
# refusal the file asked read only SQLSTATE 23503, which the table's
# same-company key raises too, so the function's own check could go
# unseen. It reads the words now, and a stranger, an acquirer not set
# up, the other mode, and what a left-out argument keeps are asked --
# after EACH call, since the first run's "kept" check came after a call
# that set the account again.

F = "set_org_payment_settlement"

m("anybody may say where the takings land", F,
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")
m("another company's bank account is not refused in words", F,
  "  if p_bank_account is not null\n     and not exists (select 1 from public.bank_accounts b",
  "  if false  -- any account\n     and not exists (select 1 from public.bank_accounts b",
  "-- any account")
m("leaving the account out clears it", F,
  "           coalesce(p_bank_account, c.settlement_bank_account_id),",
  "           p_bank_account,  -- cleared",
  "-- cleared")
m("leaving the payment mode out clears it", F,
  "                    c.payment_mode_code),",
  "                    null),  -- mode cleared",
  "-- mode cleared")
m("the payment mode is not trimmed", F,
  "           coalesce(nullif(btrim(coalesce(p_payment_mode, '')), ''),",
  "           coalesce(nullif(coalesce(p_payment_mode, ''), ''),  -- untrimmed",
  "-- untrimmed")
m("another mode's row is written", F,
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway\n     and c.mode = p_mode;",
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway;  -- any mode",
  "-- any mode")
m("an acquirer not set up is passed over in silence", F,
  "  if not found then",
  "  if false then  -- silent",
  "-- silent")
m("CONTROL", F,
  "      'Only an administrator can say where this company''s takings land'",
  "      'Only an administrator can say where this company''s takings land'  -- control",
  "-- control")

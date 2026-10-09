# Mutants for public.clear_org_payment_gateway (0412) -- one acquirer's
# keys in one mode removed: administrators only; THIS company's, THIS
# acquirer's, THIS mode's -- the other mode's keys, another acquirer's
# and another company's stay.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0412_a_tenants_own_gateway_credentials.sql \
#       supabase/tests/tenant_gateway_credentials.sql \
#       supabase/tests/mutants/clear_org_payment_gateway.py
#
# RESULT: 4 mutants and a control, all killed by
# `tenant_gateway_credentials.sql`; one before (both modes). Nothing
# else held keys in the mode being cleared, so a delete that ignored
# the acquirer or the company found nothing extra to take; the other
# acquirer and the other company now hold live keys too.
#
# Noted, not yet raised: removing a mode's keys while a payment in that
# mode is pending leaves `app.shared_payment_signature_key` nothing to
# return, so that payment's callback fails its signature and the
# invoice never settles though the money arrived.

m("anybody removes the keys",
  "clear_org_payment_gateway",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("both modes' keys go",
  "clear_org_payment_gateway",
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway\n     and c.mode = p_mode;",
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway;  -- both modes\n",
  "-- both modes")

m("every acquirer's keys go",
  "clear_org_payment_gateway",
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway\n     and c.mode = p_mode;",
  "   where c.org_id = p_org_id  -- every acquirer\n     and c.mode = p_mode;",
  "-- every acquirer")

m("every company's keys go",
  "clear_org_payment_gateway",
  "   where c.org_id = p_org_id and c.gateway_code = p_gateway\n     and c.mode = p_mode;",
  "   where c.gateway_code = p_gateway  -- every company\n     and c.mode = p_mode;",
  "-- every company")

m("CONTROL: a comment inside the block",
  "clear_org_payment_gateway",
  "  if not app.can_admin(p_org_id) then",
  "  if not app.can_admin(p_org_id) then  -- (control)",
  "(control)")

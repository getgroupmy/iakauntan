# Mutants for public.set_org_payment_gateway (0773, restated from 0412)
# -- a company's own acquirer keys for one gateway in one mode: only an
# administrator; only sandbox or production; only an acquirer the
# platform knows; a key, collection or signature left out keeps the one
# stored, and a key is required the first time; the switch, left out,
# stays where it was. 0773: switching one mode ON switches the same
# acquirer's other mode OFF -- in this company, for this acquirer, and
# saying who -- and switching a mode OFF touches nothing else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0773_one_acquirer_one_mode_at_a_time.sql \
#       supabase/tests/tenant_gateway_credentials.sql \
#       supabase/tests/mutants/set_org_payment_gateway.py
#
# RESULT: 14 mutants and a control. 13 killed by
# `tenant_gateway_credentials.sql`. Before `0773`'s block the file
# asserted the mode and acquirer refusals by SQLSTATE alone -- and the
# table's check constraint and foreign key raise the same two, so both
# guards could go -- and nothing left the collection out of a save.
#
# One is EQUIVALENT: "switching one mode on switches this one off too"
# switches the row being saved off, and the upsert straight after it
# writes `is_active`, `updated_by` and `updated_at` back over it.

m("anybody sets the keys",
  "set_org_payment_gateway",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a third mode is taken",
  "set_org_payment_gateway",
  "  if p_mode not in ('sandbox', 'production') then",
  "  if false then  -- any mode",
  "-- any mode")

m("an acquirer nobody knows is taken",
  "set_org_payment_gateway",
  "  if not exists (select 1 from public.payment_gateways g",
  "  if false and not exists (select 1 from public.payment_gateways g  -- any acquirer",
  "-- any acquirer")

m("a key left out blanks the stored one",
  "set_org_payment_gateway",
  "  v_key    := coalesce(nullif(trim(coalesce(p_api_key, '')), ''), v_key);",
  "  v_key    := nullif(trim(coalesce(p_api_key, '')), '');  -- key blanked",
  "-- key blanked")

m("a collection left out blanks the stored one",
  "set_org_payment_gateway",
  "  v_ref    := coalesce(nullif(trim(coalesce(p_collection_ref, '')), ''), v_ref);",
  "  v_ref    := nullif(trim(coalesce(p_collection_ref, '')), '');  -- collection blanked",
  "-- collection blanked")

m("a signature key left out blanks the stored one",
  "set_org_payment_gateway",
  "  v_sig    := coalesce(nullif(trim(coalesce(p_signature_key, '')), ''), v_sig);",
  "  v_sig    := nullif(trim(coalesce(p_signature_key, '')), '');  -- signature blanked",
  "-- signature blanked")

m("a switch left out turns the mode off",
  "set_org_payment_gateway",
  "  v_active := coalesce(p_is_active, v_active, false);",
  "  v_active := coalesce(p_is_active, false);  -- switch forgotten",
  "-- switch forgotten")

m("the first time, no key is needed",
  "set_org_payment_gateway",
  "  if v_key is null then",
  "  if false then  -- no key needed",
  "-- no key needed")

m("going live leaves the sandbox on",
  "set_org_payment_gateway",
  "  if v_active then",
  "  if false then  -- both on",
  "-- both on")

m("switching one mode on switches this one off too",
  "set_org_payment_gateway",
  "       and c.mode <> p_mode and c.is_active;",
  "       and c.is_active;  -- this mode too",
  "-- this mode too")

m("going live switches the company's other acquirers off",
  "set_org_payment_gateway",
  "     where c.org_id = p_org_id and c.gateway_code = p_gateway\n       and c.mode <> p_mode and c.is_active;",
  "     where c.org_id = p_org_id\n       and c.mode <> p_mode and c.is_active;  -- every acquirer",
  "-- every acquirer")

m("going live switches other companies off",
  "set_org_payment_gateway",
  "     where c.org_id = p_org_id and c.gateway_code = p_gateway\n       and c.mode <> p_mode and c.is_active;",
  "     where c.gateway_code = p_gateway\n       and c.mode <> p_mode and c.is_active;  -- every company",
  "-- every company")

m("nobody is said to have switched the other off",
  "set_org_payment_gateway",
  "       set is_active = false, updated_by = auth.uid(), updated_at = now()",
  "       set is_active = false, updated_at = now()  -- by nobody",
  "-- by nobody")

m("a mode cannot be switched off",
  "set_org_payment_gateway",
  "         is_active      = excluded.is_active,",
  "         is_active      = org_payment_gateways.is_active,  -- stuck",
  "-- stuck")

m("CONTROL: a comment inside the block",
  "set_org_payment_gateway",
  "  if v_active then",
  "  if v_active then  -- (control)",
  "(control)")

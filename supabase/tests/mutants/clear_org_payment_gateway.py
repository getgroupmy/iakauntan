# Mutants for public.clear_org_payment_gateway (0412, restated in 0779)
# -- one acquirer's keys in one mode removed: administrators only;
# THIS company's, THIS acquirer's, THIS mode's -- the other mode's
# keys, another acquirer's and another company's stay; and, since
# `0779`, not while a payment through them, started in the last day,
# is still pending.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0779_the_keys_a_waiting_payment_needs_stay.sql \
#       supabase/tests/tenant_gateway_credentials.sql \
#       supabase/tests/mutants/clear_org_payment_gateway.py
#
# RESULT: 15 mutants and a control, all killed by
# `tenant_gateway_credentials.sql`. Swept first against 0412: 4 of 4,
# one killed before its block (both modes); nothing else held keys in
# the mode being cleared, so a delete that ignored the acquirer or the
# company found nothing extra to take, and the other acquirer and the
# other company were given live keys too. Against 0779: 11 more, each
# of the seven waiting payments differing from the two that count in
# one respect only -- age, state, mode, acquirer, company.
#
# Noted then, raised since and built in `0779`: removing a mode's keys
# while a payment in that mode is pending left
# `app.shared_payment_signature_key` nothing to return. The mutants
# after the first four are 0779's.

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

m("a waiting payment does not hold the keys",
  "clear_org_payment_gateway",
  "  if v_waiting > 0 then",
  "  if false then  -- never held",
  "-- never held")

m("two waiting payments are needed to hold them",
  "clear_org_payment_gateway",
  "  if v_waiting > 0 then",
  "  if v_waiting > 1 then  -- one is not enough",
  "-- one is not enough")

m("another company's payment holds these keys",
  "clear_org_payment_gateway",
  "   where p.org_id = p_org_id\n",
  "   where true  -- any company\n",
  "-- any company")

m("another acquirer's payment holds these keys",
  "clear_org_payment_gateway",
  "     and p.gateway_code = p_gateway\n",
  "     and true  -- any acquirer\n",
  "-- any acquirer")

m("the other mode's payment holds these keys",
  "clear_org_payment_gateway",
  "     and p.mode = p_mode\n",
  "     and true  -- any mode\n",
  "-- any mode")

m("a paid payment holds the keys",
  "clear_org_payment_gateway",
  "     and p.state = 'pending'\n",
  "     and p.state <> 'failed'  -- paid counted\n",
  "-- paid counted")

m("an abandoned checkout holds the keys for good",
  "clear_org_payment_gateway",
  "     and p.created_at > now() - interval '24 hours';",
  "     and true;  -- any age",
  "-- any age")

m("an hour, not a day",
  "clear_org_payment_gateway",
  "     and p.created_at > now() - interval '24 hours';",
  "     and p.created_at > now() - interval '1 hour';  -- an hour",
  "-- an hour")

m("the acquirer is named by its code",
  "clear_org_payment_gateway",
  "      coalesce(v_name, p_gateway),",
  "      p_gateway,  -- the code",
  "-- the code")

m("always the plural",
  "clear_org_payment_gateway",
  "      case when v_waiting = 1 then 'payment' else 'payments' end,",
  "      'payments',  -- plural",
  "-- plural")

m("refused as a plain exception",
  "clear_org_payment_gateway",
  "      using errcode = '23514';\n  end if;\n\n  delete",
  "      using errcode = 'P0001';  -- plain raise\n  end if;\n\n  delete",
  "-- plain raise")

m("CONTROL: a comment inside the block",
  "clear_org_payment_gateway",
  "  if not app.can_admin(p_org_id) then",
  "  if not app.can_admin(p_org_id) then  -- (control)",
  "(control)")

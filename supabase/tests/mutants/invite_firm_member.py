# Mutants for public.invite_firm_member (0483) -- a partner or manager
# invites an address (any case, trimmed) into the firm at a role; an
# address with an account is a member at once, joined now, and is given
# the firm's clients; one without is invited, with a token good for a
# fortnight; inviting a member again changes their role, not their
# number, and makes them active.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0483_the_invitation_nobody_could_send.sql \
#       supabase/tests/firm_invitations.sql \
#       supabase/tests/mutants/invite_firm_member.py
#
# RESULT: 13 mutants and a control, all killed by
# `firm_invitations.sql`; seven before its rule-by-rule block. Every
# address was typed in lower case without spaces, so the lookup's
# case-folding and trimming, and the address kept, were unasked; so
# were who sent an invitation, its fortnight, and a suspended member
# invited back.

F = "invite_firm_member"

m("anybody invites", F,
  "  if not app.can_manage_firm(p_firm_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("no address is needed", F,
  "  if nullif(btrim(coalesce(p_email, '')), '') is null then",
  "  if false then  -- no address",
  "-- no address")

m("an account is found only by exact case", F,
  "   where lower(u.email) = lower(btrim(p_email));",
  "   where u.email = btrim(p_email);  -- exact case",
  "-- exact case")

m("an account is not found past spaces", F,
  "   where lower(u.email) = lower(btrim(p_email));",
  "   where lower(u.email) = lower(p_email);  -- untrimmed",
  "-- untrimmed")

m("the address is kept as typed", F,
  "  values (p_firm_id, v_user, lower(btrim(p_email)), p_role,",
  "  values (p_firm_id, v_user, p_email, p_role,  -- as typed",
  "-- as typed")

m("somebody with an account is only invited", F,
  "          (case when v_user is null then 'invited' else 'active' end)",
  "          (case when true then 'invited' else 'active' end)  -- always invited",
  "-- always invited")

m("they are not dated as joining", F,
  "          case when v_user is null then null else now() end)",
  "          null)  -- undated",
  "-- undated")

m("nobody is recorded as inviting", F,
  "          auth.uid(), v_token, now() + interval '14 days',",
  "          null, v_token, now() + interval '14 days',  -- nobody",
  "-- nobody")

m("an invitation never expires", F,
  "          auth.uid(), v_token, now() + interval '14 days',",
  "          auth.uid(), v_token, null,  -- never",
  "-- never")

m("an invitation lives a year", F,
  "          auth.uid(), v_token, now() + interval '14 days',",
  "          auth.uid(), v_token, now() + interval '365 days',  -- a year",
  "-- a year")

m("a second invitation does not change the role", F,
  "     set role = excluded.role, status = 'active'",
  "     set status = 'active'  -- role kept",
  "-- role kept")

m("a second invitation does not reinstate", F,
  "     set role = excluded.role, status = 'active'",
  "     set role = excluded.role  -- status kept",
  "-- status kept")

m("a joiner does not get the firm's clients", F,
  "  if v_user is not null then\n    perform app.sync_firm_access(p_firm_id);",
  "  if false then  -- no clients\n    perform app.sync_firm_access(p_firm_id);",
  "-- no clients")

m("CONTROL: a comment inside the block", F,
  "  return v_id;",
  "  return v_id;  -- (control)",
  "(control)")

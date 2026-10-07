# Mutants for public.chat_create_group (0139, the three-argument body; 0738 wraps it) -- a group conversation:
# its creator and each member switched on for chat in the company they
# are named under, and every company in it linked to the others.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_create_group.py
#
# then again against `idempotency.sql`, which kills none of its own.
#
# RESULT: 9 mutants and a control. 9 killed by `chat.sql`, seven -- every
# guard the function has -- only after a rule-by-rule block there.
# Groups had only ever been made by somebody switched on, named, with
# members switched on, from one company: so being signed out or
# switched off, a blank name, no members, a member switched off, and a
# member from a company NOT linked for chat were all unasserted. The
# last reaches across a tenancy; the function refused it all along, and
# nothing said so.

m("nobody signed in makes a group",
  "chat_create_group",
  "  if v_me is null then",
  "  if false then  -- anonymous",
  "-- anonymous")

m("somebody without chat makes a group",
  "chat_create_group",
  "  if not app.chat_enabled(p_my_org, v_me) then",
  "  if false then  -- switched off",
  "-- switched off")

m("a group needs no name",
  "chat_create_group",
  "  if btrim(coalesce(p_title, '')) = '' then",
  "  if p_title is null then  -- blank will do",
  "-- blank will do")

m("a group needs nobody in it",
  "chat_create_group",
  "     or jsonb_array_length(p_members) = 0 then",
  "     or false then  -- alone",
  "-- alone")

m("the name is kept untrimmed",
  "chat_create_group",
  "  values (false, btrim(p_title), v_me) returning id into v_id;",
  "  values (false, p_title, v_me) returning id into v_id;  -- as typed",
  "-- as typed")

m("the creator is not in their own group",
  "chat_create_group",
  "  insert into public.chat_participants (conversation_id, user_id, org_id)\n  values (v_id, v_me, p_my_org);",
  "  null;  -- outside it",
  "-- outside it")

m("a member without chat is added",
  "chat_create_group",
  "    if not app.chat_enabled(v_org, v_user) then",
  "    if false then  -- switched off",
  "-- switched off")

m("an unlinked company is added",
  "chat_create_group",
  "    if not app.chat_can_join(v_id, v_org) then",
  "    if false then  -- unlinked",
  "-- unlinked")

m("a member is filed under the creator's company",
  "chat_create_group",
  "    values (v_id, v_user, v_org)\n    on conflict",
  "    values (v_id, v_user, p_my_org)  -- my company\n    on conflict",
  "-- my company")

m("CONTROL: a comment inside the block",
  "chat_create_group",
  "  if v_me is null then",
  "  if v_me is null then  -- (control)",
  "(control)")

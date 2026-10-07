# Mutants for public.chat_add_participant (0139) -- somebody already in a
# group adds somebody else: never to a direct conversation, never
# somebody switched off, never from a company not linked to every
# company already in the room.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_add_participant.py
#
# RESULT: 5 mutants and a control, all 5 killed by `chat.sql`. Two only
# after the "Adding to a group, rule by rule" block there: somebody
# outside the group adding to it, and somebody switched off being added.
# Every earlier add was a member adding a switched-on colleague, so
# neither guard was ever the one that refused.

m("somebody outside the group adds people to it",
  "chat_add_participant",
  "  if not app.is_chat_participant(p_conversation_id) then",
  "  if false then  -- outsider",
  "-- outsider")

m("a direct conversation takes a third person",
  "chat_add_participant",
  "  if (select is_direct from public.chat_conversations\n",
  "  if false and (select is_direct from public.chat_conversations  -- three's company\n",
  "-- three's company")

m("somebody switched off is added",
  "chat_add_participant",
  "  if not app.chat_enabled(p_org_id, p_user_id) then",
  "  if false then  -- switched off",
  "-- switched off")

m("somebody from an unlinked company is added",
  "chat_add_participant",
  "  if not app.chat_can_join(p_conversation_id, p_org_id) then",
  "  if false then  -- unlinked",
  "-- unlinked")

m("the person is filed under nobody's company",
  "chat_add_participant",
  "  values (p_conversation_id, p_user_id, p_org_id)",
  "  values (p_conversation_id, p_user_id, null)  -- stateless",
  "-- stateless")

m("CONTROL: a comment inside the block",
  "chat_add_participant",
  "  if not app.chat_enabled(p_org_id, p_user_id) then",
  "  if not app.chat_enabled(p_org_id, p_user_id) then  -- (control)",
  "(control)")

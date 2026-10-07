# Mutants for public.chat_members (0139) -- who is in a room, shown only
# to somebody in it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_members.py
#
# RESULT: 4 mutants and a control, all killed by `chat.sql`. Three only
# after the "Who is listed, and to whom" block there -- the first being
# somebody outside a room reading who is in it.

m("everybody in every room is listed",
  "chat_members",
  "   where p.conversation_id = p_conversation_id\n",
  "   where true  -- every room\n",
  "-- every room")

m("somebody outside reads who is in a room",
  "chat_members",
  "     and app.is_chat_participant(p_conversation_id)\n",
  "     and true  -- outsider\n",
  "-- outsider")

m("you are not told which one is you",
  "chat_members",
  "         p.user_id = auth.uid(),\n",
  "         false,  -- not me\n",
  "-- not me")

m("somebody not seen for a while shows online",
  "chat_members",
  "                or pres.last_seen_at < now() - app.chat_presence_window()\n",
  "                or false  -- stale\n",
  "-- stale")

m("CONTROL: a comment inside the block",
  "chat_members",
  "   where p.conversation_id = p_conversation_id\n",
  "   where p.conversation_id = p_conversation_id  -- (control)\n",
  "(control)")

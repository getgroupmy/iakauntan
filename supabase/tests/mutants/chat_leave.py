# Mutants for public.chat_leave (0139) -- leaving a group: yourself and
# nobody else, and never a direct conversation, which can only be
# ignored.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_leave.py
#
# RESULT: 3 mutants and a control, all killed by `chat.sql`. One only
# after the direct-conversation refusal was added to the "Answering,
# refusing and hanging up" block: nothing had tried to leave a pair.

m("a direct conversation is left",
  "chat_leave",
  "  if (select is_direct from public.chat_conversations\n",
  "  if false and (select is_direct from public.chat_conversations  -- left alone\n",
  "-- left alone")

m("leaving takes everybody out",
  "chat_leave",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where conversation_id = p_conversation_id;  -- everybody",
  "-- everybody")

m("leaving takes nobody out",
  "chat_leave",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where false;  -- nobody",
  "-- nobody")

m("CONTROL: a comment inside the block",
  "chat_leave",
  "  delete from public.chat_participants\n",
  "  delete from public.chat_participants  -- (control)\n",
  "(control)")

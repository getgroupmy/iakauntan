# Mutants for public.chat_my_conversations (0139) -- the inbox: one row
# per conversation you are in for this company, with its last message,
# what you have not read, and who is typing.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_my_conversations.py
#
# RESULT: 10 mutants and a control, all killed by `chat.sql`. Nine only
# after "The thread and the inbox, rule by rule" block there: nobody had
# conversations in two companies, nobody without chat opened an inbox,
# and the unread count never met your own message, a taken-back one, or
# one already read.

m("another company's conversations are in this inbox",
  "chat_my_conversations",
  "     and me.org_id = p_org_id\n",
  "     and true  -- any company\n",
  "-- any company")

m("somebody without chat sees an inbox",
  "chat_my_conversations",
  "     and app.chat_enabled(p_org_id, auth.uid())\n",
  "     and true  -- no chat\n",
  "-- no chat")

m("your own messages count as unread",
  "chat_my_conversations",
  "             and m.sender_id <> auth.uid()\n",
  "             and true  -- mine unread\n",
  "-- mine unread")

m("a taken-back message counts as unread",
  "chat_my_conversations",
  "             and m.deleted_at is null\n             and m.created_at > me.last_read_at),",
  "             and m.created_at > me.last_read_at),  -- deleted unread",
  "-- deleted unread")

m("what you have read counts as unread",
  "chat_my_conversations",
  "             and m.created_at > me.last_read_at),",
  "             and true),  -- all unread",
  "-- all unread")

m("a taken-back message is the last thing said",
  "chat_my_conversations",
  "           where m.conversation_id = c.id and m.deleted_at is null\n",
  "           where m.conversation_id = c.id  -- deleted last\n",
  "-- deleted last")

m("a voice note shows as its empty body",
  "chat_my_conversations",
  "                   when m.kind = 'voice' then 'Voice note'\n",
  "                   when false then 'Voice note'  -- no label\n",
  "-- no label")

m("typing that has lapsed still shows",
  "chat_my_conversations",
  "                                and t.expires_at > now())) as typing",
  "                                and true)) as typing  -- lapsed",
  "-- lapsed")

m("a group has a counterpart",
  "chat_my_conversations",
  "         and c.is_direct\n",
  "         and true  -- counterpart\n",
  "-- counterpart")

m("one company reads as two",
  "chat_my_conversations",
  "               where p.org_id <> me.org_id) + 1 as company_count,",
  "               where true) + 1 as company_count,  -- two companies",
  "-- two companies")

m("CONTROL: a comment inside the block",
  "chat_my_conversations",
  "     and me.org_id = p_org_id\n",
  "     and me.org_id = p_org_id  -- (control)\n",
  "(control)")

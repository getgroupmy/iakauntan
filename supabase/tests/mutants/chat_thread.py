# Mutants for public.chat_thread (0144) -- a conversation's messages,
# a page at a time, to somebody in it: a taken-back body emptied, and
# the ticks on your own messages counted against EVERYBODY else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0144_chat_edit_and_delete.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_thread.py
#
# RESULT: 13 mutants and a control, all killed by `chat.sql`. Six only
# after "The thread and the inbox, rule by rule" block there. The first
# was somebody OUTSIDE a conversation reading it: the function is
# SECURITY DEFINER, so its one participant check is the whole of the
# protection, and nothing asserted it. Then nobody turned a page, and no
# page was big enough for the limit to bite. The default of fifty needed
# an EXPLICIT null to reach: the signature's own default supplies 50
# before the `coalesce` is ever asked.

m("the ticks count your own reading",
  "chat_thread",
  "     where p.conversation_id = p_conversation_id and p.user_id <> auth.uid()\n",
  "     where p.conversation_id = p_conversation_id  -- counts me\n",
  "-- counts me")

m("read by one is read by all",
  "chat_thread",
  "    select min(p.last_delivered_at) as delivered, min(p.last_read_at) as read",
  "    select min(p.last_delivered_at) as delivered, max(p.last_read_at) as read  -- anybody",
  "-- anybody")

m("delivered to one is delivered to all",
  "chat_thread",
  "    select min(p.last_delivered_at) as delivered, min(p.last_read_at) as read",
  "    select max(p.last_delivered_at) as delivered, min(p.last_read_at) as read  -- any phone",
  "-- any phone")

m("a taken-back message still shows its words",
  "chat_thread",
  "         case when m.deleted_at is null then m.body else null end,",
  "         m.body,  -- still there",
  "-- still there")

m("a taken-back message is not marked so",
  "chat_thread",
  "         m.deleted_at is not null,\n",
  "         false,  -- unmarked\n",
  "-- unmarked")

m("somebody else's message carries ticks",
  "chat_thread",
  "         case when m.sender_id <> auth.uid() then null\n",
  "         case when false then null  -- their ticks\n",
  "-- their ticks")

m("a message is never shown delivered",
  "chat_thread",
  "              when m.created_at <= o.delivered then 'delivered'\n",
  "              when false then 'delivered'  -- never delivered\n",
  "-- never delivered")

m("every conversation's messages are shown",
  "chat_thread",
  "   where m.conversation_id = p_conversation_id\n",
  "   where true  -- every room\n",
  "-- every room")

m("somebody outside reads the thread",
  "chat_thread",
  "     and app.is_chat_participant(p_conversation_id)\n",
  "     and true  -- outsider\n",
  "-- outsider")

m("an earlier page repeats the latest",
  "chat_thread",
  "     and (p_before is null or m.created_at < p_before)\n",
  "     and true  -- same page\n",
  "-- same page")

m("a page has no ceiling",
  "chat_thread",
  "   limit greatest(least(coalesce(p_limit, 50), 200), 1);",
  "   limit greatest(coalesce(p_limit, 50), 1);  -- unbounded",
  "-- unbounded")

m("a page of nothing is allowed",
  "chat_thread",
  "   limit greatest(least(coalesce(p_limit, 50), 200), 1);",
  "   limit least(coalesce(p_limit, 50), 200);  -- empty page",
  "-- empty page")

m("no page size means everything",
  "chat_thread",
  "   limit greatest(least(coalesce(p_limit, 50), 200), 1);",
  "   limit greatest(least(coalesce(p_limit, 1000), 200), 1);  -- no default",
  "-- no default")

m("CONTROL: a comment inside the block",
  "chat_thread",
  "     and app.is_chat_participant(p_conversation_id)\n",
  "     and app.is_chat_participant(p_conversation_id)  -- (control)\n",
  "(control)")

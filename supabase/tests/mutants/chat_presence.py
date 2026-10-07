# Mutants for public.chat_heartbeat, chat_mark_read, chat_mark_delivered,
# chat_typing_ping and chat_typing_stop (0136) -- the cheap, frequent
# calls: the online dot, the ticks, and "typing...".
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0136_chat_presence_and_receipts.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_presence.py
#
# RESULT: 13 mutants and a control, all killed by `chat.sql`. Eight only
# after the "Presence, ticks and typing, rule by rule" block there:
# nothing went idle; nothing read a conversation before it was
# delivered; and "typing..." was never pinged by an outsider, for too
# long, for no time, or twice. Delivery is asserted against a PINNED
# earlier time, because joining a conversation already stamps
# `last_delivered_at`, so "still null" was false before anything broke.

m("idle reads as online",
  "chat_heartbeat",
  "          (case when p_idle then 'idle' else 'online' end)",
  "          ('online')  -- never idle",
  "-- never idle")

m("a heartbeat does not move on",
  "chat_heartbeat",
  "    set state = excluded.state, last_seen_at = excluded.last_seen_at",
  "    set state = chat_presence.state, last_seen_at = excluded.last_seen_at  -- stuck",
  "-- stuck")

m("reading does not mark read",
  "chat_mark_read",
  "     set last_read_at = greatest(last_read_at, now()),",
  "     set last_read_at = last_read_at,  -- unread",
  "-- unread")

m("reading does not count as delivered",
  "chat_mark_read",
  "         last_delivered_at = greatest(last_delivered_at, now())",
  "         last_delivered_at = last_delivered_at  -- undelivered",
  "-- undelivered")

m("reading marks everybody's read",
  "chat_mark_read",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where conversation_id = p_conversation_id;  -- everybody",
  "-- everybody")

m("delivery is not recorded",
  "chat_mark_delivered",
  "     set last_delivered_at = greatest(last_delivered_at, now())",
  "     set last_delivered_at = last_delivered_at  -- undelivered",
  "-- undelivered")

m("delivery to me counts for everybody",
  "chat_mark_delivered",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where conversation_id = p_conversation_id;  -- everybody",
  "-- everybody")

m("somebody outside types into a conversation",
  "chat_typing_ping",
  "  if not app.is_chat_participant(p_conversation_id) then",
  "  if false then  -- outsider",
  "-- outsider")

m("typing lasts as long as the client asks",
  "chat_typing_ping",
  "          now() + make_interval(secs => greatest(least(p_seconds, 30), 1)))",
  "          now() + make_interval(secs => greatest(p_seconds, 1)))  -- uncapped",
  "-- uncapped")

m("typing for no time at all",
  "chat_typing_ping",
  "          now() + make_interval(secs => greatest(least(p_seconds, 30), 1)))",
  "          now() + make_interval(secs => least(p_seconds, 30)))  -- no floor",
  "-- no floor")

m("a second ping does not extend it",
  "chat_typing_ping",
  "    set expires_at = excluded.expires_at;",
  "    set expires_at = chat_typing.expires_at;  -- not extended",
  "-- not extended")

m("stopping typing stops nothing",
  "chat_typing_stop",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where false;  -- still typing",
  "-- still typing")

m("stopping typing stops everybody",
  "chat_typing_stop",
  "   where conversation_id = p_conversation_id and user_id = auth.uid();",
  "   where conversation_id = p_conversation_id;  -- everybody",
  "-- everybody")

m("CONTROL: a comment inside the block",
  "chat_typing_ping",
  "  if not app.is_chat_participant(p_conversation_id) then",
  "  if not app.is_chat_participant(p_conversation_id) then  -- (control)",
  "(control)")

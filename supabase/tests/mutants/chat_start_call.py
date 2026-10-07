# Mutants for public.chat_start_call (0140) -- ringing a conversation:
# only from inside it, joining the call already open rather than
# starting a second, closing a stale ringing call first, and ringing
# everybody but the caller, who is already in.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0140_call_signalling.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_start_call.py
#
# RESULT: 12 mutants and a control, all killed by `chat.sql`. Six only
# after the "Placing a call, rule by rule" block there: nothing pressed
# call after a call rang out unanswered, nor on a live call past its
# ringing deadline (every live call is, a minute in), and nothing read
# back the kind of call or when the caller joined it. The outsider
# mutant is killed by 0758's block -- the suspended member ringing.

m("somebody outside the conversation rings it",
  "chat_start_call",
  "  if not app.is_chat_participant(p_conversation_id) then",
  "  if false then  -- outsider",
  "-- outsider")

m("a second call is started beside the open one",
  "chat_start_call",
  "  if v_open is not null then",
  "  if false then  -- two calls",
  "-- two calls")

m("pressing call on an open one does not answer it",
  "chat_start_call",
  "    perform public.chat_join_call(v_open);",
  "    null;  -- not answered",
  "-- not answered")

m("a call in another conversation is joined",
  "chat_start_call",
  "   where conversation_id = p_conversation_id\n     and status in ('ringing', 'live')\n",
  "   where status in ('ringing', 'live')  -- any room\n",
  "-- any room")

m("a ringing call past its deadline is joined",
  "chat_start_call",
  "     and (status = 'live' or ringing_until > now())",
  "     and true  -- stale",
  "-- stale")

m("a live call is not joined",
  "chat_start_call",
  "     and (status = 'live' or ringing_until > now())",
  "     and (ringing_until > now())  -- live missed",
  "-- live missed")

m("a stale ringing call is left ringing",
  "chat_start_call",
  "     set status = 'missed', ended_at = coalesce(ended_at, ringing_until)",
  "     set status = status, ended_at = coalesce(ended_at, ringing_until)  -- still ringing",
  "-- still ringing")

m("a stale call is ended now, not when it stopped ringing",
  "chat_start_call",
  "     set status = 'missed', ended_at = coalesce(ended_at, ringing_until)",
  "     set status = 'missed', ended_at = now()  -- dated now",
  "-- dated now")

m("a video call is placed as voice",
  "chat_start_call",
  "          (case when p_kind = 'video' then 'video' else 'voice' end)",
  "          ('voice')  -- voice only",
  "-- voice only")

m("the caller is rung too",
  "chat_start_call",
  "         (case when p.user_id = v_me then 'joined' else 'ringing' end)",
  "         ('ringing')  -- rung",
  "-- rung")

m("the caller has no answering time",
  "chat_start_call",
  "         (case when p.user_id = v_me then now() end)",
  "         (null::timestamptz)  -- undated",
  "-- undated")

m("everybody in every conversation is rung",
  "chat_start_call",
  "   where p.conversation_id = p_conversation_id;",
  "   where true;  -- everybody",
  "-- everybody")

m("CONTROL: a comment inside the block",
  "chat_start_call",
  "  if v_open is not null then",
  "  if v_open is not null then  -- (control)",
  "(control)")

# Mutants for public.chat_expire_calls, chat_incoming_calls and
# chat_active_call (0140) -- the deadline that closes an unanswered
# call, the phone that rings, and the banner in a thread.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0140_call_signalling.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_call_readers.py
#
# RESULT: 18 mutants and a control. 17 killed by `chat.sql`, thirteen
# only after the "What rings, what shows, and what the deadline closes"
# block there. The one call ever expired was the only call open, so
# `chat_expire_calls` was nearly unasserted: a live call or one within
# its deadline surviving, when and why a missed call ended, the count,
# and the phones on it were all free to change.
#
# One EQUIVALENT: "a call that is over still rings". Nothing ends a call
# while a phone on it is still ringing within its deadline; the reasoning
# is beside the assertion in `chat.sql`.

m("a live call is marked missed",
  "chat_expire_calls",
  "     where status = 'ringing' and ringing_until <= now()\n",
  "     where status in ('ringing', 'live') and ringing_until <= now()  -- live missed\n",
  "-- live missed")

m("a call still ringing is marked missed",
  "chat_expire_calls",
  "     where status = 'ringing' and ringing_until <= now()\n",
  "     where status = 'ringing'  -- early\n",
  "-- early")

m("a missed call is dated now",
  "chat_expire_calls",
  "           ended_at = coalesce(ended_at, ringing_until),",
  "           ended_at = now(),  -- dated now",
  "-- dated now")

m("a missed call gives no reason",
  "chat_expire_calls",
  "           end_reason = coalesce(end_reason, 'nobody answered')",
  "           end_reason = end_reason  -- no reason",
  "-- no reason")

m("a reason already recorded is overwritten",
  "chat_expire_calls",
  "           end_reason = coalesce(end_reason, 'nobody answered')",
  "           end_reason = 'nobody answered'  -- overwritten",
  "-- overwritten")

m("the count is not of what expired",
  "chat_expire_calls",
  "  return v_n;",
  "  return 0;  -- uncounted",
  "-- uncounted")

m("phones on a missed call keep ringing",
  "chat_expire_calls",
  "     set state = 'left', left_at = coalesce(left_at, now())",
  "     set state = p.state, left_at = coalesce(left_at, now())  -- ringing on",
  "-- ringing on")

m("phones on a live call are hung up",
  "chat_expire_calls",
  "   where c.id = p.call_id and c.status = 'missed' and p.state = 'ringing';",
  "   where c.id = p.call_id and p.state = 'ringing';  -- any call",
  "-- any call")

m("somebody who answered a missed call is marked left",
  "chat_expire_calls",
  "   where c.id = p.call_id and c.status = 'missed' and p.state = 'ringing';",
  "   where c.id = p.call_id and c.status = 'missed';  -- anybody",
  "-- anybody")

m("a phone that answered still rings",
  "chat_incoming_calls",
  "     and me.state = 'ringing'\n",
  "     and true  -- answered\n",
  "-- answered")

m("a call that is over still rings",
  "chat_incoming_calls",
  "     and c.status in ('ringing', 'live')\n",
  "     and true  -- over\n",
  "-- over")

m("a call past its deadline still rings",
  "chat_incoming_calls",
  "     and c.ringing_until > now()\n",
  "     and true  -- past\n",
  "-- past")

m("a phone rings for somebody no longer in the room",
  "chat_incoming_calls",
  "     and app.is_chat_participant(c.conversation_id);",
  "     and true;  -- not in it",
  "-- not in it")

m("anybody sees the call banner",
  "chat_active_call",
  "     and app.is_chat_participant(p_conversation_id)\n",
  "     and true  -- anybody\n",
  "-- anybody")

m("an ended call shows as active",
  "chat_active_call",
  "     and (c.status = 'live'\n",
  "     and (c.status <> 'ringing'  -- ended\n",
  "-- ended")

m("a ringing call past its deadline shows as active",
  "chat_active_call",
  "          or (c.status = 'ringing' and c.ringing_until > now()))",
  "          or (c.status = 'ringing'))  -- past",
  "-- past")

m("a ringing call shows as nothing",
  "chat_active_call",
  "          or (c.status = 'ringing' and c.ringing_until > now()))",
  "          or false)  -- silent",
  "-- silent")

m("the banner counts everybody rung as in it",
  "chat_active_call",
  "           where p.call_id = c.id and p.state = 'joined'),",
  "           where p.call_id = c.id),  -- counted",
  "-- counted")

m("CONTROL: a comment inside the block",
  "chat_expire_calls",
  "  return v_n;",
  "  return v_n;  -- (control)",
  "(control)")

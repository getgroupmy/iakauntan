# Mutants for public.chat_join_call, chat_decline_call and
# chat_leave_call (0140) -- answering a ringing call, refusing one, and
# hanging up without ending it for anybody else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0140_call_signalling.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_calls.py
#
# RESULT: 24 mutants and a control. 23 killed by `chat.sql`, fifteen
# only after the "Answering, refusing and hanging up, rule by rule"
# block there. The one call anybody declined was a live call in a room,
# so the rule `chat_decline_call` exists for -- in a pair, one refusal
# ends it -- had never run; and nobody joined a call that was over or
# missing, rejoined after leaving, joined after being added mid-call,
# or hung up on a call already ended another way.
#
# One EQUIVALENT: "one refusal ends a call somebody has answered". While
# a call is ringing nobody but the caller can have answered:
# `chat_join_call` turns it live in the same transaction, under the row
# lock, and clients may only SELECT `chat_calls` and
# `chat_call_participants`. Noted beside the assertion in `chat.sql`.

m("a call that does not exist is joined in silence",
  "chat_join_call",
  "  if v_call.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("somebody outside the conversation joins its call",
  "chat_join_call",
  "  if not app.is_chat_participant(v_call.conversation_id) then",
  "  if false then  -- outsider",
  "-- outsider")

m("a call that is over is joined again",
  "chat_join_call",
  "  if v_call.status not in ('ringing', 'live') then",
  "  if false then  -- over",
  "-- over")

m("joining does not put you in it",
  "chat_join_call",
  "          'joined', now())",
  "          'ringing', now())  -- not in",
  "-- not in")

m("joining again after leaving leaves you out",
  "chat_join_call",
  "    set state = 'joined', joined_at = coalesce(",
  "    set state = public.chat_call_participants.state, joined_at = coalesce(  -- still left",
  "-- still left")

m("joining again re-dates the first answer",
  "chat_join_call",
  "          public.chat_call_participants.joined_at, now()),",
  "          now(), now()),  -- redated",
  "-- redated")

m("joining again keeps the old leaving time",
  "chat_join_call",
  "        left_at = null;",
  "        left_at = public.chat_call_participants.left_at;  -- still gone",
  "-- still gone")

m("answering leaves the call ringing",
  "chat_join_call",
  "  if v_call.status = 'ringing' then",
  "  if false then  -- unanswered",
  "-- unanswered")

m("answering forgets when it was answered",
  "chat_join_call",
  "       set status = 'live', answered_at = coalesce(answered_at, now())",
  "       set status = 'live', answered_at = answered_at  -- undated",
  "-- undated")

m("a stranger declines somebody else's call",
  "chat_decline_call",
  "  if v_call.id is null or\n     not app.is_chat_participant(v_call.conversation_id) then",
  "  if v_call.id is null then  -- stranger",
  "-- stranger")

m("a decline is not recorded",
  "chat_decline_call",
  "     set state = 'declined', left_at = now()",
  "     set state = state, left_at = now()  -- unrecorded",
  "-- unrecorded")

m("a decline is not dated",
  "chat_decline_call",
  "     set state = 'declined', left_at = now()",
  "     set state = 'declined', left_at = left_at  -- undated",
  "-- undated")

m("one refusal in a pair leaves it ringing",
  "chat_decline_call",
  "  if v_call.status = 'ringing'\n",
  "  if false and v_call.status = 'ringing'  -- rings on\n",
  "-- rings on")

m("one refusal ends a call somebody has answered",
  "chat_decline_call",
  "                      where call_id = p_call_id and state = 'joined'\n                        and user_id <> v_call.started_by)",
  "                      where false)  -- answered",
  "-- answered")

m("the caller counts as somebody who answered",
  "chat_decline_call",
  "                        and user_id <> v_call.started_by)",
  "                        and true)  -- caller counts",
  "-- caller counts")

m("one refusal ends a call others are still being rung for",
  "chat_decline_call",
  "                      where call_id = p_call_id and state = 'ringing')",
  "                      where false)  -- others ringing",
  "-- others ringing")

m("a declined call is not dated",
  "chat_decline_call",
  "       set status = 'declined', ended_at = now(), end_reason = 'declined'",
  "       set status = 'declined', ended_at = ended_at, end_reason = 'declined'  -- undated",
  "-- undated")

m("hanging up leaves you in the call",
  "chat_leave_call",
  "     set state = 'left', left_at = now()",
  "     set state = state, left_at = now()  -- still in",
  "-- still in")

m("hanging up hangs up somebody else",
  "chat_leave_call",
  "   where call_id = p_call_id and user_id = auth.uid();",
  "   where call_id = p_call_id;  -- everybody",
  "-- everybody")

m("the last one out leaves the call running",
  "chat_leave_call",
  "     and status in ('ringing', 'live')\n",
  "     and false  -- runs on\n",
  "-- runs on")

m("a call already over is ended again",
  "chat_leave_call",
  "     and status in ('ringing', 'live')\n",
  "     and true  -- re-ended\n",
  "-- re-ended")

m("a reason already recorded is overwritten",
  "chat_leave_call",
  "         end_reason = coalesce(end_reason, 'everybody left')",
  "         end_reason = 'everybody left'  -- overwritten",
  "-- overwritten")

m("the first one out ends it for everybody",
  "chat_leave_call",
  "                        and state in ('joined', 'ringing'));",
  "                        and false);  -- first out",
  "-- first out")

m("somebody still being rung does not keep it open",
  "chat_leave_call",
  "                        and state in ('joined', 'ringing'));",
  "                        and state = 'joined');  -- ringers ignored",
  "-- ringers ignored")

m("CONTROL: a comment inside the block",
  "chat_join_call",
  "  if v_call.id is null then",
  "  if v_call.id is null then  -- (control)",
  "(control)")

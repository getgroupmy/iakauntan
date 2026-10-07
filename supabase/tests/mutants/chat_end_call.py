# Mutants for public.chat_end_call (0140) -- the person who started a
# call ends it for everybody: every participant still in it leaves, and
# the call is ended with a reason that is not overwritten.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0140_call_signalling.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_end_call.py
#
# `chat.sql` is the only file that ends a call.
#
# RESULT: 10 mutants and a control. 10 killed by `chat.sql`, seven only
# after a rule-by-rule block there: the one call ended had only people
# still in it, no reason already recorded, no second call anywhere, and
# was live -- so the ended call's date, a decliner's state, an earlier
# leaving time or reason, another call, and a call already over were
# all unasserted.

m("a call that does not exist is ended in silence",
  "chat_end_call",
  "  if v_call.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody ends a call for everybody",
  "chat_end_call",
  "  if v_call.started_by <> auth.uid() then",
  "  if false then  -- anyone",
  "-- anyone")

m("the participants are left in it",
  "chat_end_call",
  "     set state = 'left', left_at = coalesce(left_at, now())",
  "     set state = state, left_at = coalesce(left_at, now())  -- still in",
  "-- still in")

m("a participant who left earlier is re-dated",
  "chat_end_call",
  "     set state = 'left', left_at = coalesce(left_at, now())",
  "     set state = 'left', left_at = now()  -- redated",
  "-- redated")

m("another call's participants are put out",
  "chat_end_call",
  "   where call_id = p_call_id and state in ('joined', 'ringing');",
  "   where state in ('joined', 'ringing');  -- every call",
  "-- every call")

m("somebody who declined is marked as having left",
  "chat_end_call",
  "   where call_id = p_call_id and state in ('joined', 'ringing');",
  "   where call_id = p_call_id;  -- whatever they did",
  "-- whatever they did")

m("the call is not ended",
  "chat_end_call",
  "     set status = 'ended', ended_at = now(),",
  "     set status = status, ended_at = now(),  -- still on",
  "-- still on")

m("the call is not dated",
  "chat_end_call",
  "     set status = 'ended', ended_at = now(),",
  "     set status = 'ended', ended_at = null,  -- undated",
  "-- undated")

m("an earlier reason is overwritten",
  "chat_end_call",
  "         end_reason = coalesce(end_reason, 'ended by the caller')",
  "         end_reason = 'ended by the caller'  -- overwritten",
  "-- overwritten")

m("an ended or missed call is ended again",
  "chat_end_call",
  "   where id = p_call_id and status in ('ringing', 'live');",
  "   where id = p_call_id;  -- whatever it was",
  "-- whatever it was")

m("CONTROL: a comment inside the block",
  "chat_end_call",
  "  if v_call.id is null then",
  "  if v_call.id is null then  -- (control)",
  "(control)")

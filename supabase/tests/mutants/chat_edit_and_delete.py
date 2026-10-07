# Mutants for public.chat_edit_message and chat_delete_message (0144) --
# a person's own words, changed within a window and marked as changed,
# or taken back and emptied.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0144_chat_edit_and_delete.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_edit_and_delete.py
#
# RESULT: 16 mutants and a control. 16 killed by `chat.sql`, seven only
# after a rule-by-rule block there: a message that is not there, a
# deleted message edited back, an edit down to nothing, a second
# deletion moving the first one's date, and somebody whose chat was
# switched off still editing and deleting.

m("a message that does not exist is edited in silence",
  "chat_edit_message",
  "  if v_sender is null then\n    raise exception 'No such message';",
  "  if false then  -- no such\n    raise exception 'No such message';",
  "-- no such")

m("anybody edits somebody's words",
  "chat_edit_message",
  "  if v_sender <> auth.uid() then\n    raise exception 'You can only edit your own messages'",
  "  if false then  -- anyone\n    raise exception 'You can only edit your own messages'",
  "-- anyone")

m("a deleted message is edited back",
  "chat_edit_message",
  "  if v_deleted is not null then",
  "  if false then  -- resurrected",
  "-- resurrected")

m("somebody taken off chat still edits",
  "chat_edit_message",
  "  if not app.is_chat_participant(v_conversation) then",
  "  if false then  -- still in",
  "-- still in")

m("a message is edited whenever",
  "chat_edit_message",
  "  if v_created < now() - app.chat_edit_window() then",
  "  if false then  -- any time",
  "-- any time")

m("a text message is edited to nothing",
  "chat_edit_message",
  "  if v_kind = 'text' and length(btrim(coalesce(p_body, ''))) = 0 then",
  "  if false then  -- empty",
  "-- empty")

m("an edit is kept untrimmed",
  "chat_edit_message",
  "     set body = btrim(coalesce(p_body, '')),",
  "     set body = coalesce(p_body, ''),  -- as typed",
  "-- as typed")

m("an edit is not marked as an edit",
  "chat_edit_message",
  "         edited_at = now()",
  "         edited_at = edited_at  -- unmarked",
  "-- unmarked")

m("a message that does not exist is deleted in silence",
  "chat_delete_message",
  "  if v_sender is null then\n    raise exception 'No such message';",
  "  if false then  -- no such\n    raise exception 'No such message';",
  "-- no such")

m("anybody deletes somebody's words",
  "chat_delete_message",
  "  if v_sender <> auth.uid() then",
  "  if false then  -- anyone",
  "-- anyone")

m("somebody taken off chat still deletes",
  "chat_delete_message",
  "  if not app.is_chat_participant(v_conversation) then",
  "  if false then  -- still in",
  "-- still in")

m("a deletion is not dated",
  "chat_delete_message",
  "     set deleted_at = coalesce(deleted_at, now()),",
  "     set deleted_at = deleted_at,  -- undated",
  "-- undated")

m("a second deletion moves the date",
  "chat_delete_message",
  "     set deleted_at = coalesce(deleted_at, now()),",
  "     set deleted_at = now(),  -- redated",
  "-- redated")

m("a deleted message keeps its words",
  "chat_delete_message",
  "         body = ''\n",
  "         body = body  -- still readable\n",
  "-- still readable")

m("a deleted message keeps its attachments",
  "chat_delete_message",
  "  delete from public.chat_attachments where message_id = p_message_id;",
  "  null;  -- files kept",
  "-- files kept")

m("CONTROL: a comment inside the block",
  "chat_delete_message",
  "  if v_sender <> auth.uid() then",
  "  if v_sender <> auth.uid() then  -- (control)",
  "(control)")

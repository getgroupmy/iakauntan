# Mutants for public.chat_directory and chat_who_is_typing (0136) --
# who you may start a conversation with, and who is typing at you.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0136_chat_presence_and_receipts.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_readers_0136.py
#
# RESULT: 10 mutants and a control. 9 killed by `chat.sql`, seven only
# after the "Who is listed, and to whom" block there -- among them
# somebody without chat reading the whole directory and somebody
# outside a room reading who is typing in it.
#
# One EQUIVALENT: "the directory lists people switched off".
# `chat_enabled(a.org_id, a.user_id)` beside it reads the same
# `chat_access` row for `is_enabled`.

m("the directory lists people switched off",
  "chat_directory",
  "   where a.is_enabled\n",
  "   where true  -- switched off\n",
  "-- switched off")

m("the directory lists you",
  "chat_directory",
  "     and a.user_id <> auth.uid()\n",
  "     and true  -- yourself\n",
  "-- yourself")

m("somebody without chat reads the directory",
  "chat_directory",
  "     and app.chat_enabled(p_org_id, auth.uid())\n",
  "     and true  -- no chat\n",
  "-- no chat")

m("the directory lists unlinked companies",
  "chat_directory",
  "     and app.chat_orgs_linked(p_org_id, a.org_id)\n",
  "     and true  -- unlinked\n",
  "-- unlinked")

m("the directory lists people whose company has no chat",
  "chat_directory",
  "     and app.chat_enabled(a.org_id, a.user_id)\n",
  "     and true  -- no module\n",
  "-- no module")

m("somebody not seen for a while shows online",
  "chat_directory",
  "                or pres.last_seen_at < now() - app.chat_presence_window()\n",
  "                or false  -- stale\n",
  "-- stale")

m("your own company is not told apart",
  "chat_directory",
  "         a.org_id <> p_org_id,\n",
  "         false,  -- all external\n",
  "-- all external")

m("you are shown typing to yourself",
  "chat_who_is_typing",
  "     and t.user_id <> auth.uid()\n",
  "     and true  -- yourself\n",
  "-- yourself")

m("typing that has expired still shows",
  "chat_who_is_typing",
  "     and t.expires_at > now()\n",
  "     and true  -- expired\n",
  "-- expired")

m("somebody outside sees who is typing",
  "chat_who_is_typing",
  "     and app.is_chat_participant(p_conversation_id);",
  "     and true;  -- outsider",
  "-- outsider")

m("CONTROL: a comment inside the block",
  "chat_who_is_typing",
  "     and t.expires_at > now()\n",
  "     and t.expires_at > now()  -- (control)\n",
  "(control)")

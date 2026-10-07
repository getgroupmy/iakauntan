# Mutants for app.chat_can_join (0139) -- a company may enter a room
# only if it is linked to EVERY company already in it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0139_group_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_can_join.py
#
# RESULT: 3 mutants and a control, all killed by `chat.sql` as it
# stood.

m("anybody can join any room",
  "chat_can_join",
  "  select not exists (\n",
  "  select true or not exists (  -- open door\n",
  "-- open door")

m("one link in the room is enough",
  "chat_can_join",
  "     where not app.chat_orgs_linked(p_org_id, existing.org_id));",
  "     where not app.chat_orgs_linked(p_org_id, existing.org_id)\n       and false);  -- one is enough",
  "-- one is enough")

m("the companies in every room are counted",
  "chat_can_join",
  "             where p.conversation_id = p_conversation_id) existing",
  "             where true) existing  -- every room",
  "-- every room")

m("CONTROL: a comment inside the block",
  "chat_can_join",
  "  select not exists (\n",
  "  select not exists (  -- (control)\n",
  "(control)")

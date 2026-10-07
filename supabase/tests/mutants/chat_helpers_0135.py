# Mutants for app.chat_orgs_linked and app.chat_participant_org (0135)
# -- whether two companies may talk, and which company somebody speaks
# for in a conversation.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0135_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_helpers_0135.py
#
# RESULT: 6 mutants and a control, all killed by `chat.sql`. One only
# after the "Which company somebody speaks for" block there: nobody in
# the file was in two conversations for two different companies, so
# `chat_participant_org` with the conversation dropped still answered
# right.

m("a company is not linked to itself",
  "chat_orgs_linked",
  "  select p_org_a = p_org_b\n",
  "  select false  -- not even itself\n",
  "-- not even itself")

m("a link asked for and not answered counts",
  "chat_orgs_linked",
  "            where l.status = 'approved'\n",
  "            where l.status in ('approved', 'pending')  -- unanswered\n",
  "-- unanswered")

m("a refused or ended link counts",
  "chat_orgs_linked",
  "            where l.status = 'approved'\n",
  "            where true  -- any answer\n",
  "-- any answer")

m("any approved link links everybody",
  "chat_orgs_linked",
  "              and l.org_a = least(p_org_a, p_org_b)\n",
  "              and true  -- anybody's link\n",
  "-- anybody's link")

m("the companies are looked up only one way round",
  "chat_orgs_linked",
  "              and l.org_a = least(p_org_a, p_org_b)\n              and l.org_b = greatest(p_org_a, p_org_b));",
  "              and l.org_a = p_org_a\n              and l.org_b = p_org_b);  -- one way",
  "-- one way")

m("somebody speaks for whichever company was found first",
  "chat_participant_org",
  "   where p.conversation_id = p_conversation_id and p.user_id = p_user_id;",
  "   where p.user_id = p_user_id limit 1;  -- any conversation",
  "-- any conversation")

m("CONTROL: a comment inside the block",
  "chat_orgs_linked",
  "            where l.status = 'approved'\n",
  "            where l.status = 'approved'  -- (control)\n",
  "(control)")

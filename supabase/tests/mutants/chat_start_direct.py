# Mutants for public.chat_start_direct (0757, restating 0135's) -- a one-to-one
# conversation: both people switched on for chat in the companies they
# speak for, those companies linked, and the same pair always finding
# the same conversation.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0757_a_conversation_with_yourself_is_refused_in_any_company.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_start_direct.py
#
# RESULT: 13 mutants and a control. 12 killed by `chat.sql`, eight only
# after a rule-by-rule block there: every pair had been two switched-on
# people in linked companies with no other conversation between them.
# The sweep against 0135 found that yourself under your OTHER company
# passed the self check and failed on `chat_participants`' primary key
# with a raw error -- asked on 7 October, answered "refuse it plainly";
# 0757. Its mutant is the twelfth killed.
#
# One EQUIVALENT:
#
#   a conversation with more people   no direct conversation has more
#   is reused                         than two: `chat_add_participant`
#                                     refuses a third person on one, and
#                                     a client cannot insert participants.

m("nobody signed in starts a conversation",
  "chat_start_direct",
  "  if v_me is null then",
  "  if false then  -- anonymous",
  "-- anonymous")

m("a conversation with oneself is started",
  "chat_start_direct",
  "  if v_me = p_other_user then",
  "  if false then  -- talking to myself",
  "-- talking to myself")

m("oneself in another company is somebody else (0135's shape)",
  "chat_start_direct",
  "  if v_me = p_other_user then",
  "  if v_me = p_other_user and p_my_org = p_other_org then  -- same company only",
  "-- same company only")

m("somebody without chat starts one",
  "chat_start_direct",
  "  if not app.chat_enabled(p_my_org, v_me) then",
  "  if false then  -- switched off",
  "-- switched off")

m("somebody without chat is talked to",
  "chat_start_direct",
  "  if not app.chat_enabled(p_other_org, p_other_user) then",
  "  if false then  -- switched off",
  "-- switched off")

m("unlinked companies talk",
  "chat_start_direct",
  "  if not app.chat_orgs_linked(p_my_org, p_other_org) then",
  "  if false then  -- unlinked",
  "-- unlinked")

m("a group is taken for the pair's conversation",
  "chat_start_direct",
  "   where c.is_direct\n",
  "   where true  -- groups too\n",
  "-- groups too")

m("a conversation I speak in for another company is reused",
  "chat_start_direct",
  "                  where p.conversation_id = c.id and p.user_id = v_me\n                    and p.org_id = p_my_org)",
  "                  where p.conversation_id = c.id and p.user_id = v_me)  -- any company",
  "-- any company")

m("a conversation with somebody else is reused",
  "chat_start_direct",
  "                  where p.conversation_id = c.id and p.user_id = p_other_user\n                    and p.org_id = p_other_org)",
  "                  where p.conversation_id = c.id)  -- anybody",
  "-- anybody")

m("a conversation with more people is reused",
  "chat_start_direct",
  "           where p.conversation_id = c.id) = 2",
  "           where p.conversation_id = c.id) >= 2  -- a crowd will do",
  "-- a crowd will do")

m("every press starts a new conversation",
  "chat_start_direct",
  "  if v_id is not null then\n    return v_id;\n  end if;",
  "  if false then  -- always new\n    return v_id;\n  end if;",
  "-- always new")

m("the other person is filed under my company",
  "chat_start_direct",
  "  values (v_id, v_me, p_my_org), (v_id, p_other_user, p_other_org);",
  "  values (v_id, v_me, p_my_org), (v_id, p_other_user, p_my_org);  -- mine",
  "-- mine")

m("CONTROL: a comment inside the block",
  "chat_start_direct",
  "  if v_me is null then",
  "  if v_me is null then  -- (control)",
  "(control)")

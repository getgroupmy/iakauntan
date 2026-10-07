# Mutants for app.chat_enabled (0758, restating 0135's) -- the gate under
# every chat permission: the company has the module, the person is
# switched on, and they are an active member of an open company with an
# open account.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0758_a_suspended_member_is_out_of_the_chat_too.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_enabled.py
#
# RESULT: 10 mutants and a control, all killed by `chat.sql`. Against
# 0135's shape, a suspended member, a closed company and a closed
# account all had chat (0758). Three more survived the first sweep
# against 0758: the module gate -- switched off, expired, another
# company's -- had never been asserted, though `chat.sql`'s header calls
# it the first of three. A membership in a SECOND company also survived
# until the suspended member was given one, so that being suspended
# here is the only thing that can say no.

m("a company without the module has chat",
  "chat_enabled",
  "            where m.org_id = p_org_id and m.module_code = 'chat'\n",
  "            where m.org_id = m.org_id and m.module_code = 'chat'  -- any company\n",
  "-- any company")

m("a module switched off still counts",
  "chat_enabled",
  "              and m.is_enabled\n",
  "              and true  -- switched off\n",
  "-- switched off")

m("an expired module still counts",
  "chat_enabled",
  "              and (m.expires_at is null or m.expires_at > now()))",
  "              and true)  -- expired",
  "-- expired")

m("somebody switched off still has chat",
  "chat_enabled",
  "              and a.is_enabled)",
  "              and true)  -- not switched on",
  "-- not switched on")

m("anybody's switch counts for everybody",
  "chat_enabled",
  "            where a.org_id = p_org_id and a.user_id = p_user_id\n",
  "            where a.org_id = p_org_id  -- anybody's switch\n",
  "-- anybody's switch")

m("a suspended member has chat (0135's shape)",
  "chat_enabled",
  "              and om.status = 'active'\n",
  "              and true  -- suspended\n",
  "-- suspended")

m("a closed company has chat",
  "chat_enabled",
  "              and o.deleted_at is null\n",
  "              and true  -- closed company\n",
  "-- closed company")

m("a closed account has chat",
  "chat_enabled",
  "                                 and p.deleted_at is not null));",
  "                                 and false));  -- closed account",
  "-- closed account")

m("somebody else's account closing shuts you out",
  "chat_enabled",
  "                               where p.id = om.user_id\n",
  "                               where true  -- anybody's account\n",
  "-- anybody's account")

m("a membership elsewhere counts here",
  "chat_enabled",
  "            where om.org_id = p_org_id and om.user_id = p_user_id\n",
  "            where om.user_id = p_user_id  -- elsewhere\n",
  "-- elsewhere")

m("CONTROL: a comment inside the block",
  "chat_enabled",
  "              and om.status = 'active'\n",
  "              and om.status = 'active'  -- (control)\n",
  "(control)")

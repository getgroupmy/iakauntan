# Mutants for public.chat_links_for and chat_access_list (0135) -- a
# company's links, and the switchboard of who has chat.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0135_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_readers_0135.py
#
# RESULT: 10 mutants and a control, all killed by `chat.sql`. Two only
# after the "Who is listed, and to whom" block there: an invitation
# nobody accepted on the switchboard, and somebody switched off reading
# as on.

m("a link names this company as the other one",
  "chat_links_for",
  "         case when l.org_a = p_org_id then l.org_b else l.org_a end,\n         o.name,",
  "         p_org_id,  -- itself\n         o.name,",
  "-- itself")

m("whoever asked is told they may answer",
  "chat_links_for",
  "         l.status = 'pending' and l.requested_by_org <> p_org_id,",
  "         l.status = 'pending',  -- answer own",
  "-- answer own")

m("an answered link still asks for an answer",
  "chat_links_for",
  "         l.status = 'pending' and l.requested_by_org <> p_org_id,",
  "         l.requested_by_org <> p_org_id,  -- still asking",
  "-- still asking")

m("whoever asked is not told so",
  "chat_links_for",
  "         l.requested_by_org = p_org_id,",
  "         false,  -- not mine",
  "-- not mine")

m("every company's links are listed",
  "chat_links_for",
  "   where (l.org_a = p_org_id or l.org_b = p_org_id)\n",
  "   where true  -- everybody's\n",
  "-- everybody's")

m("a stranger reads a company's links",
  "chat_links_for",
  "     and app.is_org_member(p_org_id)\n",
  "     and true  -- stranger\n",
  "-- stranger")

m("the switchboard lists another company's staff",
  "chat_access_list",
  "   where om.org_id = p_org_id\n",
  "   where true  -- everybody\n",
  "-- everybody")

m("the switchboard lists invitations nobody accepted",
  "chat_access_list",
  "     and om.user_id is not null\n",
  "     and true  -- invited\n",
  "-- invited")

m("anybody reads the switchboard",
  "chat_access_list",
  "     and (app.can_admin(p_org_id) or app.is_platform_admin())\n",
  "     and true  -- anybody\n",
  "-- anybody")

m("everybody reads as switched on",
  "chat_access_list",
  "         coalesce(a.is_enabled, false)\n",
  "         true  -- all on\n",
  "-- all on")

m("CONTROL: a comment inside the block",
  "chat_access_list",
  "     and om.user_id is not null\n",
  "     and om.user_id is not null  -- (control)\n",
  "(control)")

# Mutants for public.reply_to_shared_ticket (0390) -- a customer's reply
# through a ticket's share link, with no login: only on an open link;
# nothing written for an empty body; written trimmed, visible, as the
# requester, on the web; recorded as an event; a ticket waiting on the
# customer or finished comes back to the company; the link counts it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0390_the_customer_who_could_not_reply.sql \
#       supabase/tests/ticket_share.sql \
#       supabase/tests/mutants/reply_to_shared_ticket.py
#
# RESULT: 16 mutants and a control, all 16 killed by `ticket_share.sql`,
# from 8: the channel, the event and the 200 characters of the reply it
# keeps, a ticket on hold and one resolved coming back, the reason the
# reopening gives, the link's count of replies, and the id handed back
# -- each only after the file's rule-by-rule block.

F = "reply_to_shared_ticket"

m("a closed link takes a reply", F,
  "  if v_state <> 'open' then\n    return jsonb_build_object('state', coalesce(v_state, 'invalid'));",
  "  if false then  -- any link\n    return jsonb_build_object('state', coalesce(v_state, 'invalid'));",
  "-- any link")
m("the link's state is not said", F,
  "    return jsonb_build_object('state', coalesce(v_state, 'invalid'));",
  "    return jsonb_build_object('state', 'invalid');  -- unsaid",
  "-- unsaid")
m("an empty reply is written", F,
  "  if btrim(coalesce(p_body, '')) = '' then",
  "  if false then  -- empty written",
  "-- empty written")
m("the reply is kept untrimmed", F,
  "  values (t.org_id, t.id, btrim(p_body),",
  "  values (t.org_id, t.id, p_body,  -- untrimmed",
  "-- untrimmed")
m("the reply is an internal note", F,
  "          false,\n          t.requester_contact_id, 'web')",
  "          true,  -- internal\n          t.requester_contact_id, 'web')",
  "-- internal")
m("the reply is nobody's", F,
  "          t.requester_contact_id, 'web')",
  "          null, 'web')  -- nobody's",
  "-- nobody's")
m("the reply came by email", F,
  "          t.requester_contact_id, 'web')",
  "          t.requester_contact_id, 'email')  -- by email",
  "-- by email")
m("no event is recorded", F,
  "  values (t.org_id, t.id, 'requester_reply', left(btrim(p_body), 200));",
  "  select t.org_id, t.id, 'requester_reply', left(btrim(p_body), 200) where false;  -- no event",
  "-- no event")
m("the event keeps the whole reply", F,
  "  values (t.org_id, t.id, 'requester_reply', left(btrim(p_body), 200));",
  "  values (t.org_id, t.id, 'requester_reply', btrim(p_body));  -- whole",
  "-- whole")
m("a pending ticket stays pending", F,
  "  if t.status in ('pending', 'on_hold', 'resolved', 'closed') then",
  "  if t.status in ('on_hold', 'resolved', 'closed') then  -- pending stays",
  "-- pending stays")
m("a ticket on hold stays on hold", F,
  "  if t.status in ('pending', 'on_hold', 'resolved', 'closed') then",
  "  if t.status in ('pending', 'resolved', 'closed') then  -- hold stays",
  "-- hold stays")
m("a resolved ticket stays resolved", F,
  "  if t.status in ('pending', 'on_hold', 'resolved', 'closed') then",
  "  if t.status in ('pending', 'on_hold', 'closed') then  -- resolved stays",
  "-- resolved stays")
m("a closed ticket stays closed", F,
  "  if t.status in ('pending', 'on_hold', 'resolved', 'closed') then",
  "  if t.status in ('pending', 'on_hold', 'resolved') then  -- closed stays",
  "-- closed stays")
m("the reopening gives no reason", F,
  "      'Reopened by the requester');",
  "      null);  -- no reason",
  "-- no reason")
m("the link does not count replies", F,
  "     set reply_count = reply_count + 1 where id = l.id;",
  "     set reply_count = reply_count where id = l.id;  -- uncounted",
  "-- uncounted")
m("the reply's id is not handed back", F,
  "  return jsonb_build_object('state', 'open', 'comment_id', v_id);",
  "  return jsonb_build_object('state', 'open');  -- no id",
  "-- no id")

m("CONTROL", F,
  "  v_id uuid;\nbegin",
  "  v_id uuid;  -- control\nbegin",
  "-- control")

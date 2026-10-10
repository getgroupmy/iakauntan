# Mutants for app.ticket_link_state (0799, from 0390) -- the state of a
# ticket's share link, which open_shared_ticket and
# reply_to_shared_ticket both obey: invalid, revoked, expired, withdrawn
# (the ticket gone, cancelled or deleted), or open.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0799_a_deleted_ticket_is_withdrawn.sql \
#       supabase/tests/ticket_share.sql \
#       supabase/tests/mutants/ticket_link_state.py
#
# RESULT: 6 mutants and a control, all 6 killed by `ticket_share.sql`,
# the deleted ticket by `0799`'s own block. The function is executable
# by its owner alone, so there is no grant to take away by hand.

F = "ticket_link_state"

m("a token nobody issued is a link", F,
  "    link_id := null; state := 'invalid'; return;",
  "    link_id := null; state := 'open'; return;  -- uninvited",
  "-- uninvited")
m("a revoked link opens", F,
  "    when l.revoked_at is not null then 'revoked'",
  "    when false then 'revoked'  -- revoked opens",
  "-- revoked opens")
m("an expired link opens", F,
  "    when l.expires_at < now() then 'expired'",
  "    when false then 'expired'  -- expired opens",
  "-- expired opens")
m("a deleted ticket's link opens", F,
  "    when t.id is null or t.deleted_at is not null then 'withdrawn'",
  "    when t.id is null then 'withdrawn'  -- deleted opens",
  "-- deleted opens")
m("a cancelled ticket's link opens", F,
  "    when t.status = 'cancelled' then 'withdrawn'",
  "    when false then 'withdrawn'  -- cancelled opens",
  "-- cancelled opens")
m("the link is not named", F,
  "  link_id := l.id;",
  "  link_id := null;  -- unnamed",
  "-- unnamed")

m("CONTROL", F,
  "  t public.tickets;\nbegin",
  "  t public.tickets;  -- control\nbegin",
  "-- control")

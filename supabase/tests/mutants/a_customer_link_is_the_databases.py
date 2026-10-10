# Mutants for app.customer_link_is_the_databases (0794) -- on the
# customer portal, tax-details and ticket share links, a client's own
# statement may change only the address a link went to and a live
# link's revocation; a revoked link stays revoked; the functions pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0794_a_customer_link_is_the_databases.sql \
#       supabase/tests/customer_link_evidence.sql \
#       supabase/tests/mutants/a_customer_link_is_the_databases.py
#
# RESULT: 9 mutants and a control, all 9 killed by
# `customer_link_evidence.sql`, new in `0794`. The file asks every
# column of the three tables from the catalogue (more than thirty), so
# the mutants here are about which columns the guard lets through, not
# one per column.
#
# SECURITY DEFINER flipped by hand: the file fails on its first refusal
# ("it was not refused at all"); restored, it passes.

F = "customer_link_is_the_databases"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("a client's own statement passes at depth one", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")
m("no column is asked", F,
  "    if (v_new -> v_col) is distinct from (v_old -> v_col) then",
  "    if false then  -- no column asked",
  "-- no column asked")
m("the opening record is the company's too", F,
  "    continue when v_col in ('sent_to_email', 'revoked_at');",
  "    continue when v_col in ('sent_to_email', 'revoked_at', 'opened_at', 'open_count');  -- openings free",
  "-- openings free")
m("whom it points at is the company's too", F,
  "    continue when v_col in ('sent_to_email', 'revoked_at');",
  "    continue when v_col in ('sent_to_email', 'revoked_at', 'contact_id', 'ticket_id');  -- target free",
  "-- target free")
m("the expiry is the company's too", F,
  "    continue when v_col in ('sent_to_email', 'revoked_at');",
  "    continue when v_col in ('sent_to_email', 'revoked_at', 'expires_at');  -- expiry free",
  "-- expiry free")
m("the address is the database's", F,
  "    continue when v_col in ('sent_to_email', 'revoked_at');",
  "    continue when v_col in ('revoked_at');  -- address guarded",
  "-- address guarded")
m("a revoked link may come back", F,
  "  if old.revoked_at is not null\n     and new.revoked_at is distinct from old.revoked_at then",
  "  if false then  -- revivable",
  "-- revivable")
m("a live link cannot be revoked by hand", F,
  "  if old.revoked_at is not null\n     and new.revoked_at is distinct from old.revoked_at then",
  "  if new.revoked_at is distinct from old.revoked_at then  -- no revoking",
  "-- no revoking")
m("CONTROL", F,
  "  v_new  jsonb;\nbegin",
  "  v_new  jsonb;  -- control\nbegin",
  "-- control")

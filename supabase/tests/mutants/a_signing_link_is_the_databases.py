# Mutants for app.signing_link_is_the_databases (0792) -- a client's own
# statement cannot issue a signing link, write its signature, token,
# expiry, use, opening record, author or issue time, bring a retired
# link back, or delete one that was opened or used; retiring a live
# link and correcting its address stay allowed, and the link functions
# pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0792_a_signing_link_is_the_databases.sql \
#       supabase/tests/signature_evidence.sql \
#       supabase/tests/mutants/a_signing_link_is_the_databases.py
#
# RESULT: 16 mutants and a control, all 16 killed by
# `signature_evidence.sql`'s links section, new in `0792`. (Moving a
# link to another company is also refused by the table's own policy --
# this member may not write for the other company -- but in other
# words; the assertion reads the guard's, so removing the guard is
# still told apart.)
#
# SECURITY DEFINER flipped by hand: the file fails on its first
# refusal ("it was not refused at all"); restored, it passes.

F = "signing_link_is_the_databases"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")

m("a client's own statement passes at depth one", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")

m("a link may be issued by hand", F,
  "  if tg_op = 'INSERT' then\n    raise exception\n      'Signing links are issued",
  "  if false then  -- hand issued\n    raise exception\n      'Signing links are issued",
  "-- hand issued")

m("a used link may be deleted", F,
  "    if old.used_at is not null or old.opened_at is not null then",
  "    if old.opened_at is not null then  -- used deletable",
  "-- used deletable")

m("an opened link may be deleted", F,
  "    if old.used_at is not null or old.opened_at is not null then",
  "    if old.used_at is not null then  -- opened deletable",
  "-- opened deletable")

for col in ["org_id", "signature_id", "token_hash", "expires_at", "used_at",
            "opened_at", "ip_address", "user_agent", "created_by"]:
    m("a link's %s is writable" % col, F,
      "'%s'," % col,
      "'no_%s',  -- %s free\n      " % (col, col),
      "-- %s free" % col)
m("a link's created_at is writable", F,
  "'created_at'] loop",
  "'no_created_at'] loop  -- created_at free",
  "-- created_at free")

m("a retired link may come back", F,
  "  if old.revoked_at is not null\n     and new.revoked_at is distinct from old.revoked_at then",
  "  if false then  -- revivable",
  "-- revivable")

m("CONTROL", F,
  "  v_what text;",
  "  v_what text;  -- control",
  "-- control")

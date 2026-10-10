# Mutants for app.share_link_is_the_databases (0793) -- a client's own
# statement cannot write a share link's document, token, expiry, opened
# record, author or issue time, or bring a revoked link back; revoking
# a live link and correcting its address stay allowed, and the share
# functions pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0793_a_share_link_is_the_databases.sql \
#       supabase/tests/document_share.sql \
#       supabase/tests/mutants/a_share_link_is_the_databases.py
#
# RESULT: 14 mutants and a control, all 14 killed by
# `document_share.sql`'s share-link section, new in `0793`.
#
# SECURITY DEFINER flipped by hand: the file fails on its first refusal
# ("it was not refused at all"); restored, it passes.

F = "share_link_is_the_databases"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("a client's own statement passes at depth one", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")
for col in ["org_id", "document_id", "token_hash", "expires_at", "opened_at",
            "last_opened_at", "open_count", "ip_address", "user_agent",
            "created_by"]:
    m("a link's %s is writable" % col, F,
      "'%s'," % col,
      "'no_%s',  -- %s free\n      " % (col, col),
      "-- %s free" % col)
m("a link's created_at is writable", F,
  "'created_at'] loop",
  "'no_created_at'] loop  -- created_at free",
  "-- created_at free")
m("a revoked link may come back", F,
  "  if old.revoked_at is not null\n     and new.revoked_at is distinct from old.revoked_at then",
  "  if false then  -- revivable",
  "-- revivable")
m("CONTROL", F,
  "  v_what text;",
  "  v_what text;  -- control",
  "-- control")

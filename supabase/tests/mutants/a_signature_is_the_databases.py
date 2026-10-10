# Mutants for app.signature_evidence_is_the_databases (0791) -- a
# client's own statement cannot write a signature's evidence, insert
# anything but a pending line, delete an answered line, raise a request
# by hand, rewrite a request's text hash or withdrawal, or delete a
# request somebody has answered; the signing functions pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0791_a_signature_is_the_databases.sql \
#       supabase/tests/signature_evidence.sql \
#       supabase/tests/mutants/a_signature_is_the_databases.py
#
# RESULT: 24 mutants and a control, all 24 killed by
# `signature_evidence.sql`, new in `0791` -- after one more assertion:
# the first insert of a signed line also carried a name and a time, so
# the status condition could go and the others still refused it. A
# line inserted 'signed' with nothing else filled in is asked now.
#
# SECURITY DEFINER flipped by hand, because the harness mutates the
# body only: as a definer `current_user` is always the owner, nothing
# is refused, and the file fails on its first refusal ("it was not
# refused at all"). Restored, it passes.

F = "signature_evidence_is_the_databases"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")

m("the depth lets functions' inner writes through only at depth 2+", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")

m("a signed line may be inserted", F,
  "      if new.status is distinct from 'pending'\n",
  "      if false  -- any status inserted\n",
  "-- any status inserted")

m("an answered line may be deleted", F,
  "      if old.status <> 'pending' then\n        raise exception\n          'A line that has been % is the record",
  "      if false then  -- deletable\n        raise exception\n          'A line that has been % is the record",
  "-- deletable")

for col in ["request_id", "person_id", "status", "signed_at", "signed_name",
            "decline_reason", "body_sha256_at_signing", "ip_address",
            "user_agent"]:
    m("a line's %s is writable" % col, F,
      "'%s'," % col,
      "'no_%s',  -- %s free\n        " % (col, col),
      "-- %s free" % col)
m("a line's signed_by is writable", F,
  "'signed_by'] loop",
  "'no_signed_by'] loop  -- signed_by free",
  "-- signed_by free")

m("a signed line's capacity is writable", F,
  "    if old.status <> 'pending'\n       and new.capacity is distinct from old.capacity then",
  "    if false then  -- capacity free",
  "-- capacity free")

m("a request may be raised by hand", F,
  "  if tg_op = 'INSERT' then\n    raise exception\n      'Signatures are requested",
  "  if false then  -- hand raised\n    raise exception\n      'Signatures are requested",
  "-- hand raised")

m("an answered request may be deleted", F,
  "                where s.request_id = old.id and s.status <> 'pending') then",
  "                where false) then  -- request deletable",
  "-- request deletable")

for col in ["document_id", "body_sha256", "requested_by", "requested_at",
            "is_withdrawn"]:
    m("a request's %s is writable" % col, F,
      "'%s'," % col,
      "'no_%s',  -- %s free\n      " % (col, col),
      "-- %s free" % col)
m("a request's withdrawn_at is writable", F,
  "'withdrawn_at'] loop",
  "'no_withdrawn_at'] loop  -- withdrawn_at free",
  "-- withdrawn_at free")

m("CONTROL", F,
  "  v_what text;",
  "  v_what text;  -- control",
  "-- control")

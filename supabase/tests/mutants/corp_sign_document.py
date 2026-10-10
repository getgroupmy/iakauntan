# Mutants for public.corp_sign_document (0069) -- a signature taken at
# the desk: the line must exist, the caller may write for the company,
# the line is still pending and its request not withdrawn, a name is
# typed, and the text is the one circulated; the database then writes
# the evidence itself -- when, the name as typed less its spaces, the
# text's hash, the address, the browser and whose login it was.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0069_document_signatures.sql \
#       supabase/tests/secretarial.sql \
#       supabase/tests/mutants/corp_sign_document.py
#
# RESULT: 14 mutants and a control, all 14 killed by `secretarial.sql`;
# before its assertions, 6 -- signed twice, an empty or spaced name, a
# changed text, the status, the hash. The evidence itself had nothing
# asking: the time, the name less its spaces, the address, the browser
# and the login were never read back, nor a missing line, a stranger,
# or a withdrawn request (reached as the owner -- since `0791` nothing
# a client can call withdraws one).
#
# Found here: `0791`. Reading what this function writes led to the
# tables' policies, which let a client write all of it directly.

F = "corp_sign_document"

m("a line that does not exist is not refused in words", F,
  "  if s.id is null then\n    raise exception 'Signature not found'",
  "  if false then  -- not found\n    raise exception 'Signature not found'",
  "-- not found")

m("anybody may sign", F,
  "  if not app.can_write(s.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a line already signed is signed again", F,
  "  if s.status <> 'pending' then",
  "  if false then  -- any status",
  "-- any status")

m("an empty name is a signature", F,
  "  if coalesce(btrim(p_signed_name), '') = '' then",
  "  if false then  -- no name",
  "-- no name")

m("spaces are a name", F,
  "  if coalesce(btrim(p_signed_name), '') = '' then",
  "  if coalesce(p_signed_name, '') = '' then  -- spaces",
  "-- spaces")

m("a withdrawn request is signed", F,
  "  if r.is_withdrawn then",
  "  if false then  -- withdrawn signed",
  "-- withdrawn signed")

m("a changed text is signed", F,
  "  if v_now_hash <> r.body_sha256 then",
  "  if false then  -- changed signed",
  "-- changed signed")

m("the line is not marked signed", F,
  "     set status = 'signed',",
  "     set status = s.status,  -- still pending",
  "-- still pending")

m("no time is recorded", F,
  "         signed_at = now(),",
  "         signed_at = null,  -- no time",
  "-- no time")

m("the name is kept with its spaces", F,
  "         signed_name = btrim(p_signed_name),",
  "         signed_name = p_signed_name,  -- untrimmed",
  "-- untrimmed")

m("the text's hash is not recorded", F,
  "         body_sha256_at_signing = v_now_hash,",
  "         body_sha256_at_signing = null,  -- no hash",
  "-- no hash")

m("no address is recorded", F,
  "         ip_address = nullif(split_part(coalesce(\n           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,",
  "         ip_address = null,  -- no address",
  "-- no address")

m("no browser is recorded", F,
  "         user_agent = app.request_header('user-agent'),",
  "         user_agent = null,  -- no browser",
  "-- no browser")

m("whose login it was is not recorded", F,
  "         signed_by = auth.uid()",
  "         signed_by = null  -- nobody",
  "-- nobody")

m("CONTROL", F,
  "  select * into d from public.corp_documents where id = r.document_id;",
  "  select * into d from public.corp_documents where id = r.document_id;  -- control",
  "-- control")

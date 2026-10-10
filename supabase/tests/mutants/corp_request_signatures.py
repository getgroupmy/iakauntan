# Mutants for public.corp_request_signatures (0069) -- circulating a
# document for signature: it must exist, the caller may write for the
# company, somebody is asked; the text's hash is fixed as it stands,
# with who asked; raised again, the request takes the CURRENT text's
# hash, its new due date and note, and is no longer withdrawn; each
# person is asked once, in the capacity given.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0069_document_signatures.sql \
#       supabase/tests/secretarial.sql \
#       supabase/tests/mutants/corp_request_signatures.py
#
# RESULT: 10 mutants and a control, all 10 killed by `secretarial.sql`;
# before its assertions, 1 -- the text's hash. The first run reported
# three more killed that were not: the replacements for the re-raise
# wrote a bare column name inside `on conflict do update`, which is
# ambiguous, so the function failed on every call. Qualified with the
# table name they ran for real and survived, and raising a request
# again -- the only road back since `0791`, nothing withdraws one -- is
# now asserted end to end: open again, the current text's hash, the
# new date and note, nobody asked twice.

F = "corp_request_signatures"

m("a document that does not exist is not refused in words", F,
  "  if d.id is null then\n    raise exception 'Document not found'",
  "  if false then  -- not found\n    raise exception 'Document not found'",
  "-- not found")

m("anybody may circulate a document", F,
  "  if not app.can_write(d.org_id) then\n    raise exception 'Not permitted to request signatures'",
  "  if false then  -- anybody\n    raise exception 'Not permitted to request signatures'",
  "-- anybody")

m("nobody is asked", F,
  "  if coalesce(array_length(p_person_ids, 1), 0) = 0 then",
  "  if false then  -- nobody asked",
  "-- nobody asked")

m("the text's hash is not the text's", F,
  "  values (d.org_id, d.id, app.corp_body_hash(d.body), auth.uid(), p_due_on, p_note)",
  "  values (d.org_id, d.id, app.corp_body_hash(d.body || 'x'), auth.uid(), p_due_on, p_note)  -- wrong hash",
  "-- wrong hash")

m("nobody is recorded as asking", F,
  "  values (d.org_id, d.id, app.corp_body_hash(d.body), auth.uid(), p_due_on, p_note)",
  "  values (d.org_id, d.id, app.corp_body_hash(d.body), null, p_due_on, p_note)  -- nobody asked it",
  "-- nobody asked it")

m("raised again, the old hash stays", F,
  "    set body_sha256 = app.corp_body_hash(d.body),\n        due_on",
  "    set body_sha256 = corp_signature_requests.body_sha256,  -- old hash\n        due_on",
  "-- old hash")

m("raised again, the dates stay", F,
  "        due_on = excluded.due_on, note = excluded.note,",
  "        due_on = corp_signature_requests.due_on, note = corp_signature_requests.note,  -- old dates",
  "-- old dates")

m("raised again, it stays withdrawn", F,
  "        is_withdrawn = false, withdrawn_at = null",
  "        is_withdrawn = corp_signature_requests.is_withdrawn, withdrawn_at = corp_signature_requests.withdrawn_at  -- still withdrawn",
  "-- still withdrawn")

m("the capacity is dropped", F,
  "            case when p_capacities is null then null else p_capacities[i] end)",
  "            null)  -- no capacity",
  "-- no capacity")

m("a person already asked is asked again", F,
  "    on conflict (request_id, person_id) do nothing;",
  "    ;  -- asked twice",
  "-- asked twice")

m("CONTROL", F,
  "  v_id uuid;\n  i integer;",
  "  v_id uuid;  -- control\n  i integer;",
  "-- control")

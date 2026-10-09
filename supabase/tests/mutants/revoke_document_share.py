# Mutants for public.revoke_document_share (0094) -- somebody who may
# write in the document's company shuts every live share link on that
# one document, and says how many; a document that does not exist is
# said so.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0094_document_share_links.sql \
#       supabase/tests/document_share.sql \
#       supabase/tests/mutants/revoke_document_share.py
#
# RESULT: 5 mutants and a control, all killed by `document_share.sql`;
# two before its rule-by-rule block. The one revoke in the file was the
# owner's, on the one document: "anybody revokes" survived -- a
# stranger shutting a company's share links was never tried -- as did
# shutting every document's links, and a document that does not exist.

F = "revoke_document_share"

m("a document that does not exist is not said so", F,
  "  if v_org is null then\n    raise exception 'Document not found'",
  "  if false then  -- any document\n    raise exception 'Document not found'",
  "-- any document")

m("anybody revokes", F,
  "  if not app.can_write(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("every document's links are shut", F,
  "   where document_id = p_document_id and revoked_at is null;",
  "   where revoked_at is null and document_id is not null;  -- every document",
  "-- every document")

m("a link already shut is shut again", F,
  "   where document_id = p_document_id and revoked_at is null;",
  "   where document_id = p_document_id;  -- again",
  "-- again")

m("it says nothing was shut", F,
  "  return v_n;",
  "  return 0;  -- nothing",
  "-- nothing")

m("CONTROL: a comment inside the block", F,
  "  return v_n;",
  "  return v_n;  -- (control)",
  "(control)")

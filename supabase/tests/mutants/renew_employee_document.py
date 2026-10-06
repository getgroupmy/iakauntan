# Mutants for public.renew_employee_document (0388) -- a permit, passport
# or licence replaced by its renewal: once, running past the old one,
# and carrying what was not restated.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0388_the_permit_that_expired_and_nobody_was_looking.sql \
#       supabase/tests/employee_documents.sql \
#       supabase/tests/mutants/renew_employee_document.py
#
# RESULT: 16 mutants and a control. 15 killed by
# `employee_documents.sql`, five only after a rule-by-rule block there:
# every renewal had restated only the expiry, of a document that had
# one, in a file with no other renewal -- so a new title or issue date,
# a blank title, another document's renewal and the same expiry again
# were all unasserted.
#
# One EQUIVALENT:
#
#   a document with no expiry cannot  with the old expiry null,
#   be renewed                        `p_expires_date <= null` is null and
#                                     IF reads null as false, so the
#                                     `is not null` changes no answer.
#                                     The block asserts the behaviour it
#                                     is there for: such a document can
#                                     be renewed.

m("a missing document is renewed in silence",
  "renew_employee_document",
  "  if v_old.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody renews",
  "renew_employee_document",
  "  if not app.can_manage_hr(v_old.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a document is renewed twice",
  "renew_employee_document",
  "  if exists (select 1 from public.employee_documents\n              where supersedes_id = p_document) then",
  "  if false then  -- again",
  "-- again")

m("any renewal anywhere blocks this one",
  "renew_employee_document",
  "              where supersedes_id = p_document) then",
  "              where supersedes_id is not null) then  -- any",
  "-- any")

m("a renewal needs no expiry",
  "renew_employee_document",
  "  if p_expires_date is null then",
  "  if false then  -- open-ended",
  "-- open-ended")

m("a renewal may run short of the old one",
  "renew_employee_document",
  "  if v_old.expires_date is not null\n     and p_expires_date <= v_old.expires_date then",
  "  if false then  -- shorter",
  "-- shorter")

m("a renewal to the same day is a renewal",
  "renew_employee_document",
  "     and p_expires_date <= v_old.expires_date then",
  "     and p_expires_date < v_old.expires_date then  -- same day",
  "-- same day")

m("a document with no expiry cannot be renewed",
  "renew_employee_document",
  "  if v_old.expires_date is not null\n     and p_expires_date",
  "  if true  -- undated blocks\n     and p_expires_date",
  "-- undated blocks")

m("the renewal is filed under another company",
  "renew_employee_document",
  "  values (v_old.org_id, v_old.employee_id, v_old.doc_type,",
  "  values ((select id from public.organizations limit 1), v_old.employee_id, v_old.doc_type,  -- elsewhere",
  "-- elsewhere")

m("a new title is ignored",
  "renew_employee_document",
  "          coalesce(nullif(btrim(coalesce(p_title, '')), ''), v_old.title),",
  "          v_old.title,  -- old title",
  "-- old title")

m("a blank title replaces the old one",
  "renew_employee_document",
  "          coalesce(nullif(btrim(coalesce(p_title, '')), ''), v_old.title),",
  "          coalesce(p_title, v_old.title),  -- blank wins",
  "-- blank wins")

m("an issue date given is ignored",
  "renew_employee_document",
  "          coalesce(p_issued_date, v_old.expires_date),",
  "          v_old.expires_date,  -- assumed",
  "-- assumed")

m("with no issue date, the renewal has none",
  "renew_employee_document",
  "          coalesce(p_issued_date, v_old.expires_date),",
  "          p_issued_date,  -- undated",
  "-- undated")

m("the new expiry is not kept",
  "renew_employee_document",
  "          p_expires_date,\n          coalesce(nullif(btrim(coalesce(p_notes",
  "          v_old.expires_date,  -- the old one\n          coalesce(nullif(btrim(coalesce(p_notes",
  "-- the old one")

m("the old notes are dropped",
  "renew_employee_document",
  "          coalesce(nullif(btrim(coalesce(p_notes, '')), ''), v_old.notes),",
  "          nullif(btrim(coalesce(p_notes, '')), ''),  -- forgotten",
  "-- forgotten")

m("the renewal does not say what it replaced",
  "renew_employee_document",
  "          p_document)\n  returning id into v_new;",
  "          null)  -- unlinked\n  returning id into v_new;",
  "-- unlinked")

m("CONTROL: a comment inside the block",
  "renew_employee_document",
  "  if p_expires_date is null then",
  "  if p_expires_date is null then  -- (control)",
  "(control)")

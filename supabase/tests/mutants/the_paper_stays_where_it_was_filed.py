# Mutants for 0848 -- app.evidence_stays_as_filed keeps a client off an
# evidence attachment's row, and app.an_evidence_file_stays keeps one
# off its object in the `attachments` bucket.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0848_the_paper_stays_where_it_was_filed.sql \
#       supabase/tests/evidence_stays_filed.sql \
#       supabase/tests/mutants/the_paper_stays_where_it_was_filed.py
#
# RESULT: 17 of 19 killed, the control surviving. The survivors, "a row
# change one trigger down is a client too" and "a file change one
# trigger down is a client too", are equivalent: nothing writes either
# table from inside a trigger as a client -- the test says so beside its
# owner assertion.

# --- the row -------------------------------------------------------------

m('nobody is asked about a row',
  'evidence_stays_as_filed',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- row nobody asked',
  '-- row nobody asked')

m('a row change one trigger down is a client too',
  'evidence_stays_as_filed',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- row any depth',
  '-- row any depth')

m('a statement that changes nothing is a change',
  'evidence_stays_as_filed',
  '  if to_jsonb(new) is distinct from to_jsonb(old)\n',
  '  if true  -- no-op counts\n',
  '-- no-op counts')

m('only what names the file is kept',
  'evidence_stays_as_filed',
  '  if to_jsonb(new) is distinct from to_jsonb(old)\n',
  "  if (to_jsonb(new) - 'kept_at') is distinct from (to_jsonb(old) - 'kept_at')  -- kept_at free\n",
  '-- kept_at free')

m('every row is evidence',
  'evidence_stays_as_filed',
  '     and app.attachment_is_evidence(old.id) then',
  '     and true then  -- all evidence',
  '-- all evidence')

m('no row is evidence',
  'evidence_stays_as_filed',
  '     and app.attachment_is_evidence(old.id) then',
  '     and false then  -- none evidence',
  '-- none evidence')

# --- the file ------------------------------------------------------------

m('nobody is asked about a file',
  'an_evidence_file_stays',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1\n"
  "     or old.bucket_id is distinct from 'attachments' then",
  '  if true then  -- file nobody asked',
  '-- file nobody asked')

m('a file change one trigger down is a client too',
  'an_evidence_file_stays',
  '     or pg_trigger_depth() > 1\n',
  '     or false  -- file any depth\n',
  '-- file any depth')

m('every bucket is the attachments bucket',
  'an_evidence_file_stays',
  "     or old.bucket_id is distinct from 'attachments' then",
  '     or false then  -- every bucket',
  '-- every bucket')

m('no update is let through as harmless',
  'an_evidence_file_stays',
  "  if tg_op = 'UPDATE'\n",
  "  if tg_op = 'DELETE'  -- no harmless update\n",
  '-- no harmless update')

m('a move to another bucket is harmless',
  'an_evidence_file_stays',
  "     and n -> 'bucket_id' is not distinct from o -> 'bucket_id'\n",
  '     and true  -- bucket free\n',
  '-- bucket free')

m('a rename is harmless',
  'an_evidence_file_stays',
  "     and n -> 'name' is not distinct from o -> 'name'\n",
  '     and true  -- name free\n',
  '-- name free')

m('a new version is harmless',
  'an_evidence_file_stays',
  "     and n -> 'version' is not distinct from o -> 'version'\n",
  '     and true  -- version free\n',
  '-- version free')

m('new bytes are harmless',
  'an_evidence_file_stays',
  "     and n -> 'metadata' -> 'eTag' is not distinct from o -> 'metadata' -> 'eTag' then",
  '     and true then  -- etag free',
  '-- etag free')

m('every file is evidence',
  'an_evidence_file_stays',
  '                and app.attachment_is_evidence(a.id)) then',
  '                and true) then  -- every file evidence',
  '-- every file evidence')

m('any evidence anywhere makes this file evidence',
  'an_evidence_file_stays',
  '              where a.storage_path = old.name\n',
  '              where true  -- any path\n',
  '-- any path')

m('a file nothing was built from is kept anyway',
  'an_evidence_file_stays',
  '  return coalesce(new, old);\nend $$;',
  '  return new;  -- delete skipped\nend $$;',
  '-- delete skipped')

m('a file the guard does not ask about is kept anyway',
  'an_evidence_file_stays',
  "     or old.bucket_id is distinct from 'attachments' then\n    return coalesce(new, old);",
  "     or old.bucket_id is distinct from 'attachments' then\n    return new;  -- unasked skipped",
  '-- unasked skipped')

m('CONTROL: a comment inside an_evidence_file_stays',
  'an_evidence_file_stays',
  '  return coalesce(new, old);\nend $$;',
  '  return coalesce(new, old);  -- (control)\nend $$;',
  '(control)')

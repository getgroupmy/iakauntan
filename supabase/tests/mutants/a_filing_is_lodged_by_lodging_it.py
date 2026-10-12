# Mutants for 0838 -- app.a_filing_is_lodged_by_lodging_it refuses a
# client's own statement that changes a filing's status, frozen_at or
# frozen_by, or makes one other than as a draft.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0838_a_filing_is_lodged_by_lodging_it.sql \
#       supabase/tests/fs_filing_workflow_kept.sql \
#       supabase/tests/mutants/a_filing_is_lodged_by_lodging_it.py
#
# RESULT, 12 October: 6 of 7 killed by fs_filing_workflow_kept.sql, the
# control surviving. The survivor, the depth clause, is equivalent:
# fs_freeze, fs_unfreeze and fs_lodge are definers and run as the owner
# at any depth. The file says so beside the owner's assertion. "Signed
# as frozen" survived the first draft of the file, which made a filing
# with a status and with a frozen_at but never with a frozen_by alone;
# it has that case now.

m('nobody is asked',
  'a_filing_is_lodged_by_lodging_it',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'a_filing_is_lodged_by_lodging_it',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('a filing may be made lodged',
  'a_filing_is_lodged_by_lodging_it',
  "    if new.status <> 'draft' or new.frozen_at is not null\n       or new.frozen_by is not null then",
  '    if false then  -- born lodged',
  '-- born lodged')

m('a filing may be made stamped frozen',
  'a_filing_is_lodged_by_lodging_it',
  "    if new.status <> 'draft' or new.frozen_at is not null",
  "    if new.status <> 'draft' or false  -- stamp free",
  '-- stamp free')

m('a filing may be made signed as frozen',
  'a_filing_is_lodged_by_lodging_it',
  '       or new.frozen_by is not null then',
  '       or false then  -- signer free',
  '-- signer free')

m('the status is not among what moves',
  'a_filing_is_lodged_by_lodging_it',
  "  c_workflow constant text[] := array['status', 'frozen_at', 'frozen_by'];",
  "  c_workflow constant text[] := array['frozen_at', 'frozen_by'];  -- status free",
  '-- status free')

m('nothing is compared on an update',
  'a_filing_is_lodged_by_lodging_it',
  '    if v_new -> v_col is distinct from v_old -> v_col then',
  '    if false then  -- never compared',
  '-- never compared')

m('CONTROL: a comment inside a_filing_is_lodged_by_lodging_it',
  'a_filing_is_lodged_by_lodging_it',
  '  return new;\nend $$;',
  '  return new;  -- (control)\nend $$;',
  '(control)')

# Mutants for 0910 -- the import tags on the tables an import reaches
# are written by the importers alone.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0910_only_an_import_tags_a_row.sql \
#       supabase/tests/only_an_import_tags_a_row.sql \
#       supabase/tests/mutants/only_an_import_tags_a_row.py

m('nobody is asked',
  'provenance_is_the_imports',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if true then  -- nobody\n",
  '-- nobody')

m('the owner is refused too',
  'provenance_is_the_imports',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if false then  -- everyone\n",
  '-- everyone')

m('an insert is not asked',
  'provenance_is_the_imports',
  "    if tg_op = 'INSERT' and (v_new ->> v_col) is not null then\n",
  "    if false then  -- inserts free\n",
  '-- inserts free')

m('an update is not asked',
  'provenance_is_the_imports',
  "    if tg_op = 'UPDATE' and (v_new -> v_col) is distinct from (v_old -> v_col) then\n",
  "    if false then  -- updates free\n",
  '-- updates free')

m('only the batch is guarded',
  'provenance_is_the_imports',
  "  foreach v_col in array array['import_batch_id', 'import_source',\n                               'import_ref', 'imported_at'] loop\n",
  "  foreach v_col in array array['import_batch_id'] loop  -- batch only\n",
  '-- batch only')

m('the date it was imported on is left out',
  'provenance_is_the_imports',
  "  foreach v_col in array array['import_batch_id', 'import_source',\n                               'import_ref', 'imported_at'] loop\n",
  "  foreach v_col in array array['import_batch_id', 'import_source', 'import_ref'] loop  -- no date\n",
  '-- no date')

m('CONTROL: a comment inside the function',
  'provenance_is_the_imports',
  "  return new;\nend;",
  "  return new;  -- control\nend;",
  '-- control')

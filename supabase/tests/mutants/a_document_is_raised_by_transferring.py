# Mutants for 0911 -- what a sales or purchase document was raised from
# is set by transferring or crediting it, not by a client.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0911_a_document_is_raised_from_by_transferring.sql \
#       supabase/tests/a_document_is_raised_by_transferring.sql \
#       supabase/tests/mutants/a_document_is_raised_by_transferring.py

m('nobody is asked',
  'a_document_is_raised_by_transferring',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if true then  -- nobody\n",
  '-- nobody')

m('the owner is refused too',
  'a_document_is_raised_by_transferring',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if false then  -- everyone\n",
  '-- everyone')

m('an insert is not asked',
  'a_document_is_raised_by_transferring',
  "  if tg_op = 'INSERT' and new.parent_id is not null then\n",
  "  if false then  -- inserts free\n",
  '-- inserts free')

m('an update is not asked',
  'a_document_is_raised_by_transferring',
  "  if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id then\n",
  "  if false then  -- updates free\n",
  '-- updates free')

m('only a parent cut away is refused, not one changed',
  'a_document_is_raised_by_transferring',
  "  if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id then\n",
  "  if tg_op = 'UPDATE' and new.parent_id is null and old.parent_id is not null then  -- cut only\n",
  '-- cut only')

m('CONTROL: a comment inside the function',
  'a_document_is_raised_by_transferring',
  "  return new;\nend;",
  "  return new;  -- control\nend;",
  '-- control')

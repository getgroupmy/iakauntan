# Mutants for 0837 -- app.posting_is_the_posting_functions refuses a
# client's own statement that sets or changes gl_entry_id, posted_at or
# posted_by on documents, receipts, supplier payments and manufacturing
# orders (and a receipt's or payment's status), or inserts one already
# carrying them.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0837_posting_is_the_posting_functions.sql \
#       supabase/tests/posting_is_the_posting_functions.sql \
#       supabase/tests/mutants/posting_is_the_posting_functions.py
#
# RESULT, 12 October: 9 of 10 killed by
# posting_is_the_posting_functions.sql, the control surviving. The
# survivor, the depth clause, is equivalent: every function that posts,
# voids or reverses is a definer and runs as the owner at any depth. The
# file says so beside the owner's assertion.
#
# Not swept: the two `continue when not (v_new ? v_col)` lines. A
# manufacturing order has no `posted_by`, and a missing key reads as
# null on both sides of the comparison and as no value on an insert, so
# the guard answers the same with or without them.

m('nobody is asked',
  'posting_is_the_posting_functions',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'posting_is_the_posting_functions',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('only anon is a client',
  'posting_is_the_posting_functions',
  "  if current_user not in ('authenticated', 'anon')",
  "  if current_user not in ('anon')  -- anon only",
  '-- anon only')

m("a receipt's status is free",
  'posting_is_the_posting_functions',
  "    v_cols := array_append(v_cols, 'status');",
  '    null;  -- status free',
  '-- status free')

m("every table's status is guarded",
  'posting_is_the_posting_functions',
  "  if tg_table_name in ('receipts', 'purchase_payments') then",
  '  if true then  -- every status',
  '-- every status')

m('an insert is asked as an update',
  'posting_is_the_posting_functions',
  "  if tg_op = 'INSERT' then",
  '  if false then  -- inserts as updates',
  '-- inserts as updates')

m('a receipt may be recorded posted',
  'posting_is_the_posting_functions',
  "      if (v_col = 'status' and v_new ->> v_col <> 'draft')",
  '      if (false)  -- born posted',
  '-- born posted')

m('a document may be recorded with a journal',
  'posting_is_the_posting_functions',
  "         or (v_col <> 'status' and jsonb_typeof(v_new -> v_col) <> 'null') then",
  '         or (false) then  -- born with a journal',
  '-- born with a journal')

m('nothing is compared on an update',
  'posting_is_the_posting_functions',
  '    if v_new -> v_col is distinct from v_old -> v_col then',
  '    if false then  -- never compared',
  '-- never compared')

m('a receipt is not named',
  'posting_is_the_posting_functions',
  "v_new ->> 'receipt_no',",
  'null /* unnamed */,',
  '/* unnamed */')

m('CONTROL: a comment inside posting_is_the_posting_functions',
  'posting_is_the_posting_functions',
  '  return new;\nend $$;',
  '  return new;  -- (control)\nend $$;',
  '(control)')

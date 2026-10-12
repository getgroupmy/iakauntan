# Mutants for 0840 -- app.what_is_in_the_books_stays refuses a client's
# delete of a posted manufacturing order, a fixed asset depreciated or
# disposed of, and a lodged filing; drafts stay deletable.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0840_what_is_in_the_books_stays.sql \
#       supabase/tests/books_kept_on_delete.sql \
#       supabase/tests/mutants/what_is_in_the_books_stays.py
#
# RESULT: 8 of 9 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: every
# function that deletes one of these is a definer, which runs as the
# owner at any depth, and a cascade runs as the table's owner -- the test
# says so beside its owner assertion. "A disposal is not asked" survived
# the first draft, whose disposed asset had been depreciated as well:
# disposing of an asset part-way through a period writes the catch-up
# depreciation first, so the depreciation alone refused the delete. The
# forklift's residual value is its cost, so its disposal writes no
# depreciation entry -- asserted -- and the disposal alone stands.

m('nobody is asked',
  'what_is_in_the_books_stays',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'what_is_in_the_books_stays',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('a posted order may be deleted',
  'what_is_in_the_books_stays',
  '    if old.gl_entry_id is not null then',
  '    if false then  -- orders free',
  '-- orders free')

m('every order is kept, drafts too',
  'what_is_in_the_books_stays',
  '    if old.gl_entry_id is not null then',
  '    if true then  -- every order kept',
  '-- every order kept')

m('a disposal is not asked',
  'what_is_in_the_books_stays',
  '    if old.disposal_entry_id is not null\n       or exists',
  '    if false  -- disposal free\n       or exists',
  '-- disposal free')

m('a depreciated asset may be deleted',
  'what_is_in_the_books_stays',
  '       or exists (select 1 from public.depreciation_entries e\n                   where e.asset_id = old.id) then',
  '       or false then  -- depreciation free',
  '-- depreciation free')

m('every asset is kept',
  'what_is_in_the_books_stays',
  '    if old.disposal_entry_id is not null\n       or exists',
  '    if true  -- every asset kept\n       or exists',
  '-- every asset kept')

m('a lodged filing may be deleted',
  'what_is_in_the_books_stays',
  "    if old.status = 'lodged' then",
  '    if false then  -- filings free',
  '-- filings free')

m('every filing is kept',
  'what_is_in_the_books_stays',
  "    if old.status = 'lodged' then",
  '    if true then  -- every filing kept',
  '-- every filing kept')

m('CONTROL: a comment inside what_is_in_the_books_stays',
  'what_is_in_the_books_stays',
  '  return old;\nend $$;',
  '  return old;  -- (control)\nend $$;',
  '(control)')

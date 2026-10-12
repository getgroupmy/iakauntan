# Mutants for 0845 -- app.an_order_moves_by_its_functions keeps a
# manufacturing order's status to confirm and post: a client may only
# cancel an order not yet posted, and makes one only as a draft.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0845_an_order_moves_by_its_functions.sql \
#       supabase/tests/order_status_by_its_functions.sql \
#       supabase/tests/mutants/an_order_moves_by_its_functions.py
#
# RESULT: 6 of 7 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: confirming
# and posting are definers, which run as the owner at any depth -- the
# test says so beside its owner assertion.

m('nobody is asked',
  'an_order_moves_by_its_functions',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'an_order_moves_by_its_functions',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('an order may be made already confirmed',
  'an_order_moves_by_its_functions',
  "    if new.status <> 'draft' then",
  '    if false then  -- born anything',
  '-- born anything')

m('the status is not asked at all',
  'an_order_moves_by_its_functions',
  '  if new.status is distinct from old.status then',
  '  if false then  -- status free',
  '-- status free')

m('any move by hand, so long as it is not posted',
  'an_order_moves_by_its_functions',
  "    if new.status <> 'cancelled' then",
  '    if false then  -- any move',
  '-- any move')

m('only done is kept to posting',
  'an_order_moves_by_its_functions',
  "    if new.status <> 'cancelled' then",
  "    if new.status = 'done' then  -- only done",
  '-- only done')

m('a posted order may be cancelled',
  'an_order_moves_by_its_functions',
  '    if old.gl_entry_id is not null then',
  '    if false then  -- posted cancellable',
  '-- posted cancellable')

m('CONTROL: a comment inside an_order_moves_by_its_functions',
  'an_order_moves_by_its_functions',
  '  return new;\nend $$;',
  '  return new;  -- (control)\nend $$;',
  '(control)')

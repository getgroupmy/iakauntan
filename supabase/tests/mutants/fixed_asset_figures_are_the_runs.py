# Mutants for app.fixed_asset_figures_are_the_runs() (0822) -- a client's
# own statement may not write what run_depreciation and
# dispose_fixed_asset keep: each of the six columns on an update, each
# on an insert, and the owner at the top level still let through.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0822_an_asset_is_depreciated_by_depreciating_it.sql \
#       supabase/tests/fixed_asset_figures.sql \
#       supabase/tests/mutants/fixed_asset_figures_are_the_runs.py
#
# RESULT: 15 of 16 mutants killed by `fixed_asset_figures.sql`, the control
# surviving, the first time. The one that survives, `a nested statement is a
# client's too`, is equivalent: every writer of the table is a definer,
# and the file says so beside the owner's assertion. The file asks each
# of the six columns on its own, on an update and on an insert, so that
# no one of them is covered only by another.

m('the guard is never asked',
  'fixed_asset_figures_are_the_runs',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'fixed_asset_figures_are_the_runs',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'fixed_asset_figures_are_the_runs',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m("an insert's accumulated_depreciation is not asked",
  'fixed_asset_figures_are_the_runs',
  '    if new.accumulated_depreciation <> 0\n',
  '    if false  -- insert: accumulated unasked\n',
  'insert: accumulated unasked')

m("an insert's depreciated_to is not asked",
  'fixed_asset_figures_are_the_runs',
  '       or new.depreciated_to is not null\n',
  '       or false  -- insert: depreciated_to unasked\n',
  'insert: depreciated_to unasked')

m("an insert's status is not asked",
  'fixed_asset_figures_are_the_runs',
  "       or new.status is distinct from 'active'\n",
  '       or false  -- insert: status unasked\n',
  'insert: status unasked')

m("an insert's disposal_date is not asked",
  'fixed_asset_figures_are_the_runs',
  '       or new.disposal_date is not null\n',
  '       or false  -- insert: disposal_date unasked\n',
  'insert: disposal_date unasked')

m("an insert's disposal_proceeds is not asked",
  'fixed_asset_figures_are_the_runs',
  '       or new.disposal_proceeds is not null\n',
  '       or false  -- insert: disposal_proceeds unasked\n',
  'insert: disposal_proceeds unasked')

m("an insert's disposal_entry_id is not asked",
  'fixed_asset_figures_are_the_runs',
  '       or new.disposal_entry_id is not null then\n',
  '       or false then  -- insert: entry unasked\n',
  'insert: entry unasked')

m("an update's accumulated_depreciation is not asked",
  'fixed_asset_figures_are_the_runs',
  '  if new.accumulated_depreciation is distinct from old.accumulated_depreciation\n     or new.depreciated_to',
  '  if false  -- update: accumulated unasked\n     or new.depreciated_to',
  'update: accumulated unasked')

m("an update's depreciated_to is not asked",
  'fixed_asset_figures_are_the_runs',
  '     or new.depreciated_to is distinct from old.depreciated_to then',
  '     or false then  -- update: date unasked',
  'update: date unasked')

m("an update's status is not asked",
  'fixed_asset_figures_are_the_runs',
  '  if new.status is distinct from old.status\n',
  '  if false  -- update: status unasked\n',
  'update: status unasked')

m("an update's disposal_date is not asked",
  'fixed_asset_figures_are_the_runs',
  '     or new.disposal_date is distinct from old.disposal_date\n',
  '     or false  -- update: disposal date unasked\n',
  'update: disposal date unasked')

m("an update's disposal_proceeds is not asked",
  'fixed_asset_figures_are_the_runs',
  '     or new.disposal_proceeds is distinct from old.disposal_proceeds\n',
  '     or false  -- update: proceeds unasked\n',
  'update: proceeds unasked')

m("an update's disposal_entry_id is not asked",
  'fixed_asset_figures_are_the_runs',
  '     or new.disposal_entry_id is distinct from old.disposal_entry_id then',
  '     or false then  -- update: entry unasked',
  'update: entry unasked')

m('the depreciation refusal is a different kind',
  'fixed_asset_figures_are_the_runs',
  "      new.accumulated_depreciation, new.depreciated_to\n      using errcode = '42501';",
  "      new.accumulated_depreciation, new.depreciated_to\n      using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'fixed_asset_figures_are_the_runs',
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  '(control)')

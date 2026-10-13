# Mutants for 0850 -- app.an_import_is_finished_once keeps a posted or
# rolled-back import batch where it is, whoever asks, and a client off a
# batch's status altogether.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0850_an_import_is_finished_once.sql \
#       supabase/tests/import_batch_final.sql \
#       supabase/tests/mutants/an_import_is_finished_once.py
#
# RESULT: 6 of 7 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: every
# import function is a definer, which runs as the owner at any depth --
# the test says so beside its owner assertion.

m('every update is a change of status',
  'an_import_is_finished_once',
  '  if new.status is not distinct from old.status then',
  '  if false then  -- labels count',
  '-- labels count')

m('a posted import may be reopened',
  'an_import_is_finished_once',
  "  if old.status in ('posted', 'rolled_back') then",
  "  if old.status in ('rolled_back') then  -- posted reopens",
  '-- posted reopens')

m('a rolled-back import may be finished again',
  'an_import_is_finished_once',
  "  if old.status in ('posted', 'rolled_back') then",
  "  if old.status in ('posted') then  -- undone reopens",
  '-- undone reopens')

m('only a client is kept from reopening one',
  'an_import_is_finished_once',
  "  if old.status in ('posted', 'rolled_back') then",
  "  if old.status in ('posted', 'rolled_back') and current_user in ('authenticated', 'anon') then  -- clients only",
  '-- clients only')

m('a client moves a status by hand',
  'an_import_is_finished_once',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'an_import_is_finished_once',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('the functions are kept from moving a status too',
  'an_import_is_finished_once',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if false then  -- functions too',
  '-- functions too')

m('CONTROL: a comment inside an_import_is_finished_once',
  'an_import_is_finished_once',
  '    return new;\n  end if;\n\n  raise exception',
  '    return new;  -- (control)\n  end if;\n\n  raise exception',
  '(control)')

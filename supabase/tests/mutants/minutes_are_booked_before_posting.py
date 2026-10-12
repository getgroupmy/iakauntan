# Mutants for 0847 -- app.minutes_are_booked_before_posting lets a client
# book an operation's actual minutes, and only before its order is
# posted; operations are made and removed by confirming.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0847_minutes_are_booked_before_posting.sql \
#       supabase/tests/operation_minutes_booked.sql \
#       supabase/tests/mutants/minutes_are_booked_before_posting.py
#
# RESULT: 6 of 7 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: confirming
# and posting are definers, which run as the owner at any depth -- the
# test says so beside its owner assertion.

m('nobody is asked',
  'minutes_are_booked_before_posting',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'minutes_are_booked_before_posting',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('operations are made and removed by hand',
  'minutes_are_booked_before_posting',
  "  if tg_op <> 'UPDATE' then",
  '  if false then  -- made freely',
  '-- made freely')

m('only removing one is refused',
  'minutes_are_booked_before_posting',
  "  if tg_op <> 'UPDATE' then",
  "  if tg_op = 'DELETE' then  -- added freely",
  '-- added freely')

m('anything on an operation may be changed',
  'minutes_are_booked_before_posting',
  "  if (to_jsonb(new) - 'actual_minutes') is distinct from\n     (to_jsonb(old) - 'actual_minutes') then",
  '  if false then  -- columns free',
  '-- columns free')

m('a posted order takes minutes too',
  'minutes_are_booked_before_posting',
  '     where m.id = old.mo_id and m.gl_entry_id is not null;',
  '     where m.id = old.mo_id and false;  -- posted free',
  '-- posted free')

m('every order counts as posted',
  'minutes_are_booked_before_posting',
  '     where m.id = old.mo_id and m.gl_entry_id is not null;',
  '     where m.id = old.mo_id;  -- all posted',
  '-- all posted')

m('CONTROL: a comment inside minutes_are_booked_before_posting',
  'minutes_are_booked_before_posting',
  '  return new;\nend $$;',
  '  return new;  -- (control)\nend $$;',
  '(control)')

# Mutants for app.billed_time_is_kept() (0825) -- a client may not write
# is_billed or invoice_id, change a billed entry's frozen columns, delete
# a billed entry, or log one billed; unbilled time and a billed entry's
# description stay the client's, and the owner at the top is let
# through. Every element of the frozen list is a mutant of its own.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0825_billed_time_is_kept_as_it_was_billed.sql \
#       supabase/tests/billed_time_kept.sql \
#       supabase/tests/mutants/billed_time_is_kept.py
#
# RESULT: 20 of 21 mutants killed by `billed_time_kept.sql`, the control
# surviving, the first time. The survivor, `a nested statement is a
# client's too`, is equivalent -- every function that writes the table
# is a definer -- and the file says so beside the owner's assertion.
# `amount` is not on the frozen list and so has no mutant: `calc_amount`
# works it out on every write, and the file asserts that a typed one
# never reaches the row.

m('the guard is never asked',
  'billed_time_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'billed_time_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'billed_time_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m("an insert's billed mark is not asked",
  'billed_time_is_kept',
  '    if new.is_billed or new.invoice_id is not null then',
  '    if false or new.invoice_id is not null then  -- insert mark unasked',
  '-- insert mark unasked')

m("an insert's invoice is not asked",
  'billed_time_is_kept',
  '    if new.is_billed or new.invoice_id is not null then',
  '    if new.is_billed or false then  -- insert invoice unasked',
  '-- insert invoice unasked')

m('a billed entry may be deleted',
  'billed_time_is_kept',
  "    if old.is_billed then\n      raise exception\n        'Time of % on % has been billed, and the invoice it went on '",
  "    if false then  -- delete allowed\n      raise exception\n        'Time of % on % has been billed, and the invoice it went on '",
  '-- delete allowed')

m('any entry may not be deleted',
  'billed_time_is_kept',
  "    if old.is_billed then\n      raise exception\n        'Time of % on % has been billed, and the invoice it went on '",
  "    if true then  -- nothing deleted\n      raise exception\n        'Time of % on % has been billed, and the invoice it went on '",
  '-- nothing deleted')

m('the billed mark may be moved',
  'billed_time_is_kept',
  '  if new.is_billed is distinct from old.is_billed\n',
  '  if false  -- mark unasked\n',
  '-- mark unasked')

m('the invoice may be moved',
  'billed_time_is_kept',
  '     or new.invoice_id is distinct from old.invoice_id then',
  '     or false then  -- invoice unasked',
  '-- invoice unasked')

m("a billed entry's columns are not asked",
  'billed_time_is_kept',
  '  if old.is_billed then\n    v_old := to_jsonb(old);',
  '  if false then  -- columns unasked\n    v_old := to_jsonb(old);',
  '-- columns unasked')

m("an unbilled entry's columns are asked too",
  'billed_time_is_kept',
  '  if old.is_billed then\n    v_old := to_jsonb(old);',
  '  if true then  -- all frozen\n    v_old := to_jsonb(old);',
  '-- all frozen')

m('org_id is not frozen',
  'billed_time_is_kept',
  "'org_id',",
  "'created_at',",
  "'created_at'")

m('user_id is not frozen',
  'billed_time_is_kept',
  "'user_id',",
  "'created_at',",
  "'created_at'")

m('project_id is not frozen',
  'billed_time_is_kept',
  "'project_id',",
  "'created_at',",
  "'created_at'")

m('matter_id is not frozen',
  'billed_time_is_kept',
  "'matter_id',",
  "'created_at',",
  "'created_at'")

m('entry_date is not frozen',
  'billed_time_is_kept',
  "'entry_date',",
  "'created_at',",
  "'created_at'")

m('minutes is not frozen',
  'billed_time_is_kept',
  "'minutes',",
  "'created_at',",
  "'created_at'")

m('hourly_rate is not frozen',
  'billed_time_is_kept',
  "'hourly_rate',",
  "'created_at',",
  "'created_at'")

m('is_billable is not frozen',
  'billed_time_is_kept',
  "'is_billable']",
  "'created_at']",
  "'created_at'")

m('the refusal is a different kind',
  'billed_time_is_kept',
  "          old.minutes || ' minutes', old.entry_date, v_col\n          using errcode = '42501';",
  "          old.minutes || ' minutes', old.entry_date, v_col\n          using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'billed_time_is_kept',
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  '(control)')

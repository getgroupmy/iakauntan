# Mutants for app.a_ledger_account_is_closed_by_closing_it() (0829) -- a
# client may not close or reopen a ledger account by hand, nor make one
# already closed; the rest of the row is as before and the owner at the
# top is let through.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0829_a_ledger_account_is_closed_by_closing_it.sql \
#       supabase/tests/ledger_account_closed_by_closing.sql \
#       supabase/tests/mutants/a_ledger_account_is_closed_by_closing_it.py
#
# RESULT: 11 of 12 mutants killed by `ledger_account_closed_by_closing.sql`,
# the control surviving. The survivor, `a nested statement is a
# client's too`, is equivalent -- `retire_account`, the console's
# restore and the posting helpers that revive an account are definers
# -- and the file says so.
#
# The revoked delete is not in the function, so it was restored by
# hand: the grant with its policy, and the grant alone, fail the file
# (2 of 2), the policy alone fails its last assertion, and a no-op
# control passes.

m('the guard is never asked',
  'a_ledger_account_is_closed_by_closing_it',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'a_ledger_account_is_closed_by_closing_it',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'a_ledger_account_is_closed_by_closing_it',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m('a new account is not asked',
  'a_ledger_account_is_closed_by_closing_it',
  '    if new.deleted_at is not null or not new.is_active then',
  '    if false then  -- insert unasked',
  '-- insert unasked')

m("a new account's deletion mark is not asked",
  'a_ledger_account_is_closed_by_closing_it',
  '    if new.deleted_at is not null or not new.is_active then',
  '    if not new.is_active then  -- insert deleted unasked',
  '-- insert deleted unasked')

m("a new account's switch is not asked",
  'a_ledger_account_is_closed_by_closing_it',
  '    if new.deleted_at is not null or not new.is_active then',
  '    if new.deleted_at is not null then  -- insert active unasked',
  '-- insert active unasked')

m('a new open account is refused too',
  'a_ledger_account_is_closed_by_closing_it',
  '    if new.deleted_at is not null or not new.is_active then',
  '    if true then  -- every insert',
  '-- every insert')

m('the deletion mark is not asked on an update',
  'a_ledger_account_is_closed_by_closing_it',
  '  if new.deleted_at is distinct from old.deleted_at\n     or new.is_active',
  '  if false  -- deleted unasked\n     or new.is_active',
  '-- deleted unasked')

m('the switch is not asked on an update',
  'a_ledger_account_is_closed_by_closing_it',
  '     or new.is_active is distinct from old.is_active then',
  '     or false then  -- active unasked',
  '-- active unasked')

m('every update is refused',
  'a_ledger_account_is_closed_by_closing_it',
  '  if new.deleted_at is distinct from old.deleted_at\n     or new.is_active is distinct from old.is_active then',
  '  if true then  -- every update',
  '-- every update')

m('a closing is refused as some other kind',
  'a_ledger_account_is_closed_by_closing_it',
  "      'console -- not by hand.', old.code\n      using errcode = '42501';",
  "      'console -- not by hand.', old.code\n      using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('a closed insert is refused as some other kind',
  'a_ledger_account_is_closed_by_closing_it',
  "        'checks what it holds and keeps a record of it.'\n        using errcode = '42501';",
  "        'checks what it holds and keeps a record of it.'\n        using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'a_ledger_account_is_closed_by_closing_it',
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  '(control)')

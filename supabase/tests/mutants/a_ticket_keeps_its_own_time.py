# Mutants for app.a_ticket_keeps_its_own_time() (0831) -- a client may
# not move any part of a ticket's clock by hand; the ticket screen's own
# fields stay its own and the owner at the top is let through.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0831_a_ticket_keeps_its_own_time.sql \
#       supabase/tests/ticket_clock_kept.sql \
#       supabase/tests/mutants/a_ticket_keeps_its_own_time.py
#
# RESULT: 19 of 20 mutants killed by `ticket_clock_kept.sql`, the
# control surviving. The survivor, `a nested statement is a client's
# too`, is equivalent -- every function that moves the clock is a
# definer -- and the file says so.
#
# The revoked insert is not in the function, so it was restored by
# hand: the grant fails the file, and a no-op control passes.

m('the guard is never asked',
  'a_ticket_keeps_its_own_time',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'a_ticket_keeps_its_own_time',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'a_ticket_keeps_its_own_time',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m('the clock is never asked',
  'a_ticket_keeps_its_own_time',
  '  foreach v_col in array c_clock loop',
  '  foreach v_col in array array[]::text[] loop  -- clock unasked',
  '-- clock unasked')

for col in ['status', 'priority', 'sla_policy_id', 'opened_at',
            'response_due_at', 'resolution_due_at', 'first_response_at',
            'resolved_at', 'closed_at', 'response_breached',
            'resolution_breached', 'paused_minutes', 'paused_at',
            'escalation_level', 'reopened_count']:
    m(f'{col} is not asked',
      'a_ticket_keeps_its_own_time',
      f"'{col}'",
      "'resolution_note'",
      "'resolution_note'")

m('a moved clock is refused as some other kind',
  'a_ticket_keeps_its_own_time',
  "        v_col, old.ticket_no\n        using errcode = '42501';",
  "        v_col, old.ticket_no\n        using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'a_ticket_keeps_its_own_time',
  '  v_old := to_jsonb(old);',
  '  v_old := to_jsonb(old);  -- (control)',
  '(control)')

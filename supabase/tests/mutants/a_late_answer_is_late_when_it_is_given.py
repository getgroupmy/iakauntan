# Mutants for 0830 -- add_ticket_comment marks a first response given
# after its deadline, and transition_ticket a resolution after its
# deadline (moved on by paused time), each once, with its event.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0830_a_late_answer_is_late_when_it_is_given.sql \
#       supabase/tests/ticket_late_answer.sql \
#       supabase/tests/mutants/a_late_answer_is_late_when_it_is_given.py
#
# RESULT: 14 of 14 mutants killed by `ticket_late_answer.sql`, the
# control surviving. Two survived the first run -- closing a resolved
# ticket marked again, and a resolution the sweep had marked marked
# again -- for want of a ticket resolved in time and closed after its
# deadline, and one resolved after the sweep had caught it; the file
# has both now.

# -- add_ticket_comment -----------------------------------------------
m('a late first response is never marked',
  'add_ticket_comment',
  '    if v_t.response_due_at is not null and now() > v_t.response_due_at\n       and not v_t.response_breached then',
  '    if false then  -- late reply unmarked',
  '-- late reply unmarked')

m('every first response is marked late',
  'add_ticket_comment',
  '    if v_t.response_due_at is not null and now() > v_t.response_due_at\n       and not v_t.response_breached then',
  '    if not v_t.response_breached then  -- every reply late',
  '-- every reply late')

m('a breach the sweep marked is marked again',
  'add_ticket_comment',
  '       and not v_t.response_breached then',
  '       and true then  -- marked twice',
  '-- marked twice')

m('a late reply is marked without its event',
  'add_ticket_comment',
  "      values (v_t.org_id, p_ticket, 'sla_breach', 'response',\n              'First response sent after its deadline');",
  "      select v_t.org_id, p_ticket, 'sla_breach', 'response',\n              'First response sent after its deadline' where false;  -- no event",
  '-- no event')

m('a late reply writes its event and not its flag',
  'add_ticket_comment',
  '      update public.tickets set response_breached = true where id = p_ticket;',
  '      perform 1;  -- no flag',
  '-- no flag')

m('an internal note is a late first response',
  'add_ticket_comment',
  '  if not p_internal and v_t.first_response_at is null then',
  '  if v_t.first_response_at is null then  -- notes answer',
  '-- notes answer')

# -- transition_ticket_internal ---------------------------------------
m('a late resolution is never marked',
  'transition_ticket_internal',
  "  if p_to = 'resolved'\n     and v_new_due is not null and now() > v_new_due",
  "  if false  -- late resolution unmarked\n     and v_new_due is not null and now() > v_new_due",
  '-- late resolution unmarked')

m('every resolution is marked late',
  'transition_ticket_internal',
  "     and v_new_due is not null and now() > v_new_due\n",
  "     and v_new_due is not null  -- every resolution late\n",
  '-- every resolution late')

m('paused time does not move the deadline the resolution is asked against',
  'transition_ticket_internal',
  "     and v_new_due is not null and now() > v_new_due\n",
  "     and v_new_due is not null and now() > v_t.resolution_due_at  -- pause ignored\n",
  '-- pause ignored')

m('a cancelled ticket is a late resolution',
  'transition_ticket_internal',
  "  if p_to = 'resolved'\n     and v_new_due is not null",
  "  if p_to in ('resolved', 'cancelled')  -- cancelled counts\n     and v_new_due is not null",
  '-- cancelled counts')

m('closing a resolved ticket marks it again',
  'transition_ticket_internal',
  "  if p_to = 'resolved'\n     and v_new_due is not null",
  "  if p_to in ('resolved', 'closed')  -- closing counts\n     and v_new_due is not null",
  '-- closing counts')

m('a resolution already marked is marked again',
  'transition_ticket_internal',
  '     and not v_t.resolution_breached then',
  '     and true then  -- marked twice',
  '-- marked twice')

m('a late resolution is marked without its event',
  'transition_ticket_internal',
  "    values (v_t.org_id, p_ticket, 'sla_breach', 'resolution',\n            'Resolved after its deadline');",
  "    select v_t.org_id, p_ticket, 'sla_breach', 'resolution',\n            'Resolved after its deadline' where false;  -- no event",
  '-- no event')

m('a late resolution writes its event and not its flag',
  'transition_ticket_internal',
  '    update public.tickets set resolution_breached = true where id = p_ticket;',
  '    perform 1;  -- no flag',
  '-- no flag')

m('CONTROL: a comment inside add_ticket_comment',
  'add_ticket_comment',
  '  return v_id;',
  '  return v_id;  -- (control)',
  '(control)')

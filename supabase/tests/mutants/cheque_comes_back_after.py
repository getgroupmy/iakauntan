# Mutants for 0892 -- a cheque comes back no earlier than it was
# received or issued, and once paid in, no earlier than that day.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0892_a_cheque_comes_back_after_it_came_in.sql \
#       supabase/tests/cheque_comes_back_after.sql \
#       supabase/tests/mutants/cheque_comes_back_after.py

m('a cheque comes back before it was received again',
  'bounce_pdc',
  "  if v_on < v_c.received_on then\n",
  "  if false and v_on < v_c.received_on then  -- any day\n",
  '-- any day')

m('nor on the day it was received',
  'bounce_pdc',
  "  if v_on < v_c.received_on then\n",
  "  if v_on <= v_c.received_on then  -- not that day\n",
  '-- not that day')

m('not before its own date either',
  'bounce_pdc',
  "  if v_on < v_c.received_on then\n",
  "  if v_on < v_c.cheque_date then  -- cheque date instead\n",
  '-- cheque date instead')

m('a cheque paid in comes back before it was again',
  'bounce_pdc',
  "  if v_on < v_c.deposited_on then\n",
  "  if false and v_on < v_c.deposited_on then  -- any day\n",
  '-- any day')

m('nor on the day it was paid in',
  'bounce_pdc',
  "  if v_on < v_c.deposited_on then\n",
  "  if v_on <= v_c.deposited_on then  -- not that day\n",
  '-- not that day')

m('one the company wrote is called received',
  'bounce_pdc',
  "      case when v_c.direction = 'incoming' then 'received' else 'issued' end,\n",
  "      'received',  -- always received\n",
  '-- always received')

m('the returned journal is dated today, whatever was asked',
  'bounce_pdc',
  "      v_c.org_id, v_on, 'cheque', v_lines,\n",
  "      v_c.org_id, app.today(), 'cheque', v_lines,  -- today\n",
  '-- today')

m('CONTROL: a comment inside the function',
  'bounce_pdc',
  "  -- 0892: a cheque comes back no earlier than it was received or\n",
  "  -- 0892: a cheque comes back no earlier than it was received or\n  -- control\n",
  '-- control')

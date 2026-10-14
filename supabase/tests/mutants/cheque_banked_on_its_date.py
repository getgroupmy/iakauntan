# Mutants for 0886 -- a post-dated cheque is paid in and cleared on or
# after its date, and clears no earlier than it was paid in.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0886_a_post_dated_cheque_is_banked_on_its_date.sql \
#       supabase/tests/cheque_banked_on_its_date.sql \
#       supabase/tests/mutants/cheque_banked_on_its_date.py

m('a cheque is paid in before its date again',
  'deposit_pdc',
  "  if coalesce(p_on, app.today()) < v_c.cheque_date then\n",
  "  if false then  -- early pay-in\n",
  '-- early pay-in')

m('a cheque is not paid in on its date either',
  'deposit_pdc',
  "  if coalesce(p_on, app.today()) < v_c.cheque_date then\n",
  "  if coalesce(p_on, app.today()) <= v_c.cheque_date then  -- not on the day\n",
  '-- not on the day')

m('the day given is not asked, only today',
  'deposit_pdc',
  "  if coalesce(p_on, app.today()) < v_c.cheque_date then\n",
  "  if app.today() < v_c.cheque_date then  -- today only\n",
  '-- today only')

m('a cheque clears before its date again',
  'clear_pdc',
  "  if v_on < v_c.cheque_date then\n",
  "  if false then  -- early clear\n",
  '-- early clear')

m('a cheque does not clear on its date either',
  'clear_pdc',
  "  if v_on < v_c.cheque_date then\n",
  "  if v_on <= v_c.cheque_date then  -- not on the day\n",
  '-- not on the day')

m('a cheque clears before it was paid in',
  'clear_pdc',
  "  if v_on < v_c.deposited_on then\n",
  "  if false then  -- before paid in\n",
  '-- before paid in')

m('a cheque does not clear on the day it was paid in',
  'clear_pdc',
  "  if v_on < v_c.deposited_on then\n",
  "  if v_on <= v_c.deposited_on then  -- not the same day\n",
  '-- not the same day')

m('CONTROL: a comment inside the clear check',
  'clear_pdc',
  "  if v_on < v_c.cheque_date then\n",
  "  if v_on < v_c.cheque_date then  -- control\n",
  '-- control')

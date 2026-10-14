# Mutants for 0887 -- a deposit is applied, given back or kept on or
# after the day it was taken, never before.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0887_a_deposit_is_used_no_earlier_than_it_was_taken.sql \
#       supabase/tests/deposit_used_after_taken.sql \
#       supabase/tests/mutants/deposit_used_after_taken.py

m('a deposit is applied before it was taken again',
  'apply_deposit',
  "  if coalesce(p_date, app.today()) < v_note.deposit_date then\n",
  "  if false then  -- early apply\n",
  '-- early apply')

m('a deposit is not applied on the day it was taken',
  'apply_deposit',
  "  if coalesce(p_date, app.today()) < v_note.deposit_date then\n",
  "  if coalesce(p_date, app.today()) <= v_note.deposit_date then  -- not that day\n",
  '-- not that day')

m('the day given to apply is not asked, only today',
  'apply_deposit',
  "  if coalesce(p_date, app.today()) < v_note.deposit_date then\n",
  "  if app.today() < v_note.deposit_date then  -- today only\n",
  '-- today only')

m('a deposit is given back or kept before it was taken again',
  'settle_deposit',
  "  if v_on < v_note.deposit_date then\n",
  "  if false then  -- early settle\n",
  '-- early settle')

m('a deposit is not given back on the day it was taken',
  'settle_deposit',
  "  if v_on < v_note.deposit_date then\n",
  "  if v_on <= v_note.deposit_date then  -- not that day\n",
  '-- not that day')

m('the day given to settle is not asked, only today',
  'settle_deposit',
  "  if v_on < v_note.deposit_date then\n",
  "  if app.today() < v_note.deposit_date then  -- today only\n",
  '-- today only')

m('CONTROL: a comment inside the settle check',
  'settle_deposit',
  "  if v_on < v_note.deposit_date then\n",
  "  if v_on < v_note.deposit_date then  -- control\n",
  '-- control')

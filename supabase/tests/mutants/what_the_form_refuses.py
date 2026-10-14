# Mutants for 0885 -- record_departure refuses notice after the last day
# and, given none, dates it no later than the last day. The two check
# constraints are not functions; they were swept by hand (dropped, the
# file run, put back) and the result is in the handoff.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0885_what_the_form_refuses_the_database_refuses.sql \
#       supabase/tests/what_the_form_refuses.sql \
#       supabase/tests/mutants/what_the_form_refuses.py

m('notice after the last day is accepted again',
  'record_departure',
  "  if p_status = 'resigned' and p_resignation_date > p_last_working_date then\n",
  "  if false then  -- after is fine\n",
  '-- after is fine')

m('notice on the last day itself is refused',
  'record_departure',
  "  if p_status = 'resigned' and p_resignation_date > p_last_working_date then\n",
  "  if p_status = 'resigned' and p_resignation_date >= p_last_working_date then  -- on the day\n",
  '-- on the day')

m("a termination's stray date is refused",
  'record_departure',
  "  if p_status = 'resigned' and p_resignation_date > p_last_working_date then\n",
  "  if p_resignation_date > p_last_working_date then  -- any status\n",
  '-- any status')

m('a late entry resigns them today again',
  'record_departure',
  "                                            least(v_today, p_last_working_date))\n",
  "                                            v_today)  -- today again\n",
  '-- today again')

m('a late entry resigns them on the later of the two',
  'record_departure',
  "                                            least(v_today, p_last_working_date))\n",
  "                                            greatest(v_today, p_last_working_date))  -- later\n",
  '-- later')

m('every resignation is dated the last day',
  'record_departure',
  "                                            least(v_today, p_last_working_date))\n",
  "                                            p_last_working_date)  -- always the last day\n",
  '-- always the last day')

m('CONTROL: a comment inside the new check',
  'record_departure',
  "  if p_status = 'resigned' and p_resignation_date > p_last_working_date then\n",
  "  if p_status = 'resigned' and p_resignation_date > p_last_working_date then  -- control\n",
  '-- control')

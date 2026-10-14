# Mutants for 0884 -- a goal is taken off by the reviewer or HR, who set
# it, and a completed appraisal's goals are HR's alone; a cascade and
# the database's owner are not asked.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0884_an_appraisals_goals_are_the_setters.sql \
#       supabase/tests/appraisal_goals_kept.sql \
#       supabase/tests/mutants/appraisal_goals_kept.py

m('the person appraised takes a goal off again',
  'appraisal_goal_delete_guard',
  "  if v_part is distinct from 'reviewer' and v_part is distinct from 'hr' then\n",
  "  if false then  -- anyone takes one off\n",
  '-- anyone takes one off')

m('the person appraised counts as the setter, the reviewer does not',
  'appraisal_goal_delete_guard',
  "  if v_part is distinct from 'reviewer' and v_part is distinct from 'hr' then\n",
  "  if v_part is distinct from 'subject' and v_part is distinct from 'hr' then  -- subject sets\n",
  '-- subject sets')

m("a completed appraisal's goals come off",
  'appraisal_goal_delete_guard',
  "  if v_a.completed_at is not null and v_part is distinct from 'hr' then\n",
  "  if false then  -- completed comes off\n",
  '-- completed comes off')

m('only the reviewer takes one off a completed appraisal',
  'appraisal_goal_delete_guard',
  "  if v_a.completed_at is not null and v_part is distinct from 'hr' then\n",
  "  if v_a.completed_at is not null and v_part is distinct from 'reviewer' then  -- reviewer's\n",
  "-- reviewer's")

m('a cascade is asked as a client is',
  'appraisal_goal_delete_guard',
  "     or pg_trigger_depth() > 1 then\n",
  "     or false then  -- cascade asked\n",
  '-- cascade asked')

m("the database's owner is asked as a client is",
  'appraisal_goal_delete_guard',
  "  if current_user not in ('authenticated', 'anon')\n",
  "  if false  -- owner asked\n",
  '-- owner asked')

m("the reviewer rewrites a completed appraisal's goals",
  'appraisal_goal_change_guard',
  "  if v_a.completed_at is not null and v_part is distinct from 'hr' then\n",
  "  if false then  -- completed rewritten\n",
  '-- completed rewritten')

m('not even HR corrects a completed one',
  'appraisal_goal_change_guard',
  "  if v_a.completed_at is not null and v_part is distinct from 'hr' then\n",
  "  if v_a.completed_at is not null then  -- nobody corrects\n",
  '-- nobody corrects')

m('CONTROL: a comment inside the delete guard',
  'appraisal_goal_delete_guard',
  "  if v_part is distinct from 'reviewer' and v_part is distinct from 'hr' then\n",
  "  if v_part is distinct from 'reviewer' and v_part is distinct from 'hr' then  -- control\n",
  '-- control')

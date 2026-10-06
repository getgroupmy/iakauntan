# Mutants for public.open_appraisal_cycle and submit_self_appraisal
# (0379) -- who a cycle opens an appraisal for, and the half the person
# being appraised writes.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0379_the_appraisal_you_could_write_for_yourself.sql \
#       supabase/tests/appraisals.sql \
#       supabase/tests/mutants/appraisal_cycle_and_self.py
#
# RESULT: 23 mutants and a control. 23 killed by `appraisals.sql`,
# eleven only after a rule-by-rule block there. Everybody a cycle had
# been opened for joined years before it and was staying, so nothing
# pressed its edges (joined after it, joined on its last day, leaving on
# its last day); no cycle was opened again past self review, closed, or
# backwards -- the table has no check on the dates, so that refusal is
# the function's alone; and the self review's refusals were asserted by
# SQLSTATE where the trigger behind them raises the same code.

m("a missing cycle is opened in silence",
  "open_appraisal_cycle",
  "  if v_c.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody opens a cycle",
  "open_appraisal_cycle",
  "  if not app.can_manage_hr(v_c.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a closed cycle is opened again",
  "open_appraisal_cycle",
  "  if v_c.status = 'completed' then",
  "  if false then  -- reopened",
  "-- reopened")

m("a cycle that ends before it starts is opened",
  "open_appraisal_cycle",
  "  if v_c.period_end < v_c.period_start then",
  "  if false then  -- backwards",
  "-- backwards")

m("the reviewer is nobody",
  "open_appraisal_cycle",
  "  select v_c.org_id, v_c.id, e.id, e.manager_id, 'self_review'",
  "  select v_c.org_id, v_c.id, e.id, null, 'self_review'  -- unreviewed",
  "-- unreviewed")

m("another company's staff are appraised",
  "open_appraisal_cycle",
  "   where e.org_id = v_c.org_id\n     and e.hire_date <= v_c.period_end",
  "   where true  -- everybody\n     and e.hire_date <= v_c.period_end",
  "-- everybody")

m("somebody who joined after the period is appraised",
  "open_appraisal_cycle",
  "     and e.hire_date <= v_c.period_end\n",
  "     and true  -- not yet joined\n",
  "-- not yet joined")

m("somebody who joined on the last day is left out",
  "open_appraisal_cycle",
  "     and e.hire_date <= v_c.period_end\n",
  "     and e.hire_date < v_c.period_end  -- the last day too late\n",
  "-- the last day too late")

m("somebody who left before the end is appraised",
  "open_appraisal_cycle",
  "     and (e.last_working_date is null\n          or e.last_working_date >= v_c.period_end)",
  "     and true  -- leavers too",
  "-- leavers too")

m("somebody leaving on the last day is left out",
  "open_appraisal_cycle",
  "          or e.last_working_date >= v_c.period_end)",
  "          or e.last_working_date > v_c.period_end)  -- not the last day",
  "-- not the last day")

m("a second opening appraises everybody twice",
  "open_appraisal_cycle",
  "     and not exists (select 1 from public.appraisals a\n                      where a.cycle_id = v_c.id and a.employee_id = e.id);",
  "     and true;  -- again",
  "-- again")

m("an appraisal in another cycle counts as this one's",
  "open_appraisal_cycle",
  "                      where a.cycle_id = v_c.id and a.employee_id = e.id);",
  "                      where a.employee_id = e.id);  -- any cycle",
  "-- any cycle")

m("nothing opened is counted",
  "open_appraisal_cycle",
  "  get diagnostics v_n = row_count;",
  "  v_n := 0;  -- uncounted",
  "-- uncounted")

m("a draft cycle stays a draft",
  "open_appraisal_cycle",
  "     set status = case when status = 'draft' then 'self_review'",
  "     set status = case when false then 'self_review'  -- still draft",
  "-- still draft")

m("a cycle past self review is put back to it",
  "open_appraisal_cycle",
  "     set status = case when status = 'draft' then 'self_review'",
  "     set status = case when true then 'self_review'  -- back again",
  "-- back again")

m("a missing appraisal is self-reviewed in silence",
  "submit_self_appraisal",
  "  if v_a.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody writes the self review",
  "submit_self_appraisal",
  "  if app.appraisal_part(p_appraisal) is distinct from 'subject' then",
  "  if false then  -- anyone",
  "-- anyone")

m("the self review is written twice",
  "submit_self_appraisal",
  "  if v_a.self_submitted_at is not null then",
  "  if false then  -- again",
  "-- again")

m("a self rating needs no words",
  "submit_self_appraisal",
  "  if p_comments is null or btrim(p_comments) = '' then",
  "  if p_comments is null then  -- blank will do",
  "-- blank will do")

m("the self rating is not kept",
  "submit_self_appraisal",
  "    self_rating       = p_rating,",
  "    self_rating       = null,  -- unrated",
  "-- unrated")

m("the self comments are kept untrimmed",
  "submit_self_appraisal",
  "    self_comments     = btrim(p_comments),",
  "    self_comments     = p_comments,  -- as typed",
  "-- as typed")

m("the appraisal does not move on to the manager",
  "submit_self_appraisal",
  "                             then 'manager_review'::app.appraisal_status",
  "                             then status  -- stays",
  "-- stays")

m("an appraisal past the self review is moved back to the manager",
  "submit_self_appraisal",
  "    status            = case when status = 'self_review'",
  "    status            = case when true  -- whatever it was",
  "-- whatever it was")

m("CONTROL: a comment inside the block",
  "open_appraisal_cycle",
  "  get diagnostics v_n = row_count;",
  "  get diagnostics v_n = row_count;  -- (control)",
  "(control)")

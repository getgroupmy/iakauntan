# Mutants for public.submit_manager_appraisal, finalise_appraisal and
# reopen_appraisal (0379) -- the manager's half of an appraisal, HR's
# final rating over it, and HR taking either back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0379_the_appraisal_you_could_write_for_yourself.sql \
#       supabase/tests/appraisals.sql \
#       supabase/tests/mutants/appraisal_decisions.py
#
# RESULT: 40 mutants and a control. 40 killed by `appraisals.sql`,
# twenty only after a rule-by-rule block there. Several guards were met
# only where `app.appraisal_change_guard` refuses the same thing in the
# same words, so the function's check could go: a non-reviewer is told
# "named reviewer" by both, and only arriving before the self review is
# due tells them apart, since the function's check runs first. Others
# were refused but asserted by SQLSTATE, or never tried -- a self review
# due today, a cycle with no due date, a blank final rating, another
# appraisal's goals -- and the way back had only ever reopened the self
# review.

# --- submit_manager_appraisal ----------------------------------------

m("a missing appraisal is reviewed in silence",
  "submit_manager_appraisal",
  "  if v_a.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody writes the manager's half",
  "submit_manager_appraisal",
  "  if app.appraisal_part(p_appraisal) is distinct from 'reviewer' then",
  "  if false then  -- anyone",
  "-- anyone")

m("the manager's half is written twice",
  "submit_manager_appraisal",
  "  if v_a.manager_submitted_at is not null then",
  "  if false then  -- again",
  "-- again")

m("a rating needs no words",
  "submit_manager_appraisal",
  "  if p_comments is null or btrim(p_comments) = '' then",
  "  if p_comments is null then  -- blank will do",
  "-- blank will do")

m("the manager answers before the self review",
  "submit_manager_appraisal",
  "  if v_a.self_submitted_at is null then\n    select self_review_due",
  "  if false then  -- first\n    select self_review_due",
  "-- first")

m("a self review not yet due is not waited for",
  "submit_manager_appraisal",
  "    if v_due is null or v_due >= v_today then",
  "    if v_due is null then  -- overdue or not",
  "-- overdue or not")

m("a self review due today is overdue",
  "submit_manager_appraisal",
  "    if v_due is null or v_due >= v_today then",
  "    if v_due is null or v_due > v_today then  -- due is late",
  "-- due is late")

m("a cycle with no due date is never waited for",
  "submit_manager_appraisal",
  "    if v_due is null or v_due >= v_today then",
  "    if v_due >= v_today then  -- undated is overdue",
  "-- undated is overdue")

m("the rating is not kept",
  "submit_manager_appraisal",
  "    manager_rating                = p_rating,",
  "    manager_rating                = null,  -- unrated",
  "-- unrated")

m("the comments are kept untrimmed",
  "submit_manager_appraisal",
  "    manager_comments              = btrim(p_comments),",
  "    manager_comments              = p_comments,  -- as typed",
  "-- as typed")

m("the increment is not kept",
  "submit_manager_appraisal",
  "    recommended_increment_percent = p_increment,",
  "    recommended_increment_percent = null,  -- none",
  "-- none")

m("the bonus is not kept",
  "submit_manager_appraisal",
  "    recommended_bonus             = p_bonus,",
  "    recommended_bonus             = null,  -- none",
  "-- none")

m("a promotion is never recommended",
  "submit_manager_appraisal",
  "    promotion_recommended         = coalesce(p_promotion, false),",
  "    promotion_recommended         = false,  -- never",
  "-- never")

m("a blank development plan is kept as blank",
  "submit_manager_appraisal",
  "    development_plan              = nullif(btrim(coalesce(\n                                      p_development_plan, '')), ''),",
  "    development_plan              = p_development_plan,  -- as typed",
  "-- as typed")

m("the appraisal does not move on to calibration",
  "submit_manager_appraisal",
  "                                      then 'calibration'::app.appraisal_status",
  "                                      then status  -- stays",
  "-- stays")

m("a completed appraisal is moved back to calibration",
  "submit_manager_appraisal",
  "                                      when status in ('self_review',\n                                                      'manager_review')",
  "                                      when true  -- whatever it was",
  "-- whatever it was")

# --- finalise_appraisal -----------------------------------------------

m("a missing appraisal is finalised in silence",
  "finalise_appraisal",
  "  if v_a.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody finalises",
  "finalise_appraisal",
  "  if app.appraisal_part(p_appraisal) is distinct from 'hr' then",
  "  if false then  -- anyone",
  "-- anyone")

m("a completed appraisal is finalised again",
  "finalise_appraisal",
  "  if v_a.completed_at is not null then",
  "  if false then  -- twice",
  "-- twice")

m("a final rating needs no manager's half",
  "finalise_appraisal",
  "  if v_a.manager_submitted_at is null then",
  "  if false then  -- one-sided",
  "-- one-sided")

m("a completed appraisal needs no rating",
  "finalise_appraisal",
  "  if p_final_rating is null then",
  "  if false then  -- unrated",
  "-- unrated")

m("goals that do not add to a hundred are taken",
  "finalise_appraisal",
  "  if v_goals > 0 and round(v_weight, 2) <> 100 then",
  "  if false then  -- any weights",
  "-- any weights")

m("an appraisal with no goals must still add to a hundred",
  "finalise_appraisal",
  "  if v_goals > 0 and round(v_weight, 2) <> 100 then",
  "  if round(v_weight, 2) <> 100 then  -- goals required",
  "-- goals required")

m("another appraisal's goals are weighed",
  "finalise_appraisal",
  "    from public.appraisal_goals where appraisal_id = p_appraisal;",
  "    from public.appraisal_goals;  -- everybody's",
  "-- everybody's")

m("a different final rating needs no reason",
  "finalise_appraisal",
  "  if p_final_rating is distinct from v_a.manager_rating\n     and (p_calibration_note is null or btrim(p_calibration_note) = '') then",
  "  if false then  -- unexplained",
  "-- unexplained")

m("a blank reason will do",
  "finalise_appraisal",
  "     and (p_calibration_note is null or btrim(p_calibration_note) = '') then",
  "     and p_calibration_note is null then  -- blank will do",
  "-- blank will do")

m("agreeing with the manager needs a reason too",
  "finalise_appraisal",
  "  if p_final_rating is distinct from v_a.manager_rating\n",
  "  if true  -- always explain\n",
  "-- always explain")

m("the final rating is not kept",
  "finalise_appraisal",
  "    final_rating     = p_final_rating,",
  "    final_rating     = v_a.manager_rating,  -- the manager's",
  "-- the manager's")

m("the calibration note is kept untrimmed",
  "finalise_appraisal",
  "    calibration_note = nullif(btrim(coalesce(p_calibration_note, '')), ''),",
  "    calibration_note = p_calibration_note,  -- as typed",
  "-- as typed")

m("the appraisal is not marked complete",
  "finalise_appraisal",
  "    completed_at     = now(),",
  "    completed_at     = null,  -- open",
  "-- open")

# --- reopen_appraisal ------------------------------------------------

m("a missing appraisal is reopened in silence",
  "reopen_appraisal",
  "  if v_a.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody reopens",
  "reopen_appraisal",
  "  if not app.can_manage_hr(v_a.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("any side may be named",
  "reopen_appraisal",
  "  if p_side not in ('self', 'manager', 'final') then",
  "  if false then  -- anything",
  "-- anything")

m("reopening the self review leaves it submitted",
  "reopen_appraisal",
  "      self_submitted_at = null,",
  "      self_submitted_at = self_submitted_at,  -- still in",
  "-- still in")

m("reopening the self review leaves the appraisal complete",
  "reopen_appraisal",
  "      self_submitted_at = null,\n      completed_at      = null,",
  "      self_submitted_at = null,\n      completed_at      = completed_at,  -- still done",
  "-- still done")

m("reopening the manager's half leaves it submitted",
  "reopen_appraisal",
  "      manager_submitted_at = null,",
  "      manager_submitted_at = manager_submitted_at,  -- still in",
  "-- still in")

m("reopening the manager's half leaves the appraisal complete",
  "reopen_appraisal",
  "      manager_submitted_at = null,\n      completed_at         = null,",
  "      manager_submitted_at = null,\n      completed_at         = completed_at,  -- still done",
  "-- still done")

m("reopening the final rating leaves it complete",
  "reopen_appraisal",
  "      completed_at = null,\n      status       = 'calibration',",
  "      completed_at = completed_at,  -- still done\n      status       = 'calibration',",
  "-- still done")

m("a reopened final rating goes back to the manager",
  "reopen_appraisal",
  "      status       = 'calibration',",
  "      status       = 'manager_review',  -- too far",
  "-- too far")

m("CONTROL: a comment inside the block",
  "finalise_appraisal",
  "  if p_final_rating is null then",
  "  if p_final_rating is null then  -- (control)",
  "(control)")

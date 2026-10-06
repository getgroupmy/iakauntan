# Mutants for app.may_decide_claim_step (0752, restating 0119's) -- who may decide the step
# in front of an expense claim.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0752_a_claim_step_is_nobodys_unless_it_is_yours.sql \
#       supabase/tests/claim_approval_chain.sql \
#       supabase/tests/mutants/may_decide_claim_step.py
#
# then again against `expense_claims.sql`.
#
# RESULT: 14 mutants and a control. 12 killed, all by
# `claim_approval_chain.sql` and all only after a rule-by-rule block
# there. Before it, ten of twelve survived: every role stage in both
# files was cleared by the OWNER, an administrator who may act at any
# stage, so no assertion could tell HR's step from finance's or either
# from a plain employee's. That block found the defect 0752 fixes.
#
# Two EQUIVALENT:
#
#   a step that does not exist may    without `v_step.id is null` a
#   be decided                        missing step falls through to the
#                                     CASE with no stage, and 0752's
#                                     `coalesce(..., false)` answers it.
#   a manager step with nobody named  a pending step that names nobody
#   is anybody's                      cannot arise: `build_claim_chain`
#                                     writes one as SKIPPED, and the
#                                     plain foreign key on
#                                     `approver_employee_id` refuses to
#                                     delete an employee a step names.

m("a step that does not exist may be decided",
  "may_decide_claim_step",
  "  if v_step.id is null or v_step.status <> 'pending' then return false; end if;",
  "  if v_step.status <> 'pending' then return false; end if;  -- no such",
  "-- no such")

m("a decided step may be decided again",
  "may_decide_claim_step",
  "  if v_step.id is null or v_step.status <> 'pending' then return false; end if;",
  "  if v_step.id is null then return false; end if;  -- twice",
  "-- twice")

m("an administrator may not act at any stage",
  "may_decide_claim_step",
  "  if app.can_admin(v_step.org_id) then return true; end if;",
  "  null;  -- no way out",
  "-- no way out")

m("anybody who manages HR acts at any stage",
  "may_decide_claim_step",
  "  if app.can_admin(v_step.org_id) then return true; end if;",
  "  if app.can_manage_hr(v_step.org_id) then return true; end if;  -- HR anywhere",
  "-- HR anywhere")

m("another company's employee record is mine",
  "may_decide_claim_step",
  "   where e.org_id = v_step.org_id and e.user_id = auth.uid();",
  "   where e.user_id = auth.uid() limit 1;  -- any company",
  "-- any company")

m("a manager step with nobody named is anybody's",
  "may_decide_claim_step",
  "    when 'manager' then v_step.approver_employee_id is not null\n                    and v_step.approver_employee_id = v_me",
  "    when 'manager' then v_step.approver_employee_id is not distinct from v_me  -- null too",
  "-- null too")

m("any employee is the manager",
  "may_decide_claim_step",
  "    when 'manager' then v_step.approver_employee_id is not null\n                    and v_step.approver_employee_id = v_me",
  "    when 'manager' then v_me is not null  -- any employee",
  "-- any employee")

m("any employee is the unit head",
  "may_decide_claim_step",
  "    when 'unit_head' then v_step.approver_employee_id is not null\n                    and v_step.approver_employee_id = v_me",
  "    when 'unit_head' then v_me is not null  -- any employee",
  "-- any employee")

m("anybody decides the HR step",
  "may_decide_claim_step",
  "    when 'hr' then app.can_manage_hr(v_step.org_id)",
  "    when 'hr' then true  -- anyone",
  "-- anyone")

m("the HR step needs the ledger",
  "may_decide_claim_step",
  "    when 'hr' then app.can_manage_hr(v_step.org_id)",
  "    when 'hr' then app.can_post(v_step.org_id)  -- finance",
  "-- finance")

m("anybody decides the finance step",
  "may_decide_claim_step",
  "    when 'finance' then app.can_post(v_step.org_id)",
  "    when 'finance' then true  -- anyone",
  "-- anyone")

m("the finance step needs HR",
  "may_decide_claim_step",
  "    when 'finance' then app.can_post(v_step.org_id)",
  "    when 'finance' then app.can_manage_hr(v_step.org_id)  -- HR",
  "-- HR")

m("NULL is an answer again (0119's shape)",
  "may_decide_claim_step",
  "  end, false);",
  "  end, null);  -- unknown",
  "-- unknown")

m("CONTROL: a comment inside the block",
  "may_decide_claim_step",
  "  -- actually decided it.",
  "  -- actually decided it. (control)",
  "(control)")

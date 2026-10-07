# Mutants for public.approve_budget (0274) -- a draft budget with lines
# in it, agreed by somebody who may post, and recorded as theirs.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0274_the_number_the_board_agreed.sql \
#       supabase/tests/budgets.sql \
#       supabase/tests/mutants/approve_budget.py
#
# RESULT: 8 mutants and a control. 8 killed by `budgets.sql`, six only
# after rule-by-rule assertions there: the file had agreed one budget and
# refused one empty one, so who may agree, a missing budget, agreeing
# twice, and what an agreement records were all unasserted.

m("a budget that does not exist is approved in silence",
  "approve_budget",
  "  if v_b.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody approves a budget",
  "approve_budget",
  "  if not app.can_post(v_b.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("an approved budget is approved again",
  "approve_budget",
  "  if v_b.status <> 'draft' then",
  "  if false then  -- twice",
  "-- twice")

m("an empty budget is approved",
  "approve_budget",
  "  if not exists (select 1 from public.budget_lines l where l.budget_id = p_id) then",
  "  if false then  -- empty",
  "-- empty")

m("another budget's lines make this one non-empty",
  "approve_budget",
  "  if not exists (select 1 from public.budget_lines l where l.budget_id = p_id) then",
  "  if not exists (select 1 from public.budget_lines l) then  -- anybody's",
  "-- anybody's")

m("the approval is not dated",
  "approve_budget",
  "     set status = 'approved', approved_at = now(), approved_by = auth.uid()",
  "     set status = 'approved', approved_at = null, approved_by = auth.uid()  -- whenever",
  "-- whenever")

m("the approval names nobody",
  "approve_budget",
  "     set status = 'approved', approved_at = now(), approved_by = auth.uid()",
  "     set status = 'approved', approved_at = now(), approved_by = null  -- anonymous",
  "-- anonymous")

m("every budget is approved",
  "approve_budget",
  "   where id = p_id;\n  return true;",
  "   where true;  -- all of them\n  return true;",
  "-- all of them")

m("CONTROL: a comment inside the block",
  "approve_budget",
  "  if v_b.status <> 'draft' then",
  "  if v_b.status <> 'draft' then  -- (control)",
  "(control)")

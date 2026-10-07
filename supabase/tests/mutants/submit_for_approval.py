# Mutants for public.submit_for_approval (0167) -- a document sent up
# its approval chain: whose it is, whether any rule covers it, and the
# steps the matching rules make.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0167_approval_workflow.sql \
#       supabase/tests/approvals.sql \
#       supabase/tests/mutants/submit_for_approval.py
#
# then again against `approval_state.sql`, which kills none of its own.
#
# RESULT: 18 mutants and a control. 17 killed by `approvals.sql`, eleven
# only after a rule-by-rule block there: every document submitted had
# matched exactly the rules there were, so no retired rule, no rule for
# another kind or type, no rule out of the document's reach and no two
# rules for one step were ever in the way; and the four refusals were
# never met.
#
# One EQUIVALENT:
#
#   a request with no steps is      `app.approval_required` filters the
#   left standing                   rules exactly as the step loop does,
#                                   so a document it says needs approval
#                                   always gets at least one step.

m("a sales document is read as a purchase",
  "submit_for_approval",
  "  if p_kind = 'sales_document' then",
  "  if false then  -- sales unread",
  "-- sales unread")

m("a document that does not exist is submitted in silence",
  "submit_for_approval",
  "  if v_org is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody submits",
  "submit_for_approval",
  "  if not app.can_write(v_org) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a document no rule covers is submitted anyway",
  "submit_for_approval",
  "  if not app.approval_required(v_org, p_kind, v_type, v_amount) then",
  "  if false then  -- always",
  "-- always")

m("an approved document is submitted again",
  "submit_for_approval",
  "  if app.is_approved(v_org, p_kind, p_entity_id) then",
  "  if false then  -- again",
  "-- again")

m("the request names nobody as raising it",
  "submit_for_approval",
  "  values (v_org, p_kind, p_entity_id, v_no, coalesce(v_amount, 0), auth.uid())",
  "  values (v_org, p_kind, p_entity_id, v_no, coalesce(v_amount, 0), null)  -- anonymous",
  "-- anonymous")

m("the request carries no amount",
  "submit_for_approval",
  "  values (v_org, p_kind, p_entity_id, v_no, coalesce(v_amount, 0), auth.uid())",
  "  values (v_org, p_kind, p_entity_id, v_no, 0, auth.uid())  -- free",
  "-- free")

m("another company's rules make the steps",
  "submit_for_approval",
  "     where rl.org_id = v_org and rl.entity_kind = p_kind and rl.is_active",
  "     where rl.entity_kind = p_kind and rl.is_active  -- any company",
  "-- any company")

m("a retired rule makes a step",
  "submit_for_approval",
  "     where rl.org_id = v_org and rl.entity_kind = p_kind and rl.is_active",
  "     where rl.org_id = v_org and rl.entity_kind = p_kind  -- retired too",
  "-- retired too")

m("a rule for another kind makes a step",
  "submit_for_approval",
  "     where rl.org_id = v_org and rl.entity_kind = p_kind and rl.is_active",
  "     where rl.org_id = v_org and rl.is_active  -- any kind",
  "-- any kind")

m("a rule for another type makes a step",
  "submit_for_approval",
  "       and (rl.doc_type is null or rl.doc_type = v_type)",
  "       and true  -- any type",
  "-- any type")

m("a rule above the amount makes a step",
  "submit_for_approval",
  "       and coalesce(v_amount, 0) >= rl.min_amount",
  "       and true  -- any amount",
  "-- any amount")

m("a rule AT the amount makes no step",
  "submit_for_approval",
  "       and coalesce(v_amount, 0) >= rl.min_amount",
  "       and coalesce(v_amount, 0) > rl.min_amount  -- above only",
  "-- above only")

m("two rules for one step make two steps",
  "submit_for_approval",
  "    select distinct on (rl.step_no) rl.step_no, rl.approver_role,",
  "    select rl.step_no, rl.approver_role,  -- every rule",
  "-- every rule")

m("the newest of two rules for a step wins",
  "submit_for_approval",
  "     order by rl.step_no, rl.created_at",
  "     order by rl.step_no, rl.created_at desc  -- newest",
  "-- newest")

m("a step forgets whom it names",
  "submit_for_approval",
  "    values (v_org, v_request, r.step_no, r.approver_role, r.approver_user_id);",
  "    values (v_org, v_request, r.step_no, r.approver_role, null);  -- nobody",
  "-- nobody")

m("a request with no steps is left standing",
  "submit_for_approval",
  "  if v_steps = 0 then",
  "  if false then  -- empty",
  "-- empty")

m("CONTROL: a comment inside the block",
  "submit_for_approval",
  "  if v_steps = 0 then",
  "  if v_steps = 0 then  -- (control)",
  "(control)")

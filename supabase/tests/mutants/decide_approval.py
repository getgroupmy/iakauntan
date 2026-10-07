# Mutants for public.decide_approval (0755, restating 0167's) -- one step of a document's
# approval chain: the step in front, decided by whoever it names or a
# holder of the role it asks for, never by whoever raised the document.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0755_a_named_approver_who_has_left_decides_nothing.sql \
#       supabase/tests/approvals.sql \
#       supabase/tests/mutants/decide_approval.py
#
# then again against `approval_state.sql`, which kills none.
#
# RESULT: 21 mutants and a control. 21 killed by `approvals.sql`, eleven
# only after a rule-by-rule block there. Whoever raised a document in
# the file never held the role that clears it, so the role check always
# refused them first and the self-approval guard was never what spoke;
# the rest were refusals tried without reading their words, and the
# record a decision leaves on the step and the request.
#
# The 21st is 0167's own shape. A step naming a PERSON was theirs after
# they left the company -- nothing asked whether they were still a
# member. Found by reading the guard, not by a mutant: a sweep only
# varies what is there. Asked on 7 October, answered "fix it"; 0755.

m("a missing request is decided in silence",
  "decide_approval",
  "  if not found then\n    raise exception 'No such approval request'",
  "  if false then  -- no such\n    raise exception 'No such approval request'",
  "-- no such")

m("a decided request is decided again",
  "decide_approval",
  "  if q.status <> 'pending' then",
  "  if false then  -- twice",
  "-- twice")

m("the last step is decided first",
  "decide_approval",
  "   order by step_no limit 1;",
  "   order by step_no desc limit 1;  -- back to front",
  "-- back to front")

m("a decided step is decided again",
  "decide_approval",
  "   where request_id = p_request_id and status = 'pending'\n   order by step_no limit 1;",
  "   where request_id = p_request_id  -- any step\n   order by step_no limit 1;",
  "-- any step")

m("a request with nothing left is decided anyway",
  "decide_approval",
  "  if not found then\n    raise exception 'Nothing left to decide on this request'",
  "  if false then  -- nothing waiting\n    raise exception 'Nothing left to decide on this request'",
  "-- nothing waiting")

m("a named step is anybody's",
  "decide_approval",
  "    if s.approver_user_id <> auth.uid() then",
  "    if false then  -- anyone",
  "-- anyone")

m("a named step is decided by the role",
  "decide_approval",
  "  if s.approver_user_id is not null then\n    if s.approver_user_id <> auth.uid() then",
  "  if false then  -- role instead\n    if s.approver_user_id <> auth.uid() then",
  "-- role instead")

m("a named approver who has left still decides (0167's shape)",
  "decide_approval",
  "    if not app.is_org_member(q.org_id) then",
  "    if false then  -- gone but named",
  "-- gone but named")

m("a role step is anybody's",
  "decide_approval",
  "  elsif not app.has_org_role(q.org_id, array[s.approver_role]) then",
  "  elsif false then  -- anyone",
  "-- anyone")

m("whoever raised it approves it",
  "decide_approval",
  "  if q.requested_by = auth.uid() then",
  "  if false then  -- self",
  "-- self")

m("a rejection approves the step",
  "decide_approval",
  "     set status = case when p_approve then 'approved'::app.approval_status\n                       else 'rejected'::app.approval_status end,",
  "     set status = 'approved'::app.approval_status,  -- always yes",
  "-- always yes")

m("the step does not say who decided it",
  "decide_approval",
  "         decided_by = auth.uid(), decided_at = now(), note = p_note",
  "         decided_by = null, decided_at = now(), note = p_note  -- anonymous",
  "-- anonymous")

m("the step does not say when",
  "decide_approval",
  "         decided_by = auth.uid(), decided_at = now(), note = p_note",
  "         decided_by = auth.uid(), decided_at = null, note = p_note  -- whenever",
  "-- whenever")

m("the step's note is dropped",
  "decide_approval",
  "         decided_by = auth.uid(), decided_at = now(), note = p_note",
  "         decided_by = auth.uid(), decided_at = now(), note = null  -- unsaid",
  "-- unsaid")

m("a rejection leaves the request pending",
  "decide_approval",
  "  if not p_approve then\n    update public.approval_requests",
  "  if false then  -- carry on\n    update public.approval_requests",
  "-- carry on")

m("a rejection is not dated",
  "decide_approval",
  "       set status = 'rejected', decided_at = now()",
  "       set status = 'rejected', decided_at = null  -- whenever",
  "-- whenever")

m("a rejection says it was something else",
  "decide_approval",
  "    return 'rejected';",
  "    return 'pending';  -- misreported",
  "-- misreported")

m("the request is approved at the first step",
  "decide_approval",
  "  if v_left = 0 then",
  "  if true then  -- first yes",
  "-- first yes")

m("the request is never approved",
  "decide_approval",
  "  if v_left = 0 then",
  "  if false then  -- never",
  "-- never")

m("an approval is not dated",
  "decide_approval",
  "       set status = 'approved', decided_at = now()",
  "       set status = 'approved', decided_at = null  -- whenever",
  "-- whenever")

m("an approval says it is still pending",
  "decide_approval",
  "    return 'approved';",
  "    return 'pending';  -- misreported",
  "-- misreported")

m("CONTROL: a comment inside the block",
  "decide_approval",
  "  -- May this person decide *this* step?",
  "  -- May this person decide *this* step? (control)",
  "(control)")

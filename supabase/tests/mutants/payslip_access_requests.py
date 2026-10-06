# Mutants for public.request_payslip_access, decide_payslip_access and
# revoke_payslip_access (0046) -- an auditor asks to read payslips, an
# administrator who is somebody else says yes for a fixed number of
# days, and can take it back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0046_hrms_payslip_access_rpcs.sql \
#       supabase/tests/payslip_access.sql \
#       supabase/tests/mutants/payslip_access_requests.py
#
# then again against `statutory.sql`, which kills none.
#
# RESULT: 32 mutants and a control. 32 killed by `payslip_access.sql`,
# seventeen only after a rule-by-rule block there. Most were refusals
# asserted by SQLSTATE alone with the next guard down raising the same
# code: a stranger is refused 42501 by the membership check and again by
# the auditor check, so either could go unnoticed. One was the guard the
# scheme rests on -- an auditor approving their own request had only
# been tried while they were still an auditor, whom the admin check
# stops first; the block promotes them to administrator and tries again.
# The rest were what a decision and a revocation write.

# --- request_payslip_access ------------------------------------------

m("a stranger asks for a company's payslips",
  "request_payslip_access",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a request needs no reason",
  "request_payslip_access",
  "  if coalesce(btrim(p_reason), '') = '' then",
  "  if p_reason is null then  -- blank will do",
  "-- blank will do")

m("somebody who runs payroll asks anyway",
  "request_payslip_access",
  "  if app.can_run_payroll(p_org_id) then",
  "  if false then  -- payroll too",
  "-- payroll too")

m("anybody, not only an auditor, asks",
  "request_payslip_access",
  "  if not app.has_org_role(p_org_id, array['auditor']::app.member_role[]) then",
  "  if false then  -- any member",
  "-- any member")

m("a period that ends before it starts is taken",
  "request_payslip_access",
  "     and p_period_to < p_period_from then",
  "     and false then  -- backwards",
  "-- backwards")

m("a one-day period is refused as backwards",
  "request_payslip_access",
  "     and p_period_to < p_period_from then",
  "     and p_period_to <= p_period_from then  -- a day is backwards",
  "-- a day is backwards")

m("a second pending request is taken",
  "request_payslip_access",
  "       and r.status = 'pending')\n  then",
  "       and false)  -- again\n  then",
  "-- again")

m("another auditor's pending request blocks mine",
  "request_payslip_access",
  "       and r.requested_by = auth.uid()\n",
  "       and true  -- anybody's\n",
  "-- anybody's")

m("a decided request blocks a new one",
  "request_payslip_access",
  "       and r.status = 'pending')\n  then",
  "       and true)  -- ever\n  then",
  "-- ever")

m("the reason is kept untrimmed",
  "request_payslip_access",
  "  values (p_org_id, auth.uid(), btrim(p_reason), p_period_from, p_period_to,",
  "  values (p_org_id, auth.uid(), p_reason, p_period_from, p_period_to,  -- as typed",
  "-- as typed")

m("the period is not kept",
  "request_payslip_access",
  "  values (p_org_id, auth.uid(), btrim(p_reason), p_period_from, p_period_to,",
  "  values (p_org_id, auth.uid(), btrim(p_reason), null, null,  -- any period",
  "-- any period")

m("the run and employee are not kept",
  "request_payslip_access",
  "          p_run_id, p_employee_id)",
  "          null, null)  -- everybody's",
  "-- everybody's")

# --- decide_payslip_access -------------------------------------------

m("a request that does not exist is decided in silence",
  "decide_payslip_access",
  "  if v_req.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody decides",
  "decide_payslip_access",
  "  if not app.can_admin(v_req.org_id) then",
  "  if false then  -- by anyone",
  "-- by anyone")

m("an auditor approves their own request",
  "decide_payslip_access",
  "  if v_req.requested_by = auth.uid() then",
  "  if false then  -- self",
  "-- self")

m("a decided request is decided again",
  "decide_payslip_access",
  "  if v_req.status <> 'pending' then",
  "  if false then  -- twice",
  "-- twice")

m("access that never expires is granted",
  "decide_payslip_access",
  "  if p_approve and coalesce(p_days, 0) <= 0 then",
  "  if p_approve and p_days < 0 then  -- for ever",
  "-- for ever")

m("a refusal needs a number of days",
  "decide_payslip_access",
  "  if p_approve and coalesce(p_days, 0) <= 0 then",
  "  if coalesce(p_days, 0) <= 0 then  -- even to say no",
  "-- even to say no")

m("a refusal grants",
  "decide_payslip_access",
  "    status = case when p_approve then 'approved'::app.access_request_status\n                  else 'rejected'::app.access_request_status end,",
  "    status = 'approved'::app.access_request_status,  -- always yes",
  "-- always yes")

m("nobody is named as the decider",
  "decide_payslip_access",
  "    decided_by = auth.uid(),",
  "    decided_by = null,  -- anonymous",
  "-- anonymous")

m("no time is recorded",
  "decide_payslip_access",
  "    decided_at = now(),",
  "    decided_at = null,  -- whenever",
  "-- whenever")

m("the note is dropped",
  "decide_payslip_access",
  "    decision_note = p_note,",
  "    decision_note = null,  -- unsaid",
  "-- unsaid")

m("access never expires",
  "decide_payslip_access",
  "                      then now() + make_interval(days => p_days) end",
  "                      then null end  -- for ever",
  "-- for ever")

m("access lasts a day longer",
  "decide_payslip_access",
  "                      then now() + make_interval(days => p_days) end",
  "                      then now() + make_interval(days => p_days + 1) end  -- a day more",
  "-- a day more")

m("a refusal still has an expiry",
  "decide_payslip_access",
  "    expires_at = case when p_approve\n",
  "    expires_at = case when true  -- dated anyway\n",
  "-- dated anyway")

# --- revoke_payslip_access -------------------------------------------

m("a request that does not exist is revoked in silence",
  "revoke_payslip_access",
  "  if v_req.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody revokes",
  "revoke_payslip_access",
  "  if not app.can_admin(v_req.org_id) then",
  "  if false then  -- by anyone",
  "-- by anyone")

m("a pending request is revoked",
  "revoke_payslip_access",
  "  if v_req.status <> 'approved' then",
  "  if false then  -- whatever it is",
  "-- whatever it is")

m("nobody is named as revoking it",
  "revoke_payslip_access",
  "    revoked_by = auth.uid(),",
  "    revoked_by = null,  -- anonymous",
  "-- anonymous")

m("no time is recorded for the revocation",
  "revoke_payslip_access",
  "    revoked_at = now(),",
  "    revoked_at = null,  -- whenever",
  "-- whenever")

m("a revocation with no note wipes the decision's",
  "revoke_payslip_access",
  "    decision_note = coalesce(p_note, decision_note)",
  "    decision_note = p_note  -- wiped",
  "-- wiped")

m("a revocation's note is not kept",
  "revoke_payslip_access",
  "    decision_note = coalesce(p_note, decision_note)",
  "    decision_note = decision_note  -- unsaid",
  "-- unsaid")

m("CONTROL: a comment inside the block",
  "request_payslip_access",
  "  if app.can_run_payroll(p_org_id) then",
  "  if app.can_run_payroll(p_org_id) then  -- (control)",
  "(control)")

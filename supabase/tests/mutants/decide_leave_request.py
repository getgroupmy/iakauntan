# Mutants for public.decide_leave_request (0037) -- approving or
# rejecting a filed leave request: who may, which requests, and what it
# does to the balance the request held.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0037_hrms_workflow_rpcs.sql \
#       supabase/tests/leave_requests.sql \
#       supabase/tests/mutants/decide_leave_request.py
#
# then again against `leave_year_shapes.sql`.
#
# RESULT: 19 mutants and a control. 19 killed across the two files, two
# of them only after a rule-by-rule block in `leave_year_shapes.sql`:
#
#   no time is recorded               nothing read `decided_at`, only
#                                     who decided
#   another employee's balance moves  every balance the decision moved
#                                     was the only one on that type and
#                                     year; a colleague's now sits beside
#                                     it, with a hold of their own

m("a request that does not exist is decided in silence",
  "decide_leave_request",
  "  if v_req.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("a decided request is decided again",
  "decide_leave_request",
  "  if v_req.status <> 'submitted' then",
  "  if false then  -- twice",
  "-- twice")

m("anybody decides",
  "decide_leave_request",
  "  if not (app.can_manage_hr(v_req.org_id)\n          or app.manages_employee(v_req.employee_id)) then",
  "  if false then  -- by anyone",
  "-- by anyone")

m("only HR decides, not the employee's manager",
  "decide_leave_request",
  "          or app.manages_employee(v_req.employee_id)) then",
  "          or false) then  -- no manager",
  "-- no manager")

m("only the manager decides, not HR",
  "decide_leave_request",
  "  if not (app.can_manage_hr(v_req.org_id)\n",
  "  if not (false  -- no HR\n",
  "-- no HR")

m("the balance is looked for in the year the request was filed",
  "decide_leave_request",
  "  v_year := extract(year from v_req.start_date)::integer;",
  "  v_year := extract(year from v_req.created_at)::integer;  -- filed",
  "-- filed")

m("a rejection approves",
  "decide_leave_request",
  "    status = case when p_approve then 'approved'::app.request_status\n                  else 'rejected'::app.request_status end,",
  "    status = 'approved'::app.request_status,  -- always yes",
  "-- always yes")

m("an approval rejects",
  "decide_leave_request",
  "    status = case when p_approve then 'approved'::app.request_status\n                  else 'rejected'::app.request_status end,",
  "    status = case when p_approve then 'rejected'::app.request_status\n                  else 'rejected'::app.request_status end,  -- always no",
  "-- always no")

m("nobody is named as the approver",
  "decide_leave_request",
  "    approver_id = auth.uid(),",
  "    approver_id = null,  -- anonymous",
  "-- anonymous")

m("no time is recorded",
  "decide_leave_request",
  "    decided_at = now(),",
  "    decided_at = null,  -- whenever",
  "-- whenever")

m("the note is dropped",
  "decide_leave_request",
  "    decision_note = p_note\n",
  "    decision_note = null  -- unsaid\n",
  "-- unsaid")

m("the hold stays on",
  "decide_leave_request",
  "    pending_days = greatest(pending_days - v_req.total_days, 0),",
  "    pending_days = pending_days,  -- held",
  "-- held")

m("the hold goes below nothing",
  "decide_leave_request",
  "    pending_days = greatest(pending_days - v_req.total_days, 0),",
  "    pending_days = pending_days - v_req.total_days,  -- negative",
  "-- negative")

m("the hold comes off entirely",
  "decide_leave_request",
  "    pending_days = greatest(pending_days - v_req.total_days, 0),",
  "    pending_days = 0,  -- every hold",
  "-- every hold")

m("a rejection consumes the days",
  "decide_leave_request",
  "    taken_days = taken_days + case when p_approve then v_req.total_days else 0 end",
  "    taken_days = taken_days + v_req.total_days  -- spent",
  "-- spent")

m("an approval consumes nothing",
  "decide_leave_request",
  "    taken_days = taken_days + case when p_approve then v_req.total_days else 0 end",
  "    taken_days = taken_days  -- free",
  "-- free")

m("another employee's balance moves",
  "decide_leave_request",
  "  where employee_id = v_req.employee_id\n    and leave_type_id",
  "  where true  -- everyone\n    and leave_type_id",
  "-- everyone")

m("another leave type's balance moves",
  "decide_leave_request",
  "    and leave_type_id = v_req.leave_type_id\n",
  "    and true  -- any type\n",
  "-- any type")

m("another year's balance moves",
  "decide_leave_request",
  "    and leave_year = v_year;",
  "    and true;  -- any year",
  "-- any year")

m("CONTROL: a comment inside the block",
  "decide_leave_request",
  "  -- The hold comes off either way; only an approval consumes the balance.",
  "  -- The hold comes off either way; only an approval consumes the balance. (control)",
  "(control)")

# Mutants for public.my_approvals (0169) -- the approval steps waiting on
# the person asking: the step in front of each request, theirs by name
# or by role, never on a document they raised.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0169_approval_state.sql \
#       supabase/tests/approvals.sql \
#       supabase/tests/mutants/my_approvals.py
#
# RESULT: 9 mutants and a control. 7 killed by `approvals.sql`, six only
# after a rule-by-rule block there: the inbox had only been read where
# it held the one request its reader could decide.
#
# Two EQUIVALENT, by the tables:
#
#   a decided step is still listed     the inbox takes the lowest PENDING
#                                      step number, and step numbers are
#                                      unique per request, so the step it
#                                      finds is pending.
#   a named step is listed for the     `approval_rules_one_approver`: a
#   role too                           rule names a role or a person, a
#                                      step copies it, and a named step's
#                                      role is null -- no role check
#                                      passes on null.

m("a stranger reads a company's desk",
  "my_approvals",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("another company's requests are listed",
  "my_approvals",
  "     where q.org_id = p_org_id\n       and q.status = 'pending'",
  "     where true  -- any company\n       and q.status = 'pending'",
  "-- any company")

m("a settled request is still listed",
  "my_approvals",
  "       and q.status = 'pending'\n       and s.status = 'pending'",
  "       and true  -- settled too\n       and s.status = 'pending'",
  "-- settled too")

m("a decided step is still listed",
  "my_approvals",
  "       and s.status = 'pending'\n",
  "       and true  -- decided too\n",
  "-- decided too")

m("a step further down the chain is listed",
  "my_approvals",
  "       and s.step_no = (select min(s2.step_no) from public.approval_steps s2\n                         where s2.request_id = q.id and s2.status = 'pending')",
  "       and true  -- any step",
  "-- any step")

m("a step named for somebody else is listed",
  "my_approvals",
  "       and (s.approver_user_id = auth.uid()\n            or (s.approver_user_id is null",
  "       and (s.approver_user_id is not null  -- anybody's\n            or (s.approver_user_id is null",
  "-- anybody's")

m("a named step is listed for the role too",
  "my_approvals",
  "            or (s.approver_user_id is null\n                and app.has_org_role",
  "            or (true  -- the role as well\n                and app.has_org_role",
  "-- the role as well")

m("a role step is listed for anybody",
  "my_approvals",
  "                and app.has_org_role(p_org_id, array[s.approver_role])))",
  "                and true))  -- any role",
  "-- any role")

m("my own document is on my desk",
  "my_approvals",
  "       and q.requested_by is distinct from auth.uid()",
  "       and true  -- mine too",
  "-- mine too")

m("CONTROL: a comment inside the block",
  "my_approvals",
  "  if not app.is_org_member(p_org_id) then",
  "  if not app.is_org_member(p_org_id) then  -- (control)",
  "(control)")

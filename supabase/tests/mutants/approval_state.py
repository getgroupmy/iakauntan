# Mutants for public.approval_state (0169) -- what a document's screen
# says about its approval: whether it needs one, whether it has one,
# the step it waits on, who that is, and whether it is the reader.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0169_approval_state.sql \
#       supabase/tests/approval_state.sql \
#       supabase/tests/mutants/approval_state.py
#
# then again against `approvals.sql`, which kills none the first misses.
#
# RESULT: 11 mutants and a control. 11 killed by `approval_state.sql`,
# five only after a rule-by-rule block there: every request had one
# step, held by a role, and was read while it waited -- so a settled
# request, a decided step, a second waiting step, a step naming a person
# and a step that is somebody else's were all unasserted.

m("a sales document is read as something else",
  "approval_state",
  "  if p_kind = 'sales_document' then",
  "  if false then  -- sales unread",
  "-- sales unread")

m("a stranger is told a document's state",
  "approval_state",
  "  if v_org is null or not app.is_org_member(v_org) then",
  "  if v_org is null then  -- anyone",
  "-- anyone")

m("another document's request is reported",
  "approval_state",
  "       and q.entity_id = p_entity_id and q.status = 'pending'",
  "       and q.status = 'pending'  -- any document",
  "-- any document")

m("a settled request is reported as waiting",
  "approval_state",
  "       and q.entity_id = p_entity_id and q.status = 'pending'",
  "       and q.entity_id = p_entity_id  -- settled too",
  "-- settled too")

m("a decided step is reported as waiting",
  "approval_state",
  "         where s2.request_id = q.id and s2.status = 'pending'",
  "         where s2.request_id = q.id  -- decided too",
  "-- decided too")

m("the last step is reported as the one waiting",
  "approval_state",
  "         order by s2.step_no limit 1) s on true;",
  "         order by s2.step_no desc limit 1) s on true;  -- the end",
  "-- the end")

m("a named approver is not named",
  "approval_state",
  "          where pr.id = s.approver_user_id),",
  "          where false),  -- unnamed",
  "-- unnamed")

m("a role step says nothing of the role",
  "approval_state",
  "             else 'an ' || replace(s.approver_role::text, '_', ' ') end),",
  "             else null end),  -- silent",
  "-- silent")

m("a named step is mine whoever I am",
  "approval_state",
  "      coalesce(s.approver_user_id = auth.uid()\n",
  "      coalesce(s.approver_user_id is not null  -- anybody's\n",
  "-- anybody's")

m("a role step is mine without the role",
  "approval_state",
  "                   and app.has_org_role(v_org, array[s.approver_role])),",
  "                   and true),  -- any role",
  "-- any role")

m("my own document waits on me",
  "approval_state",
  "        and q.requested_by is distinct from auth.uid()",
  "        and true  -- mine too",
  "-- mine too")

m("CONTROL: a comment inside the block",
  "approval_state",
  "  if v_org is null or not app.is_org_member(v_org) then",
  "  if v_org is null or not app.is_org_member(v_org) then  -- (control)",
  "(control)")

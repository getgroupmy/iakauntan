# Mutants for public.update_leave_contact (0395) -- the number to call
# while somebody is away: the request must exist; only the employee on
# leave, or HR, and a caller with NO employee record is not the
# employee; only while it is an absence (draft, submitted, approved)
# and not over (its last day is still today); the number trimmed, and a
# blank one clears it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0395_the_number_to_call_while_they_are_away.sql \
#       supabase/tests/leave_requests.sql \
#       supabase/tests/mutants/update_leave_contact.py
#
# RESULT: 10 mutants and a control, all killed by `leave_requests.sql`;
# seven before three assertions were added: no request had been a
# draft, none ended today -- so `<` against `<=` on the last day was
# open -- and none was missing.

m("a request that does not exist is not said so",
  "update_leave_contact",
  "  if v_req.id is null then\n    raise exception 'No such leave request.'",
  "  if false then  -- no such request\n    raise exception 'No such leave request.'",
  "-- no such request")

m("anybody changes the contact",
  "update_leave_contact",
  "  if v_req.employee_id is distinct from v_me\n     and not app.can_manage_hr(v_req.org_id) then",
  "  if false then  -- whoever asks\n",
  "-- whoever asks")

m("a caller with no employee record is taken for the employee",
  "update_leave_contact",
  "  if v_req.employee_id is distinct from v_me",
  "  if v_req.employee_id <> v_me  -- null waved through",
  "-- null waved through")

m("HR may not change it",
  "update_leave_contact",
  "     and not app.can_manage_hr(v_req.org_id) then",
  "     then  -- HR refused too",
  "-- HR refused too")

m("a cancelled request's contact is changed",
  "update_leave_contact",
  "  if v_req.status not in ('draft', 'submitted', 'approved') then",
  "  if false then  -- any status",
  "-- any status")

m("a draft's contact cannot be changed",
  "update_leave_contact",
  "  if v_req.status not in ('draft', 'submitted', 'approved') then",
  "  if v_req.status not in ('submitted', 'approved') then  -- draft refused",
  "-- draft refused")

m("a past absence's contact is changed",
  "update_leave_contact",
  "  if v_req.end_date < (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if false then  -- past too",
  "-- past too")

m("an absence ending today cannot be changed",
  "update_leave_contact",
  "  if v_req.end_date < (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if v_req.end_date <= (now() at time zone 'Asia/Kuala_Lumpur')::date then  -- not today",
  "-- not today")

m("the number is kept untrimmed",
  "update_leave_contact",
  "     set contact_while_away = nullif(btrim(p_contact), '')",
  "     set contact_while_away = nullif(p_contact, '')  -- untrimmed",
  "-- untrimmed")

m("a blank number is kept as blank",
  "update_leave_contact",
  "     set contact_while_away = nullif(btrim(p_contact), '')",
  "     set contact_while_away = btrim(p_contact)  -- blank kept",
  "-- blank kept")

m("CONTROL: a comment inside the block",
  "update_leave_contact",
  "  if v_req.status not in ('draft', 'submitted', 'approved') then",
  "  if v_req.status not in ('draft', 'submitted', 'approved') then  -- (control)",
  "(control)")

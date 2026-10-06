# Mutants for public.submit_leave_request (0507, the 10-argument
# overload; 0737's idempotent wrapper calls it) -- an employee's leave
# request: whose it is, whether the days are there, and the hold it
# places on the balance until somebody decides.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0507_an_employee_belongs_to_one_company.sql \
#       supabase/tests/leave_requests.sql \
#       supabase/tests/mutants/submit_leave_request.py
#
# then again against `leave_year_shapes.sql`, `tenant_foreign_keys.sql`
# and `idempotency.sql`.
#
# RESULT: 14 mutants and a control. 14 killed: leave_requests.sql takes
# thirteen, leave_year_shapes.sql the carried-forward days.
#
#   Unsweepable until 6 October: the harness's superseded-migration
#   guard matched by NAME, so 0737's 11-argument idempotent wrapper made
#   it refuse every run against 0507 and point at the wrapper. It now
#   matches the overload's argument count (`mutate_sql.arity`).

m("a login with no employee record files leave",
  "submit_leave_request",
  "  if v_emp is null then\n    raise exception 'No employee record is linked to this login'",
  "  if false then\n    raise exception 'No employee record is linked to this login'  -- nobody",
  "-- nobody")

m("anybody files leave for anybody",
  "submit_leave_request",
  "  if v_emp is distinct from v_me\n     and not app.can_manage_hr(p_org_id) then",
  "  if false then  -- for anyone",
  "-- for anyone")

m("a member off the payroll files for an employee",
  "submit_leave_request",
  "  if v_emp is distinct from v_me\n",
  "  if v_emp <> v_me  -- null slips\n",
  "-- null slips")

m("another company's employee is named",
  "submit_leave_request",
  "  if not exists (select 1 from public.employees e\n                  where e.id = v_emp and e.org_id = p_org_id) then",
  "  if false then  -- any company",
  "-- any company")

m("the last day before the first is accepted",
  "submit_leave_request",
  "  if p_end_date < p_start_date then",
  "  if false then  -- backwards",
  "-- backwards")

m("a one-day request is refused as backwards",
  "submit_leave_request",
  "  if p_end_date < p_start_date then",
  "  if p_end_date <= p_start_date then  -- one day",
  "-- one day")

m("paid leave is never checked against the balance",
  "submit_leave_request",
  "  if v_type.is_paid then",
  "  if false then  -- unchecked",
  "-- unchecked")

m("carried-forward days are not counted as available",
  "submit_leave_request",
  "    select coalesce(entitled_days, 0) + coalesce(carried_forward, 0)",
  "    select coalesce(entitled_days, 0)  -- no carry",
  "-- no carry")

m("days already pending are counted as available",
  "submit_leave_request",
  "         - coalesce(pending_days, 0)\n",
  "  -- pending ignored\n",
  "-- pending ignored")

m("the balance is another year's",
  "submit_leave_request",
  "       and leave_year = v_year;",
  "       and leave_year = v_year - 1;  -- last year",
  "-- last year")

m("a request for exactly what is left is refused",
  "submit_leave_request",
  "    if v_available is not null and p_total_days > v_available then",
  "    if v_available is not null and p_total_days >= v_available then  -- exactly",
  "-- exactly")

m("a blank contact is stored as given",
  "submit_leave_request",
  "    nullif(btrim(p_contact_while_away), ''),",
  "    p_contact_while_away,  -- blank kept",
  "-- blank kept")

m("the request holds nothing against the balance",
  "submit_leave_request",
  "    set pending_days = public.leave_balances.pending_days + p_total_days;",
  "    set pending_days = public.leave_balances.pending_days;  -- no hold",
  "-- no hold")

m("the hold replaces what was pending",
  "submit_leave_request",
  "    set pending_days = public.leave_balances.pending_days + p_total_days;",
  "    set pending_days = p_total_days;  -- replaced",
  "-- replaced")

m("CONTROL: a comment inside the block",
  "submit_leave_request",
  "  -- Held against the balance while it awaits a decision, so two requests",
  "  -- CONTROL\n  -- Held against the balance while it awaits a decision, so two requests",
  "-- CONTROL")

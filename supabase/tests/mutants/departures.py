# Mutants for app.employee_departure_guard and public.reinstate_employee
# (0371) -- somebody who has left has a last working day, on or after the
# day they joined; and bringing them back clears the departure.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0371_the_leaver_who_was_still_being_paid.sql \
#       supabase/tests/departures.sql \
#       supabase/tests/mutants/departures.py
#
# RESULT: 16 mutants and a control. 16 killed by `departures.sql`,
# eleven only after a rule-by-rule block there; `payroll_shapes.sql`,
# `employee_documents.sql` and `leave_year_shapes.sql` touch a leaver
# and kill none. The guard had only been reached through
# `record_departure`, whose own check refuses a date before the hire
# date first; nobody retired; no saved leaver's date was moved; no row
# already in a leaving state was edited while breaking the rule; and
# "clears all three fields" was asserted of a row where two had never
# been set.

# --- employee_departure_guard ----------------------------------------

m("a retired employee needs no last day",
  "employee_departure_guard",
  "  if new.employment_status not in ('resigned', 'terminated', 'retired') then",
  "  if new.employment_status not in ('resigned', 'terminated') then  -- retired free",
  "-- retired free")

m("nobody needs a last day",
  "employee_departure_guard",
  "  if new.employment_status not in ('resigned', 'terminated', 'retired') then",
  "  if true then  -- no guard",
  "-- no guard")

m("an unchanged leaver is checked again",
  "employee_departure_guard",
  "  if tg_op = 'UPDATE'\n     and old.employment_status = new.employment_status",
  "  if false  -- every save\n     and old.employment_status = new.employment_status",
  "-- every save")

m("moving the last day is not checked",
  "employee_departure_guard",
  "     and old.last_working_date is not distinct from new.last_working_date then",
  "     and true then  -- the date may move",
  "-- the date may move")

m("a change of departure is not checked",
  "employee_departure_guard",
  "     and old.employment_status = new.employment_status\n",
  "     and true  -- any status\n",
  "-- any status")

m("a leaver needs no last day",
  "employee_departure_guard",
  "  if new.last_working_date is null then",
  "  if false then  -- undated",
  "-- undated")

m("a last day may come before the first",
  "employee_departure_guard",
  "  if new.last_working_date < new.hire_date then",
  "  if false then  -- before they joined",
  "-- before they joined")

m("a last day on the first day is refused",
  "employee_departure_guard",
  "  if new.last_working_date < new.hire_date then",
  "  if new.last_working_date <= new.hire_date then  -- one-day job",
  "-- one-day job")

# --- reinstate_employee ----------------------------------------------

m("an employee that does not exist is reinstated in silence",
  "reinstate_employee",
  "  if v_emp.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody reinstates",
  "reinstate_employee",
  "  if not app.can_manage_hr(v_emp.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a confirmed employee comes back on probation",
  "reinstate_employee",
  "    employment_status  = case when v_emp.confirmation_date is null\n                              then 'probation'::app.employment_status\n                              else 'active'::app.employment_status end,",
  "    employment_status  = 'probation'::app.employment_status,  -- start again",
  "-- start again")

m("an unconfirmed employee comes back confirmed",
  "reinstate_employee",
  "    employment_status  = case when v_emp.confirmation_date is null\n                              then 'probation'::app.employment_status\n                              else 'active'::app.employment_status end,",
  "    employment_status  = 'active'::app.employment_status,  -- skip probation",
  "-- skip probation")

m("the last day stays",
  "reinstate_employee",
  "    last_working_date  = null,",
  "    last_working_date  = last_working_date,  -- still leaving",
  "-- still leaving")

m("the resignation stays",
  "reinstate_employee",
  "    resignation_date   = null,",
  "    resignation_date   = resignation_date,  -- still resigned",
  "-- still resigned")

m("the reason they were let go stays",
  "reinstate_employee",
  "    termination_reason = null,",
  "    termination_reason = termination_reason,  -- on file",
  "-- on file")

m("another employee is reinstated",
  "reinstate_employee",
  "    updated_at         = now()\n  where id = p_employee;",
  "    updated_at         = now()\n  where true;  -- everybody",
  "-- everybody")

m("CONTROL: a comment inside the block",
  "employee_departure_guard",
  "  if new.last_working_date is null then",
  "  if new.last_working_date is null then  -- (control)",
  "(control)")

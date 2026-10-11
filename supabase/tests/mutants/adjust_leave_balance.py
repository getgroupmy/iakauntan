# Mutants for public.adjust_leave_balance (0812) -- HR adds days, more
# or fewer, to an employee's leave balance for a year, with a reason,
# and the change is kept beside who made it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0812_a_leave_balance_is_adjusted_with_a_reason.sql \
#       supabase/tests/leave_adjustments.sql \
#       supabase/tests/mutants/adjust_leave_balance.py
#
# RESULT: 13 mutants and a control, all 13 killed by
# `leave_adjustments.sql`, new in `0812`. Four of the refusals, deleted,
# are refused by something else instead -- the employee's missing org,
# the two check constraints on the log, the same-org key -- and are
# killed because the file asks for the function's own words.

F = "adjust_leave_balance"

m("anybody adjusts a balance", F,
  "  if not app.can_manage_hr(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")
m("an employee who is not there is not said so", F,
  "  if v_org is null then\n    raise exception 'No such employee.' using errcode = 'P0002';",
  "  if false then  -- nobody asked\n    raise exception 'No such employee.' using errcode = 'P0002';",
  "-- nobody asked")
m("another company's kind of leave is taken", F,
  "                  where t.id = p_leave_type_id and t.org_id = v_org) then",
  "                  where t.id = p_leave_type_id) then  -- any company's",
  "-- any company's")
m("no reason is asked", F,
  "  if coalesce(btrim(p_reason), '') = '' then",
  "  if false then  -- no reason",
  "-- no reason")
m("a reason of spaces is a reason", F,
  "  if coalesce(btrim(p_reason), '') = '' then",
  "  if coalesce(p_reason, '') = '' then  -- spaces",
  "-- spaces")
m("an adjustment of no days is taken", F,
  "  if v_days = 0 then",
  "  if false then  -- nothing",
  "-- nothing")
m("an adjustment replaces the last", F,
  "     set adjustment_days = public.leave_balances.adjustment_days + excluded.adjustment_days,",
  "     set adjustment_days = excluded.adjustment_days,  -- replaced",
  "-- replaced")
m("the adjustment is not kept", F,
  "  insert into public.leave_balance_adjustments\n    (org_id, employee_id, leave_type_id, leave_year, days, reason, adjusted_by)\n  values (v_org, p_employee_id, p_leave_type_id, p_leave_year, v_days,\n          btrim(p_reason), auth.uid());",
  "  perform 1;  -- unkept",
  "-- unkept")
m("nobody is named beside it", F,
  "          btrim(p_reason), auth.uid());",
  "          btrim(p_reason), null);  -- nobody",
  "-- nobody")
m("the reason is kept with its spaces", F,
  "          btrim(p_reason), auth.uid());",
  "          p_reason, auth.uid());  -- spaces kept",
  "-- spaces kept")
m("the record says the wrong way round", F,
  "  values (v_org, p_employee_id, p_leave_type_id, p_leave_year, v_days,\n          btrim(p_reason), auth.uid());",
  "  values (v_org, p_employee_id, p_leave_type_id, p_leave_year, -v_days,  -- signed\n          btrim(p_reason), auth.uid());",
  "-- signed")
m("what is left forgets what is held", F,
  "         + coalesce(b.adjustment_days, 0) - coalesce(b.taken_days, 0)\n         - coalesce(b.pending_days, 0)",
  "         + coalesce(b.adjustment_days, 0) - coalesce(b.taken_days, 0)  -- unheld",
  "-- unheld")
m("what is left is any year's", F,
  "     and b.leave_type_id = p_leave_type_id\n     and b.leave_year = p_leave_year;",
  "     and b.leave_type_id = p_leave_type_id;  -- any year",
  "-- any year")

m("CONTROL", F,
  "  v_left numeric;\nbegin",
  "  v_left numeric;  -- control\nbegin",
  "-- control")

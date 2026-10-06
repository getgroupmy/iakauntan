# Mutants for app.roll_leave_year (0058) -- January's rollover: a
# balance for every active leave type and every employee still here,
# carrying forward what was left, capped by the type's own limit.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0058_periodic_jobs.sql \
#       supabase/tests/leave_year_shapes.sql \
#       supabase/tests/mutants/roll_leave_year.py
#
# then again against `scheduled_work.sql`.
#
# RESULT: 20 mutants and a control. 19 killed, all by
# `leave_year_shapes.sql` (`scheduled_work.sql` only names the job and
# kills none), five of them only after a rule-by-rule block there:
#
#   somebody dismissed is rolled          everybody who had left had
#                                         RESIGNED
#   the carry is read from the wrong      last year had one balance, so
#   leave type                            any type's was the right one
#   an overdrawn year carries a debt      no year was overdrawn
#   the type's cap is ignored             every carry was under its cap
#   nothing is counted                    nothing read the return value
#
# One EQUIVALENT, and it stays so:
#
#   a type with no cap carries everything  `max_carry_forward` is NOT
#                                          NULL with a default of nought,
#                                          so the coalesce's fallback is
#                                          never reached. The roll's own
#                                          section asserts the column and
#                                          the default.

m("another company's leave types are rolled",
  "roll_leave_year",
  "     where org_id = p_org_id and is_active\n",
  "     where is_active  -- every company\n",
  "-- every company")

m("a retired leave type is rolled",
  "roll_leave_year",
  "     where org_id = p_org_id and is_active\n",
  "     where org_id = p_org_id  -- retired too\n",
  "-- retired too")

m("another company's staff are rolled",
  "roll_leave_year",
  "       where e.org_id = p_org_id\n",
  "       where true  -- every company's staff\n",
  "-- every company's staff")

m("somebody who resigned is rolled",
  "roll_leave_year",
  "         and e.employment_status not in ('resigned', 'terminated')",
  "         and e.employment_status not in ('terminated')  -- resigned too",
  "-- resigned too")

m("somebody dismissed is rolled",
  "roll_leave_year",
  "         and e.employment_status not in ('resigned', 'terminated')",
  "         and e.employment_status not in ('resigned')  -- dismissed too",
  "-- dismissed too")

m("the carry is read from this year, not last",
  "roll_leave_year",
  "         and b.leave_year = p_year - 1;",
  "         and b.leave_year = p_year;  -- this year",
  "-- this year")

m("the carry is read from the wrong leave type",
  "roll_leave_year",
  "       where b.employee_id = v_emp.id and b.leave_type_id = v_type.id\n",
  "       where b.employee_id = v_emp.id  -- any type\n",
  "-- any type")

m("last year's entitlement is not counted",
  "roll_leave_year",
  "        greatest(coalesce(v_prev.entitled_days, 0)\n",
  "        greatest(0  -- no entitlement\n",
  "-- no entitlement")

m("last year's carry is not carried again",
  "roll_leave_year",
  "               + coalesce(v_prev.carried_forward, 0)\n",
  "               + 0  -- no carry\n",
  "-- no carry")

m("an adjustment is not counted",
  "roll_leave_year",
  "               + coalesce(v_prev.adjustment_days, 0)\n",
  "               + 0  -- no adjustment\n",
  "-- no adjustment")

m("an adjustment counts against",
  "roll_leave_year",
  "               + coalesce(v_prev.adjustment_days, 0)\n",
  "               - coalesce(v_prev.adjustment_days, 0)  -- minus\n",
  "-- minus")

m("leave taken is not taken off",
  "roll_leave_year",
  "               - coalesce(v_prev.taken_days, 0), 0),",
  "               - 0, 0),  -- untaken",
  "-- untaken")

m("an overdrawn year carries a debt",
  "roll_leave_year",
  "               - coalesce(v_prev.taken_days, 0), 0),",
  "               - coalesce(v_prev.taken_days, 0), -1e9),  -- a debt",
  "-- a debt")

m("the type's cap is ignored",
  "roll_leave_year",
  "        coalesce(v_type.max_carry_forward, 0));",
  "        1e9);  -- uncapped",
  "-- uncapped")

m("a type with no cap carries everything",
  "roll_leave_year",
  "        coalesce(v_type.max_carry_forward, 0));",
  "        coalesce(v_type.max_carry_forward, 1e9));  -- no cap, no limit",
  "-- no cap, no limit")

m("the new year is entitled to last year's days",
  "roll_leave_year",
  "              app.leave_entitlement(v_type, v_emp.hire_date, p_year), v_carry)",
  "              app.leave_entitlement(v_type, v_emp.hire_date, p_year - 1), v_carry)  -- last year's",
  "-- last year's")

m("the new year is entitled to the type's default",
  "roll_leave_year",
  "              app.leave_entitlement(v_type, v_emp.hire_date, p_year), v_carry)",
  "              v_type.default_days, v_carry)  -- flat",
  "-- flat")

m("nothing is carried",
  "roll_leave_year",
  "              app.leave_entitlement(v_type, v_emp.hire_date, p_year), v_carry)",
  "              app.leave_entitlement(v_type, v_emp.hire_date, p_year), 0)  -- fresh",
  "-- fresh")

m("an existing balance is counted as rolled",
  "roll_leave_year",
  "      if found then v_n := v_n + 1; end if;",
  "      v_n := v_n + 1;  -- every one",
  "-- every one")

m("nothing is counted",
  "roll_leave_year",
  "      if found then v_n := v_n + 1; end if;",
  "      null;  -- uncounted",
  "-- uncounted")

m("CONTROL: a comment inside the block",
  "roll_leave_year",
  "      -- forward is how leave liability grows unnoticed.",
  "      -- forward is how leave liability grows unnoticed. (control)",
  "(control)")

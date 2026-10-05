# Mutants for the three small statutory helpers in 0029:
# app.round_statutory, app.epf_category and app.age_at.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0029_hrms_statutory_functions.sql \
#       supabase/tests/statutory_schedules.sql \
#       supabase/tests/mutants/rounding_and_category.py
#
# Small functions; every statutory figure in the product passes through
# at least one. round_statutory decides the sen on every EPF, SOCSO, EIS
# and PCB line, epf_category decides which population an employee is
# charged as, and age_at decides the 60 boundary.
#
# RESULT, 5 October: 8 mutants, and the eighth FOUND A REAL GAP.
#
#   statutory_schedules.sql  kills 7 -- all three rounding modes and the
#                            default, the permanent-resident rule, and
#                            the 60 boundary from both sides
#   age_at's null default     SURVIVED every file that calls it. Nothing
#                            asserted that a missing date of birth is
#                            assumed to be THIRTY -- and that number
#                            decides an EPF rate, because epf_category
#                            flips at 60. Two assertions were added to
#                            payroll_engine_sweep.sql beside the
#                            existing boundary checks, and the mutant
#                            now dies: "no birthday on file is treated
#                            as thirty: expected 30, got 60".
#
# Note `age_at` is NOT called by statutory_schedules.sql, so run its
# mutant against payroll_engine_sweep.sql or payroll_shapes.sql. A
# survivor against a file that never calls the function says nothing.

m("up_ringgit rounds DOWN, so every ceiling becomes a floor",
  "round_statutory",
  "    when 'up_ringgit'   then ceil(p_amount)",
  "    when 'up_ringgit'   then floor(p_amount)",
  "then floor(p_amount)")

m("nearest_5sen rounds to the nearest SEN instead",
  "round_statutory",
  "    when 'nearest_5sen' then round(p_amount * 20) / 20",
  "    when 'nearest_5sen' then round(p_amount, 2)  -- 5sen dropped",
  "-- 5sen dropped")

m("nearest_5sen rounds to the nearest TEN sen",
  "round_statutory",
  "then round(p_amount * 20) / 20",
  "then round(p_amount * 10) / 10",
  "round(p_amount * 10) / 10")

m("the default mode truncates the sen instead of rounding them",
  "round_statutory",
  "    else round(p_amount, 2)\n  end;",
  "    else trunc(p_amount, 2)\n  end;",
  "else trunc(p_amount, 2)")

m("a permanent resident is charged as a non-citizen",
  "epf_category",
  "    when p_residency in ('citizen', 'permanent_resident')",
  "    when p_residency in ('citizen')  -- PR dropped",
  "-- PR dropped")

m("the citizen 60 boundary moves to 61",
  "epf_category",
  "      then case when p_age >= 60 then 'citizen_60plus'"
  " else 'citizen_under60' end",
  "      then case when p_age >= 61 then 'citizen_60plus'"
  " else 'citizen_under60' end",
  "p_age >= 61 then 'citizen_60plus'")

m("the non-citizen 60 boundary excludes somebody who is exactly 60",
  "epf_category",
  "      else case when p_age >= 60 then 'noncitizen_60plus'",
  "      else case when p_age > 60 then 'noncitizen_60plus'",
  "when p_age > 60 then 'noncitizen_60plus'")

m("a missing date of birth is assumed to be 60, not 30",
  "age_at",
  "  select case when p_dob is null then 30",
  "  select case when p_dob is null then 60",
  "when p_dob is null then 60")

m("CONTROL -- a comment inside the round_statutory block",
  "round_statutory",
  "  select case p_mode",
  "  -- CONTROL: this line cannot change a number.\n  select case p_mode",
  "-- CONTROL: this line cannot change a number.")

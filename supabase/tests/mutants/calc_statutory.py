# Mutants for app.calc_statutory -- EPF, SOCSO and EIS contributions.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0404_the_wage_that_fell_between_two_bands.sql \
#       supabase/tests/<file>.sql \
#       supabase/tests/mutants/calc_statutory.py
#
# CLAUDE.md's second rule is that anything touching EPF, SOCSO, EIS, PCB
# or an SSM deadline needs a test that would fail if the number moved.
# Before 5 October that had never been MEASURED; `bank_rules.py` was the
# only mutant file here. Every mutant below moves a statutory number.
#
# RESULT, 5 October: all 8 killed by the suite, control surviving every
# run. But NOT by any one file, and that is the thing to carry:
#
#   statutory.sql            4 of 8 -- the SOCSO ceiling, the KWSP RM20
#                            round-up, its direction, and the rate swap
#   statutory_schedules.sql  3 more -- the is_verified contract `0404`
#                            exists for, a band's flat amount, and the
#                            unpaid-month guard
#   statutory_changeover.sql the last -- band selection order
#   payroll_run.sql          none of these
#
# **A per-file score understates the suite.** statutory.sql alone reads
# 4 of 8, which looks like four missing assertions and is not: three of
# those four are caught by statutory_schedules.sql and the fourth by
# statutory_changeover.sql. `mutate_sql.py` takes ONE test file, CI runs
# all of them, so a survivor is only a gap once every file that calls the
# function has been tried. Four files call this one.
#
# Nearly reported as a gap: "a wage no band covers reports the schedule
# as verified" survives statutory.sql, and that is the exact defect
# `0404` was written to fix. It would have read as the fix being
# unprotected. statutory_schedules.sql kills it.

m("the insured ceiling ignored, so high wages over-contribute",
  "calc_statutory",
  "  v_wage := least(p_wage, coalesce(v_rate.wage_ceiling, p_wage));",
  "  v_wage := p_wage;  -- ceiling dropped",
  "-- ceiling dropped")

m("KWSP's round-up to the next RM20 removed",
  "calc_statutory",
  "    v_wage := ceil(v_wage / v_sched.wage_round_up_to) "
  "* v_sched.wage_round_up_to;",
  "    v_wage := v_wage;  -- round-up dropped",
  "-- round-up dropped")

m("the wage rounded DOWN to the band instead of up",
  "calc_statutory",
  "    v_wage := ceil(v_wage / v_sched.wage_round_up_to)",
  "    v_wage := floor(v_wage / v_sched.wage_round_up_to)",
  "v_wage := floor(v_wage")

m("the lowest matching band wins instead of the highest",
  "calc_statutory",
  "   order by r.wage_from desc\n   limit 1;",
  "   order by r.wage_from asc\n   limit 1;",
  "order by r.wage_from asc")

m("a wage no band covers reports the schedule as verified (the 0404 defect)",
  "calc_statutory",
  "  if v_rate.id is null then\n"
  "    return query select 0::numeric, 0::numeric, v_sched.id, false;",
  "  if v_rate.id is null then\n"
  "    return query select 0::numeric, 0::numeric, v_sched.id,"
  " v_sched.is_verified;",
  "v_sched.id, v_sched.is_verified;\n    return;\n  end if;\n\n"
  "  -- Contributions stop")

m("a flat band amount ignored in favour of the percentage",
  "calc_statutory",
  "  v_ee := coalesce(v_rate.employee_amount,\n"
  "                   app.round_statutory(v_wage * v_rate.employee_rate / 100,",
  "  v_ee := coalesce(null::numeric,\n"
  "                   app.round_statutory(v_wage * v_rate.employee_rate / 100,",
  "coalesce(null::numeric,")

m("the employee pays the employer's rate",
  "calc_statutory",
  "                   app.round_statutory(v_wage * v_rate.employee_rate / 100,\n"
  "                                       v_sched.result_rounding));",
  "                   app.round_statutory(v_wage * v_rate.employer_rate / 100,\n"
  "                                       v_sched.result_rounding));"
  "  -- swapped",
  "/ 100,\n                                       v_sched.result_rounding));"
  "  -- swapped")

m("an unpaid month contributes, because the guard lost its equals",
  "calc_statutory",
  "  if p_wage <= 0 then",
  "  if p_wage < 0 then",
  "if p_wage < 0 then")

m("CONTROL -- a comment inside the function block",
  "calc_statutory",
  "begin\n  v_sched := app.statutory_schedule_on(p_body, p_date);",
  "begin\n  -- CONTROL: this line cannot change a number.\n"
  "  v_sched := app.statutory_schedule_on(p_body, p_date);",
  "-- CONTROL: this line cannot change a number.")

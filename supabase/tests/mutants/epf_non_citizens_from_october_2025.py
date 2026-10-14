# Mutants for 0906 -- EPF for non-citizens at 2% and 2% from October
# 2025, on the wage itself, with the pre-1998 member on the old terms.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0906_epf_for_non_citizens_from_october_2025.sql \
#       supabase/tests/epf_non_citizens_from_october_2025.sql \
#       supabase/tests/mutants/epf_non_citizens_from_october_2025.py

m("a band's own step is ignored",
  'calc_statutory',
  "  v_step := coalesce(v_rate.wage_round_up_to, v_sched.wage_round_up_to);\n",
  "  v_step := v_sched.wage_round_up_to;  -- table only\n",
  '-- table only')

m("the table's step is ignored",
  'calc_statutory',
  "  v_step := coalesce(v_rate.wage_round_up_to, v_sched.wage_round_up_to);\n",
  "  v_step := v_rate.wage_round_up_to;  -- band only\n",
  '-- band only')

m('the pre-1998 flag is not read',
  'epf_category',
  "    when coalesce(p_pre_august_1998, false)\n",
  "    when false  -- no flag\n",
  '-- no flag')

m('the pre-1998 member turns sixty a year late',
  'epf_category',
  "      then case when p_age >= 60 then 'noncitizen_pre1998_60plus'\n",
  "      then case when p_age >= 61 then 'noncitizen_pre1998_60plus'  -- 61\n",
  '-- 61')

m('the payroll run does not pass the flag',
  'calculate_payroll_run',
  "                                v_emp.epf_pre_august_1998),  -- 0906",
  "                                false),  -- 0906 unpassed",
  '-- 0906 unpassed')

m('the publisher drops a band\'s step',
  'platform_publish_statutory_schedule',
  "      (v_rate ->> 'wage_round_up_to')::numeric,\n",
  "      null,  -- step dropped\n",
  '-- step dropped')

m('CONTROL: a comment inside the function',
  'calc_statutory',
  "  v_step := coalesce(v_rate.wage_round_up_to, v_sched.wage_round_up_to);\n",
  "  -- control\n  v_step := coalesce(v_rate.wage_round_up_to, v_sched.wage_round_up_to);\n",
  '-- control')

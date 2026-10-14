# Mutants for 0894 -- unpaid leave counts only on the days a payslip pays
# for, and leave outside employment is refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0894_unpaid_leave_is_taken_while_employed.sql \
#       supabase/tests/unpaid_leave_while_employed.sql \
#       supabase/tests/mutants/unpaid_leave_while_employed.py

m('leave runs to the end of the period again',
  'calculate_payroll_run',
  "             * ((least(lr.end_date, v_to)\n",
  "             * ((least(lr.end_date, v_period.period_end)  -- period end\n",
  '-- period end')

m('leave runs from the start of the period again',
  'calculate_payroll_run',
  "                 - greatest(lr.start_date, v_from) + 1)::numeric\n",
  "                 - greatest(lr.start_date, v_period.period_start) + 1)::numeric  -- period start\n",
  '-- period start')

m('leave after the last day is still read',
  'calculate_payroll_run',
  "       and lr.start_date <= v_to\n",
  "       and lr.start_date <= v_period.period_end  -- read to period end\n",
  '-- read to period end')

m('leave before the first day is still read',
  'calculate_payroll_run',
  "       and lr.end_date >= v_from;\n",
  "       and lr.end_date >= v_period.period_start;  -- read from period start\n",
  '-- read from period start')

m('leave before the hire date is taken',
  'leave_within_employment',
  "  if new.start_date < v_e.hire_date then\n",
  "  if false and new.start_date < v_e.hire_date then  -- any start\n",
  '-- any start')

m('not on the first day either',
  'leave_within_employment',
  "  if new.start_date < v_e.hire_date then\n",
  "  if new.start_date <= v_e.hire_date then  -- not the first day\n",
  '-- not the first day')

m('only leave ending before the hire date is refused',
  'leave_within_employment',
  "  if new.start_date < v_e.hire_date then\n",
  "  if new.end_date < v_e.hire_date then  -- ends before\n",
  '-- ends before')

m('leave after the last day is taken',
  'leave_within_employment',
  "  if new.end_date > v_e.last_working_date then\n",
  "  if false and new.end_date > v_e.last_working_date then  -- any end\n",
  '-- any end')

m('not on the last day either',
  'leave_within_employment',
  "  if new.end_date > v_e.last_working_date then\n",
  "  if new.end_date >= v_e.last_working_date then  -- not the last day\n",
  '-- not the last day')

m('only leave starting after the last day is refused',
  'leave_within_employment',
  "  if new.end_date > v_e.last_working_date then\n",
  "  if new.start_date > v_e.last_working_date then  -- starts after\n",
  '-- starts after')

m('CONTROL: a comment inside the function',
  'calculate_payroll_run',
  "    -- 0894: unpaid leave counts only on the days this payslip pays for,\n",
  "    -- 0894: unpaid leave counts only on the days this payslip pays for,\n    -- control\n",
  '-- control')

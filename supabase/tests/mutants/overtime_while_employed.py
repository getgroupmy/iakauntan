# Mutants for 0895 -- nobody clocks in outside employment, and payroll
# pays overtime only on the days a payslip pays for.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0895_overtime_is_worked_while_employed.sql \
#       supabase/tests/overtime_while_employed.sql \
#       supabase/tests/mutants/overtime_while_employed.py

m('overtime is read across the whole period again',
  'calculate_payroll_run',
  "       and a.work_date between v_from and v_to;\n",
  "       and a.work_date between v_period.period_start and v_period.period_end;  -- whole period\n",
  '-- whole period')

m('overtime is read up to the end of the period',
  'calculate_payroll_run',
  "       and a.work_date between v_from and v_to;\n",
  "       and a.work_date between v_from and v_period.period_end;  -- to period end\n",
  '-- to period end')

m('a clock-in before the hire date is taken',
  'clock_in',
  "  if v_date < v_e.hire_date then\n",
  "  if false and v_date < v_e.hire_date then  -- any first day\n",
  '-- any first day')

m('not on the first day either',
  'clock_in',
  "  if v_date < v_e.hire_date then\n",
  "  if v_date <= v_e.hire_date then  -- not the first day\n",
  '-- not the first day')

m('a clock-in after the last day is taken',
  'clock_in',
  "  if v_date > v_e.last_working_date then\n",
  "  if false and v_date > v_e.last_working_date then  -- any last day\n",
  '-- any last day')

m('not on the last day either',
  'clock_in',
  "  if v_date > v_e.last_working_date then\n",
  "  if v_date >= v_e.last_working_date then  -- not the last day\n",
  '-- not the last day')

m('the login is asked about, not the employee clocked',
  'clock_in',
  "  select * into v_e from public.employees where id = v_emp;\n",
  "  select * into v_e from public.employees where id = v_me;  -- the login\n",
  '-- the login')

m('CONTROL: a comment inside the function',
  'clock_in',
  "  -- 0895: nobody clocks in on a day they are not employed -- before\n",
  "  -- 0895: nobody clocks in on a day they are not employed -- before\n  -- control\n",
  '-- control')

# Mutants for public.post_payroll_run -- the journal a payroll run posts.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0050_hrms_post_payroll_split_claims.sql \
#       supabase/tests/payroll_run.sql \
#       supabase/tests/mutants/post_payroll_run.py
#
# CLAUDE.md's twelfth way a green test covers a broken thing is about
# this family: a 1120 fallback survived in SIX posting functions with
# 382 assertion files running.
#
# RESULT, 5 October: 12 mutants, and the twelfth FOUND A REAL GAP.
#
# The first ten all died against payroll_run.sql -- but FIVE of them died
# on "Journal does not balance", which is the double-entry invariant and
# NOT a statement about where the money went. That is a weaker kill than
# it looks, and it prompted the last two.
#
#   balanced-but-wrong-account, PCB -> zakat payable:  KILLED, because
#     zakat has an assertion of its own ("zakat withheld is owed").
#   balanced-but-wrong-account, EPF <-> SOCSO employer expense:
#     SURVIVED payroll_run.sql, payroll_chart.sql,
#     statutory_remittances.sql and ea_form.sql.
#
# payroll_chart.sql looks like the file that would catch that and
# cannot: it reads the fallback codes out of the function's SOURCE and
# checks each EXISTS in a seeded chart. Swap two and every code named is
# still a real account. Three assertions were added to payroll_run.sql
# and the mutant now dies on "the EPF employer contribution is charged
# to 6110".
#
# THE LESSON: a journal-balance failure is a cheap kill. A mutation that
# moves money SYMMETRICALLY -- two accounts exchanged, a code changed to
# another valid one -- balances perfectly, and only an assertion naming
# the account catches it. Prefer those when writing mutants for a
# posting function.

m('staff claims are not netted off salary expense, so pay is overstated',
  'post_payroll_run',
  "    v_run.total_gross - v_claims, 0, 'Salaries and wages');",
  "    v_run.total_gross, 0, 'Salaries and wages');  -- claims not netted",
  '-- claims not netted')

m("EPF payable credits only the employee's half",
  'post_payroll_run',
  "    0, v_run.total_epf_employee + v_run.total_epf_employer, 'EPF payable');",
  "    0, v_run.total_epf_employee, 'EPF payable');  -- employer half lost",
  '-- employer half lost')

m("SOCSO payable credits only the employee's half",
  'post_payroll_run',
  "    0, v_run.total_socso_employee + v_run.total_socso_employer, 'SOCSO payable');",
  "    0, v_run.total_socso_employee, 'SOCSO payable');  -- socso half lost",
  '-- socso half lost')

m('net salaries payable is credited with GROSS, not net',
  'post_payroll_run',
  "    0, v_run.total_net, 'Net salaries payable');",
  "    0, v_run.total_gross, 'Net salaries payable');",
  "v_run.total_gross, 'Net salaries payable');")

m('the HRD Corp levy is expensed but never made payable',
  'post_payroll_run',
  "    v_run.org_id, null, '2195', 0, v_run.total_hrdf, 'HRD Corp levy payable');",
  "    v_run.org_id, null, '2195', 0, 0, 'HRD Corp levy payable');",
  "'2195', 0, 0, 'HRD Corp levy payable');")

m("a court-ordered CP38 deduction is left out of the year's PCB",
  'post_payroll_run',
  'p.eis_employee, p.eis_employer, p.pcb + p.cp38, p.zakat, p.net_pay, 1',
  'p.eis_employee, p.eis_employer, p.pcb, p.zakat, p.net_pay, 1  -- cp38 dropped',
  '-- cp38 dropped')

m('a run with no payslips can be posted',
  'post_payroll_run',
  '  if v_run.employee_count = 0 then',
  '  if false then  -- empty-run guard dropped',
  '-- empty-run guard dropped')

m('a draft run can be posted, before anything was calculated',
  'post_payroll_run',
  "  if v_run.status not in ('calculated', 'approved') then",
  "  if v_run.status not in ('calculated', 'approved', 'draft') then",
  "'approved', 'draft') then")

m('the journal is dated the period end rather than the pay date',
  'post_payroll_run',
  '    p_entry_date   => v_period.pay_date,',
  '    p_entry_date   => v_period.period_end,',
  'p_entry_date   => v_period.period_end,')

m('anybody may post a payroll run',
  'post_payroll_run',
  '  if not app.can_run_payroll(v_run.org_id) then',
  '  if false then  -- permission check dropped',
  '-- permission check dropped')

m("EPF and SOCSO employer expense post to each other's account",
  'post_payroll_run',
  "    v_run.org_id, v_set.epf_expense_account_id, '6110',\n    v_run.total_epf_employer, 0, 'EPF employer contribution');",
  "    v_run.org_id, v_set.socso_expense_account_id, '6120',\n    v_run.total_epf_employer, 0, 'EPF employer contribution');  -- accounts swapped",
  '-- accounts swapped')

m('the PCB payable credit goes to the zakat payable account',
  'post_payroll_run',
  "    v_run.org_id, v_set.pcb_payable_account_id, '2180',\n    0, v_run.total_pcb, 'PCB / MTD payable');",
  "    v_run.org_id, v_set.zakat_payable_account_id, '2185',\n    0, v_run.total_pcb, 'PCB / MTD payable');  -- pcb to zakat",
  '-- pcb to zakat')

m('CONTROL -- a comment inside the function block',
  'post_payroll_run',
  'begin\n  select * into v_run from public.payroll_runs where id = p_run_id;',
  'begin\n  -- CONTROL: this line cannot change a number.\n  select * into v_run from public.payroll_runs where id = p_run_id;',
  '-- CONTROL: this line cannot change a number.')


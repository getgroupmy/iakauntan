# Mutants for public.report_statutory_remittances (0457) -- what each
# posted payroll owes to EPF, SOCSO, EIS, LHDN (PCB), HRD Corp and the
# zakat authority, when each is due, and whether it is overdue.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0457_the_fifteenth_of_the_month_after.sql \
#       supabase/tests/statutory_remittances.sql \
#       supabase/tests/mutants/report_statutory_remittances.py
#
# RESULT: (pending)

m("another company's payroll is on the list",
  "report_statutory_remittances",
  "     where r.org_id = p_org_id\n       and r.status in ('posted', 'paid')",
  "     where true  -- any org\n       and r.status in ('posted', 'paid')",
  "-- any org")

m("a draft run is on the list",
  "report_statutory_remittances",
  "       and r.status in ('posted', 'paid')",
  "       and true  -- draft run",
  "-- draft run")

m("a paid run is left off",
  "report_statutory_remittances",
  "       and r.status in ('posted', 'paid')",
  "       and r.status in ('posted')  -- no paid",
  "-- no paid")

m("a period paid before the start is listed",
  "report_statutory_remittances",
  "       and (p_from is null or p.pay_date >= p_from)",
  "       and true  -- before start",
  "-- before start")

m("a period paid after the end is listed",
  "report_statutory_remittances",
  "       and (p_to is null or p.pay_date <= p_to)",
  "       and true  -- after end",
  "-- after end")

m("the start date itself is outside the range",
  "report_statutory_remittances",
  "       and (p_from is null or p.pay_date >= p_from)",
  "       and (p_from is null or p.pay_date > p_from)  -- gt",
  "-- gt")

m("the end date itself is outside the range",
  "report_statutory_remittances",
  "       and (p_to is null or p.pay_date <= p_to)",
  "       and (p_to is null or p.pay_date < p_to)  -- lt",
  "-- lt")

m("the employer's EPF is read as the employee's",
  "report_statutory_remittances",
  "           sum(r.total_epf_employer)   as epf_r,",
  "           sum(r.total_epf_employee)   as epf_r,  -- epf twice",
  "-- epf twice")

m("SOCSO's employer share is lost",
  "report_statutory_remittances",
  "        ('socso', r.soc_e, r.soc_r),",
  "        ('socso', r.soc_e, 0::numeric),  -- no socso r",
  "-- no socso r")

m("EIS's employee share is lost",
  "report_statutory_remittances",
  "        ('eis',   r.eis_e, r.eis_r),",
  "        ('eis',   0::numeric, r.eis_r),  -- no eis e",
  "-- no eis e")

m("PCB is left off",
  "report_statutory_remittances",
  "        ('pcb',   0::numeric, r.pcb),",
  "        ('pcb',   0::numeric, 0::numeric),  -- no pcb",
  "-- no pcb")

m("the HRD levy is left off",
  "report_statutory_remittances",
  "        ('hrdf',  0::numeric, r.hrdf),",
  "        ('hrdf',  0::numeric, 0::numeric),  -- no hrdf",
  "-- no hrdf")

m("zakat is left off",
  "report_statutory_remittances",
  "        ('zakat', 0::numeric, r.zakat)",
  "        ('zakat', 0::numeric, 0::numeric)  -- no zakat",
  "-- no zakat")

m("the total is the employer's share only",
  "report_statutory_remittances",
  "         round(s.employee_amount + s.employer_amount, 2),\n         app.remittance_due(s.pay_date, s.code),",
  "         round(s.employer_amount, 2),  -- total r only\n         app.remittance_due(s.pay_date, s.code),",
  "-- total r only")

m("the due date is the pay date",
  "report_statutory_remittances",
  "         round(s.employee_amount + s.employer_amount, 2),\n         app.remittance_due(s.pay_date, s.code),",
  "         round(s.employee_amount + s.employer_amount, 2),\n         s.pay_date,  -- due on pay date",
  "-- due on pay date")

m("a remittance already paid is still overdue",
  "report_statutory_remittances",
  "         sr.paid_on is null\n           and app.remittance_due(s.pay_date, s.code) is not null",
  "         true  -- paid overdue\n           and app.remittance_due(s.pay_date, s.code) is not null",
  "-- paid overdue")

m("overdue on the due date itself",
  "report_statutory_remittances",
  "           and app.remittance_due(s.pay_date, s.code) < app.today()",
  "           and app.remittance_due(s.pay_date, s.code) <= app.today()  -- le",
  "-- le")

m("nothing is ever overdue",
  "report_statutory_remittances",
  "           and app.remittance_due(s.pay_date, s.code) < app.today()",
  "           and false  -- never overdue",
  "-- never overdue")

m("another company's remittance marks this one paid",
  "report_statutory_remittances",
  "           on sr.org_id = p_org_id and sr.period_id = s.period_id",
  "           on true  -- any org paid\n          and sr.period_id = s.period_id",
  "-- any org paid")

m("paying EPF marks every body paid",
  "report_statutory_remittances",
  "          and sr.code = s.code",
  "          and sr.code = 'epf'  -- epf pays all",
  "-- epf pays all")

m("a member without payroll rights reads the list",
  "report_statutory_remittances",
  "   where app.can_run_payroll(p_org_id)",
  "   where app.is_org_member(p_org_id)  -- any member",
  "-- any member")

m("a body that took nothing is listed",
  "report_statutory_remittances",
  "     and s.employee_amount + s.employer_amount <> 0",
  "     and true  -- nil body",
  "-- nil body")

m("CONTROL: a comment inside the block",
  "report_statutory_remittances",
  "  split as (",
  "  -- CONTROL\n  split as (",
  "-- CONTROL")

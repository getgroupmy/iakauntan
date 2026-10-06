# Mutants for app.covering_grant (0047) -- which approved request, if
# any, lets this auditor read this payslip: theirs, in this company,
# approved, unexpired, and naming this run, this employee and a period
# this pay date falls in, wherever it names one.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0047_hrms_payslip_access_log.sql \
#       supabase/tests/payslip_access.sql \
#       supabase/tests/mutants/covering_grant.py
#
# RESULT: 12 mutants and a control. 12 killed by `payslip_access.sql`,
# five only after a rule-by-rule block there: nothing sat ON an edge (a
# grant expiring this instant, a period whose first or last day is the
# pay date), no two grants covered one payslip, and no auditor belonged
# to a second company whose grant could answer for the first.
#
# NOT MUTATED, AND A QUESTION FOR THE USER: `p_pay_date is null` lets a
# grant bounded to a period cover a payslip with no pay date at all --
# fail-open, on the most private table here. `payslips.pay_date` is
# nullable; production had none null on 6 October (36 payslips) and no
# access requests at all, so it is latent. Whether an undated payslip
# should be outside every bounded grant is a policy call, and is in
# docs/handoff.md as item 20.

m("another company's grant covers this one",
  "covering_grant",
  "   where r.org_id = p_org_id\n",
  "   where true  -- any company\n",
  "-- any company")

m("another auditor's grant covers me",
  "covering_grant",
  "     and r.requested_by = auth.uid()\n",
  "     and true  -- anybody's\n",
  "-- anybody's")

m("a pending or revoked request covers",
  "covering_grant",
  "     and r.status = 'approved'\n",
  "     and r.status <> 'rejected'  -- not refused will do\n",
  "-- not refused will do")

m("an expired grant still covers",
  "covering_grant",
  "     and (r.expires_at is null or r.expires_at > now())\n",
  "     and true  -- no expiry\n",
  "-- no expiry")

m("a grant covers on the instant it expires",
  "covering_grant",
  "     and (r.expires_at is null or r.expires_at > now())\n",
  "     and (r.expires_at is null or r.expires_at >= now())  -- inclusive\n",
  "-- inclusive")

m("a grant for one run covers every run",
  "covering_grant",
  "     and (r.run_id is null or r.run_id = p_run_id)\n",
  "     and true  -- any run\n",
  "-- any run")

m("a grant for one employee covers everybody",
  "covering_grant",
  "     and (r.employee_id is null or r.employee_id = p_employee_id)\n",
  "     and true  -- anybody\n",
  "-- anybody")

m("a grant from a date covers what came before",
  "covering_grant",
  "     and (r.period_from is null or p_pay_date is null\n          or p_pay_date >= r.period_from)\n",
  "     and true  -- any start\n",
  "-- any start")

m("a grant from a date does not cover the date itself",
  "covering_grant",
  "          or p_pay_date >= r.period_from)\n",
  "          or p_pay_date > r.period_from)  -- after only\n",
  "-- after only")

m("a grant to a date covers what came after",
  "covering_grant",
  "     and (r.period_to is null or p_pay_date is null\n          or p_pay_date <= r.period_to)\n",
  "     and true  -- any end\n",
  "-- any end")

m("a grant to a date does not cover the date itself",
  "covering_grant",
  "          or p_pay_date <= r.period_to)\n",
  "          or p_pay_date < r.period_to)  -- before only\n",
  "-- before only")

m("the grant that ends soonest is named",
  "covering_grant",
  "   order by r.expires_at desc nulls last\n",
  "   order by r.expires_at asc nulls last  -- soonest\n",
  "-- soonest")

m("CONTROL: a comment inside the block",
  "covering_grant",
  "   limit 1;",
  "   limit 1;  -- (control)",
  "(control)")

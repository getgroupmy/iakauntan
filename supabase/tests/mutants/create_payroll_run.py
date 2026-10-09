# Mutants for public.create_payroll_run (0769) -- a payroll run opened
# over a pay period: by somebody who may run payroll, and only where the
# period has no run that is not void.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0769_one_payroll_for_one_pay_period.sql \
#       supabase/tests/payroll_periods.sql \
#       supabase/tests/mutants/create_payroll_run.py
#
# RESULT: 3 of 4 killed, control surviving, and the fourth EQUIVALENT:
# "another company's run holds this company's period" cannot happen,
# because a run's period must be its own company's
# (`payroll_runs_period_same_org`), so no other company's run can name
# this period at all. The `org_id` clause is redundant; it stays because
# it reads as what is meant.

m("anybody opens a payroll run",
  "create_payroll_run",
  "  if not app.can_run_payroll(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a second live run is opened, left to the index",
  "create_payroll_run",
  "  if v_live.id is not null then",
  "  if false then  -- left to the index",
  "-- left to the index")

m("a void run still holds its period",
  "create_payroll_run",
  "     and r.status <> 'void'\n   limit 1;",
  "     and true  -- void counts\n   limit 1;",
  "-- void counts")

m("another company's run holds this company's period",
  "create_payroll_run",
  "   where r.org_id = p_org_id and r.period_id = p_period_id",
  "   where r.period_id = p_period_id  -- any company",
  "-- any company")

m("CONTROL: a comment inside the block",
  "create_payroll_run",
  "  if v_live.id is not null then",
  "  if v_live.id is not null then  -- (control)",
  "(control)")

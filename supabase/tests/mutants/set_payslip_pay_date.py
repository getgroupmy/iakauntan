# Mutants for app.set_payslip_pay_date (0045) -- a payslip with no pay
# date of its own takes its pay period's, and one that has a date keeps
# it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0045_hrms_payslip_access_requests.sql \
#       supabase/tests/payslip_access.sql \
#       supabase/tests/mutants/set_payslip_pay_date.py
#
# RESULT: 3 mutants and a control. 3 killed by `payslip_access.sql`, one
# only after a block there: every payslip had arrived without a date of
# its own, so overwriting a given one changed nothing anybody read.

m("a payslip is never given its period's date",
  "set_payslip_pay_date",
  "  if new.pay_date is null then",
  "  if false then  -- undated",
  "-- undated")

m("a payslip's own date is overwritten",
  "set_payslip_pay_date",
  "  if new.pay_date is null then",
  "  if true then  -- the period's always",
  "-- the period's always")

m("the date comes from any run",
  "set_payslip_pay_date",
  "     where r.id = new.run_id;",
  "     limit 1;  -- any run",
  "-- any run")

m("CONTROL: a comment inside the block",
  "set_payslip_pay_date",
  "  return new;",
  "  return new;  -- (control)",
  "(control)")

# Mutants for 0767's three functions: `record_statutory_remittance` (a
# payment to KWSP, PERKESO, LHDN or HRD Corp recorded against a posted
# payroll), `report_statutory_remittances` (what is owed, what was sent,
# what is short) and `report_statutory_due` (what is still to chase).
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0767_a_remittance_settles_what_it_covers.sql \
#       supabase/tests/statutory_remittances.sql \
#       supabase/tests/mutants/statutory_remittance.py

m("anybody records a remittance",
  "record_statutory_remittance",
  "  if not app.can_run_payroll(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("another company's pay period is taken",
  "record_statutory_remittance",
  "   where p.id = p_period_id and p.org_id = p_org_id;",
  "   where p.id = p_period_id;  -- any company",
  "-- any company")

m("a pay period that does not exist is not said so",
  "record_statutory_remittance",
  "  if v_pay is null then",
  "  if false then  -- no period",
  "-- no period")

m("a payment to nobody is taken",
  "record_statutory_remittance",
  "                  where r.code = p_code) then",
  "                  where true) then  -- any code",
  "-- any code")

m("nil is recorded as a payment",
  "record_statutory_remittance",
  "  if round(coalesce(p_amount, 0), 2) <= 0 then",
  "  if false then  -- nil taken",
  "-- nil taken")

m("nil is recorded, only a negative refused",
  "record_statutory_remittance",
  "  if round(coalesce(p_amount, 0), 2) <= 0 then",
  "  if round(coalesce(p_amount, 0), 2) < 0 then  -- zero taken",
  "-- zero taken")

m("a payroll still in draft is remitted against",
  "record_statutory_remittance",
  "                    and r.status in ('posted', 'paid')) then",
  "                    ) then  -- any status",
  "-- any status")

m("the deadline is not stamped on the record",
  "record_statutory_remittance",
  "          app.remittance_due(v_pay, p_code),",
  "          null,  -- no deadline",
  "-- no deadline")

m("with no date given, it is recorded as sent on payday",
  "record_statutory_remittance",
  "          coalesce(p_paid_on, app.today()),",
  "          coalesce(p_paid_on, v_pay),  -- payday",
  "-- payday")

m("a second recording keeps the first amount",
  "record_statutory_remittance",
  "     set amount = excluded.amount,",
  "     set amount = statutory_remittances.amount,  -- first amount",
  "-- first amount")

m("a second recording keeps the first reference",
  "record_statutory_remittance",
  "         reference = excluded.reference,",
  "         reference = statutory_remittances.reference,  -- first ref",
  "-- first ref")

m("any recorded payment settles it, as before",
  "report_statutory_remittances",
  "         coalesce(sr.amount, 0)\n             < round(s.employee_amount + s.employer_amount, 2)",
  "         sr.paid_on is null  -- any row",
  "-- any row")

m("paying exactly what is owed leaves it overdue",
  "report_statutory_remittances",
  "             < round(s.employee_amount + s.employer_amount, 2)",
  "             <= round(s.employee_amount + s.employer_amount, 2)  -- exact is short",
  "-- exact is short")

m("what was sent is not reported",
  "report_statutory_remittances",
  "         sr.amount,\n",
  "         null::numeric,  -- unsent\n",
  "-- unsent")

m("paying more is short by a negative amount",
  "report_statutory_remittances",
  "         greatest(round(s.employee_amount + s.employer_amount, 2)\n                  - coalesce(sr.amount, 0), 0)",
  "         round(s.employee_amount + s.employer_amount, 2)\n                  - coalesce(sr.amount, 0)  -- negative short",
  "-- negative short")

m("the chase stops at the first payment, as before",
  "report_statutory_due",
  "   where r.short_amount > 0",
  "   where r.paid_on is null  -- first payment",
  "-- first payment")

m("CONTROL: a comment inside the block",
  "record_statutory_remittance",
  "  if v_pay is null then",
  "  if v_pay is null then  -- (control)",
  "(control)")

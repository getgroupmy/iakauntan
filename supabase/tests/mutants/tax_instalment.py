# Mutants for 0768's two functions: `record_tax_instalment` (one CP204
# instalment paid) and `tax_estimate_payment_summary` (where the
# instalment year stands, behind the tax tile).
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0768_an_instalment_is_paid_when_it_is_covered.sql \
#       supabase/tests/tax_estimate_payments.sql \
#       supabase/tests/mutants/tax_instalment.py

m("an estimate that does not exist is not said so",
  "record_tax_instalment",
  "  if e.id is null then",
  "  if false then  -- no such estimate",
  "-- no such estimate")

m("anybody records an instalment",
  "record_tax_instalment",
  "  if not app.can_post(e.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an instalment the schedule does not have is taken",
  "record_tax_instalment",
  "  if p_instalment_no > v_count then",
  "  if false then  -- thirteenth",
  "-- thirteenth")

m("nil is recorded as an instalment paid",
  "record_tax_instalment",
  "  if v_amount <= 0 then",
  "  if false then  -- nil taken",
  "-- nil taken")

m("nil is recorded, only a negative refused",
  "record_tax_instalment",
  "  if v_amount <= 0 then",
  "  if v_amount < 0 then  -- zero taken",
  "-- zero taken")

m("a bare recording pays nothing rather than the schedule",
  "record_tax_instalment",
  "  v_amount := round(coalesce(p_amount, v_sched, 0), 2);",
  "  v_amount := round(coalesce(p_amount, 1), 2);  -- not the schedule",
  "-- not the schedule")

m("with no date given, it is recorded as paid on the due date",
  "record_tax_instalment",
  "     coalesce(p_paid_on, app.today()),",
  "     coalesce(p_paid_on, date '2026-01-15'),  -- not today",
  "-- not today")

m("a second recording keeps the first amount",
  "record_tax_instalment",
  "         amount = excluded.amount,",
  "         amount = tax_estimate_payments.amount,  -- first amount",
  "-- first amount")

m("any payment counts an instalment paid, as before",
  "tax_estimate_payment_summary",
  "    count(*) filter (where s.paid_on is not null and s.outstanding = 0)::integer,",
  "    count(*) filter (where s.paid_on is not null)::integer,  -- any payment",
  "-- any payment")

m("any payment takes an instalment off the overdue count, as before",
  "tax_estimate_payment_summary",
  "      where s.outstanding > 0 and s.due_on < v_today\n    )::integer,",
  "      where s.paid_on is null and s.due_on < v_today and s.amount > 0  -- unpaid only\n    )::integer,",
  "-- unpaid only")

m("any payment takes it off the overdue total, as before",
  "tax_estimate_payment_summary",
  "      where s.outstanding > 0 and s.due_on < v_today), 0),",
  "      where s.paid_on is null and s.due_on < v_today), 0),  -- unpaid total",
  "-- unpaid total")

m("an instalment not yet due is counted overdue",
  "tax_estimate_payment_summary",
  "      where s.outstanding > 0 and s.due_on < v_today\n    )::integer,",
  "      where s.outstanding > 0\n    )::integer,  -- all overdue",
  "-- all overdue")

m("any payment moves next due past it, as before",
  "tax_estimate_payment_summary",
  "    min(s.due_on) filter (where s.outstanding > 0),",
  "    min(s.due_on) filter (where s.paid_on is null and s.amount > 0),  -- next unpaid",
  "-- next unpaid")

m("next due says the whole instalment, not what is left",
  "tax_estimate_payment_summary",
  "    (array_agg(s.outstanding order by s.due_on)",
  "    (array_agg(s.amount order by s.due_on)  -- whole amount",
  "-- whole amount")

m("CONTROL: a comment inside the block",
  "record_tax_instalment",
  "  if v_amount <= 0 then",
  "  if v_amount <= 0 then  -- (control)",
  "(control)")

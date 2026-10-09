# Mutants for public.mark_payroll_paid (0051) -- the note that a posted
# payroll's transfer left the bank: only by somebody who may run
# payroll, only from `posted`, once, and stamped with when.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0051_hrms_payment_instruction.sql \
#       supabase/tests/statutory.sql \
#       supabase/tests/mutants/mark_payroll_paid.py
#
# RESULT: 5 mutants and a control, all killed by `statutory.sql`. One
# only after "and is stamped with when it was paid": nothing read
# `paid_at` back, so a run marked paid with no date passed.

m("a run that does not exist is not said so",
  "mark_payroll_paid",
  "  if v_run.id is null then",
  "  if false then  -- no such run",
  "-- no such run")

m("anybody marks a payroll paid",
  "mark_payroll_paid",
  "  if not app.can_run_payroll(v_run.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a run in any state is marked paid",
  "mark_payroll_paid",
  "  if v_run.status <> 'posted' then",
  "  if false then  -- any state",
  "-- any state")

m("a paid run is marked paid again",
  "mark_payroll_paid",
  "  if v_run.status <> 'posted' then",
  "  if v_run.status not in ('posted', 'paid') then  -- twice",
  "-- twice")

m("when it was paid is not recorded",
  "mark_payroll_paid",
  "     set status = 'paid', paid_at = now() where id = p_run_id;",
  "     set status = 'paid' where id = p_run_id;  -- undated",
  "-- undated")

m("CONTROL: a comment inside the block",
  "mark_payroll_paid",
  "  if v_run.id is null then",
  "  if v_run.id is null then  -- (control)",
  "(control)")

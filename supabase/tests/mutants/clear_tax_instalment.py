# Mutants for public.clear_tax_instalment (0673) -- an instalment payment
# unrecorded: the estimate must exist; the caller must be able to post;
# the payment is found by the ROOT of the estimate, so clearing through
# a revision clears what was recorded against the original; and only
# the instalment named.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0673_what_was_payable_and_what_was_paid.sql \
#       supabase/tests/tax_estimate_payments.sql \
#       supabase/tests/mutants/clear_tax_instalment.py
#
# RESULT: 4 mutants and a control, all killed by
# `tax_estimate_payments.sql`; one before its rule-by-rule block (the
# stranger). The file cleared one payment against the root it was
# recorded on, with no other payment beside it, so clearing every
# instalment or keying to the revision passed. The revision case is on
# `co_ending_now`'s period: a revision made on a 2026 period is refused
# from 1 January 2027 (measured with run_at_dates.sh).

m("an estimate that does not exist is not said so",
  "clear_tax_instalment",
  "  if e.id is null then\n    raise exception 'No such estimate'",
  "  if false then  -- no such estimate\n    raise exception 'No such estimate'",
  "-- no such estimate")

m("anybody clears a payment",
  "clear_tax_instalment",
  "  if not app.can_post(e.org_id) then\n    raise exception 'Not permitted to clear an instalment'",
  "  if false then  -- whoever asks\n    raise exception 'Not permitted to clear an instalment'",
  "-- whoever asks")

m("a revision clears only what was recorded against itself",
  "clear_tax_instalment",
  "     and root_estimate_id = app.tax_estimate_root(p_estimate_id)",
  "     and root_estimate_id = p_estimate_id  -- not the root",
  "-- not the root")

m("every instalment is cleared, not the one named",
  "clear_tax_instalment",
  "     and instalment_no = p_instalment_no;",
  "     and p_instalment_no is not null;  -- all of them",
  "-- all of them")

m("CONTROL: a comment inside the block",
  "clear_tax_instalment",
  "     and instalment_no = p_instalment_no;",
  "     and instalment_no = p_instalment_no;  -- (control)",
  "(control)")

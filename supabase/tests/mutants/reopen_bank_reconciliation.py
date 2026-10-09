# Mutants for public.reopen_bank_reconciliation (0157) -- a completed
# reconciliation undone: it must exist, the caller must be able to
# post; refused while a LATER COMPLETED reconciliation of the SAME
# account stands -- not an earlier one, not one still in progress, not
# another account's; its lines released and the reconciliation gone.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0157_reconciliations_march_forward.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/reopen_bank_reconciliation.py
#
# RESULT: 8 mutants and a control. 6 killed by `bank_reconciliation.sql`,
# two before its rule-by-rule block: with one bank account "a later
# reconciliation of this account" and "of any account" were the same
# row, and the file never reopened a later one with an earlier standing.
#
# Two are EQUIVALENT:
#   * "a later one still in progress blocks it": nothing writes an
#     `in_progress` row. `complete_bank_reconciliation` is the only
#     writer and inserts `completed`; `authenticated` has SELECT only;
#     production held no reconciliation of any status (read 9 Oct).
#   * "the lines stay closed": `bank_transactions_reconciliation_fk` is
#     ON DELETE SET NULL, so deleting the reconciliation releases them.

m("a reconciliation that does not exist is not said so",
  "reopen_bank_reconciliation",
  "  if not found then\n    raise exception 'Reconciliation % not found'",
  "  if false then  -- no such reconciliation\n    raise exception 'Reconciliation % not found'",
  "-- no such reconciliation")

m("anybody reopens",
  "reopen_bank_reconciliation",
  "  if not app.can_post(r.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a reconciliation is reopened under a later one",
  "reopen_bank_reconciliation",
  "  if v_next is not null then",
  "  if false then  -- out of order",
  "-- out of order")

m("another account's later reconciliation blocks it",
  "reopen_bank_reconciliation",
  "   where bank_account_id = r.bank_account_id and status = 'completed'",
  "   where org_id = r.org_id and status = 'completed'  -- any account",
  "-- any account")

m("a later one still in progress blocks it",
  "reopen_bank_reconciliation",
  "   where bank_account_id = r.bank_account_id and status = 'completed'",
  "   where bank_account_id = r.bank_account_id  -- any status",
  "-- any status")

m("an earlier one blocks it",
  "reopen_bank_reconciliation",
  "     and statement_date > r.statement_date;",
  "     and statement_date <> r.statement_date;  -- earlier too",
  "-- earlier too")

m("the lines stay closed",
  "reopen_bank_reconciliation",
  "   where reconciliation_id = p_id;\n\n  delete",
  "   where reconciliation_id = p_id and false;  -- lines kept\n\n  delete",
  "-- lines kept")

m("the reconciliation is kept",
  "reopen_bank_reconciliation",
  "  delete from public.bank_reconciliations where id = p_id;",
  "  perform 1;  -- kept",
  "-- kept")

m("CONTROL: a comment inside the block",
  "reopen_bank_reconciliation",
  "  if v_next is not null then",
  "  if v_next is not null then  -- (control)",
  "(control)")

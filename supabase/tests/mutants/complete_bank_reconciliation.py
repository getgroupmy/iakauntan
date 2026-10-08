# Mutants for public.complete_bank_reconciliation (0716) -- closing a
# statement: only forward of the last one, only when it agrees, saying
# which kind of disagreement it is, and stamping the lines it closed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0716_nothing_in_the_books_is_not_a_difference.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/complete_bank_reconciliation.py
#
# RESULT: 15 mutants and a control. 14 killed by `bank_reconciliation.sql`,
# two only after the "Closed only by closing it" block there: an account
# that is not there, and a reconciliation still in progress after the one
# being closed. Writing that block found `0761`: the table could be
# written directly, so none of this function's rules were binding.
#
# One EQUIVALENT: the statement balance stored unrounded -- the column is
# numeric(18,2). Noted beside the assertion.

m("an account that does not exist is reconciled in silence",
  "complete_bank_reconciliation",
  "  if v_org is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody closes a reconciliation",
  "complete_bank_reconciliation",
  "  if not app.can_post(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a closed period is closed again",
  "complete_bank_reconciliation",
  "  if v_last is not null and p_statement_date <= v_last then",
  "  if false then  -- again",
  "-- again")

m("the same date as the last one is closed again",
  "complete_bank_reconciliation",
  "  if v_last is not null and p_statement_date <= v_last then",
  "  if v_last is not null and p_statement_date < v_last then  -- same day",
  "-- same day")

m("a draft reconciliation counts as the last one",
  "complete_bank_reconciliation",
  "   where bank_account_id = p_bank_account_id and status = 'completed';",
  "   where bank_account_id = p_bank_account_id;  -- any status",
  "-- any status")

m("another account's reconciliation counts as the last one",
  "complete_bank_reconciliation",
  "   where bank_account_id = p_bank_account_id and status = 'completed';",
  "   where status = 'completed';  -- any account",
  "-- any account")

m("a difference is buried",
  "complete_bank_reconciliation",
  "  if v_diff <> 0 then",
  "  if false then  -- buried",
  "-- buried")

m("empty books read as a difference to hunt",
  "complete_bank_reconciliation",
  "    if v_posted = 0 then",
  "    if false then  -- hunt",
  "-- hunt")

m("books starting later are not said to",
  "complete_bank_reconciliation",
  "      if v_start is not null and v_start > p_statement_date then",
  "      if false then  -- unexplained",
  "-- unexplained")

m("the statement balance is stored unrounded",
  "complete_bank_reconciliation",
  "    round(p_statement_balance, 2),",
  "    p_statement_balance + 0.001,  -- unrounded",
  "-- unrounded")

m("the closed lines are not stamped",
  "complete_bank_reconciliation",
  "     and is_reconciled and reconciliation_id is null;",
  "     and false;  -- unstamped",
  "-- unstamped")

m("lines after the statement are stamped",
  "complete_bank_reconciliation",
  "     and transaction_date <= p_statement_date\n",
  "     and true  -- the future too\n",
  "-- the future too")

m("unmatched lines are stamped",
  "complete_bank_reconciliation",
  "     and is_reconciled and reconciliation_id is null;",
  "     and reconciliation_id is null;  -- unmatched too",
  "-- unmatched too")

m("lines of an earlier reconciliation are restamped",
  "complete_bank_reconciliation",
  "     and is_reconciled and reconciliation_id is null;",
  "     and is_reconciled;  -- restamped",
  "-- restamped")

m("another account's lines are stamped",
  "complete_bank_reconciliation",
  "   where bank_account_id = p_bank_account_id\n     and transaction_date <= p_statement_date",
  "   where true  -- any account\n     and transaction_date <= p_statement_date",
  "-- any account")

m("CONTROL: a comment inside the block",
  "complete_bank_reconciliation",
  "  if v_diff <> 0 then",
  "  if v_diff <> 0 then  -- (control)",
  "(control)")

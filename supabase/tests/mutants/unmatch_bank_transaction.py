# Mutants for public.unmatch_bank_transaction (0717) -- a statement line
# let go of what it was matched to: the line must exist, the caller
# must be able to post, and a line closed into a completed
# reconciliation stays put; an entry the line itself CREATED is
# reversed, on the line's own date -- but only that: not a receipt's
# or a journal's entry the line was merely matched to, not one already
# reversed, not one that is not posted; and every trace of the match
# cleared from the line.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0717_a_statement_line_can_become_a_posting.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/unmatch_bank_transaction.py
#
# RESULT: 14 mutants and a control. 12 killed by `bank_reconciliation.sql`,
# five before its rule-by-rule block: the file never let go of a
# receipt, so reversing whatever entry the line pointed at -- the
# receipt's own posting -- passed, and nothing read the reversal's date
# or met a journal already reversed by hand.
#
# Two are EQUIVALENT:
#   * "another line's entry is reversed": an entry line A made is held
#     by A while it stands -- `match_bank_transaction` refuses a
#     document already matched to another line -- and once A lets go it
#     is reversed, which the `not exists` clause catches anyway.
#   * "an entry that is not posted is reversed": a line's entry is
#     posted when made (the approval trigger raises, it does not leave a
#     draft) and nothing in the schema moves a posted entry to draft or
#     void; a reversal is a second entry.

m("a line that does not exist is not said so",
  "unmatch_bank_transaction",
  "  if not found then\n    raise exception 'Statement line % not found'",
  "  if false then  -- no such line\n    raise exception 'Statement line % not found'",
  "-- no such line")

m("anybody unmatches",
  "unmatch_bank_transaction",
  "  if not app.can_post(t.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a closed line is unmatched",
  "unmatch_bank_transaction",
  "  if t.reconciliation_id is not null then",
  "  if false then  -- closed line",
  "-- closed line")

m("the entry of whatever it was matched to is reversed",
  "unmatch_bank_transaction",
  "       and e.source_table = 'bank_transactions'\n       and e.source_id = t.id",
  "       and true  -- any entry\n",
  "-- any entry")

m("another line's entry is reversed",
  "unmatch_bank_transaction",
  "       and e.source_id = t.id",
  "       and true  -- any line's",
  "-- any line's")

m("an entry that is not posted is reversed",
  "unmatch_bank_transaction",
  "       and e.status = 'posted'\n",
  "       and true  -- any status\n",
  "-- any status")

m("an entry already reversed is reversed again",
  "unmatch_bank_transaction",
  "       and not exists (select 1 from public.gl_entries r\n                        where r.reversed_entry_id = e.id\n                          and r.status = 'posted');",
  "       and true;  -- reversed again\n",
  "-- reversed again")

m("the line's own entry is left in the ledger",
  "unmatch_bank_transaction",
  "    if coalesce(v_mine, false) then",
  "    if false then  -- left in the ledger",
  "-- left in the ledger")

m("the reversal is dated today",
  "unmatch_bank_transaction",
  "      perform public.reverse_gl_entry(t.gl_entry_id, t.transaction_date);",
  "      perform public.reverse_gl_entry(t.gl_entry_id, app.today());  -- dated today",
  "-- dated today")

m("the line still says which table it matched",
  "unmatch_bank_transaction",
  "     set matched_table = null, matched_id = null, gl_entry_id = null,",
  "     set matched_id = null, gl_entry_id = null,  -- table kept",
  "-- table kept")

m("the line still says which document it matched",
  "unmatch_bank_transaction",
  "     set matched_table = null, matched_id = null, gl_entry_id = null,",
  "     set matched_table = null, gl_entry_id = null,  -- document kept",
  "-- document kept")

m("the line still points at the entry",
  "unmatch_bank_transaction",
  "     set matched_table = null, matched_id = null, gl_entry_id = null,",
  "     set matched_table = null, matched_id = null,  -- entry kept",
  "-- entry kept")

m("the line stays ticked",
  "unmatch_bank_transaction",
  "         is_reconciled = false, reconciled_at = null, updated_at = now()",
  "         reconciled_at = null, updated_at = now()  -- still ticked",
  "-- still ticked")

m("the line keeps when it was ticked",
  "unmatch_bank_transaction",
  "         is_reconciled = false, reconciled_at = null, updated_at = now()",
  "         is_reconciled = false, updated_at = now()  -- time kept",
  "-- time kept")

m("CONTROL: a comment inside the block",
  "unmatch_bank_transaction",
  "  if t.reconciliation_id is not null then",
  "  if t.reconciliation_id is not null then  -- (control)",
  "(control)")

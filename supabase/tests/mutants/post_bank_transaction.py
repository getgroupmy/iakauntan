# Mutants for public.post_bank_transaction -- a line off a bank
# statement, posted straight to the ledger against an account the
# bookkeeper picks.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0723_the_matter_a_reconciled_line_belongs_to.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/post_bank_transaction.py
#
# then again against `matter_on_a_bank_line.sql`.
#
# RESULT, 5 October: 28 mutants (27 plus a control). 15 killed on the
# first file and 12 survived; `matter_on_a_bank_line.sql` kills 5, three
# of which only it kills. Across both files 27 of 27 die and the control
# lives. Nothing is equivalent.
#
#   bank_reconciliation.sql   kills 15, then 24 with the nine below
#   matter_on_a_bank_line.sql kills the three matter mutants
#
# A PER-FILE SCORE UNDERSTATES THE SUITE AGAIN, and more sharply than
# anywhere else in this sweep: 15 and 5 against a union of 24. The
# matter file reaches the same function and kills three mutants the
# bank file cannot see, while missing nineteen it does. Run every file
# that reaches the function, every time.
#
# THE NINE GAPS closed in `bank_reconciliation.sql`, all four families
# represented:
#
#   * PERMISSION. `app.can_post` -- neither file ever signed in as
#     somebody who may not post. A statement line posted straight to
#     the ledger IS a posting. Asserted on the whole message, because
#     four guards above it also use the word "privileges".
#   * BOUNDARY, of a shape worth naming. `round(t.amount, 2)` is a
#     no-op on a numeric(18,2) column, so the mutant worth writing is
#     not a wider rounding but `round(..., 0)` -- and it survived
#     because every amount in both files is a round hundred. The
#     boundary was not in the code, it was in the FIXTURE: no line had
#     cents to lose. 123.45 kills it.
#   * COLLAPSE. The description is a three-step fallback --
#     p_description, then the line's own, then 'Bank statement line' --
#     and every fixture in both files gave the line a description, so
#     the third step was unreachable and the first two indistinguishable
#     from "blank is a description". A line with no description at all
#     (which MT940 imports produce routinely) and a p_description of
#     nothing but spaces separate all three.
#   * SHAPE THAT BALANCES. Three of the nine -- the contact, the
#     statement reference, and `reconciled_at` -- are fields that have
#     nothing to do with debit or credit. A journal missing all three
#     balances perfectly, posts cleanly, and reconciles. No balance
#     assertion anywhere could see them.
#
# AND THE TWO-GUARDS-ONE-CODE SHAPE, for the fifth time in this sweep.
# `reconciliation_id is not null` and `matched_table is not null` sit
# one after the other, both raise 23514, and both always hold together
# -- `unmatch_bank_transaction` refuses a line in a closed
# reconciliation, so there is no route to a line stamped with one and
# not matched. Cutting the first lets the second answer in its place
# with a different sentence and the same code. The file caught
# `23514` generically and could not tell them apart. Only the WHOLE
# message does.
#
# This is the function at the top of `scripts/mutation_targets.py` --
# the money mover with the FEWEST test files reaching it (two) of all
# forty-five. It is also the one a bookkeeper uses most: every line a
# bank import cannot match to a receipt or a bill ends up here, which
# is most of them in a small company's first month.
#
# The four families this sweep keeps finding, each looked for on
# purpose:
#
#   * PERMISSION. `app.can_post` is called and nothing asserts it.
#     Neither file ever signs in as somebody who cannot post.
#   * BOUNDARY. `round(t.amount, 2)` is a no-op on a numeric(18,2)
#     column -- so the boundary worth standing on is not the rounding
#     but the CENTS: no fixture in either file posts a line that has
#     any. Every amount is a round hundred.
#   * COLLAPSE. The description is a three-step fallback --
#     p_description, then the line's own, then a literal -- and a
#     fixture whose lines all carry a description can only see the
#     first two steps.
#   * SHAPE THAT BALANCES. The two legs are built from one `v_amount`
#     with the signs mirrored, so a defect in a field that is not
#     debit or credit -- contact_id, reference, reconciled_at -- leaves
#     a journal that balances perfectly and says the wrong thing.

m("anybody can post a statement line to the ledger",
  "post_bank_transaction",
  "  if not app.can_post(t.org_id) then",
  "  if false then  -- post guard dropped",
  "-- post guard dropped")

m("a line inside a COMPLETED reconciliation can be posted again",
  "post_bank_transaction",
  "  if t.reconciliation_id is not null then",
  "  if false then  -- completed-reconciliation guard dropped",
  "-- completed-reconciliation guard dropped")

m("a line already matched to something can be posted over it",
  "post_bank_transaction",
  "  if t.matched_table is not null then",
  "  if false then  -- already-matched guard dropped",
  "-- already-matched guard dropped")

m("a line for nothing posts a journal of nothing",
  "post_bank_transaction",
  "  if v_amount = 0 then",
  "  if v_amount is null then  -- nil guard dropped",
  "-- nil guard dropped")

m("the amount is rounded to whole ringgit, losing the cents",
  "post_bank_transaction",
  "  v_amount := round(t.amount, 2);",
  "  v_amount := round(t.amount, 0);  -- cents rounded away",
  "-- cents rounded away")

m("a DELETED account is still offered to post against",
  "post_bank_transaction",
  "   where id = p_account_id and org_id = t.org_id and deleted_at is null;",
  "   where id = p_account_id and org_id = t.org_id;"
  "  -- deleted accounts allowed",
  "-- deleted accounts allowed")

m("another company's account is offered to post against",
  "post_bank_transaction",
  "   where id = p_account_id and org_id = t.org_id and deleted_at is null;",
  "   where id = p_account_id and deleted_at is null;"
  "  -- org scope dropped",
  "-- org scope dropped")

m("a HEADING can receive the posting",
  "post_bank_transaction",
  "  if v_acct.is_group then",
  "  if false then  -- heading guard dropped",
  "-- heading guard dropped")

m("both sides of the posting can be the bank itself",
  "post_bank_transaction",
  "  if v_acct.id = v_bank.account_id then",
  "  if false then  -- same-account guard dropped",
  "-- same-account guard dropped")

m("another firm's matter can be tagged on the line",
  "post_bank_transaction",
  "  if p_matter_id is not null\n"
  "     and not exists (select 1 from public.matters m\n"
  "                      where m.id = p_matter_id and m.org_id = t.org_id) then",
  "  if false then  -- matter org guard dropped",
  "-- matter org guard dropped")

m("a description of nothing but spaces is used as the description",
  "post_bank_transaction",
  "  v_desc := nullif(trim(coalesce(p_description, '')), '');",
  "  v_desc := p_description;  -- blank description taken literally",
  "-- blank description taken literally")

m("a line with no description of its own gets a null one",
  "post_bank_transaction",
  "  v_desc := coalesce(v_desc, nullif(trim(coalesce(t.description, '')), ''),\n"
  "                     'Bank statement line');",
  "  v_desc := coalesce(v_desc, nullif(trim(coalesce(t.description, '')), ''));"
  "  -- last-resort description dropped",
  "-- last-resort description dropped")

m("the description given by the person is ignored",
  "post_bank_transaction",
  "  v_desc := nullif(trim(coalesce(p_description, '')), '');",
  "  v_desc := null;  -- given description ignored",
  "-- given description ignored")

m("the line's own description is ignored",
  "post_bank_transaction",
  "  v_desc := coalesce(v_desc, nullif(trim(coalesce(t.description, '')), ''),\n"
  "                     'Bank statement line');",
  "  v_desc := coalesce(v_desc, 'Bank statement line');"
  "  -- line description ignored",
  "-- line description ignored")

m("the journal takes today's date rather than the day the money moved",
  "post_bank_transaction",
  "    p_entry_date => t.transaction_date,",
  "    p_entry_date => current_date,  -- entry date is today",
  "-- entry date is today")

m("the bank's leg takes the WRONG side",
  "post_bank_transaction",
  "        'debit', case when v_amount > 0 then v_amount else 0 end,\n"
  "        'credit', case when v_amount < 0 then -v_amount else 0 end),",
  "        'debit', case when v_amount < 0 then -v_amount else 0 end,\n"
  "        'credit', case when v_amount > 0 then v_amount else 0 end),"
  "  -- bank sides swapped",
  "-- bank sides swapped")

m("the chosen account's leg takes the WRONG side",
  "post_bank_transaction",
  "        'debit', case when v_amount < 0 then -v_amount else 0 end,\n"
  "        'credit', case when v_amount > 0 then v_amount else 0 end)),",
  "        'debit', case when v_amount > 0 then v_amount else 0 end,\n"
  "        'credit', case when v_amount < 0 then -v_amount else 0 end)),"
  "  -- chosen sides swapped",
  "-- chosen sides swapped")

m("the bank's own leg is tagged with the matter too",
  "post_bank_transaction",
  "        'account_id', v_bank.account_id,\n"
  "        'description', v_desc,",
  "        'account_id', v_bank.account_id,\n"
  "        'description', v_desc,\n"
  "        'matter_id', p_matter_id,  -- bank leg tagged",
  "-- bank leg tagged")

m("the matter is not tagged on the line it was given for",
  "post_bank_transaction",
  "        'matter_id', p_matter_id,\n"
  "        'debit', case when v_amount < 0",
  "        'matter_id', null,  -- matter not tagged\n"
  "        'debit', case when v_amount < 0",
  "-- matter not tagged")

m("the contact is not recorded on the posting",
  "post_bank_transaction",
  "        'contact_id', p_contact_id,",
  "        'contact_id', null,  -- contact not recorded",
  "-- contact not recorded")

m("the journal does not say which table it came from",
  "post_bank_transaction",
  "    p_source_table => 'bank_transactions',",
  "    p_source_table => 'bank_accounts',  -- wrong source table",
  "-- wrong source table")

m("the journal does not point back at the line",
  "post_bank_transaction",
  "    p_source_id => t.id,",
  "    p_source_id => null,  -- source line forgotten",
  "-- source line forgotten")

m("the statement's own reference is not carried onto the journal",
  "post_bank_transaction",
  "    p_reference => t.reference);",
  "    p_reference => null);  -- reference dropped",
  "-- reference dropped")

m("the line is not matched to the journal it just became",
  "post_bank_transaction",
  "     set matched_table = 'gl_entries', matched_id = v_entry,",
  "     set matched_table = null, matched_id = null,  -- match not recorded",
  "-- match not recorded")

m("the line does not remember its journal",
  "post_bank_transaction",
  "         gl_entry_id = v_entry, is_reconciled = true,",
  "         gl_entry_id = null, is_reconciled = true,  -- entry not kept",
  "-- entry not kept")

m("the line is left unreconciled",
  "post_bank_transaction",
  "         gl_entry_id = v_entry, is_reconciled = true,",
  "         gl_entry_id = v_entry, is_reconciled = false,"
  "  -- not marked reconciled",
  "-- not marked reconciled")

m("WHEN the line was reconciled is not recorded",
  "post_bank_transaction",
  "         reconciled_at = now(), updated_at = now()",
  "         reconciled_at = null, updated_at = now()  -- when not recorded",
  "-- when not recorded")

m("CONTROL -- a comment beside the description fallback",
  "post_bank_transaction",
  "  v_desc := nullif(trim(coalesce(p_description, '')), '');",
  "  v_desc := nullif(trim(coalesce(p_description, '')), '');"
  "  -- CONTROL: this cannot change a description.",
  "-- CONTROL: this cannot change a description.")

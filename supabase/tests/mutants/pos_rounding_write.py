# Mutants for the two columns public.complete_pos_sale WRITES with the
# rounding adjustment it computed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0546_scan_a_serial_number_at_the_till.sql \
#       supabase/tests/pos.sql \
#       supabase/tests/mutants/pos_rounding_write.py
#
# RESULT, 5 October: 4 mutants (3 plus a control). TWO killed on the
# first run, one survived; all three killed after. The control lived.
#
# THE SURVEY WAS RIGHT ABOUT THE FUNCTION AND WRONG ABOUT TWO OF THE
# THREE COLUMNS, which is exactly what its own docstring says to expect:
#
#   sales_documents.rounding_amount  KILLED, without being named --
#     zeroing it unbalances the journal (debits 10.05 against credits
#     10.03) and `pos.sql`'s ledger assertions catch that.
#   pos_sales.total_amount           KILLED, by the takings total.
#   pos_sales.rounding_amount        SURVIVED. Covered by nothing at all
#     in thirty-three files.
#
# One real gap of three is a useful hit rate for a survey that costs
# nothing to run, and it is the reason the tool reports rather than
# gates: two of those three findings would have failed CI over code
# that is covered.
#
# The gap itself is worth the trip. A sale whose receipt said 10.05
# while its own row said 10.03 passed every assertion in `pos.sql`, and
# the figure every POS report reads is the column rather than the return
# value.
#
# A NARROW SWEEP, pointed by `scripts/state_write_coverage.py` rather
# than by the ranking. That survey reported `rounding_amount` as a
# column `complete_pos_sale` writes and no test file reaching it names
# -- across THIRTY-THREE files.
#
# Which looked wrong, because `pos_rounding.sql` exists and
# `pos.sql` asserts the rounding in three tenders. Checked:
#
#   * `pos_rounding.sql` tests `app.pos_cash_due`, the pure function. It
#     never calls complete_pos_sale -- its own header says "the function
#     is pure, so this file needs no fixtures".
#   * `pos.sql` asserts the RETURNED figure: `r.rounding` is 0.02 on a
#     cash sale, 0 on a card one, 0.02 on the cash half of a split. It
#     never reads either column back.
#   * `recurring_template_carries_the_document.sql` names
#     `rounding_amount` in a list of columns a recurring raise must not
#     copy, and complete_pos_sale only in a comment.
#
# So the ARITHMETIC is asserted twice over and the WRITE not at all. A
# sale whose receipt says 10.05 while its row says 10.03 is a till that
# reconciles against nothing, and the figure a report reads is the
# column rather than the return value.
#
# AND THE FUNCTION'S OWN COMMENT CLAIMS OTHERWISE. Above the update:
# "this is POS taking a number the trigger normally owns, and THE TEST
# ASSERTS THE RESULT". That is the fourth shape of something that looks
# like coverage and is not -- after a comment naming a gap, a static
# sweep of source text, and a careful sweep of the guard next door. This
# one is a comment in the CODE asserting that a test exists.

m("the document does not record the rounding it was given",
  "complete_pos_sale",
  "  update public.sales_documents d\n     set rounding_amount = v_adj,",
  "  update public.sales_documents d\n     set rounding_amount = 0,"
  "  -- document rounding not stored",
  "-- document rounding not stored")

m("the sale does not record the rounding it charged",
  "complete_pos_sale",
  "         contact_id = v_contact,\n         rounding_amount = v_adj,",
  "         contact_id = v_contact,\n         rounding_amount = 0,"
  "  -- sale rounding not stored",
  "-- sale rounding not stored")

m("the sale's total is left unrounded while its receipt says otherwise",
  "complete_pos_sale",
  "         total_amount = round(v_sale.total_amount + v_adj, 2),",
  "         total_amount = v_sale.total_amount,  -- sale total not rounded",
  "-- sale total not rounded")

m("CONTROL -- a comment beside the sale update",
  "complete_pos_sale",
  "         contact_id = v_contact,\n         rounding_amount = v_adj,",
  "         contact_id = v_contact,  -- CONTROL: this cannot change a figure.\n"
  "         rounding_amount = v_adj,",
  "-- CONTROL: this cannot change a figure.")

# Mutants for app.post_goods_received_internal -- the goods arrived, the
# bill has not, and the ledger has to say so.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0609_the_goods_arrived_and_nobody_wrote_it_down.sql \
#       supabase/tests/goods_received.sql \
#       supabase/tests/mutants/post_goods_received_internal.py
#
# and then again against `supabase/tests/posting_a_bill.sql`, the other
# file that reaches it. A per-file score understates the suite: on
# `record_group_payment` the two files scored 4 and 7 survivors against
# a union of 2.
#
# Ranked top by scripts/mutation_targets.py among money movers with no
# mutants file.
#
# RESULT, 5 October: 18 mutants, SIX killed and TWELVE survived -- the
# worst score of any function measured this session. 18 of 18 after the
# work. `posting_a_bill.sql` killed only the two journal-balance
# mutations `goods_received.sql` already killed, so the union is twelve.
#
# Almost all twelve were ONE fixture problem wearing twelve hats. Every
# note in the file was in MYR at rate 1, for an item whose selling unit
# is its stocking unit, with no inventory account of its own, in a
# company with one warehouse. So
#
#   subtotal * rate    ==  subtotal
#   base_quantity      ==  quantity
#   round(x, 6)        ==  round(x, 2)     (the costs all divided clean)
#   the item's account ==  the chart's 1310
#   the default warehouse == the only warehouse
#
# and FIVE separate rules in the function were asserting the same
# arithmetic. The twelfth entry in docs/widget-tests.md at its widest:
# not one value collapsed into another, but a whole fixture flattened
# until half the function was unobservable.
#
# The fix was one note: 5 cartons of 24 at USD 100, rate 4.2345, into a
# company with two warehouses and an item carrying its own inventory
# account. Unit cost 500 * 4.2345 / 120 = 17.643750, where dropping the
# rate gives 4.166667, dividing by the 5 cartons gives 423.450000, and
# rounding to two places gives 17.64. The test asserts all four are
# different, so the one figure cannot be reached by the wrong route.
#
# Four of the twelve were plain gaps rather than collapses: no 2118
# account, the movement-to-journal link, the status, and the
# `row_count = 0` guard. That last one needed checking before it could
# be called a gap: reaching it means a tracked line whose subtotal is
# non-zero while its quantity is zero, which takes a NEGATIVE discount.
# The schema permits one -- verified, not assumed -- so the branch is
# reachable and the guard is live code. Had it not been, the mutant
# would have been equivalent.
#
# A goods received note is TWO claims, and a test can satisfy one while
# the other is wrong:
#
#   * the JOURNAL -- inventory debited line by line, the whole lot
#     credited to 2118 "Goods Received Not Invoiced", which is what
#     makes the stock an asset before an invoice exists. Getting the
#     2118 side wrong leaves the balance sheet short a liability while
#     the trial balance still foots.
#   * the STOCK -- one movement per line, at a unit cost derived from
#     the line subtotal and the BASE quantity, which is the figure the
#     weighted average is then built on. A wrong unit cost here is
#     invisible until something is sold.
#
# The unit-cost expression is the most interesting target in the file:
# `round(line_subtotal * rate / base_quantity, 6)` to SIX places, with a
# zero-quantity guard in front of it. Both the divisor and the guard get
# mutants.

m("a document that is not a goods received note is posted",
  "post_goods_received_internal",
  "  if v_doc.doc_type <> 'goods_received' then",
  "  if v_doc.doc_type = 'goods_received' and false then  -- type inverted",
  "-- type inverted")

m("an already-posted note is posted again",
  "post_goods_received_internal",
  "  if v_doc.gl_entry_id is not null then",
  "  if false then  -- repost guard dropped",
  "-- repost guard dropped")

m("the exchange rate is ignored on the journal",
  "post_goods_received_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := 1;  -- rate dropped",
  "-- rate dropped")

m("a company with no 2118 account posts anyway",
  "post_goods_received_internal",
  "  if v_grni is null then\n    raise exception 'Receiving goods needs"
  " account 2118",
  "  if false then  -- grni guard dropped\n    raise exception 'Receiving"
  " goods needs account 2118",
  "-- grni guard dropped")

m("lines for items that are NOT stocked are capitalised too",
  "post_goods_received_internal",
  "     where l.document_id = p_id\n       and l.line_type = 'item'\n"
  "       and i.track_inventory\n     order by l.line_no",
  "     where l.document_id = p_id\n       and l.line_type = 'item'\n"
  "     order by l.line_no  -- track_inventory dropped",
  "-- track_inventory dropped")

m("the item's own inventory account is ignored for the chart default",
  "post_goods_received_internal",
  "    v_inv_acct := coalesce(v_line.inventory_account_id,",
  "    v_inv_acct := coalesce(null::uuid,  -- item account ignored",
  "-- item account ignored")

m("inventory is CREDITED and 2118 debited",
  "post_goods_received_internal",
  "        'debit',       greatest(v_amount, 0),\n"
  "        'credit',      greatest(-v_amount, 0),",
  "        'debit',       greatest(-v_amount, 0),\n"
  "        'credit',      greatest(v_amount, 0),  -- inventory side swapped",
  "-- inventory side swapped")

m("2118 is DEBITED rather than credited",
  "post_goods_received_internal",
  "    'description', 'Goods received, not yet invoiced',\n"
  "    'debit',       0,\n    'credit',      v_total,",
  "    'description', 'Goods received, not yet invoiced',\n"
  "    'debit',       v_total,\n    'credit',      0,  -- grni side swapped",
  "-- grni side swapped")

m("a note of pure service lines posts an empty entry",
  "post_goods_received_internal",
  "  if v_total = 0 then\n    raise exception 'Nothing on % is stock",
  "  if false then  -- empty guard dropped\n"
  "    raise exception 'Nothing on % is stock",
  "-- empty guard dropped")

m("the stock movement is for the LINE quantity, not the base quantity",
  "post_goods_received_internal",
  "         coalesce(l.base_quantity, l.quantity),\n"
  "         case when coalesce(l.base_quantity, l.quantity) = 0 then 0",
  "         l.quantity,  -- base quantity ignored\n"
  "         case when coalesce(l.base_quantity, l.quantity) = 0 then 0",
  "-- base quantity ignored")

m("the unit cost divides by the LINE quantity, not the base quantity",
  "post_goods_received_internal",
  "              else round(l.line_subtotal * v_rate\n"
  "                         / coalesce(l.base_quantity, l.quantity), 6) end,",
  "              else round(l.line_subtotal * v_rate\n"
  "                         / l.quantity, 6) end,  -- divisor changed",
  "-- divisor changed")

m("the unit cost ignores the exchange rate",
  "post_goods_received_internal",
  "              else round(l.line_subtotal * v_rate\n"
  "                         / coalesce(l.base_quantity, l.quantity), 6) end,",
  "              else round(l.line_subtotal\n"
  "                         / coalesce(l.base_quantity, l.quantity), 6) end,"
  "  -- rate dropped from unit cost",
  "-- rate dropped from unit cost")

m("the unit cost is rounded to two places instead of six",
  "post_goods_received_internal",
  "                         / coalesce(l.base_quantity, l.quantity), 6) end,",
  "                         / coalesce(l.base_quantity, l.quantity), 2) end,"
  "  -- rounded to 2",
  "-- rounded to 2")

m("the stock lands in whatever warehouse, not the default one",
  "post_goods_received_internal",
  "         coalesce(l.warehouse_id, (select id from public.warehouses\n"
  "                                    where org_id = v_doc.org_id\n"
  "                                      and is_default limit 1)),",
  "         coalesce(l.warehouse_id, (select id from public.warehouses\n"
  "                                    where org_id = v_doc.org_id\n"
  "                                      limit 1)),  -- is_default dropped",
  "-- is_default dropped")

m("lines with no quantity still make a movement",
  "post_goods_received_internal",
  "     and l.quantity > 0;",
  "     and l.quantity >= 0;  -- zero quantity included",
  "-- zero quantity included")

m("a note where nothing has a quantity posts anyway",
  "post_goods_received_internal",
  "  if v_n = 0 then\n    raise exception 'Nothing on % has a quantity",
  "  if false then  -- row_count guard dropped\n"
  "    raise exception 'Nothing on % has a quantity",
  "-- row_count guard dropped")

m("the movements are not linked to the journal",
  "post_goods_received_internal",
  "         'purchase_documents', v_doc.id, l.id, v_entry_id, auth.uid()",
  "         'purchase_documents', v_doc.id, l.id, null, auth.uid()"
  "  -- link dropped",
  "-- link dropped")

m("the note is left unposted",
  "post_goods_received_internal",
  "     set gl_entry_id = v_entry_id,\n         status      = 'posted',",
  "     set gl_entry_id = v_entry_id,\n         status      = 'draft',"
  "  -- status not advanced",
  "-- status not advanced")

m("CONTROL -- a comment inside the function block",
  "post_goods_received_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")

# Mutants for 0805 -- public.prepare_einvoice, restated from 0770: a
# sales document already carried by a consolidated e-Invoice gets no
# e-Invoice of its own, in `request_einvoice_for_sale`'s words. Only the
# new rule is mutated here; the rest of the function is 0770's.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0805_a_consolidated_sale_is_not_filed_twice.sql \
#       supabase/tests/pos_einvoice_consolidation.sql \
#       supabase/tests/mutants/a_consolidated_sale_is_not_filed_twice.py
#
# RESULT: 4 mutants and a control, all 4 killed by
# `pos_einvoice_consolidation.sql`'s `0805` block, which asks as the
# owner with the role `authenticated`: a sale in the month's return is
# refused in those words and none is made for it, and a sale outside the
# return is prepared beside it. The same rule in
# `request_einvoice_for_sale` now stands in front of this one, which
# that function calls after naming the buyer: deleting it there is
# refused here instead, in the same words, and the buyer change rolls
# back with it -- an equivalent for whoever sweeps that function.

F = "prepare_einvoice"

m("the consolidation is not asked", F,
  "  if exists (select 1 from public.einvoice_consolidation_items ci\n              where ci.sales_document_id = v_doc.id) then",
  "  if false then  -- unasked",
  "-- unasked")
m("any sale in any return is refused", F,
  "              where ci.sales_document_id = v_doc.id) then",
  "              where true) then  -- any sale",
  "-- any sale")
m("a sale is refused for another sale's place in the return", F,
  "              where ci.sales_document_id = v_doc.id) then",
  "              where ci.sales_document_id <> v_doc.id) then  -- another's",
  "-- another's")
m("the refusal is said in other words", F,
  "      'This sale has already gone into a consolidated e-Invoice. Raise a '",
  "      'This sale is in a consolidated e-Invoice. Raise a '  -- reworded",
  "-- reworded")

m("CONTROL", F,
  "  -- 0805. Already told LHDN this sale had no identified buyer: the\n",
  "  -- 0805. Already told LHDN this sale had no identified buyer: the  -- control\n",
  "-- control")

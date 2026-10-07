# Mutants for 0759's two changes: app.post_purchase_document_internal
# taking a bill's header discount off its lines, and
# public.accept_intercompany_bill carrying the delivery charge.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0759_a_bills_discount_comes_off_its_costs.sql \
#       supabase/tests/bill_credit.sql \
#       supabase/tests/mutants/purchase_discount_0759.py
#
# The intercompany half is `accept_intercompany_bill.py`.
#
# RESULT: 6 mutants and a control, all killed by `bill_credit.sql`. Two
# only after a five-sen discount and a dollar bill were added: 100.01
# over 100 / 300 / 600 rounds to exactly 100.01 with nothing left over,
# so who took the remainder could not be seen.

m("the discount is posted nowhere (0691's shape)",
  "post_purchase_document_internal",
  "    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2)\n              - v_sign * v_share;",
  "    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2);  -- no discount",
  "-- no discount")

m("the first line takes the rounding, not the largest",
  "post_purchase_document_internal",
  "     order by abs(l.line_subtotal) desc, l.line_no\n",
  "     order by l.line_no  -- first line\n",
  "-- first line")

m("the remainder is not given to anybody",
  "post_purchase_document_internal",
  "      when v_line.id = v_big then v_disc - v_run\n",
  "      when false then v_disc - v_run  -- no remainder\n",
  "-- no remainder")

m("the discount is spread evenly, not by share",
  "post_purchase_document_internal",
  "      else round(v_disc * round(v_line.line_subtotal * v_rate, 2)\n                 / v_lines_net, 2)\n    end;",
  "      else round(v_disc / 3, 2)  -- evenly\n    end;",
  "-- evenly")

m("a credit note's discount goes the wrong way",
  "post_purchase_document_internal",
  "              - v_sign * v_share;",
  "              - v_share;  -- one way",
  "-- one way")

m("a foreign discount is not converted",
  "post_purchase_document_internal",
  "  v_disc := round(coalesce(v_doc.discount_amount, 0) * v_rate, 2);",
  "  v_disc := round(coalesce(v_doc.discount_amount, 0), 2);  -- unconverted",
  "-- unconverted")

m("CONTROL: a comment inside the block",
  "post_purchase_document_internal",
  "  if v_disc <> 0 then",
  "  if v_disc <> 0 then  -- (control)",
  "(control)")

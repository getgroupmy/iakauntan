# Mutants for app.move_document_bundles -- what selling (or crediting) a
# bundle takes off (or puts back on) the shelf, and the cost of sale it
# books. Reached only through a trigger on sales_documents.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0745_a_bundle_costs_what_its_own_line_moved.sql \
#       supabase/tests/item_bundles.sql \
#       supabase/tests/mutants/move_document_bundles.py
#
# RESULT, 6 October: 11 mutants, 10 killed, 1 EQUIVALENT, control alive
# -- all in item_bundles.sql, the only file that sells a bundle. It
# killed 5 before this sweep. Five more needed assertions, and one of
# them was the fixture trap again:
#
#   - the line's own warehouse: every sale named the DEFAULT store, so
#     the line's warehouse and the fallback were one row
#   - the line's base quantity: every sale was in single sets
#   - the cost journal's date: every invoice was dated today
#   - the movements' link to the journal that booked them
#   - a credit note's movement TYPE (the sign was asserted; the type
#     was not, and a return filed as assembly_out reads as a sale)
#
# EQUIVALENT: "a retired recipe still takes parts off the shelf". The
# outer `and r.is_active` is redundant -- app.pos_recipe_components
# joins only active recipes, so a retired bundle's components come back
# empty either way. The guard is in the callee. The assertion stays,
# because it pins what a caller sees.
#
# AND THE SWEEP FOUND A DEFECT, fixed in 0745 (this file runs against
# 0745's body): two bundle lines sharing a part read each other's
# movement cost back. Section 4b of item_bundles.sql; 580 against 319
# before the fix.

m("the cost of what moved is never added up",
  "move_document_bundles",
  "      v_cost := v_cost + coalesce(v_moved, 0);",
  "      v_cost := v_cost;  -- cost not summed",
  "-- cost not summed")

m("a sale puts the parts ON the shelf",
  "move_document_bundles",
  "        v_row.item_id, v_wh, -p_sign * v_qty, v_unit,",
  "        v_row.item_id, v_wh, p_sign * v_qty, v_unit,  -- sign flipped",
  "-- sign flipped")

m("a credit note's movement is filed as an assembly OUT",
  "move_document_bundles",
  "        (case when p_sign = 1 then 'assembly_out' else 'assembly_in' end)",
  "        'assembly_out'  -- type fixed\n",
  "-- type fixed")

m("returned parts come back at the current average, not what they left at",
  "move_document_bundles",
  "      if p_sign = -1 then\n        select sm.unit_cost into v_unit",
  "      if false then  -- return cost dropped\n        select sm.unit_cost into v_unit",
  "-- return cost dropped")

m("cost of sale is debited to purchases",
  "move_document_bundles",
  "   where a.org_id = v_doc.org_id and a.code = '5200';",
  "   where a.org_id = v_doc.org_id and a.code = '5100';  -- cogs to 5100",
  "-- cogs to 5100")

m("cost of sale is CREDITED and inventory debited",
  "move_document_bundles",
  "      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),\n"
  "    jsonb_build_object('account_id', v_inv,",
  "      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)),  -- cogs swapped\n"
  "    jsonb_build_object('account_id', v_inv,",
  "-- cogs swapped")

m("the line's own warehouse is ignored",
  "move_document_bundles",
  "    v_wh := coalesce(v_line.warehouse_id,",
  "    v_wh := coalesce(null::uuid,  -- line warehouse ignored\n",
  "-- line warehouse ignored")

m("a retired recipe still takes parts off the shelf",
  "move_document_bundles",
  "                    where r.item_id = l.item_id and r.is_active)",
  "                    where r.item_id = l.item_id)  -- retired counts",
  "-- retired counts")

m("a line sold in cartons moves pieces as if they were cartons",
  "move_document_bundles",
  "           coalesce(l.base_quantity, l.quantity) as qty, l.warehouse_id",
  "           l.quantity as qty, l.warehouse_id  -- base unit dropped",
  "-- base unit dropped")

m("the cost journal is dated today, not the invoice's date",
  "move_document_bundles",
  "    v_doc.org_id, v_doc.doc_date, 'stock_movement', v_lines,",
  "    v_doc.org_id, current_date, 'stock_movement', v_lines,  -- dated today",
  "-- dated today")

m("the movements never learn which journal booked them",
  "move_document_bundles",
  "  update public.stock_movements sm\n     set gl_entry_id = v_entry",
  "  update public.stock_movements sm\n     set gl_entry_id = null  -- link dropped\n",
  "-- link dropped")

m("CONTROL -- a comment inside the function block",
  "move_document_bundles",
  "      v_unit := 0;",
  "      v_unit := 0;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")

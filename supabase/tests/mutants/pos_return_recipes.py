# Mutants for app.pos_return_recipes (migration 0269) -- the dish's
# ingredients going back on the shelf when the sale is credited.
#
# ONE HALF OF A PAIR. `pos_deplete_recipes.py` is the other, and the two
# are SEPARATE FILES because the two functions are last defined in
# different migrations -- 0424 and 0269, 155 apart -- and
# `scripts/mutate_sql.py` exits fatally when a mutant names a function
# the migration it was given does not contain. A single file for the
# pair aborts the run for whichever half it is not pointed at.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0269_crediting_a_counter_sale_puts_it_back.sql \
#       supabase/tests/pos_recipes.sql \
#       supabase/tests/mutants/pos_return_recipes.py
#
# then again against `pos_fnb.sql`, `credit_note_return.sql`,
# `lot_allocation_shapes.sql` and `lots_across_the_new_sources.sql`.
#
# Both halves are reached by a TRIGGER, not by a call:
# `pos_deplete_recipes` fires on `pos_sales` going to completed and
# `pos_return_recipes` on a credit note being posted against the sale's
# invoice. `scripts/mutation_targets.py` cannot count their test files
# for that reason, so the five above were chosen by which files have
# RECIPE fixtures -- and that choice is itself a judgement this sweep did
# not measure. The thirty-odd other files that call `complete_pos_sale`
# sell items with no recipe, so they reach the function and return at the
# first `having sum(n.quantity) > 0`.
#
# NOT A MUTANT -- A DEFECT, reported in `docs/handoff.md` and NOT fixed:
# the depletion half has a whole `union all` branch over
# `pos_sale_line_modifiers`, and the return half HAS NO REFERENCE TO ANY
# MODIFIER TABLE. Measured on `pos_recipes.sql`'s own section-7 fixture:
# two eggs out, one back. A mutation sweep cannot find that -- it breaks
# what is there and cannot see what is missing -- which is why it was
# found by reading the two halves against each other instead.
#
# RESULT, 6 October -- SUPERSEDES the 5 October one below: 21 of 28
# KILLED, 7 EQUIVALENT, control alive. Of the seven left "STILL OPEN"
# below, three are now killed and four turned out to be equivalent:
#
# KILLED by pos_recipes.sql section 10, which has the stores the block
# above lacks: the food returned into another company's warehouse, and
# into the default rather than the outlet's own. And a DISCOUNT line
# naming the dish, on a credit for one plate of two -- food still
# owing, so the clamp cannot stop the mutant first -- kills the
# line-type rule.
#
# EQUIVALENT, beyond the three proven below:
#   - "a credit line of zero quantity puts food back": a zero line
#     contributes zero, and `if v_qty <= 0 then continue` drops it.
#     (The code.)
#   - "the food comes back at the LATEST cost" and "... read off a
#     movement that PUT FOOD BACK": depletion runs once per sale and is
#     grouped by item, so a sale has exactly ONE outbound movement per
#     ingredient, made in an earlier transaction than any credit. First,
#     latest and outbound-only all find that row. The note below asked
#     for "two outbound layers at different costs"; a sale cannot have
#     two.  (The caller and the code.)
#   - "an ingredient nobody counts is put back": what can come back is
#     clamped to what went out, and an untracked ingredient never went
#     out. The ONE case that tells them apart is an ingredient whose
#     tracking is switched OFF between the sale and the credit -- and
#     what should happen then is itself a question, so it is recorded
#     rather than asserted.
#
# RESULT, 5 October: 29 mutants (28 plus a control).
#
#   BEFORE the work, across all five files:  8 of 28, and ONLY
#   `credit_note_return.sql` killed anything. `pos_recipes.sql` -- the
#   file named for recipes -- killed ZERO, along with `pos_fnb.sql` and
#   both lot files. That is the asymmetry reported in
#   `docs/handoff.md` as a number: the file that tests the recipe path
#   tested one direction of it.
#
#   AFTER section 9b: 18 of 28 on `pos_recipes.sql` alone, and 18 of 28
#   across the five -- the SAME figure, because everything
#   `credit_note_return.sql` kills is now a subset of what this file
#   does. THREE of the remainder are equivalent and proven so below,
#   giving 18 of 25 killable. The control lived throughout.
#
#   The first draft of this header said "21 of 28 across the five",
#   having added `credit_note_return.sql`'s eight to this file's
#   eighteen without checking the overlap. A union is not a sum, and the
#   figure was corrected from the measurement rather than from the
#   arithmetic that produced it.
#
# The two things this function DOCUMENTS were both unasserted before
# this. `0269` writes them into the body -- "A credit note posted twice
# -- reversed and re-posted, say -- must not return the food twice" and
# "Never more than went out" -- and the mutants for both lived. A rule
# in a comment is not a rule.
#
# AND THE DATE FIXTURE WAS COLLAPSED. Section 9b's first version
# asserted that the return is dated the credit note and not the sale --
# and both date mutants survived it, because the fixture settles the
# bill and credits it on the SAME DAY, so the two answers are one row.
# The duplicate credit note is now dated the day after. That is
# CLAUDE.md's first trap met head on, in a block written by somebody who
# had just read the warning.
#
# STILL OPEN, measured and not papered over -- SEVEN mutants needing
# fixtures this block does not have: food returned into another
# company's warehouse, and into the default rather than the outlet's own
# (two organizations, and an outlet carrying `warehouse_id`); a non-item
# or zero-quantity credit line, and an untracked ingredient (a sale with
# food STILL OWING, because otherwise the clamp stops the mutant before
# its own condition is reached); and the unit cost read off the newest
# movement or off an inbound one (two outbound layers at different
# costs).

# ===================================================================
# app.pos_return_recipes -- the plate coming back
# ===================================================================

# EQUIVALENT, and the proof is the guard BELOW it -- the "code's own
# shape" kind. With the refusal dropped, `v_sale` is an all-null record,
# so `where o.id = v_sale.outlet_id` matches nothing, `v_wh` stays null
# and the next guard returns null anyway. Nothing a fixture can do
# distinguishes the two forms.
m("a credit against a sale that is not there puts food back",
  "pos_return_recipes",
  "  if v_sale.id is null or v_doc.id is null then\n    return null;\n  end if;",
  "  if false then\n    return null;\n  end if;  -- missing sale or credit not checked",
  "-- missing sale or credit not checked")

# EQUIVALENT for the same family of reason, one step further on. With
# only the sale checked, a credit note that is not there gives an
# all-null `v_doc` -- and then the loop over `sales_document_lines where
# l.document_id = p_credit` finds NO ROWS, so nothing is moved, `v_cost`
# stays zero and the function returns null at the zero-cost short
# circuit. The body never reaches anything that reads `v_doc`.
m("a credit with no document behind it puts food back",
  "pos_return_recipes",
  "  if v_sale.id is null or v_doc.id is null then",
  "  if v_sale.id is null then  -- missing credit note unchecked",
  "-- missing credit note unchecked")

m("the food goes back into ANOTHER company's warehouse",
  "pos_return_recipes",
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))",
  "                    where w.org_id <> v_sale.org_id and w.is_default limit 1))"
  "  -- return warehouse taken from elsewhere",
  "-- return warehouse taken from elsewhere")

m("an outlet with its OWN warehouse gets the food back elsewhere",
  "pos_return_recipes",
  "  select coalesce(o.warehouse_id,\n"
  "                  (select w.id from public.warehouses w\n"
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))\n"
  "    into v_wh",
  "  select (select w.id from public.warehouses w\n"
  "           where w.org_id = v_sale.org_id and w.is_default limit 1)\n"
  "    into v_wh  -- outlet warehouse ignored on the way back",
  "-- outlet warehouse ignored on the way back")

m("A CREDIT NOTE POSTED TWICE RETURNS THE FOOD TWICE",
  "pos_return_recipes",
  "  if exists (select 1 from public.stock_movements sm\n"
  "              where sm.source_table = 'pos_sales'\n"
  "                and sm.source_id = p_sale\n"
  "                and sm.source_line_id = p_credit) then\n    return null;\n  end if;",
  "  if false then\n    return null;\n  end if;  -- double-return guard dropped",
  "-- double-return guard dropped")

m("a SECOND credit note against the same sale returns nothing",
  "pos_return_recipes",
  "                and sm.source_line_id = p_credit) then",
  "                and sm.source_line_id is not null) then"
  "  -- double-return guard reads any credit",
  "-- double-return guard reads any credit")

m("the lines of ANOTHER credit note are returned",
  "pos_return_recipes",
  "     where l.document_id = p_credit\n       and l.line_type = 'item'",
  "     where l.line_type = 'item'  -- credit note scope dropped",
  "-- credit note scope dropped")

m("a delivery charge on the credit note is treated as food",
  "pos_return_recipes",
  "       and l.line_type = 'item'\n       and l.item_id is not null",
  "       and l.item_id is not null  -- line_type no longer checked",
  "-- line_type no longer checked")

m("a credit line of zero quantity puts food back",
  "pos_return_recipes",
  "       and l.quantity > 0\n       and i.track_inventory",
  "       and i.track_inventory  -- zero-quantity credit lines included",
  "-- zero-quantity credit lines included")

m("an ingredient nobody counts is put back on the shelf",
  "pos_return_recipes",
  "       and l.quantity > 0\n       and i.track_inventory",
  "       and l.quantity > 0  -- track_inventory dropped on the way back",
  "-- track_inventory dropped on the way back")

m("MORE COMES BACK THAN EVER WENT OUT",
  "pos_return_recipes",
  "    v_qty  := least(round(v_row.quantity, 4), round(v_left, 4));",
  "    v_qty  := round(v_row.quantity, 4);  -- never-more-than-went-out clamp dropped",
  "-- never-more-than-went-out clamp dropped")

m("what has already come back is not counted against the next credit",
  "pos_return_recipes",
  "    v_left := app.pos_recipe_consumed(p_sale, v_row.item_id)\n"
  "              - app.pos_recipe_returned(p_sale, v_row.item_id);",
  "    v_left := app.pos_recipe_consumed(p_sale, v_row.item_id);"
  "  -- already-returned not deducted",
  "-- already-returned not deducted")

m("the clamp takes the LARGER of the two",
  "pos_return_recipes",
  "    v_qty  := least(round(v_row.quantity, 4), round(v_left, 4));",
  "    v_qty  := greatest(round(v_row.quantity, 4), round(v_left, 4));"
  "  -- return clamp inverted",
  "-- return clamp inverted")

m("a fully returned ingredient gets a movement of zero",
  "pos_return_recipes",
  "    if v_qty <= 0 then\n      continue;\n    end if;",
  "    if v_qty < 0 then\n      continue;\n    end if;  -- zero-return skip narrowed",
  "-- zero-return skip narrowed")

m("the food comes back at the LATEST cost rather than the one it left at",
  "pos_return_recipes",
  "       and sm.item_id = v_row.item_id and sm.quantity < 0\n"
  "     order by sm.created_at limit 1;",
  "       and sm.item_id = v_row.item_id and sm.quantity < 0\n"
  "     order by sm.created_at desc limit 1;  -- unit cost read off the newest",
  "-- unit cost read off the newest")

# The replacement KEEPS the trailing newline. Without it the marker
# comment ran straight into `order by sm.created_at limit 1;` on the
# following line and commented it out, which the harness reported as a
# HARNESS ERROR ("syntax error at or near insert") and then aborted the
# whole file on -- so every mutant after this one went unmeasured in all
# five files. See the pre-flight note in the header.
m("the cost it left at is read off a movement that PUT FOOD BACK",
  "pos_return_recipes",
  "       and sm.item_id = v_row.item_id and sm.quantity < 0\n",
  "       and sm.item_id = v_row.item_id"
  "  -- outbound filter dropped from the cost read\n",
  "-- outbound filter dropped from the cost read")

m("THE FOOD COMES BACK OFF THE SHELF INSTEAD OF ONTO IT",
  "pos_return_recipes",
  "      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, v_qty,",
  "      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, -v_qty,"
  "  -- return sign flipped",
  "-- return sign flipped")

m("the return is recorded as a further issue",
  "pos_return_recipes",
  "      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, v_qty,",
  "      v_doc.doc_date, 'assembly_out', v_row.item_id, v_wh, v_qty,"
  "  -- return movement type flipped",
  "-- return movement type flipped")

m("the return is dated the day of the SALE, not the day of the credit",
  "pos_return_recipes",
  "      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, v_qty,",
  "      app.malaysian_day(v_sale.completed_at), 'assembly_in', v_row.item_id, v_wh, v_qty,"
  "  -- return dated the sale",
  "-- return dated the sale")

m("the return does not say which credit note made it",
  "pos_return_recipes",
  "      'pos_sales', p_sale, p_credit,\n      'Credited ' || v_doc.doc_no, auth.uid());",
  "      'pos_sales', p_sale, null,\n      'Credited ' || v_doc.doc_no, auth.uid());"
  "  -- credit note not recorded on the movement",
  "-- credit note not recorded on the movement")

m("a credit that cost nothing posts a journal of nothing",
  "pos_return_recipes",
  "  if round(v_cost, 2) = 0 then\n    return null;\n  end if;\n\n"
  "  select a.id into v_cogs",
  "  if false then  -- zero-cost return short circuit dropped\n    return null;\n  end if;\n\n"
  "  select a.id into v_cogs",
  "-- zero-cost return short circuit dropped")

m("the credited food cost is released from the wrong account",
  "pos_return_recipes",
  "   where a.org_id = v_sale.org_id and a.code = '5200';",
  "   where a.org_id = v_sale.org_id and a.code = '5100';  -- return cogs code changed",
  "-- return cogs code changed")

m("the credited food goes back into the wrong stock account",
  "pos_return_recipes",
  "   where a.org_id = v_sale.org_id and a.code = '1310';",
  "   where a.org_id = v_sale.org_id and a.code = '1210';  -- return stock code changed",
  "-- return stock code changed")

m("THE RETURN JOURNAL IS THE SAME WAY ROUND AS THE DEPLETION",
  "pos_return_recipes",
  "      'description', 'Ingredients returned ' || v_doc.doc_no,\n"
  "      'debit', round(v_cost, 2), 'credit', 0),",
  "      'description', 'Ingredients returned ' || v_doc.doc_no,\n"
  "      'debit', 0, 'credit', round(v_cost, 2)),  -- return sides flipped",
  "-- return sides flipped")

m("the return journal is not marked as a stock movement",
  "pos_return_recipes",
  "    v_sale.org_id, v_doc.doc_date, 'stock_movement', v_lines,",
  "    v_sale.org_id, v_doc.doc_date, 'manual', v_lines,"
  "  -- return journal source lied about",
  "-- return journal source lied about")

m("the return journal is dated the sale rather than the credit",
  "pos_return_recipes",
  "    v_sale.org_id, v_doc.doc_date, 'stock_movement', v_lines,",
  "    v_sale.org_id, app.malaysian_day(v_sale.completed_at), 'stock_movement', v_lines,"
  "  -- return journal dated the sale",
  "-- return journal dated the sale")

m("the returning movements are never linked to their journal",
  "pos_return_recipes",
  "     and sm.source_line_id = p_credit and sm.gl_entry_id is null;",
  "     and sm.source_line_id = p_credit and false;"
  "  -- return movements not linked",
  "-- return movements not linked")

# EQUIVALENT, proven by the OTHER conjunct in the same `where`. The
# update keeps `and sm.gl_entry_id is null`, so dropping the credit-note
# scope can only reach movements that have no journal yet -- and both
# halves of this pair link every movement they write. There is no
# unlinked movement for the widened scope to catch.
#
# An earlier attempt to kill it asserted `count(distinct gl_entry_id) =
# 1` over the depleting movements, which cannot fail either way: under
# the mutant they would all be restamped with the SAME journal, so the
# count stays one. A distinctness check does not separate "unchanged"
# from "all changed together".
m("the DEPLETING movements are relinked to the return's journal",
  "pos_return_recipes",
  "     and sm.source_line_id = p_credit and sm.gl_entry_id is null;",
  "     and sm.gl_entry_id is null;  -- return scope dropped from the link",
  "-- return scope dropped from the link")

m("CONTROL (return) -- a comment beside the cost",
  "pos_return_recipes",
  "  v_cost   numeric := 0;",
  "  v_cost   numeric := 0;  -- CONTROL: this cannot change a quantity.",
  "-- CONTROL: this cannot change a quantity.")

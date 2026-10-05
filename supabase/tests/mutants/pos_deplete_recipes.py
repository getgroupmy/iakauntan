# Mutants for app.pos_deplete_recipes (migration 0424) -- the dish's
# ingredients coming off the shelf when a counter sale is settled.
#
# ONE HALF OF A PAIR. `pos_return_recipes.py` is the other, and the two
# are SEPARATE FILES because the two functions are last defined in
# different migrations -- 0424 and 0269, 155 apart -- and
# `scripts/mutate_sql.py` exits fatally when a mutant names a function
# the migration it was given does not contain. A single file for the
# pair aborts the run for whichever half it is not pointed at.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0424_a_moment_cast_to_a_day.sql \
#       supabase/tests/pos_recipes.sql \
#       supabase/tests/mutants/pos_deplete_recipes.py
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
# RESULT: see the kill sheet appended when this has been run.

# ===================================================================
# app.pos_deplete_recipes -- the plate going out
# ===================================================================

m("a sale that is not there is still depleted",
  "pos_deplete_recipes",
  "  if v_sale.id is null then\n    return null;\n  end if;",
  "  if false then\n    return null;\n  end if;  -- missing sale not checked",
  "-- missing sale not checked")

m("an outlet with its OWN warehouse is ignored",
  "pos_deplete_recipes",
  "  select coalesce(o.warehouse_id,\n"
  "                  (select w.id from public.warehouses w\n"
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))\n"
  "    into v_wh\n"
  "    from public.pos_outlets o where o.id = v_sale.outlet_id;\n"
  "  if v_wh is null then\n    return null;\n  end if;",
  "  select (select w.id from public.warehouses w\n"
  "           where w.org_id = v_sale.org_id and w.is_default limit 1)\n"
  "    into v_wh\n"
  "    from public.pos_outlets o where o.id = v_sale.outlet_id;\n"
  "  if v_wh is null then\n    return null;\n  end if;"
  "  -- outlet warehouse ignored on the way out",
  "-- outlet warehouse ignored on the way out")

m("an outlet with no warehouse of its own depletes nothing",
  "pos_deplete_recipes",
  "  select coalesce(o.warehouse_id,\n"
  "                  (select w.id from public.warehouses w\n"
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))\n"
  "    into v_wh",
  "  select o.warehouse_id\n"
  "    into v_wh  -- default-warehouse fallback dropped on the way out",
  "-- default-warehouse fallback dropped on the way out")

m("the ingredients come out of ANOTHER company's warehouse",
  "pos_deplete_recipes",
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))",
  "                    where w.org_id <> v_sale.org_id and w.is_default limit 1))"
  "  -- warehouse taken from elsewhere",
  "-- warehouse taken from elsewhere")

m("the ingredients come out of whichever warehouse is first",
  "pos_deplete_recipes",
  "                    where w.org_id = v_sale.org_id and w.is_default limit 1))",
  "                    where w.org_id = v_sale.org_id limit 1))"
  "  -- is_default dropped on the way out",
  "-- is_default dropped on the way out")

# The branch the RETURN half does not have at all. See the defect note.
m("A MODIFIER'S INGREDIENTS ARE NOT TAKEN OFF THE SHELF",
  "pos_deplete_recipes",
  "      union all\n"
  "      select c.item_id, sum(c.quantity)\n"
  "        from public.pos_sale_lines l\n"
  "        join public.pos_sale_line_modifiers m on m.line_id = l.id",
  "      union all\n"
  "      select c.item_id, sum(c.quantity)\n"
  "        from public.pos_sale_lines l\n"
  "        join public.pos_sale_line_modifiers m on m.line_id = l.id\n"
  "         and false  -- modifier branch switched off",
  "-- modifier branch switched off")

m("a modifier with no recipe quantity takes an ingredient anyway",
  "pos_deplete_recipes",
  "         and coalesce(pm.recipe_quantity, 0) > 0",
  "         and true  -- zero recipe quantity no longer excluded",
  "-- zero recipe quantity no longer excluded")

m("two of a dish take one dish's worth of its modifier",
  "pos_deplete_recipes",
  "            * m.quantity * l.quantity) c",
  "            * m.quantity) c  -- line quantity dropped from the modifier",
  "-- line quantity dropped from the modifier")

m("a dish's own recipe is read for the wrong sale",
  "pos_deplete_recipes",
  "       where l.sale_id = p_sale and l.item_id is not null",
  "       where l.item_id is not null  -- sale scope dropped",
  "-- sale scope dropped")

m("an ingredient nobody counts is still taken off the shelf",
  "pos_deplete_recipes",
  "     where i.track_inventory\n     group by n.item_id, i.name, i.tracking",
  "     group by n.item_id, i.name, i.tracking"
  "  -- track_inventory dropped on the way out",
  "-- track_inventory dropped on the way out")

m("an ingredient the dish needs none of gets a movement of nothing",
  "pos_deplete_recipes",
  "     having sum(n.quantity) > 0",
  "     having sum(n.quantity) >= 0  -- zero-need boundary widened",
  "-- zero-need boundary widened")

m("a recipe measured in grams is rounded to whole units",
  "pos_deplete_recipes",
  "    v_qty := round(v_row.quantity, 4);",
  "    v_qty := round(v_row.quantity, 0);  -- recipe quantity rounded whole",
  "-- recipe quantity rounded whole")

m("an UNTRACKED ingredient is clamped to a lot balance it has none of",
  "pos_deplete_recipes",
  "    if v_row.tracking is not null and v_row.tracking <> 'none' then",
  "    if true then  -- lot clamp applied to everything",
  "-- lot clamp applied to everything")

m("a lot-tracked ingredient is taken beyond what the lots hold",
  "pos_deplete_recipes",
  "    if v_row.tracking is not null and v_row.tracking <> 'none' then",
  "    if false then  -- lot clamp never applied",
  "-- lot clamp never applied")

m("the lot clamp takes the LARGER of the two",
  "pos_deplete_recipes",
  "      v_qty := least(v_qty, round(app.lot_available(v_row.item_id, v_wh), 4));",
  "      v_qty := greatest(v_qty, round(app.lot_available(v_row.item_id, v_wh), 4));"
  "  -- lot clamp inverted",
  "-- lot clamp inverted")

m("an ingredient with nothing left gets a movement of zero",
  "pos_deplete_recipes",
  "    if v_qty <= 0 then\n      continue;\n    end if;",
  "    if v_qty < 0 then\n      continue;\n    end if;  -- zero-quantity skip narrowed",
  "-- zero-quantity skip narrowed")

m("THE INGREDIENTS GO ONTO THE SHELF INSTEAD OF OFF IT",
  "pos_deplete_recipes",
  "      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,",
  "      'assembly_out', v_row.item_id, v_wh, v_qty, 0,  -- depletion sign flipped",
  "-- depletion sign flipped")

m("the depletion is recorded as a receipt",
  "pos_deplete_recipes",
  "      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,",
  "      'assembly_in', v_row.item_id, v_wh, -v_qty, 0,  -- movement type flipped",
  "-- movement type flipped")

m("the plate is dated the day the job ran, not the night it was served",
  "pos_deplete_recipes",
  "      coalesce(app.malaysian_day(v_sale.completed_at), app.today()),\n"
  "      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,",
  "      app.today(),\n"
  "      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,"
  "  -- movement dated today",
  "-- movement dated today")

m("the movement does not say which sale took the ingredients",
  "pos_deplete_recipes",
  "      'pos_sales', p_sale, 'Recipe ' || v_sale.sale_no);",
  "      'pos_sales', null, 'Recipe ' || v_sale.sale_no);  -- source sale forgotten",
  "-- source sale forgotten")

m("the cost is read off the FIRST movement rather than the one just made",
  "pos_deplete_recipes",
  "     order by sm.created_at desc limit 1;\n\n    v_cost := v_cost + coalesce(v_moved, 0);",
  "     order by sm.created_at limit 1;\n\n    v_cost := v_cost + coalesce(v_moved, 0);"
  "  -- cost read off the oldest movement",
  "-- cost read off the oldest movement")

m("only the last ingredient's cost reaches the journal",
  "pos_deplete_recipes",
  "    v_cost := v_cost + coalesce(v_moved, 0);\n  end loop;",
  "    v_cost := coalesce(v_moved, 0);\n  end loop;  -- cost not accumulated",
  "-- cost not accumulated")

m("a sale that consumed nothing posts a journal of nothing",
  "pos_deplete_recipes",
  "  if round(v_cost, 2) = 0 then\n    return null;\n  end if;\n\n"
  "  select a.id into v_cogs",
  "  if false then\n    return null;\n  end if;\n\n"
  "  select a.id into v_cogs  -- zero-cost short circuit dropped",
  "-- zero-cost short circuit dropped")

m("the food cost is charged to the wrong account",
  "pos_deplete_recipes",
  "   where a.org_id = v_sale.org_id and a.code = '5200';",
  "   where a.org_id = v_sale.org_id and a.code = '5100';  -- cogs code changed",
  "-- cogs code changed")

m("the ingredients are taken out of the wrong stock account",
  "pos_deplete_recipes",
  "   where a.org_id = v_sale.org_id and a.code = '1310';",
  "   where a.org_id = v_sale.org_id and a.code = '1210';  -- stock code changed",
  "-- stock code changed")

m("a chart with no cost-of-sales account posts anyway",
  "pos_deplete_recipes",
  "  if v_cogs is null or v_inv is null then\n    return null;\n  end if;\n\n  v_lines := jsonb_build_array(",
  "  if false then\n    return null;\n  end if;\n\n  v_lines := jsonb_build_array("
  "  -- missing-account short circuit dropped",
  "-- missing-account short circuit dropped")

m("the food cost is CREDITED and the stock debited",
  "pos_deplete_recipes",
  "      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),",
  "      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)),"
  "  -- cogs side flipped",
  "-- cogs side flipped")

m("a NEGATIVE recipe cost is posted on the same side as a positive one",
  "pos_deplete_recipes",
  "      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),",
  "      'debit', 0, 'credit', v_cost),  -- cogs sign clamp dropped",
  "-- cogs sign clamp dropped")

m("the recipe journal is not marked as a stock movement",
  "pos_deplete_recipes",
  "    'stock_movement', v_lines,\n    'Recipe consumption ' || v_sale.sale_no,",
  "    'manual', v_lines,\n    'Recipe consumption ' || v_sale.sale_no,"
  "  -- depletion journal source lied about",
  "-- depletion journal source lied about")

m("the movements are never linked to the journal that costed them",
  "pos_deplete_recipes",
  "  update public.stock_movements sm\n     set gl_entry_id = v_entry\n"
  "   where sm.source_table = 'pos_sales' and sm.source_id = p_sale\n"
  "     and sm.gl_entry_id is null;",
  "  update public.stock_movements sm\n     set gl_entry_id = v_entry\n"
  "   where false;  -- movements not linked to the journal",
  "-- movements not linked to the journal")

m("an EARLIER sale's movements are relinked to this journal",
  "pos_deplete_recipes",
  "   where sm.source_table = 'pos_sales' and sm.source_id = p_sale\n"
  "     and sm.gl_entry_id is null;",
  "   where sm.source_table = 'pos_sales' and sm.source_id = p_sale;"
  "  -- already-linked movements relinked",
  "-- already-linked movements relinked")

m("CONTROL (deplete) -- a comment beside the cost",
  "pos_deplete_recipes",
  "  v_cost   numeric := 0;",
  "  v_cost   numeric := 0;  -- CONTROL: this cannot change a quantity.",
  "-- CONTROL: this cannot change a quantity.")


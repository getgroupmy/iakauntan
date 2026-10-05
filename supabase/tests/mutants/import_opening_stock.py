# Mutants for public.import_opening_stock -- the stock a company already
# had on the day it started using this system.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0152_import_opening_stock.sql \
#       supabase/tests/opening_stock.sql \
#       supabase/tests/mutants/import_opening_stock.py
#
# then again against `opening_import_shapes.sql` and
# `migration_progress.sql`, the other two files that reach it.
#
# This is a different shape from the posting functions: THIRTEEN
# validation rules in one `elsif` chain, a preview mode and a commit
# mode, and a comparison against what the ledger already says stock is
# worth. An `elsif` chain is the easiest thing in SQL to test
# incompletely, because every rule after the first shadows the ones
# before it -- a row that trips rule 2 never reaches rule 7, so a
# fixture can cover thirteen rules with thirteen rows and still not
# prove that any particular rule is the one that fired.
#
# RESULT, 5 October: 25 mutants, TWENTY-FOUR killed on the first file
# and the twenty-fifth killed by another -- 25 of 25, NO GAPS, nothing
# equivalent. The best result of any function in this sweep.
#
#   opening_stock.sql          kills 24 of 25
#   opening_import_shapes.sql  kills the 25th, and 17 others
#   migration_progress.sql     kills 1 (it drives the preview, not the
#                              rules)
#
# The twenty-fifth is the one worth recording, because the prediction
# was half right. Going in, the three gap families this sweep keeps
# finding were written down and looked for deliberately -- and the
# BOUNDARY one duly survived `opening_stock.sql`: `v_cost < 0` mutated
# to `<= 0`, which refuses stock brought in at no cost. That is a real
# boundary and the same shape as `send_stock_transfer`'s `< v_qty`
# an hour earlier.
#
# It is not a gap. `opening_import_shapes.sql` asserts it directly --
# "stock brought in at no cost at all is allowed -- samples are stock".
# The assertion was written by somebody who had thought about free
# samples, in the file about shapes rather than the file about opening
# stock.
#
# So: right about the shape, wrong about the gap, and the only reason no
# duplicate assertion was added is the rule this sweep keeps proving --
# run EVERY file that reaches the function before believing a survivor.
# Four functions in this sweep have now had a survivor in one file that
# another file kills.
#
# The three gap families this sweep keeps finding are each represented
# on purpose:
#
#   * a PERMISSION guard -- `app.check_open_item_run`, the first line of
#     the function and the only thing standing between a stranger and
#     another company's opening stock.
#   * BOUNDARIES -- `v_qty <= 0` and `v_cost < 0` sit next to each
#     other and differ: a quantity of zero is refused and a cost of zero
#     is ALLOWED, because free stock is a real thing and stock nobody
#     has is not. Mutating each to the other's form is the off-by-one
#     that a fixture of ordinary positive numbers cannot see.
#   * a FIXTURE COLLAPSE -- the duplicate-row key is
#     `item|warehouse|lot`, and a file of untracked items in one
#     warehouse makes all three the same discriminator.

m("a stranger may import another company's opening stock",
  "import_opening_stock",
  "  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);",
  "  -- guard dropped: app.check_open_item_run(p_org_id, p_rows, p_as_at);",
  "-- guard dropped")

m("a row with no item code is accepted",
  "import_opening_stock",
  "    if v_item_code is null then\n      v_problem := 'No item code.';",
  "    if false then  -- no-code rule dropped\n"
  "      v_problem := 'No item code.';",
  "-- no-code rule dropped")

m("an item that is not in the system is accepted",
  "import_opening_stock",
  "    elsif v_item_id is null then\n      v_problem := format(\n"
  "        '%s is not an item here. Import the item list first.',"
  " v_item_code);",
  "    elsif false then  -- unknown-item rule dropped\n"
  "      v_problem := format(\n"
  "        '%s is not an item here. Import the item list first.',"
  " v_item_code);",
  "-- unknown-item rule dropped")

m("a service is given an opening quantity",
  "import_opening_stock",
  "    elsif not coalesce(v_tracked, false) then",
  "    elsif coalesce(v_tracked, false) and false then"
  "  -- not-stocked rule dropped",
  "-- not-stocked rule dropped")

m("the same item, warehouse and lot may appear twice",
  "import_opening_stock",
  "    elsif v_key = any (v_seen) then",
  "    elsif false then  -- duplicate rule dropped",
  "-- duplicate rule dropped")

m("the duplicate key ignores the lot, so two batches collide",
  "import_opening_stock",
  "    v_key := lower(coalesce(v_item_code, '')) || '|'\n"
  "          || lower(coalesce(v_wh_code, '')) || '|'\n"
  "          || lower(coalesce(v_lot_ref, ''));",
  "    v_key := lower(coalesce(v_item_code, '')) || '|'\n"
  "          || lower(coalesce(v_wh_code, ''));  -- lot dropped from key",
  "-- lot dropped from key")

m("the duplicate key ignores the warehouse",
  "import_opening_stock",
  "    v_key := lower(coalesce(v_item_code, '')) || '|'\n"
  "          || lower(coalesce(v_wh_code, '')) || '|'\n"
  "          || lower(coalesce(v_lot_ref, ''));",
  "    v_key := lower(coalesce(v_item_code, '')) || '|'\n"
  "          || lower(coalesce(v_lot_ref, ''));"
  "  -- warehouse dropped from key",
  "-- warehouse dropped from key")

m("a warehouse code that is not a warehouse is accepted",
  "import_opening_stock",
  "    elsif v_wh_code is not null and v_wh_id is null then",
  "    elsif false then  -- unknown-warehouse rule dropped",
  "-- unknown-warehouse rule dropped")

m("an opening quantity of zero is accepted",
  "import_opening_stock",
  "    elsif v_qty <= 0 then",
  "    elsif v_qty < 0 then  -- zero quantity allowed",
  "-- zero quantity allowed")

m("free stock is refused, which it should not be",
  "import_opening_stock",
  "    elsif v_cost < 0 then",
  "    elsif v_cost <= 0 then  -- zero cost refused",
  "-- zero cost refused")

m("a negative cost is accepted",
  "import_opening_stock",
  "    elsif v_cost < 0 then",
  "    elsif false then  -- negative cost allowed",
  "-- negative cost allowed")

m("a batch-tracked item may come in without a batch",
  "import_opening_stock",
  "    elsif v_tracking <> 'none' and v_lot_ref is null then",
  "    elsif false then  -- missing-lot rule dropped",
  "-- missing-lot rule dropped")

m("an untracked item may carry a lot number nobody reads",
  "import_opening_stock",
  "    elsif v_tracking = 'none' and v_lot_ref is not null then",
  "    elsif false then  -- stray-lot rule dropped",
  "-- stray-lot rule dropped")

# The first version of this mutant dropped the closing parenthesis with
# the predicate and came back as `mismatched parentheses at or near ";"`
# -- a HARNESS ERROR, not a kill. `false and` keeps the shape.
m("an item that has already moved may be given an opening balance",
  "import_opening_stock",
  "    elsif exists (select 1 from public.stock_movements m\n"
  "                   where m.org_id = p_org_id and m.item_id = v_item_id)",
  "    elsif exists (select 1 from public.stock_movements m\n"
  "                   where false and m.org_id = p_org_id"
  " and m.item_id = v_item_id)  -- already-moved rule dropped",
  "-- already-moved rule dropped")

m("the file's value is the quantity plus the cost, not times it",
  "import_opening_stock",
  "      v_value := v_value + round(v_qty * v_cost, 2);",
  "      v_value := v_value + round(v_qty + v_cost, 2);  -- value added",
  "-- value added")

m("a file with errors is committed anyway",
  "import_opening_stock",
  "  if p_commit and v_bad > 0 then",
  "  if false then  -- bad-file guard dropped",
  "-- bad-file guard dropped")

m("opening stock may be brought in twice",
  "import_opening_stock",
  "    if exists (select 1 from public.stock_movements m\n"
  "                where m.org_id = p_org_id\n"
  "                  and m.movement_type = 'opening_balance')",
  "    if false  -- already-opened guard dropped",
  "-- already-opened guard dropped")

m("a row with no warehouse goes nowhere instead of to the default",
  "import_opening_stock",
  "      v_wh_id := v_default_wh;\n      if v_wh_code is not null then",
  "      v_wh_id := null;  -- default warehouse dropped\n"
  "      if v_wh_code is not null then",
  "-- default warehouse dropped")

m("the quantity and the cost are written the wrong way round",
  "import_opening_stock",
  "        v_item_id, v_wh_id, v_qty, v_cost,",
  "        v_item_id, v_wh_id, v_cost, v_qty,  -- qty and cost swapped",
  "-- qty and cost swapped")

m("the batch rows are never written",
  "import_opening_stock",
  "      if v_tracking <> 'none' then\n        insert into public.stock_lots",
  "      if false then  -- lot writing dropped\n"
  "        insert into public.stock_lots",
  "-- lot writing dropped")

m("a committed row still reads as a preview",
  "import_opening_stock",
  "                    then jsonb_set(x, '{status}', '\"imported\"')",
  "                    then x  -- imported status dropped",
  "-- imported status dropped")

m("draft journals count towards what the ledger says",
  "import_opening_stock",
  "     and e.status = 'posted' and e.entry_date <= p_as_at;",
  "     and e.entry_date <= p_as_at;  -- posted filter dropped",
  "-- posted filter dropped")

m("journals after the opening date count towards the ledger",
  "import_opening_stock",
  "     and e.status = 'posted' and e.entry_date <= p_as_at;",
  "     and e.status = 'posted';  -- as-at filter dropped",
  "-- as-at filter dropped")

m("every account counts towards the ledger, not just inventory",
  "import_opening_stock",
  "   where l.org_id = p_org_id and a.account_subtype = 'inventory'",
  "   where l.org_id = p_org_id  -- inventory filter dropped",
  "-- inventory filter dropped")

m("agreement and disagreement with the ledger are reported the wrong way",
  "import_opening_stock",
  "      'status', case when round(v_value - v_ledger, 2) = 0\n"
  "                     then 'ok' else 'warning' end,",
  "      'status', case when round(v_value - v_ledger, 2) = 0\n"
  "                     then 'warning' else 'ok' end,  -- verdict inverted",
  "-- verdict inverted")

m("CONTROL -- a comment inside the function block",
  "import_opening_stock",
  "    v_problem := null;\n    v_kind := 'ok';",
  "    v_problem := null;\n    v_kind := 'ok';"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")

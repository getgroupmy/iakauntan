# Mutants for public.post_stock_adjustment -- a stocktake's difference
# turned into stock movements and a journal.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0087_stock_adjustments.sql \
#       supabase/tests/stock_adjustments.sql \
#       supabase/tests/mutants/post_stock_adjustment.py
#
# and again against `supabase/tests/lot_allocation_shapes.sql`, the other
# file that reaches it.
#
# RESULT, 5 October: 22 mutants, EIGHTEEN killed on the first run --
# the second-best score measured -- and four survived. 21 of 22 now,
# the last being proven EQUIVALENT rather than closed.
# `lot_allocation_shapes.sql`, the other file reaching it, killed
# nothing `stock_adjustments.sql` had not already killed.
#
# THE THREE GAPS:
#   1. no 5900 and no account named on the count
#   2. no 1310 and no account on the item
#   3. a worthless line writing a journal line of two zeroes
#
# The third is the one worth reading twice. `if v_cost = 0 then
# continue` skips a line whose stock is worth nothing, and nothing in
# `app.create_gl_entry_internal` drops a line of two zeroes -- so
# without that `continue` the journal gains a row of `debit 0, credit
# 0`: an entry in the ledger recording no money. It BALANCES, so no
# balance assertion sees it, and every figure asserted elsewhere stays
# right. Only COUNTING the journal's lines catches it. That is the
# clearest case yet of a defect that is invisible to every assertion
# about values and visible to one about shape.
#
# THE EQUIVALENT, proven rather than argued: reversing
# `order by created_at desc` on the read-back changes nothing, because
# `source_line_id` is per LINE, this function inserts exactly one
# movement per line, it is the ONLY function in the repository that
# writes a `stock_adjustments`-sourced movement (checked, not assumed),
# and a second post is refused. One matching row, so the ordering
# orders nothing.
#
# Three things make this one worth a careful set:
#
#   * the UNIT COST falls back twice -- `nullif(unit_cost, 0)`, then the
#     item's `average_cost`, then zero. Each step gets a mutant, because
#     a fixture that always types a unit cost cannot tell them apart.
#   * the DIRECTION is derived twice from one number: `difference > 0`
#     picks the movement type, and `v_cost > 0` picks which side of the
#     journal. Swapping either is symmetric on the balance and only an
#     assertion naming an account catches it.
#   * the WAREHOUSE is taken from the adjustment and never resolved. The
#     function's own comment says why -- "a posting function that
#     silently picks a warehouse is a posting function that moves stock
#     somewhere nobody asked for" -- so the mutant makes it pick one,
#     which is the behaviour the comment forbids.
#
# The `order by created_at desc limit 1` read-back is included on
# purpose and is EXPECTED to be equivalent: `source_line_id` is per
# LINE, so the predicate matches exactly one row and the ordering has
# nothing to order. Included rather than assumed, because the same
# shape in `app.pos_deplete_recipes` looked identical and needed the
# `group by` to prove it.

m("anybody may post a stocktake",
  "post_stock_adjustment",
  "  if not app.can_post(v_adj.org_id) then",
  "  if not app.can_post(v_adj.org_id) and false then  -- can_post dropped",
  "-- can_post dropped")

m("an already-posted adjustment is posted again",
  "post_stock_adjustment",
  "  if v_adj.gl_entry_id is not null then",
  "  if false then  -- repost guard dropped",
  "-- repost guard dropped")

m("the stock moves to the DEFAULT warehouse, not the one chosen",
  "post_stock_adjustment",
  "  v_wh := v_adj.warehouse_id;",
  "  v_wh := app.default_warehouse(v_adj.org_id);  -- warehouse resolved",
  "-- warehouse resolved")

m("the account named on the adjustment is ignored for 5900",
  "post_stock_adjustment",
  "  v_adj_acct := coalesce(v_adj.account_id,",
  "  v_adj_acct := coalesce(null::uuid,  -- named account ignored",
  "-- named account ignored")

m("a company with no 5900 and no named account posts anyway",
  "post_stock_adjustment",
  "  if v_adj_acct is null then\n    raise exception\n"
  "      'No inventory adjustment account (5900)",
  "  if false then  -- 5900 guard dropped\n    raise exception\n"
  "      'No inventory adjustment account (5900)",
  "-- 5900 guard dropped")

m("the difference is counted the wrong way round",
  "post_stock_adjustment",
  "           round(coalesce(l.counted_quantity, 0)\n"
  "                 - coalesce(l.system_quantity, 0), 4) as difference,",
  "           round(coalesce(l.system_quantity, 0)\n"
  "                 - coalesce(l.counted_quantity, 0), 4) as difference,"
  "  -- difference inverted",
  "-- difference inverted")

m("a typed unit cost of zero is used instead of the average cost",
  "post_stock_adjustment",
  "           coalesce(nullif(l.unit_cost, 0), i.average_cost, 0) as unit_cost,",
  "           coalesce(l.unit_cost, i.average_cost, 0) as unit_cost,"
  "  -- nullif dropped",
  "-- nullif dropped")

m("the item's average cost is not the fallback",
  "post_stock_adjustment",
  "           coalesce(nullif(l.unit_cost, 0), i.average_cost, 0) as unit_cost,",
  "           coalesce(nullif(l.unit_cost, 0), 0) as unit_cost,"
  "  -- average_cost dropped",
  "-- average_cost dropped")

m("the item's own inventory account is ignored for the chart's 1310",
  "post_stock_adjustment",
  "           coalesce(i.inventory_account_id,\n"
  "             (select id from public.accounts\n"
  "               where org_id = v_adj.org_id and code = '1310'))"
  " as inventory_account,",
  "           coalesce(null::uuid,\n"
  "             (select id from public.accounts\n"
  "               where org_id = v_adj.org_id and code = '1310'))"
  " as inventory_account,  -- item account ignored",
  "-- item account ignored")

m("the lines that DO differ are the ones skipped",
  "post_stock_adjustment",
  "    if r.difference = 0 then continue; end if;",
  "    if r.difference <> 0 then continue; end if;  -- skip inverted",
  "-- skip inverted")

m("an item that does not track inventory is adjusted anyway",
  "post_stock_adjustment",
  "    if not r.track_inventory then",
  "    if not r.track_inventory and false then  -- tracking guard dropped",
  "-- tracking guard dropped")

m("a company with no 1310 and an item naming none posts anyway",
  "post_stock_adjustment",
  "    if r.inventory_account is null then",
  "    if false then  -- 1310 guard dropped",
  "-- 1310 guard dropped")

m("a shortfall is recorded as stock coming IN",
  "post_stock_adjustment",
  "      case when r.difference > 0 then 'adjustment_in' else 'adjustment_out' end",
  "      case when r.difference > 0 then 'adjustment_out' else 'adjustment_in' end"
  "  -- movement type swapped",
  "-- movement type swapped")

m("the read-back takes the OLDEST movement for the line",
  "post_stock_adjustment",
  "     order by created_at desc limit 1;",
  "     order by created_at asc limit 1;  -- read-back reversed",
  "-- read-back reversed")

m("the read-back is not scoped to this line",
  "post_stock_adjustment",
  "     where source_line_id = r.id and source_table = 'stock_adjustments'",
  "     where source_table = 'stock_adjustments'  -- line scope dropped",
  "-- line scope dropped")

m("a worthless line still writes a journal line",
  "post_stock_adjustment",
  "    if v_cost = 0 then continue; end if;",
  "    if false then continue; end if;  -- zero-cost skip dropped",
  "-- zero-cost skip dropped")

m("inventory is credited for a gain and debited for a loss",
  "post_stock_adjustment",
  "    if v_cost > 0 then",
  "    if v_cost < 0 then  -- inventory side swapped",
  "-- inventory side swapped")

m("the adjustment account takes the wrong side",
  "post_stock_adjustment",
  "    'debit', case when v_total < 0 then -v_total else 0 end,\n"
  "    'credit', case when v_total > 0 then v_total else 0 end,",
  "    'debit', case when v_total > 0 then v_total else 0 end,\n"
  "    'credit', case when v_total < 0 then -v_total else 0 end,"
  "  -- adjustment side swapped",
  "-- adjustment side swapped")

m("the running total subtracts what it should add",
  "post_stock_adjustment",
  "    v_total := v_total + v_cost;",
  "    v_total := v_total - v_cost;  -- total sign flipped",
  "-- total sign flipped")

m("an adjustment that changes nothing posts an empty journal",
  "post_stock_adjustment",
  "  if v_total = 0 then",
  "  if false then  -- nothing-to-adjust guard dropped",
  "-- nothing-to-adjust guard dropped")

m("the movements are never linked to the journal",
  "post_stock_adjustment",
  "  update public.stock_movements set gl_entry_id = v_entry_id\n"
  "   where source_table = 'stock_adjustments' and source_id = p_id;",
  "  update public.stock_movements set gl_entry_id = null  -- link dropped\n"
  "   where source_table = 'stock_adjustments' and source_id = p_id;",
  "-- link dropped")

m("the adjustment is left unposted",
  "post_stock_adjustment",
  "     set gl_entry_id = v_entry_id, status = 'posted', posted_at = now(),",
  "     set gl_entry_id = v_entry_id, status = 'draft', posted_at = now(),"
  "  -- status not advanced",
  "-- status not advanced")

m("CONTROL -- a comment inside the function block",
  "post_stock_adjustment",
  "  v_wh := v_adj.warehouse_id;",
  "  v_wh := v_adj.warehouse_id;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")

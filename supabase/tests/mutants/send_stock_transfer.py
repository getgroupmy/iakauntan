# Mutants for public.send_stock_transfer -- stock leaving one store for
# another, and sitting in transit until it arrives.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0267_the_batch_that_went_in_the_van.sql \
#       supabase/tests/stock_transfers.sql \
#       supabase/tests/mutants/send_stock_transfer.py
#
# then again against `lot_allocation_shapes.sql` and
# `lots_across_the_new_sources.sql`, the other two files that reach it.
# Three files is the most of any function in this sweep, which on the
# record so far cuts both ways: `record_group_payment` had three and no
# gaps, while `post_goods_received_internal` had two and twelve.
#
# RESULT, 5 October: 23 mutants, NINETEEN killed on the first run and
# four survived. Across all three files 23 of 23 are killed; nothing is
# equivalent.
#
#   stock_transfers.sql            kills 19, then 22
#   lot_allocation_shapes.sql      kills 7
#   lots_across_the_new_sources.sql kills 7
#
# Four survivors in one file against THREE in the union, and the
# difference is instructive rather than arithmetic: both lot files
# transfer BATCH-TRACKED items, so they reach the `app.lot_available`
# check that `stock_transfers.sql`'s untracked items skip entirely. The
# mutant that points that check at the DESTINATION warehouse is killed
# only there, and still is -- the fixture here was deliberately NOT
# given a tracked item for it, because two files already own that case
# and a third copy would be upkeep without cover.
#
# THE THREE GAPS, all closed in stock_transfers.sql:
#
#   1. `< v_qty` on the stock check, mutated to `<=`. Sending a store's
#      ENTIRE holding is the ordinary last transfer of a line, and no
#      fixture emptied a store completely -- every one left a remainder,
#      so "not enough" and "exactly enough" were never distinguished.
#      The cheapest possible gap to leave open, and the easiest to miss:
#      an off-by-one on a boundary nobody's fixture stood on.
#   2. the 1310 guard, which no company in the suite was without.
#   3. the movement-to-journal link, which nothing asserted at all.
#
# Four shapes here are worth attacking separately:
#
#   * TWO quantities and one variable. `v_qty` holds the converted
#     quantity for the stock check and the movement, and is then
#     REASSIGNED to `-sm.total_cost` for the journal. A mutant that
#     drops the negation changes the journal and nothing else.
#   * TWO warehouses. Everything leaves `from_warehouse_id`; taking it
#     out of the destination instead is a mutation no balance assertion
#     sees, because the journal is the same either way.
#   * TWO stock checks, with different reasons: `allow_negative_stock`
#     guards the quantity, and `app.lot_available` guards the BATCHES.
#     An item with no tracking skips the second entirely, so a fixture
#     of untracked items cannot see it.
#   * the UOM conversion, applied twice -- once for the movement and
#     once for `sent_quantity` on the line. Each gets its own mutant,
#     because a fixture whose selling unit is its stocking unit cannot
#     tell either from the raw quantity.

m("anybody may send a transfer",
  "send_stock_transfer",
  "  if not app.can_write_module(v_t.org_id, 'inventory') then",
  "  if not app.can_write_module(v_t.org_id, 'inventory') and false then"
  "  -- can_write dropped",
  "-- can_write dropped")

m("a transfer already sent is sent again",
  "send_stock_transfer",
  "  if v_t.status <> 'draft' then",
  "  if false then  -- resend guard dropped",
  "-- resend guard dropped")

m("an empty transfer is sent",
  "send_stock_transfer",
  "  if not exists (select 1 from public.stock_transfer_lines l\n"
  "                  where l.transfer_id = p_id) then",
  "  if false then  -- empty guard dropped",
  "-- empty guard dropped")

m("negative stock is always allowed, whatever the company said",
  "send_stock_transfer",
  "  v_neg := coalesce(v_neg, false);",
  "  v_neg := true;  -- negative stock forced on",
  "-- negative stock forced on")

m("the company's setting is ignored and negative stock refused",
  "send_stock_transfer",
  "  v_neg := coalesce(v_neg, false);",
  "  v_neg := false;  -- setting ignored",
  "-- setting ignored")

m("the quantity is not converted into the stocking unit",
  "send_stock_transfer",
  "    v_qty := round(app.uom_qty(v_line.item_id, v_line.quantity,"
  " v_line.uom_code), 6);",
  "    v_qty := round(v_line.quantity, 6);  -- conversion dropped",
  "-- conversion dropped")

m("sending exactly what the store holds is refused",
  "send_stock_transfer",
  "                      and sl.warehouse_id = v_t.from_warehouse_id), 0)"
  " < v_qty then",
  "                      and sl.warehouse_id = v_t.from_warehouse_id), 0)"
  " <= v_qty then  -- exact stock refused",
  "-- exact stock refused")

m("the stock check reads the DESTINATION store",
  "send_stock_transfer",
  "                      and sl.warehouse_id = v_t.from_warehouse_id), 0)"
  " < v_qty then",
  "                      and sl.warehouse_id = v_t.to_warehouse_id), 0)"
  " < v_qty then  -- stock check reads the wrong store",
  "-- stock check reads the wrong store")

m("the batch check is skipped",
  "send_stock_transfer",
  "    if v_line.tracking is not null and v_line.tracking <> 'none'\n"
  "       and app.lot_available(v_line.item_id, v_t.from_warehouse_id)"
  " < v_qty then",
  "    if false then  -- batch check dropped",
  "-- batch check dropped")

m("the batch check reads the DESTINATION store",
  "send_stock_transfer",
  "       and app.lot_available(v_line.item_id, v_t.from_warehouse_id)"
  " < v_qty then",
  "       and app.lot_available(v_line.item_id, v_t.to_warehouse_id)"
  " < v_qty then  -- batch check reads the wrong store",
  "-- batch check reads the wrong store")

m("the stock LEAVES the destination store",
  "send_stock_transfer",
  "      v_t.from_warehouse_id, -v_qty, 0,",
  "      v_t.to_warehouse_id, -v_qty, 0,  -- movement on the wrong store",
  "-- movement on the wrong store")

m("the movement ADDS stock to the store it is leaving",
  "send_stock_transfer",
  "      v_t.from_warehouse_id, -v_qty, 0,",
  "      v_t.from_warehouse_id, v_qty, 0,  -- movement sign flipped",
  "-- movement sign flipped")

m("the journal total takes the cost without negating it",
  "send_stock_transfer",
  "    select sm.unit_cost, -sm.total_cost into v_cost, v_qty",
  "    select sm.unit_cost, sm.total_cost into v_cost, v_qty"
  "  -- cost negation dropped",
  "-- cost negation dropped")

m("the sent quantity is recorded in the unit that was typed",
  "send_stock_transfer",
  "       set sent_quantity  = round(\n"
  "             app.uom_qty(l.item_id, l.quantity, l.uom_code), 6),",
  "       set sent_quantity  = round(l.quantity, 6),  -- sent qty unconverted",
  "-- sent qty unconverted")

m("the sent unit cost is not recorded",
  "send_stock_transfer",
  "           sent_unit_cost = v_cost",
  "           sent_unit_cost = 0  -- sent cost dropped",
  "-- sent cost dropped")

m("the journal is written only when nothing moved",
  "send_stock_transfer",
  "  if round(v_total, 2) <> 0 then",
  "  if round(v_total, 2) = 0 then  -- journal condition inverted",
  "-- journal condition inverted")

m("a company with no 1310 sends anyway",
  "send_stock_transfer",
  "    if v_inv is null then\n      raise exception 'No inventory account"
  " (1310) in the chart.'",
  "    if false then  -- 1310 guard dropped\n      raise exception"
  " 'No inventory account (1310) in the chart.'",
  "-- 1310 guard dropped")

m("both legs of the journal go to goods in transit",
  "send_stock_transfer",
  "      jsonb_build_object('account_id', v_inv,\n"
  "        'description', 'Sent ' || v_t.transfer_no,",
  "      jsonb_build_object('account_id', v_transit,\n"
  "        'description', 'Sent ' || v_t.transfer_no,  -- inventory leg"
  " retargeted",
  "-- inventory leg retargeted")

m("inventory is debited and goods in transit credited",
  "send_stock_transfer",
  "      jsonb_build_object('account_id', v_transit,\n"
  "        'description', 'In transit ' || v_t.transfer_no,\n"
  "        'debit', round(v_total, 2), 'credit', 0),",
  "      jsonb_build_object('account_id', v_transit,\n"
  "        'description', 'In transit ' || v_t.transfer_no,\n"
  "        'debit', 0, 'credit', round(v_total, 2)),  -- transit side swapped",
  "-- transit side swapped")

m("the movements are not linked to the journal",
  "send_stock_transfer",
  "    update public.stock_movements sm set gl_entry_id = v_entry",
  "    update public.stock_movements sm set gl_entry_id = null"
  "  -- link dropped",
  "-- link dropped")

m("the transfer is left in draft",
  "send_stock_transfer",
  "     set status = 'sent', sent_at = now(), sent_by = auth.uid(),",
  "     set status = 'draft', sent_at = now(), sent_by = auth.uid(),"
  "  -- status not advanced",
  "-- status not advanced")

m("the transfer does not remember the journal it was sent with",
  "send_stock_transfer",
  "         send_entry_id = v_entry, updated_at = now()",
  "         send_entry_id = null, updated_at = now()  -- entry not recorded",
  "-- entry not recorded")

m("CONTROL -- a comment inside the function block",
  "send_stock_transfer",
  "  v_neg := coalesce(v_neg, false);",
  "  v_neg := coalesce(v_neg, false);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")

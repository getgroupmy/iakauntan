# Mutants for public.run_item_conversion (0422; the idempotency wrapper
# in 0738 calls it) -- one item cut into others: by somebody who may
# write inventory, an active conversion, a number of times more than
# none, in the store given or the default one; never more than the store
# holds unless negative stock is allowed, nor more than its batches; out
# at cost, in at each output's share of that cost.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0422_what_day_the_work_was_done.sql \
#       supabase/tests/stock_transfers.sql \
#       supabase/tests/mutants/run_item_conversion.py
#
# RESULT: 16 mutants and a control, all killed by `stock_transfers.sql`.
# Eight only after its rule-by-rule block: the conversion that does not
# exist, who may, no times, the default store (a second store made first,
# or "the default" and "any store" were one row), a company with no store,
# the exact amount the store holds, negative stock allowed, and more than
# the batches hold -- reached by switching tracking on after the stock
# arrived, since batch-tracked stock cannot arrive without a batch.

m("a conversion that does not exist is not said so",
  "run_item_conversion",
  "  if v_c.id is null then\n    raise exception 'No such conversion.'",
  "  if false then  -- no such conversion\n    raise exception 'No such conversion.'",
  "-- no such conversion")

m("anybody runs a conversion",
  "run_item_conversion",
  "  if not app.can_write_module(v_c.org_id, 'inventory') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a switched-off conversion runs",
  "run_item_conversion",
  "  if not v_c.is_active then",
  "  if false then  -- switched off runs",
  "-- switched off runs")

m("a conversion is run no times",
  "run_item_conversion",
  "  if coalesce(p_times, 0) <= 0 then",
  "  if coalesce(p_times, 0) < 0 then  -- zero times",
  "-- zero times")

m("any store is the default",
  "run_item_conversion",
  "                     where w.org_id = v_c.org_id and w.is_default limit 1));",
  "                     where w.org_id = v_c.org_id limit 1));  -- any store",
  "-- any store")

m("a company with no store is not said so",
  "run_item_conversion",
  "  if v_wh is null then\n    raise exception 'This company has no store to do it in.'",
  "  if false then  -- no store\n    raise exception 'This company has no store to do it in.'",
  "-- no store")

m("the times are ignored",
  "run_item_conversion",
  "      * p_times, 6);\n\n  select coalesce(ps.allow_negative_stock",
  "      * 1, 6);  -- once\n\n  select coalesce(ps.allow_negative_stock",
  "-- once")

m("exactly what the store holds is not enough",
  "run_item_conversion",
  "                    and sl.warehouse_id = v_wh), 0) < v_qty then",
  "                    and sl.warehouse_id = v_wh), 0) <= v_qty then  -- exact refused",
  "-- exact refused")

m("more than the store holds is cut up",
  "run_item_conversion",
  "  if not coalesce(v_neg, false) then",
  "  if false then  -- never short",
  "-- never short")

m("negative stock allowed is ignored",
  "run_item_conversion",
  "  if not coalesce(v_neg, false) then",
  "  if true then  -- always checked",
  "-- always checked")

m("more than the batches hold is cut up",
  "run_item_conversion",
  "     and app.lot_available(v_c.from_item_id, v_wh) < v_qty then",
  "     and false then  -- batches ignored",
  "-- batches ignored")

m("the item cut up does not leave the store",
  "run_item_conversion",
  "    app.today(), 'assembly_out', v_c.from_item_id, v_wh, -v_qty, 0,",
  "    app.today(), 'assembly_out', v_c.from_item_id, v_wh, 0, 0,  -- nothing out",
  "-- nothing out")

m("each output is the quantity for once, whatever the times",
  "run_item_conversion",
  "    v_oqty  := round(app.uom_qty(v_out.item_id, v_out.quantity, v_out.uom_code)\n                       * p_times, 6);",
  "    v_oqty  := round(app.uom_qty(v_out.item_id, v_out.quantity, v_out.uom_code), 6);  -- outputs once",
  "-- outputs once")

m("each output takes the whole cost",
  "run_item_conversion",
  "    v_share := round(v_value * v_out.cost_share / 100.0, 2);",
  "    v_share := round(v_value, 2);  -- whole cost",
  "-- whole cost")

m("each output comes in at nothing",
  "run_item_conversion",
  "      case when v_oqty = 0 then 0 else round(v_share / v_oqty, 6) end,",
  "      0,  -- free",
  "-- free")

m("the value answered is nothing",
  "run_item_conversion",
  "  return round(v_value, 2);",
  "  return 0;  -- answers nothing",
  "-- answers nothing")

m("CONTROL: a comment inside the block",
  "run_item_conversion",
  "  if not v_c.is_active then",
  "  if not v_c.is_active then  -- (control)",
  "(control)")

-- =====================================================================
-- iAkauntan :: the shelf is worth nothing when the last one leaves
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/stock_value_returns_to_zero.sql
--
-- `app.apply_stock_movement` values stock at a moving weighted average
-- and carries one guard:
--
--     -- Guard against a negative valuation when stock runs to zero.
--     if v_new_qty = 0 then
--       v_new_value := 0;
--
-- That line is doing something quietly load-bearing. It *forces* the
-- value to zero, so if the movements did not already net to zero the
-- difference vanishes -- off the balance sheet, with nothing posted
-- anywhere and nothing said. Inventory and the 1310 control account
-- would drift apart by that much, permanently, and the only way anyone
-- would find it is a stock count.
--
-- Measured before this file was written: it never has to discard
-- anything, and the reason is `average_cost numeric(18, 6)`. Seven
-- units bought for 41.07 average 5.867143; seven of those cost
-- 41.070001, which rounds back to 41.07 exactly. At two decimals the
-- average would be 5.87, seven of them 41.09, and the guard would
-- silently swallow two sen on one small item.
--
-- So what is pinned here is the precision, not the guard. A change of
-- `average_cost` to `numeric(18, 2)` -- which looks like tidying a
-- money column, and which nothing else in the schema would object to --
-- is caught by this file and by nothing else.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.move(
  p_org uuid, p_item uuid, p_wh uuid, p_type text, p_qty numeric,
  p_cost numeric, p_no text)
returns void language plpgsql as $$
begin
  insert into public.stock_movements
    (org_id, item_id, warehouse_id, movement_type, movement_date,
     quantity, unit_cost, movement_no)
  values (p_org, p_item, p_wh, p_type::app.stock_movement_type,
          current_date, p_qty, p_cost, p_no);
end $$;

do $$
declare
  v_org  uuid;
  v_wh   uuid;
  v_item uuid;
  s      record;
  v_sum  numeric;
begin
  v_org := pg_temp.test_org('Kos Purata Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'W', 'Widget', 'stock', true, 'C62', 10.00, 3.00)
  returning id into v_item;

  -- ------------------------------------------------------------------
  -- An average that does not divide evenly
  -- ------------------------------------------------------------------
  -- 3 at 3.33 and 4 at 7.77 is 41.07 over seven units. The average is
  -- 5.867142857..., which is exactly the shape that loses money to a
  -- two-decimal rounding.
  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 3, 3.33, 'R1');
  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 4, 7.77, 'R2');

  select * into s from public.stock_levels where item_id = v_item;
  perform pg_temp.check_eq('seven units on the shelf', s.quantity, 7);
  perform pg_temp.check_eq('worth what was paid for them', s.value, 41.07);
  perform pg_temp.check_true('at an average that needs more than two decimals',
    s.average_cost <> round(s.average_cost, 2));

  -- ------------------------------------------------------------------
  -- Sell every one of them
  -- ------------------------------------------------------------------
  perform pg_temp.move(v_org, v_item, v_wh, 'sales_delivery', -7, 0, 'S1');

  select * into s from public.stock_levels where item_id = v_item;
  perform pg_temp.check_eq('the shelf is empty', s.quantity, 0);
  perform pg_temp.check_eq('and worth nothing', s.value, 0);

  -- The assertion the file exists for. The movements are what the
  -- ledger is told; if they do not net to zero, the guard above
  -- swallowed the difference and inventory has drifted from 1310.
  select round(sum(total_cost), 2) into v_sum
    from public.stock_movements where item_id = v_item;
  perform pg_temp.check_eq(
    'and what went out is exactly what came in, so the guard discarded '
    'nothing', v_sum, 0);

  -- ------------------------------------------------------------------
  -- The same again, sold in two goes
  -- ------------------------------------------------------------------
  -- One movement can be exact by luck. Two roundings against the same
  -- six-decimal average is the ordinary case and the harder one.
  delete from public.stock_movements where item_id = v_item;
  update public.stock_levels
     set quantity = 0, value = 0, average_cost = 0 where item_id = v_item;

  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 3, 3.33, 'R3');
  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 4, 7.77, 'R4');
  perform pg_temp.move(v_org, v_item, v_wh, 'sales_delivery', -4, 0, 'S2');
  perform pg_temp.move(v_org, v_item, v_wh, 'sales_delivery', -3, 0, 'S3');

  select * into s from public.stock_levels where item_id = v_item;
  select round(sum(total_cost), 2) into v_sum
    from public.stock_movements where item_id = v_item;
  perform pg_temp.check_eq('emptied in two sales as well', s.quantity, 0);
  perform pg_temp.check_eq('worth nothing', s.value, 0);
  perform pg_temp.check_eq('and still nothing discarded', v_sum, 0);

  -- ------------------------------------------------------------------
  -- What negative stock does, stated rather than assumed
  -- ------------------------------------------------------------------
  -- Nothing refuses a sale of stock that is not there -- there is no
  -- check constraint on `stock_levels.quantity` and no guard in the
  -- trigger. This is not asserting that permitting it is right; it is
  -- writing down what happens, because the behaviour is invisible
  -- otherwise and somebody will meet it.
  delete from public.stock_movements where item_id = v_item;
  update public.stock_levels
     set quantity = 0, value = 0, average_cost = 0 where item_id = v_item;

  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 2, 5.00, 'R5');
  perform pg_temp.move(v_org, v_item, v_wh, 'sales_delivery', -4, 0, 'S4');

  select * into s from public.stock_levels where item_id = v_item;
  perform pg_temp.check_eq('two units short is allowed', s.quantity, -2);
  perform pg_temp.check_eq(
    'and carried at minus the average, not at nothing', s.value, -10.00);

  -- Replacing them at a different price blends, as a moving average
  -- does. The eight units left are physically all 4.00 stock and are
  -- carried at 30.00 rather than 32.00: the two sold short went to
  -- cost of sales at 5.00 and were replaced at 4.00, and the two
  -- ringgit difference stays in the valuation instead of being posted
  -- as a variance. That is the known cost of moving average over a
  -- negative balance, and it is written here so it is a decision
  -- somebody made rather than a surprise.
  perform pg_temp.move(v_org, v_item, v_wh, 'purchase_receipt', 10, 4.00, 'R6');
  select * into s from public.stock_levels where item_id = v_item;
  perform pg_temp.check_eq('eight on the shelf after replacing them',
    s.quantity, 8);
  perform pg_temp.check_eq('carried at 30.00, not the 32.00 they cost',
    s.value, 30.00);
end $$;

rollback;

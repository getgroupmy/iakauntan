-- =====================================================================
-- Inventory forecasting :: the arithmetic
--
-- Every number here is one a buyer is asked to act on with money, so
-- every one is checked against a worked example rather than against
-- whatever the code currently returns.
--
-- Two properties get their own assertions because they are the errors
-- that look right:
--
--   * safety stock scales with the SQUARE ROOT of lead time, not lead
--     time. Quadrupling the lead time doubles the buffer. Getting this
--     wrong overstates stock by that root and nothing about the output
--     looks wrong.
--
--   * empty periods are demand of zero, not absent observations.
--     Dropping them raises the mean and collapses the variance, and it
--     collapses it hardest for the intermittent items whose buffer
--     matters most.
-- =====================================================================
\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_item     uuid;
  v_wh       uuid;
  v_n        integer;
  v_z        numeric;
  v_a        numeric;
  v_b        numeric;
  v_fc       numeric[];
  v_series   numeric[];
begin
  -- ------------------------------------------------------------------
  -- The normal quantile
  -- ------------------------------------------------------------------
  -- Six decimal places against published values, across all three
  -- branches of the approximation: the lower tail, the central region
  -- and the upper tail. A transcription slip in any one coefficient
  -- moves at least one of these.
  v_n := 0;
  for v_a, v_b in
    select * from (values
      (0.0100::numeric, -2.326348::numeric),
      (0.5000::numeric,  0.000000::numeric),
      (0.9000::numeric,  1.281552::numeric),
      (0.9500::numeric,  1.644854::numeric),
      (0.9750::numeric,  1.959964::numeric),
      (0.9900::numeric,  2.326348::numeric),
      (0.9990::numeric,  3.090232::numeric)) as t(p, z)
  loop
    perform pg_temp.check_eq(
      format('normal_z(%s)', v_a), round(app.normal_z(v_a), 6), v_b);
    v_n := v_n + 1;
  end loop;
  -- The control. A loop that compared nothing would report seven
  -- successes just as quietly.
  perform pg_temp.check_eq('quantiles actually compared', v_n, 7);

  -- Outside (0,1) there is no finite answer, and an infinite safety
  -- stock is not something anybody can order.
  begin
    perform app.normal_z(1.0);
    raise exception 'FAIL normal_z(1) should have been refused';
  exception when numeric_value_out_of_range then
    raise notice 'ok   normal_z refuses 1';
  end;

  -- ------------------------------------------------------------------
  -- Safety stock
  -- ------------------------------------------------------------------
  -- z(0.95) = 1.644854, sigma 2/day, lead time 9 days.
  --   1.644854 * 2 * sqrt(9) = 1.644854 * 2 * 3 = 9.869124
  perform pg_temp.check_eq('safety stock at 95% over nine days',
    app.safety_stock(0.95, 2, 9), 9.8691);

  -- The square root, asserted as a relationship rather than a value:
  -- four times the lead time is twice the buffer. If the implementation
  -- used L instead of sqrt(L) this ratio would be 4, and every
  -- individual number would still look plausible.
  v_a := app.safety_stock(0.95, 2, 4);
  v_b := app.safety_stock(0.95, 2, 16);
  perform pg_temp.check_eq(
    'quadrupling lead time doubles safety stock, it does not quadruple it',
    round(v_b / v_a, 6), 2.000000);

  -- Nothing varies, nothing is buffered.
  perform pg_temp.check_eq('no variability needs no buffer',
    app.safety_stock(0.95, 0, 30), 0);

  -- ------------------------------------------------------------------
  -- Reorder point
  -- ------------------------------------------------------------------
  -- 5/day over 9 days, plus the buffer above: 45 + 9.8691
  perform pg_temp.check_eq('reorder point is lead demand plus buffer',
    app.reorder_point(5, 9, 9.8691), 54.8691);

  -- ------------------------------------------------------------------
  -- Moving average
  -- ------------------------------------------------------------------
  -- Last two of [2,4,6,8] average 7, and the horizon is flat.
  v_fc := app.forecast_moving_average(array[2,4,6,8]::numeric[], 2, 3);
  perform pg_temp.check_eq('moving average takes the window',   v_fc[1], 7);
  perform pg_temp.check_eq('and is flat across the horizon',    v_fc[3], 7);
  perform pg_temp.check_eq('one element per horizon bucket',
    array_length(v_fc, 1), 3);

  -- A window longer than the history averages what there is rather than
  -- failing: somebody asking for four periods of a three period item is
  -- not making a mistake.
  perform pg_temp.check_eq('a window longer than the history uses all of it',
    (app.forecast_moving_average(array[2,4]::numeric[], 5, 1))[1], 3);

  -- ------------------------------------------------------------------
  -- Exponential smoothing
  -- ------------------------------------------------------------------
  -- Seeded at the first observation, alpha 0.5:
  --   level = 10
  --   level = 0.5*20 + 0.5*10 = 15
  --   level = 0.5*30 + 0.5*15 = 22.5
  perform pg_temp.check_eq('exponential smoothing weights the recent',
    (app.forecast_exponential_smoothing(array[10,20,30]::numeric[], 0.5, 1))[1],
    22.5);

  -- A flat history smooths to itself whatever alpha is, which is the
  -- property that catches a seeding bug: seeded at zero this would
  -- climb toward 4 instead of sitting on it.
  perform pg_temp.check_eq('a flat history smooths to itself',
    (app.forecast_exponential_smoothing(array[4,4,4,4]::numeric[], 0.3, 1))[1], 4);

  -- ------------------------------------------------------------------
  -- Seasonal naive
  -- ------------------------------------------------------------------
  -- Season of 3 over [1,2,3,4,5,6]: the last season is [4,5,6] and a
  -- horizon of 4 wraps back to its start.
  v_fc := app.forecast_seasonal_naive(array[1,2,3,4,5,6]::numeric[], 3, 4);
  perform pg_temp.check_eq('seasonal naive repeats the last season (1)', v_fc[1], 4);
  perform pg_temp.check_eq('seasonal naive repeats the last season (3)', v_fc[3], 6);
  perform pg_temp.check_eq('and wraps when the horizon is longer',      v_fc[4], 4);

  -- Without a whole season it declines rather than repeating a
  -- fragment and calling it seasonality. The run falls back and records
  -- which method it actually used.
  perform pg_temp.check_true('seasonal naive refuses half a season',
    app.forecast_seasonal_naive(array[1,2]::numeric[], 4, 2) is null);

  -- ------------------------------------------------------------------
  -- Cover
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('cover is stock over daily demand',
    app.days_of_cover(100, 4), 25);
  perform pg_temp.check_true('an item nothing consumes has no stockout date',
    app.days_of_cover(100, 0) is null);
  perform pg_temp.check_eq('owing stock is no cover at all',
    app.days_of_cover(-5, 4), 0);

  -- ------------------------------------------------------------------
  -- What to order
  -- ------------------------------------------------------------------
  -- Target covers lead time AND review period: 5/day * (4 + 14) + 20
  -- = 110. Holding 10, so order 100.
  perform pg_temp.check_eq('order up to lead time plus review period',
    app.suggested_order_qty(10, 5, 4, 14, 20), 100);

  -- Cartons of 12: 100 rounds UP to 108. Rounding to nearest would give
  -- 96 and the order arrives short, which is the entire reason the
  -- supplier quoted a multiple.
  perform pg_temp.check_eq('an order multiple rounds up, never down',
    app.suggested_order_qty(10, 5, 4, 14, 20, null, null, null, 12), 108);

  -- A minimum can break the multiple, so the multiple is reapplied:
  -- 200 raised, then ceil(200/12)*12 = 204. Applying them the other way
  -- round returns 200, which the supplier will not ship.
  perform pg_temp.check_eq('a minimum that breaks the multiple is re-rounded',
    app.suggested_order_qty(10, 5, 4, 14, 20, null, null, 200, 12), 204);

  -- A ceiling the buyer set beats the model: target capped at 50,
  -- holding 10, so 40 rather than 100. This is how somebody stops the
  -- system ordering a year of something perishable.
  perform pg_temp.check_eq('a maximum caps the target',
    app.suggested_order_qty(10, 5, 4, 14, 20, null, 50), 40);

  -- Already covered: nothing, not a negative.
  perform pg_temp.check_eq('enough stock orders nothing',
    app.suggested_order_qty(500, 5, 4, 14, 20), 0);

  -- ------------------------------------------------------------------
  -- Buckets
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a week is seven days',  app.bucket_days('week'), 7);
  -- The average Gregorian month, not 30. Thirty drifts five days a year.
  perform pg_temp.check_eq('a month is 30.44 days', app.bucket_days('month'), 30.44);

  -- ------------------------------------------------------------------
  -- Demand, including the periods with none
  -- ------------------------------------------------------------------
  v_org := pg_temp.test_org('Forecast Fixture Sdn Bhd');

  -- The module has to be on for the guard inside demand_series.
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'forecasting', true)
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Main') returning id into v_wh;

  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'WIDGET', 'Widget', 'stock', true, 'C62')
  returning id into v_item;

  -- Two sales in week one, none in week two, one in week three.
  -- Outbound is stored negative, as the ledger does it.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id, warehouse_id, quantity)
  values
    (v_org, 'M1', 'sales_delivery', date '2026-01-05', v_item, v_wh, -2),
    (v_org, 'M2', 'sales_delivery', date '2026-01-07', v_item, v_wh, -4),
    (v_org, 'M3', 'sales_delivery', date '2026-01-19', v_item, v_wh, -3);

  select array_agg(qty order by period_start) into v_series
    from app.demand_series(v_org, v_item, null, 'week',
                           date '2026-01-05', date '2026-01-21', false, false);

  perform pg_temp.check_eq('three weeks come back, not two',
    array_length(v_series, 1), 3);
  perform pg_temp.check_eq('a week of sales is positive demand', v_series[1], 6);
  -- The assertion this whole module leans on.
  perform pg_temp.check_eq('a week with no sales is demand of zero',
    v_series[2], 0);
  perform pg_temp.check_eq('and the week after is itself again', v_series[3], 3);

  -- Which is what makes the mean 3 rather than 4.5.
  select avg(x) into v_a from unnest(v_series) x;
  perform pg_temp.check_eq(
    'the mean counts the quiet week, so it is 3 and not 4.5', v_a, 3);

  -- A return nets off without special handling, because it is stored
  -- with the opposite sign.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id, warehouse_id, quantity)
  values (v_org, 'M4', 'sales_return', date '2026-01-06', v_item, v_wh, 1);

  select array_agg(qty order by period_start) into v_series
    from app.demand_series(v_org, v_item, null, 'week',
                           date '2026-01-05', date '2026-01-11', false, false);
  perform pg_temp.check_eq('a return reduces the demand it came back from',
    v_series[1], 5);

  -- Shrinkage is not demand unless somebody says it is. An item that
  -- keeps being written off does not need more of itself ordered.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id, warehouse_id, quantity)
  values (v_org, 'M5', 'write_off', date '2026-01-06', v_item, v_wh, -10);

  select array_agg(qty order by period_start) into v_series
    from app.demand_series(v_org, v_item, null, 'week',
                           date '2026-01-05', date '2026-01-11', false, false);
  perform pg_temp.check_eq('a write-off is not demand by default', v_series[1], 5);

  select array_agg(qty order by period_start) into v_series
    from app.demand_series(v_org, v_item, null, 'week',
                           date '2026-01-05', date '2026-01-11', false, true);
  perform pg_temp.check_eq('and is demand when the company says so',
    v_series[1], 15);

  raise notice 'inventory forecasting: all assertions passed';
end;
$$;

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

-- =====================================================================
-- Inventory forecasting :: the suggestion becomes an order
--
-- The arithmetic above decides what to buy. This decides whether a
-- buyer can act on it without retyping, and the ways that goes wrong
-- all cost real money:
--
--   * ordering twice because the screen was submitted twice, or
--     because the forecast was re-run after the drafts were raised and
--     could not see them;
--   * an item quietly left out because nobody had set a supplier;
--   * a draft deleted and the suggestion never coming back, so the
--     stock is never ordered at all.
--
-- The fixture pins each item's target with min_quantity = max_quantity
-- so every suggested quantity is a number that can be checked by hand,
-- independently of which forecasting method ran.
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_wh2    uuid;
  v_sup_a  uuid;
  v_sup_b  uuid;
  v_bolt   uuid;
  v_nut    uuid;
  v_clamp  uuid;
  v_gasket uuid;
  v_orphan uuid;
  v_run    uuid;
  v_line   uuid;
  v_doc    uuid;
  v_n      integer;
  v_docs   integer;
  v_a      numeric;
  v_b      numeric;
  v_c      numeric;
  v_txt    text;
  v_outsider uuid;
begin
  v_org := pg_temp.test_org('Replenishment Fixture Sdn Bhd');

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['forecasting','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Main') returning id into v_wh;
  -- A second location, holding nothing. Its emptiness is the point: a
  -- branch with no stock and no history must answer for itself rather
  -- than borrow whatever was forecast last.
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'BR2', 'Branch') returning id into v_wh2;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-A', 'Ah Seng Fasteners', 'supplier') returning id into v_sup_a;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-B', 'Zenith Tooling', 'supplier') returning id into v_sup_b;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values
    (v_org, 'BOLT',  'Bolt',  'stock', true, 'C62', 10),
    (v_org, 'NUT',   'Nut',   'stock', true, 'C62', 5),
    (v_org, 'CLAMP', 'Clamp', 'stock', true, 'C62', 2.5),
    -- Deep stock and almost no demand: overstocked on every measure
    -- the model has, and still under the floor its buyer set.
    (v_org, 'GASKET', 'Gasket', 'stock', true, 'C62', 1.25),
    (v_org, 'SPARE', 'Spare', 'stock', true, 'C62', 1);

  select id into v_bolt   from public.items where org_id = v_org and code = 'BOLT';
  select id into v_nut    from public.items where org_id = v_org and code = 'NUT';
  select id into v_clamp  from public.items where org_id = v_org and code = 'CLAMP';
  select id into v_gasket from public.items where org_id = v_org and code = 'GASKET';
  select id into v_orphan from public.items where org_id = v_org and code = 'SPARE';

  -- Some demand, so the fixture is not forecasting silence — and the
  -- stock it was sold out of. Selling what was never bought in leaves
  -- the position negative, and the order-up-to would then cover the
  -- hole as well as the target: correct behaviour, but it would make
  -- every quantity below a number nobody could check by hand.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id, warehouse_id,
     quantity, unit_cost)
  values
    (v_org, 'R0', 'purchase_receipt', current_date - 30, v_bolt, v_wh, 12, 10),
    (v_org, 'R1', 'sales_delivery',   current_date - 20, v_bolt, v_wh, -5, 0),
    (v_org, 'R2', 'sales_delivery',   current_date - 12, v_bolt, v_wh, -7, 0),
    (v_org, 'R4', 'purchase_receipt', current_date - 30, v_nut,  v_wh, 3,  5),
    (v_org, 'R3', 'sales_delivery',   current_date - 4,  v_nut,  v_wh, -3, 0),
    (v_org, 'R5', 'purchase_receipt', current_date - 30, v_gasket, v_wh, 500, 1.25),
    (v_org, 'R6', 'sales_delivery',   current_date - 10, v_gasket, v_wh, -2, 0);

  -- Target pinned, so the suggestion is exactly the target: nothing is
  -- on hand, so ordering up to it is the whole quantity.
  insert into public.item_forecast_params
    (org_id, item_id, min_quantity, max_quantity, supplier_id)
  values
    (v_org, v_bolt,   100, 100, v_sup_a),
    (v_org, v_nut,     60,  60, v_sup_a),
    (v_org, v_clamp,   40,  40, v_sup_b),
    -- Deliberately no supplier: the item nobody can be asked to supply.
    (v_org, v_orphan,  25,  25, null);

  -- No ceiling on this one: the point is the floor, and 498 on hand
  -- against a floor of 600 leaves 102 to buy.
  insert into public.item_forecast_params
    (org_id, item_id, min_quantity, supplier_id)
  values (v_org, v_gasket, 600, v_sup_b);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods)
  values (v_org, 'week', 2, 84, 3)
  on conflict (org_id) do update set bucket = 'week';

  v_run := public.run_inventory_forecast(v_org);

  -- ------------------------------------------------------------------
  -- What the run says, before anything is ordered
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.forecast_suggestions(v_org);
  perform pg_temp.check_eq('five items are suggested', v_n, 5);

  select s.suggested_qty, s.already_drafted, s.outstanding, s.supplier_name
    into v_a, v_b, v_c, v_txt
    from public.forecast_suggestions(v_org) s where s.item_code = 'BOLT';
  perform pg_temp.check_eq('the pinned target is the suggestion', v_a, 100);
  perform pg_temp.check_eq('nothing is drafted yet', v_b, 0);
  perform pg_temp.check_eq('so all of it is outstanding', v_c, 100);
  perform pg_temp.check_true('and the supplier is named for the buyer',
    v_txt = 'Ah Seng Fasteners');

  -- ------------------------------------------------------------------
  -- One order per supplier
  -- ------------------------------------------------------------------
  -- ------------------------------------------------------------------
  -- A buyer's floor is a reason to order, whatever the cover says
  -- ------------------------------------------------------------------
  -- The gasket has years of stock by every measure the model has, and
  -- it is still under the minimum its buyer set. Before this was
  -- fixed the row read `overstocked` while the suggestion beside it
  -- said to buy a hundred, which reads as a bug in the arithmetic.
  select s.state::text, s.days_cover, s.suggested_qty into v_txt, v_a, v_b
    from public.forecast_suggestions(v_org) s where s.item_code = 'GASKET';
  -- The control: without this the state below could be right because
  -- the item is genuinely short, which is not what is being tested.
  perform pg_temp.check_true('the gasket really is deeply stocked', v_a > 1000);
  perform pg_temp.check_eq('and still 102 short of the floor its buyer set', v_b, 102);
  perform pg_temp.check_true('so it reads as something to order, not as overstock',
    v_txt = 'order_now');

  select count(*), count(*) filter (where r.document_id is not null)
    into v_n, v_docs
    from public.create_po_from_suggestions(v_org) r;
  perform pg_temp.check_eq('two suppliers, two orders, and one row that is not an order',
    v_n, 3);
  perform pg_temp.check_eq('two documents were raised', v_docs, 2);

  select d.id, count(l.*), sum(l.quantity), d.subtotal
    into v_doc, v_n, v_a, v_b
    from public.purchase_documents d
    join public.purchase_document_lines l on l.document_id = d.id
   where d.org_id = v_org and d.contact_id = v_sup_a
   group by d.id, d.subtotal;
  perform pg_temp.check_eq('both of one supplier''s items on one order', v_n, 2);
  perform pg_temp.check_eq('and the quantities are the suggestions', v_a, 160);
  -- 100 bolts at 10 plus 60 nuts at 5. The totals triggers did this,
  -- which is the point: the order is an ordinary purchase order.
  perform pg_temp.check_eq('priced from the item cost and totalled by the triggers',
    v_b, 1300);

  select d.status::text, count(l.*) filter (where l.forecast_line_id is not null)
    into v_txt, v_n
    from public.purchase_documents d
    join public.purchase_document_lines l on l.document_id = d.id
   where d.id = v_doc group by d.status;
  perform pg_temp.check_true('the order is a draft, not something sent to a supplier',
    v_txt = 'draft');
  perform pg_temp.check_eq('every line remembers the suggestion it came from', v_n, 2);

  -- The item with no supplier is reported rather than dropped.
  select r.line_count, r.total_quantity, r.note into v_n, v_a, v_txt
    from public.create_po_from_suggestions(v_org) r where r.document_id is null;
  perform pg_temp.check_eq('the unassigned item is counted', v_n, 1);
  perform pg_temp.check_eq('with its quantity', v_a, 25);
  perform pg_temp.check_true('and named, so somebody can fix it',
    v_txt like '%SPARE%');

  -- ------------------------------------------------------------------
  -- The double tap
  -- ------------------------------------------------------------------
  select s.already_drafted, s.outstanding into v_a, v_b
    from public.forecast_suggestions(v_org) s where s.item_code = 'BOLT';
  perform pg_temp.check_eq('the draft is netted off the suggestion', v_a, 100);
  perform pg_temp.check_eq('leaving nothing outstanding', v_b, 0);

  select count(*) filter (where r.document_id is not null) into v_docs
    from public.create_po_from_suggestions(v_org) r;
  perform pg_temp.check_eq('a second identical call raises no second order', v_docs, 0);

  -- ------------------------------------------------------------------
  -- A quantity given is a target, not an increment
  -- ------------------------------------------------------------------
  select s.line_id into v_line
    from public.forecast_suggestions(v_org) s where s.item_code = 'BOLT';

  select count(*) filter (where r.document_id is not null) into v_docs
    from public.create_po_from_suggestions(v_org,
      jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 100))) r;
  perform pg_temp.check_eq('asking again for the hundred already drafted orders nothing',
    v_docs, 0);

  select sum(r.total_quantity) filter (where r.document_id is not null) into v_a
    from public.create_po_from_suggestions(v_org,
      jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 130))) r;
  perform pg_temp.check_eq('asking for 130 when 100 is drafted orders the difference',
    v_a, 30);

  -- ------------------------------------------------------------------
  -- The two counters partition the live orders between them
  -- ------------------------------------------------------------------
  -- This is the claim the whole netting-off rests on. A draft counted
  -- by both would be subtracted twice and the item under-ordered; one
  -- counted by neither would be ordered twice.
  perform pg_temp.check_eq('a draft is not stock on the way',
    app.quantity_on_order(v_org, v_bolt, null), 0);
  perform pg_temp.check_eq('it is stock on a draft',
    app.quantity_on_draft_order(v_org, v_bolt, null), 130);

  update public.purchase_documents set status = 'pending'
   where org_id = v_org and contact_id = v_sup_a;

  perform pg_temp.check_eq('approving it moves the whole quantity across',
    app.quantity_on_order(v_org, v_bolt, null), 130);
  perform pg_temp.check_eq('and leaves nothing behind',
    app.quantity_on_draft_order(v_org, v_bolt, null), 0);

  -- ------------------------------------------------------------------
  -- Deleting a draft returns its suggestion
  -- ------------------------------------------------------------------
  -- Derived, not recorded. A flag written on the forecast line would
  -- still claim this stock was on order.
  select s.outstanding into v_a
    from public.forecast_suggestions(v_org) s where s.item_code = 'CLAMP';
  perform pg_temp.check_eq('the clamp is fully drafted', v_a, 0);

  delete from public.purchase_documents
   where org_id = v_org and contact_id = v_sup_b;

  select s.outstanding into v_a
    from public.forecast_suggestions(v_org) s where s.item_code = 'CLAMP';
  perform pg_temp.check_eq('and comes back the moment the draft is deleted', v_a, 40);

  -- ------------------------------------------------------------------
  -- Somebody else's replenishment
  -- ------------------------------------------------------------------
  -- ------------------------------------------------------------------
  -- One location's answer is not another's
  -- ------------------------------------------------------------------
  -- The run records the warehouse it was about. Without that, "the
  -- latest run for this company" is the only question that can be
  -- asked, and forecasting a branch after the company silently
  -- re-labels the branch's figures as the company's — real numbers
  -- about the wrong stock, with nothing to show for it.
  -- Nothing is stocked at the branch and nothing has ever moved there,
  -- so its own answer is "nothing to order" — and this run is the
  -- newest in the company, which is what makes the control below bite.
  v_run := public.run_inventory_forecast(v_org, v_wh2);

  select count(*) into v_n
    from public.forecast_runs r
   where r.org_id = v_org and r.warehouse_id = v_wh2;
  perform pg_temp.check_eq('the run knows which location it was for', v_n, 1);

  select count(*) into v_n
    from public.forecast_runs r
   where r.org_id = v_org and r.warehouse_id is null;
  perform pg_temp.check_eq('and the company-level run is still its own', v_n, 1);

  -- Nothing is stocked at the second warehouse, so its suggestions are
  -- its own rather than the company's five.
  select count(*) into v_n from public.forecast_suggestions(v_org, v_wh2);
  select count(*) into v_docs from public.forecast_suggestions(v_org);
  perform pg_temp.check_true(
    'the branch is asked its own question, not the company''s',
    v_n <> v_docs);

  -- The control. If the company-level call had started returning the
  -- branch's newer run, both would be equal and the assertion above
  -- would pass for the wrong reason.
  perform pg_temp.check_eq(
    'and the company still answers with its own five', v_docs, 5);

  v_outsider := pg_temp.another_user('outsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform * from public.create_po_from_suggestions(v_org);
    raise exception 'FAIL a non-member raised a purchase order';
  exception when insufficient_privilege then
    raise notice 'ok   a non-member cannot order against this company''s forecast';
  end;

  raise notice 'forecast to purchase order: all assertions passed';
end;
$$;

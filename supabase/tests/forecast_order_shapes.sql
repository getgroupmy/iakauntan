-- =====================================================================
-- iAkauntan :: what the forecast looks at, and what the order says
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/forecast_order_shapes.sql
--
-- `inventory_forecast.sql` checks the ARITHMETIC against worked
-- examples -- safety stock scaling with the root of lead time, empty
-- periods counting as zero -- and then checks that a suggestion becomes
-- a draft order and does not become two.
--
-- A sweep of 64 one-line mutants over `run_inventory_forecast` and
-- `create_po_from_suggestions` killed 10. That is the worst result of
-- this campaign, and the reason is that the two orchestrators had never
-- been tested as orchestrators: the file behind them holds one company,
-- one location, one currency, five items that are all stock-tracked and
-- active, and no purchase history at all.
--
-- So none of the following was observable.
--
-- WHICH ITEMS ARE LOOKED AT. A service, a discontinued line and a
-- deleted one were all forecast, and an item the buyer had excluded was
-- forecast anyway. Every parameter an item can carry of its own --
-- method, window, alpha, service level, lead time -- could be ignored
-- in favour of the company default.
--
-- WHAT THE POSITION IS. `available = on hand - reserved + on order`,
-- and reserved and on order were nought throughout, so both signs could
-- be flipped. So could the warehouse filter on the stock read.
--
-- WHAT THE ORDER SAYS. Neither permission check, the run it reads, the
-- date it is expected, the currency, the payment terms, the warehouse
-- on the line, and above all THE PRICE -- which is read from the last
-- purchase, from this supplier by preference, in this currency, not
-- voided, not deleted. Every one of those five conditions could be
-- deleted, because there was no purchase history for the lookup to get
-- wrong.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.fc_org(p_name text)
returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v, m, true from unnest(array['forecasting','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v, date_trunc('year', current_date)::date);
  return v;
end $$;

create or replace function pg_temp.fc_line(p_run uuid, p_item uuid)
returns public.forecast_lines language sql stable as $$
  select l.* from public.forecast_lines l
   where l.run_id = p_run and l.item_id = p_item;
$$;

-- =====================================================================
-- 1. Which items the run looks at, and what it records about them
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.fc_org('Ramalan Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_main uuid; v_branch uuid; v_sup uuid;
  v_plain uuid; v_service uuid; v_off uuid; v_gone uuid; v_skip uuid;
  v_thin uuid; v_season uuid; v_lead uuid;
  v_run uuid; v_run2 uuid; v_l public.forecast_lines;
  v_d date := current_date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'BR2', 'Branch') returning id into v_branch;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-A', 'Ah Seng', 'supplier') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'PLAIN', 'Plain', 'stock', true, 'C62', 10)
  returning id into v_plain;
  -- A service has no quantity to forecast, and forecasting one produces
  -- a reorder point for something that cannot run out.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SERVICE', 'Fitting', 'service', false, 'C62', 10)
  returning id into v_service;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     is_active)
  values (v_org, 'OFF', 'Discontinued', 'stock', true, 'C62', 10, false)
  returning id into v_off;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     deleted_at)
  values (v_org, 'GONE', 'Deleted', 'stock', true, 'C62', 10, now())
  returning id into v_gone;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SKIP', 'Excluded', 'stock', true, 'C62', 10)
  returning id into v_skip;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'THIN', 'Barely sold', 'stock', true, 'C62', 10)
  returning id into v_thin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SEASON', 'Seasonal', 'stock', true, 'C62', 10)
  returning id into v_season;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'LEAD', 'Lead timed', 'stock', true, 'C62', 10)
  returning id into v_lead;

  -- Demand, and the stock it came out of. PLAIN sells one a day for
  -- twelve weeks, so its weekly buckets are seven and its DAILY mean is
  -- one -- which is the conversion a bucket has to make and the one a
  -- run that forgot to make it gets seven times wrong.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'RCV-' || i, 'purchase_receipt', v_d - 90, v_plain, v_main,
         0, 10 from generate_series(1, 1) i;
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'SLD-' || d, 'sales_delivery', v_d - d, v_plain, v_main,
         -1, 0 from generate_series(1, 84) d;

  -- SEASON and LEAD sell the same way, so their figures are comparable.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'SLS-' || d, 'sales_delivery', v_d - d, v_season, v_main,
         -1, 0 from generate_series(1, 84) d;
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'SLL-' || d, 'sales_delivery', v_d - d, v_lead, v_main,
         -1, 0 from generate_series(1, 84) d;
  -- SKIP sells too, so its absence is a decision rather than a lack of
  -- anything to say.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'SLK-' || d, 'sales_delivery', v_d - d, v_skip, v_main,
         -1, 0 from generate_series(1, 84) d;
  -- THIN sold twice, a fortnight apart: two weekly periods against the
  -- four this company asks for.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'SLT-1', 'sales_delivery', v_d - 7,  v_thin, v_main, -1, 0),
         (v_org, 'SLT-2', 'sales_delivery', v_d - 21, v_thin, v_main, -1, 0);

  -- Parameters are held per LOCATION, so a row with no warehouse on it
  -- is the company-wide answer and does not reach a run for one branch.
  -- These are this branch's.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, is_excluded)
  values (v_org, v_skip, v_main, true);
  -- The item's own method, and a window too short for a season to fit
  -- in, so the fallback fires and says so.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, method, window_periods)
  values (v_org, v_season, v_main, 'seasonal_naive', 52);
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, lead_time_days)
  values (v_org, v_lead, v_main, 3);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods,
     default_method, default_lead_time_days)
  values (v_org, 'week', 2, 84, 4, 'moving_average', 14)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4, default_method = 'moving_average',
        default_lead_time_days = 14;

  v_run := public.run_inventory_forecast(v_org, v_main);

  -- ------------------------------------------------------------------
  -- Who is on the run
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a service has no quantity to forecast',
    (select count(*) from public.forecast_lines l
      where l.run_id = v_run and l.item_id = v_service), 0);
  perform pg_temp.check_eq('nor has a discontinued line',
    (select count(*) from public.forecast_lines l
      where l.run_id = v_run and l.item_id = v_off), 0);
  perform pg_temp.check_eq('nor a deleted one',
    (select count(*) from public.forecast_lines l
      where l.run_id = v_run and l.item_id = v_gone), 0);
  perform pg_temp.check_eq(
    'an item the buyer excluded is not forecast, however well it sells',
    (select count(*) from public.forecast_lines l
      where l.run_id = v_run and l.item_id = v_skip), 0);
  perform pg_temp.check_eq('while the ordinary one is',
    (select count(*) from public.forecast_lines l
      where l.run_id = v_run and l.item_id = v_plain), 1);

  -- The counters on the run itself, which are what the screen shows
  -- before anybody opens a row. Five items are stocked, active and on
  -- file; one of them the buyer excluded.
  perform pg_temp.check_eq('five items were considered',
    (select r.items_considered from public.forecast_runs r
      where r.id = v_run), 5);
  perform pg_temp.check_eq('one was skipped because the buyer said so',
    (select r.items_skipped from public.forecast_runs r
      where r.id = v_run), 1);
  perform pg_temp.check_eq('and four were forecast',
    (select r.items_forecast from public.forecast_runs r
      where r.id = v_run), 4);

  -- ------------------------------------------------------------------
  -- What the run says about one item
  -- ------------------------------------------------------------------
  v_l := pg_temp.fc_line(v_run, v_plain);

  -- ONE A DAY, in weekly buckets. Seven a week divided by seven days is
  -- one, and a run that reported the BUCKET's mean as the day's would
  -- say seven -- and then order seven times what is needed.
  -- A range rather than a figure, because the first and last weekly
  -- buckets of an 84-day window are partial and dilute the mean by a
  -- few per cent. What is being asserted is the CONVERSION, and a run
  -- that reported the bucket's mean as the day's would say about six
  -- and a half -- then order seven times what is needed.
  perform pg_temp.check_true(
    'a bucket''s demand is divided into days: about one a day, not '
    'about seven',
    v_l.mean_daily_demand between 0.8 and 1.2);

  -- The company's default method, and the item's own where it has one.
  perform pg_temp.check_eq('an item with no method of its own takes the '
    'company''s', v_l.method_used::text, 'moving_average');
  perform pg_temp.check_eq(
    'a seasonal method with no season to work from falls back, and says '
    'so, rather than reporting a seasonal forecast that is not one',
    (pg_temp.fc_line(v_run, v_season)).method_used::text, 'moving_average');

  -- Lead time, best evidence first.
  perform pg_temp.check_eq('a lead time somebody typed is used and named',
    (pg_temp.fc_line(v_run, v_lead)).lead_time_source, 'item');
  perform pg_temp.check_eq('and it is the number they typed',
    (pg_temp.fc_line(v_run, v_lead)).lead_time_days, 3);
  perform pg_temp.check_eq(
    'an item with nothing typed and nothing measured falls to the '
    'company''s figure', v_l.lead_time_source, 'settings');
  perform pg_temp.check_eq('which is fourteen days', v_l.lead_time_days, 14);
end $$;

-- =====================================================================
-- 2. The position: what is here, what is spoken for, what is coming
-- =====================================================================
--
-- `available = on hand - reserved + on order`, and every existing
-- fixture leaves the middle and the last at nought -- so both signs
-- could be flipped and nothing moved. So could the warehouse filter on
-- the stock read: a branch's forecast counted the whole company's shelf.
do $$
declare
  v_org uuid := pg_temp.fc_org('Kedudukan Sdn Bhd');
  v_main uuid; v_branch uuid; v_sup uuid; v_item uuid; v_po uuid;
  v_run uuid; v_l public.forecast_lines;
  v_d date := current_date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'BR2', 'Branch') returning id into v_branch;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-A', 'Ah Seng', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'WIDGET', 'Widget', 'stock', true, 'C62', 10)
  returning id into v_item;

  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'SLD-' || d, 'sales_delivery', v_d - d, v_item, v_main,
         -1, 0 from generate_series(1, 84) d;

  -- Twenty on the shelf here, five spoken for, and a hundred sitting in
  -- the branch. All three numbers are different, so any one of them
  -- being read wrong shows.
  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, reserved_quantity)
  values (v_org, v_item, v_main, 20, 5),
         (v_org, v_item, v_branch, 100, 0)
  on conflict (item_id, warehouse_id) do update
    set quantity = excluded.quantity,
        reserved_quantity = excluded.reserved_quantity;

  -- And eight on order, which is stock arriving rather than stock gone.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, expected_date, contact_id,
     currency, exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-EXIST', v_d, v_d + 7, v_sup, 'MYR',
          1, 'approved')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_po, 1, 'item', v_item, 'Widget', 8, 'C62', 10, v_main);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods)
  values (v_org, 'week', 2, 84, 4)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4;

  v_run := public.run_inventory_forecast(v_org, v_main);
  v_l := pg_temp.fc_line(v_run, v_item);

  perform pg_temp.check_eq('what is on this branch''s shelf is counted',
    v_l.on_hand, 20);
  perform pg_temp.check_eq(
    'and only this branch''s -- the hundred in the other store is not '
    'stock this location can sell',
    v_l.on_hand, 20);
  perform pg_temp.check_eq('what is spoken for is recorded', v_l.reserved, 5);
  perform pg_temp.check_eq('and what is on its way', v_l.on_order, 8);
  perform pg_temp.check_eq(
    'available is what is here, less what is promised, plus what is '
    'coming: twenty less five plus eight',
    v_l.available, 23);
end $$;

-- =====================================================================
-- 3. What the row is called
-- =====================================================================
--
-- The state is the loudest thing on a replenishment screen and the
-- thing a buyer sorts by. The ladder is seven branches deep and the
-- first that matches wins, so each one has to be reached by an item
-- that is NOT also caught by the one above it.
do $$
declare
  v_org uuid := pg_temp.fc_org('Keadaan Stok Sdn Bhd');
  v_main uuid; v_sup uuid;
  v_out uuid; v_dead uuid; v_deep uuid; v_capped uuid; v_fine uuid;
  v_run uuid;
  v_d date := current_date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-A', 'Ah Seng', 'supplier') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'OUT', 'Sold out', 'stock', true, 'C62', 10),
         (v_org, 'DEAD', 'Nobody buys it', 'stock', true, 'C62', 10),
         (v_org, 'DEEP', 'Years of it', 'stock', true, 'C62', 10),
         (v_org, 'CAPPED', 'Over its ceiling', 'stock', true, 'C62', 10),
         (v_org, 'FINE', 'Just right', 'stock', true, 'C62', 10);
  select id into v_out    from public.items where org_id = v_org and code = 'OUT';
  select id into v_dead   from public.items where org_id = v_org and code = 'DEAD';
  select id into v_deep   from public.items where org_id = v_org and code = 'DEEP';
  select id into v_capped from public.items where org_id = v_org and code = 'CAPPED';
  select id into v_fine   from public.items where org_id = v_org and code = 'FINE';

  -- OUT, DEEP, CAPPED and FINE all sell one a day. DEAD sells nothing
  -- at all, which is the difference between "sold out" and "we do not
  -- stock it any more".
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'S' || it.code || '-' || d, 'sales_delivery', v_d - d,
         it.id, v_main, -1, 0
    from generate_series(1, 84) d
    join public.items it on it.org_id = v_org
   where it.code in ('OUT', 'DEEP', 'CAPPED', 'FINE');

  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, reserved_quantity)
  values (v_org, v_out,    v_main, 0,    0),
         (v_org, v_dead,   v_main, 0,    0),
         -- Years of cover: one a day and two thousand on the shelf.
         (v_org, v_deep,   v_main, 2000, 0),
         -- Comfortably stocked, but over the ceiling its buyer set.
         (v_org, v_capped, v_main, 120,  0),
         -- Enough for the pipeline and no more, and a quantity that
         -- does not divide into the daily demand -- so the day it runs
         -- out has a fraction to round, and rounding it the other way
         -- is a different day.
         (v_org, v_fine,   v_main, 55,   0)
  on conflict (item_id, warehouse_id) do update
    set quantity = excluded.quantity;

  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, max_quantity)
  values (v_org, v_capped, v_main, 100);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods,
     default_lead_time_days)
  values (v_org, 'week', 2, 84, 4, 14)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4, default_lead_time_days = 14;

  v_run := public.run_inventory_forecast(v_org, v_main);

  perform pg_temp.check_eq(
    'nothing on the shelf and somebody buying it is stocked out',
    (pg_temp.fc_line(v_run, v_out)).state::text, 'stocked_out');
  perform pg_temp.check_true(
    'nothing on the shelf and NOBODY buying it is not -- an item the '
    'company no longer stocks is not an emergency, and calling it one '
    'is how a buyer stops reading the column',
    (pg_temp.fc_line(v_run, v_dead)).state::text <> 'stocked_out');

  perform pg_temp.check_eq(
    'stock past the ceiling its buyer set is overstocked, whatever the '
    'days of cover say',
    (pg_temp.fc_line(v_run, v_capped)).state::text, 'overstocked');
  perform pg_temp.check_eq(
    'and so is stock three times past what the pipeline needs',
    (pg_temp.fc_line(v_run, v_deep)).state::text, 'overstocked');
  perform pg_temp.check_true(
    'while enough for the pipeline and no more is none of those',
    (pg_temp.fc_line(v_run, v_fine)).state::text in ('ok', 'order_soon'));

  -- WHEN IT RUNS OUT, which is the date on the screen. Sixty on the
  -- shelf at one a day runs out in sixty days, and the day it runs out
  -- is the day the cover is used up -- rounded DOWN, because a shelf
  -- that empties in the afternoon is empty that day.
  perform pg_temp.check_true(
    'the day it runs out is counted down, not up',
    (pg_temp.fc_line(v_run, v_fine)).stockout_on
      = v_d + floor((pg_temp.fc_line(v_run, v_fine)).days_cover)::integer);
  perform pg_temp.check_true('and there was a fraction to round',
    (pg_temp.fc_line(v_run, v_fine)).days_cover
      <> floor((pg_temp.fc_line(v_run, v_fine)).days_cover));

  -- The counter on the run: only an item that needs something counts.
  perform pg_temp.check_true(
    'the run counts the items that need ordering, not every item it '
    'looked at',
    (select r.items_suggested < r.items_forecast
       from public.forecast_runs r where r.id = v_run));
end $$;

-- =====================================================================
-- 4. What the order says
-- =====================================================================
--
-- The suggestion is a number on a screen. The order is a document sent
-- to a supplier, and every field on it was untested: the currency, the
-- payment terms, the date it is expected, the warehouse on the line,
-- and above all THE PRICE -- read from the last purchase, from this
-- supplier by preference, in this currency, not voided, not deleted.
-- Five conditions, and there was no purchase history for any of them
-- to get wrong.
do $$
declare
  v_org uuid := pg_temp.fc_org('Pesanan Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_outsider uuid;
  v_main uuid; v_branch uuid;
  v_local uuid; v_foreign uuid; v_norate uuid; v_term uuid;
  v_item uuid; v_slow uuid; v_taxed uuid; v_imported uuid;
  v_tax uuid; v_deadtax uuid;
  v_run uuid; v_doc uuid; v_d date := current_date;
  v_price numeric; v_n integer;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'BR2', 'Branch') returning id into v_branch;

  insert into public.payment_terms
    (org_id, code, name, days, term_type)
  values (v_org, 'N30', 'Net 30', 30, 'net') returning id into v_term;

  insert into public.contacts
    (org_id, code, name, contact_type, currency, payment_term_id)
  values (v_org, 'S-A', 'Ah Seng', 'supplier', 'MYR', v_term)
  returning id into v_local;
  -- A supplier who invoices in dollars, and one who invoices in a
  -- currency nobody has entered a rate for.
  insert into public.contacts (org_id, code, name, contact_type, currency)
  values (v_org, 'S-U', 'Union Tools', 'supplier', 'USD')
  returning id into v_foreign;
  insert into public.contacts (org_id, code, name, contact_type, currency)
  values (v_org, 'S-Z', 'Zenith Overseas', 'supplier', 'SGD')
  returning id into v_norate;

  insert into public.exchange_rates (org_id, from_currency, to_currency,
                                     rate_date, rate, source)
  values (v_org, 'USD', 'MYR', v_d - 1, 4.5, 'manual')
  on conflict do nothing;

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, is_active)
  values (v_org, 'SST6', 'Service tax', '01', 6, 'both', true)
  returning id into v_tax;
  -- Switched off since the item was set up, which is what a rate change
  -- looks like: the old code stays on file so old documents still read.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, is_active)
  values (v_org, 'OLD10', 'Old rate', '01', 10, 'both', false)
  returning id into v_deadtax;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'AITEM', 'Bought before', 'stock', true, 'C62', 10, v_local)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'BSLOW', 'Slow to arrive', 'stock', true, 'C62', 10, v_local)
  returning id into v_slow;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id, purchase_tax_code_id)
  values (v_org, 'CTAXED', 'Taxed', 'stock', true, 'C62', 10, v_local,
          v_deadtax)
  returning id into v_taxed;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'DUSD', 'From abroad', 'stock', true, 'C62', 10, v_foreign)
  returning id into v_imported;

  -- THE PRICE HISTORY, built so that four of the five conditions on the
  -- lookup each have something to exclude.
  --
  --   a bill from THIS supplier at 12, in ringgit, a month ago -- the
  --     right answer;
  --   a bill from ANOTHER supplier at 99, yesterday -- more recent, and
  --     not this supplier's price;
  --   a VOIDED bill from this supplier at 77, yesterday;
  --   a DELETED bill from this supplier at 88, yesterday;
  --   a bill from this supplier at 55 in dollars, yesterday -- a price
  --     in another currency is not a price.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'B-RIGHT', v_d - 30, v_local, 'MYR', 1, 'posted');
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  select v_org, d.id, 1, 'item', v_item, 'x', 1, 'C62', 12
    from public.purchase_documents d
   where d.org_id = v_org and d.doc_no = 'B-RIGHT';

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'B-OTHER', v_d - 1, v_norate, 'MYR', 1, 'posted'),
         (v_org, 'bill', 'B-VOID',  v_d - 1, v_local,  'MYR', 1, 'void'),
         (v_org, 'bill', 'B-FX',    v_d - 1, v_local,  'USD', 4.5, 'posted');
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, deleted_at)
  values (v_org, 'bill', 'B-GONE', v_d - 1, v_local, 'MYR', 1, 'posted',
          now());

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  select v_org, d.id, 1, 'item', v_item, 'x', 1, 'C62',
         case d.doc_no when 'B-OTHER' then 99 when 'B-VOID' then 77
                       when 'B-GONE' then 88 else 55 end
    from public.purchase_documents d
   where d.org_id = v_org and d.doc_no in ('B-OTHER','B-VOID','B-GONE','B-FX');

  -- Demand for everything, so every item has a suggestion.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'S' || it.code || '-' || d, 'sales_delivery', v_d - d,
         it.id, v_main, -1, 0
    from generate_series(1, 84) d
    join public.items it on it.org_id = v_org
   where it.code in ('AITEM','BSLOW','CTAXED','DUSD');

  -- Lead times: the slow line sets the date on the whole order, so the
  -- two items on Ah Seng's order disagree on purpose.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, lead_time_days, min_quantity,
     max_quantity)
  values (v_org, v_item,  v_main,  5, 30, 30),
         (v_org, v_slow,  v_main, 40, 10, 10),
         (v_org, v_taxed, v_main,  5, 10, 10),
         (v_org, v_imported, v_main, 5, 10, 10);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods)
  values (v_org, 'week', 2, 84, 4)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4;

  v_run := public.run_inventory_forecast(v_org, v_main);

  -- ------------------------------------------------------------------
  -- Who may raise one
  -- ------------------------------------------------------------------
  v_outsider := pg_temp.another_user('outsider@forecast.test');
  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_refused('a stranger cannot raise the orders',
    format('select count(*) from public.create_po_from_suggestions(%L)', v_org),
    '%not permitted%');
  perform pg_temp.sign_in_as(v_owner);

  -- A FORECASTING LICENCE IS NOT A LICENCE TO BUY. The company keeps
  -- forecasting and loses purchasing, and the orders stop.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';
  perform pg_temp.check_refused(
    'reading a forecast is not permission to commit the company to '
    'buying something',
    format('select count(*) from public.create_po_from_suggestions(%L)', v_org),
    '%not permitted to raise purchase orders%');
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'purchases';

  -- And a location nobody has forecast has nothing to order from.
  perform pg_temp.check_refused(
    'a location with no forecast of its own says so, rather than '
    'ordering from another branch''s',
    format('select count(*) from public.create_po_from_suggestions(%L, null, null, %L)',
           v_org, v_branch),
    '%No forecast has been run%');

  -- ------------------------------------------------------------------
  -- The orders
  -- ------------------------------------------------------------------
  perform * from public.create_po_from_suggestions(v_org, null, null, v_main);

  select d.id into v_doc from public.purchase_documents d
   where d.org_id = v_org and d.doc_type = 'purchase_order'
     and d.contact_id = v_local and d.doc_no <> 'PO-EXIST';

  perform pg_temp.check_eq('the local supplier is ordered from in ringgit',
    (select d.currency::text from public.purchase_documents d
      where d.id = v_doc), 'MYR');
  perform pg_temp.check_eq('on their own payment terms',
    (select d.payment_term_id from public.purchase_documents d
      where d.id = v_doc), v_term);
  perform pg_temp.check_eq(
    'and expected when the SLOWEST line on it can arrive -- one date on '
    'the document, and the slowest line sets it',
    (select d.expected_date::text from public.purchase_documents d
      where d.id = v_doc), (v_d + 40)::text);

  -- THE PRICE. Twelve is what this supplier charged, a month ago, in
  -- ringgit. Ninety-nine, seventy-seven, eighty-eight and fifty-five
  -- are all more recent and all wrong.
  select l.unit_price into v_price
    from public.purchase_document_lines l
   where l.document_id = v_doc and l.item_id = v_item;
  perform pg_temp.check_eq(
    'the price is what THIS supplier last charged, in THIS currency, on '
    'a document that was neither voided nor deleted',
    v_price, 12);

  perform pg_temp.check_eq('the line says which store it is for',
    (select l.warehouse_id from public.purchase_document_lines l
      where l.document_id = v_doc and l.item_id = v_item), v_main);

  -- A TAX CODE SWITCHED OFF SINCE THE ITEM WAS SET UP. Ordering with no
  -- tax is better than ordering at a rate nobody can charge, and the
  -- code has to come off with the rate or the document carries a
  -- reference to something that is gone.
  perform pg_temp.check_eq('a tax code switched off is not charged',
    (select l.tax_rate from public.purchase_document_lines l
      where l.document_id = v_doc and l.item_id = v_taxed), 0);
  perform pg_temp.check_true('and is not left on the line either',
    (select l.tax_code_id is null from public.purchase_document_lines l
      where l.document_id = v_doc and l.item_id = v_taxed));

  -- The foreign supplier with a rate on file gets an order in their own
  -- money.
  perform pg_temp.check_eq('a supplier who invoices in dollars is ordered '
    'from in dollars',
    (select d.currency::text from public.purchase_documents d
      where d.org_id = v_org and d.contact_id = v_foreign
        and d.doc_type = 'purchase_order'), 'USD');
end $$;

-- =====================================================================
-- 5. The parameters an item carries of its own
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.fc_org('Tetapan Item Sdn Bhd');
  v_main uuid; v_br uuid; v_smooth uuid; v_smooth2 uuid;
  v_careful uuid; v_plain uuid;
  v_capped uuid;
  v_run uuid; v_run2 uuid; v_considered integer;
  v_d date := current_date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'BR2', 'Branch') returning id into v_br;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SMOOTH', 'Smoothed', 'stock', true, 'C62', 10),
         (v_org, 'SMOOTH2', 'Smoothed harder', 'stock', true, 'C62', 10),
         (v_org, 'CAREFUL', 'Held carefully', 'stock', true, 'C62', 10),
         (v_org, 'PLAIN', 'Ordinary', 'stock', true, 'C62', 10),
         (v_org, 'CAPPED', 'Over its ceiling', 'stock', true, 'C62', 10);
  select id into v_smooth  from public.items where org_id = v_org and code = 'SMOOTH';
  select id into v_smooth2 from public.items where org_id = v_org and code = 'SMOOTH2';
  select id into v_careful from public.items where org_id = v_org and code = 'CAREFUL';
  select id into v_plain   from public.items where org_id = v_org and code = 'PLAIN';
  select id into v_capped  from public.items where org_id = v_org and code = 'CAPPED';

  -- Demand that VARIES, so the spread is not nought and a service level
  -- has something to buy cover against. Three a day some days, none on
  -- others.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'S' || it.code || '-' || d, 'sales_delivery', v_d - d,
         it.id, v_main, case when d % 3 = 0 then -3 else -1 end, 0
    from generate_series(1, 84) d
    join public.items it on it.org_id = v_org
   where it.code in ('SMOOTH', 'SMOOTH2', 'CAREFUL', 'PLAIN', 'CAPPED');

  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, reserved_quantity)
  -- A hundred on the shelf: well past the ceiling its buyer set, and
  -- about sixty days of cover -- nowhere near the three pipelines the
  -- model calls overstocked on its own.
  values (v_org, v_capped, v_main, 100, 0)
  on conflict (item_id, warehouse_id) do update
    set quantity = excluded.quantity;

  -- The item's own method, its own service level, and its own ceiling.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, method)
  values (v_org, v_smooth, v_main, 'exponential_smoothing');
  -- The same method with a different weight on the most recent period.
  -- Alpha is the whole of what exponential smoothing is, and an item
  -- carrying its own must not be smoothed at the company's.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, method, alpha)
  values (v_org, v_smooth2, v_main, 'exponential_smoothing', 0.900);
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, service_level)
  values (v_org, v_careful, v_main, 0.9999);
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, max_quantity)
  values (v_org, v_capped, v_main, 20);
  -- At the BRANCH, two of the four are excluded. The two runs then have
  -- different counters, which is the only way to tell a run that writes
  -- its own from one that writes every run in the company.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, is_excluded)
  values (v_org, v_smooth, v_br, true),
         (v_org, v_careful, v_br, true);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods,
     default_method, service_level, default_lead_time_days)
  values (v_org, 'week', 2, 84, 4, 'moving_average', 0.5000, 14)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4, default_method = 'moving_average',
        service_level = 0.5000, default_lead_time_days = 14;

  v_run := public.run_inventory_forecast(v_org, v_main);

  perform pg_temp.check_eq(
    'an item with a method of its own is forecast that way, not the '
    'company''s',
    (pg_temp.fc_line(v_run, v_smooth)).method_used::text,
    'exponential_smoothing');
  perform pg_temp.check_eq('while one without takes the company''s',
    (pg_temp.fc_line(v_run, v_plain)).method_used::text, 'moving_average');
  perform pg_temp.check_true(
    'and an item smoothed at its own weight gets a different answer '
    'from one smoothed at the company''s -- same method, same demand, '
    'different alpha',
    (pg_temp.fc_line(v_run, v_smooth2)).forecast_total
      <> (pg_temp.fc_line(v_run, v_smooth)).forecast_total);

  -- A SERVICE LEVEL IS A CHOICE ABOUT HOW OFTEN TO RUN OUT, and an item
  -- held to one nine in ten thousand carries more buffer than one held
  -- to one in two. Same demand, same lead time, same everything else.
  perform pg_temp.check_true(
    'an item held to a higher service level carries a bigger buffer',
    (pg_temp.fc_line(v_run, v_careful)).safety_stock
      > (pg_temp.fc_line(v_run, v_plain)).safety_stock);
  perform pg_temp.check_true('and the company''s level is what the rest get',
    (pg_temp.fc_line(v_run, v_plain)).safety_stock
      = (pg_temp.fc_line(v_run, v_smooth)).safety_stock);

  -- A CEILING THE BUYER SET, on stock that is nowhere near enough cover
  -- to be called overstocked by the model. Without the ceiling arm this
  -- row reads "ok" and the buyer is never told they are holding more
  -- than they decided to.
  perform pg_temp.check_eq(
    'stock past the ceiling its buyer set is overstocked, even when the '
    'days of cover are unremarkable',
    (pg_temp.fc_line(v_run, v_capped)).state::text, 'overstocked');

  -- ------------------------------------------------------------------
  -- One run does not rewrite another's counters
  -- ------------------------------------------------------------------
  select r.items_considered into v_considered
    from public.forecast_runs r where r.id = v_run;
  perform pg_temp.check_eq('the first run looked at five items',
    v_considered, 5);

  -- The branch holds nothing and has no history, so its run forecasts
  -- nothing -- and the main store's run must still say four.
  v_run2 := public.run_inventory_forecast(v_org, v_br);
  perform pg_temp.check_eq('the branch skipped the two it was told to',
    (select r.items_skipped from public.forecast_runs r
      where r.id = v_run2), 2);
  perform pg_temp.check_eq('and forecast the other three',
    (select r.items_forecast from public.forecast_runs r
      where r.id = v_run2), 3);
  perform pg_temp.check_eq(
    'while the main store''s run still says five -- the counters belong '
    'to the run, not to the company',
    (select r.items_forecast from public.forecast_runs r
      where r.id = v_run), 5);
  perform pg_temp.check_eq('and it skipped nothing',
    (select r.items_skipped from public.forecast_runs r
      where r.id = v_run), 0);
end $$;

-- =====================================================================
-- 6. Which forecast an order is raised from
-- =====================================================================
do $$
declare
  v_a uuid := pg_temp.fc_org('Pesanan A Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_b uuid;
  v_main uuid; v_sup uuid; v_sgd uuid; v_item uuid; v_far uuid;
  v_run uuid; v_n integer; v_note text;
  v_d date := current_date;
begin
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.fc_org('Pesanan B Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_a, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.contacts (org_id, code, name, contact_type, currency)
  values (v_a, 'S-A', 'Ah Seng', 'supplier', 'MYR') returning id into v_sup;
  -- A supplier who invoices in a currency nobody has entered a rate for.
  insert into public.contacts (org_id, code, name, contact_type, currency)
  values (v_a, 'S-Z', 'Zenith Overseas', 'supplier', 'SGD')
  returning id into v_sgd;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_a, 'LOCAL', 'Local', 'stock', true, 'C62', 10, v_sup)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_a, 'FAR', 'From abroad', 'stock', true, 'C62', 10, v_sgd)
  returning id into v_far;

  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_a, 'S' || it.code || '-' || d, 'sales_delivery', v_d - d,
         it.id, v_main, -1, 0
    from generate_series(1, 84) d
    join public.items it on it.org_id = v_a
   where it.code in ('LOCAL', 'FAR');

  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, min_quantity, max_quantity)
  values (v_a, v_item, v_main, 30, 30),
         (v_a, v_far,  v_main, 10, 10);

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods)
  values (v_a, 'week', 2, 84, 4)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4;

  -- COMPANY B RUNS A FORECAST AND COMPANY A HAS NOT. A's order run must
  -- say there is nothing to order from, rather than reaching across.
  perform public.run_inventory_forecast(v_b, null);
  perform pg_temp.check_refused(
    'a company with no forecast of its own is told so, rather than '
    'ordering from the company next door''s',
    format('select count(*) from public.create_po_from_suggestions(%L, null, null, %L)',
           v_a, v_main),
    '%No forecast has been run%');
  -- And asked the way the screen asks it, with no location named at
  -- all -- which is the shape company B's run has, so it is the shape
  -- that could be reached across for.
  perform pg_temp.check_refused('however the question is asked',
    format('select count(*) from public.create_po_from_suggestions(%L)', v_a),
    '%No forecast has been run%');

  -- READING A FORECAST IS ITS OWN PERMISSION. A company that has
  -- purchases but not forecasting is refused, and the refusal names
  -- the module it is short of rather than the other one.
  update public.org_modules set is_enabled = false
   where org_id = v_a and module_code = 'forecasting';
  perform pg_temp.check_refused(
    'a company without forecasting cannot order from a forecast',
    format('select count(*) from public.create_po_from_suggestions(%L)', v_a),
    '%not permitted to read forecasting%');
  perform pg_temp.check_refused('nor run one',
    format('select public.run_inventory_forecast(%L)', v_a),
    '%not permitted to run a forecast%');
  update public.org_modules set is_enabled = true
   where org_id = v_a and module_code = 'forecasting';

  v_run := public.run_inventory_forecast(v_a, v_main);

  -- A SUPPLIER WHOSE MONEY NOBODY HAS A RATE FOR. Their order is left
  -- out with a reason rather than aborting the orders that can be
  -- raised -- and the local supplier's order is raised regardless.
  select count(*) into v_n
    from public.create_po_from_suggestions(v_a, null, null, v_main) r
   where r.document_id is not null;
  perform pg_temp.check_eq(
    'the supplier we can price is ordered from', v_n, 1);

  select r.note into v_note
    from public.create_po_from_suggestions(v_a, null, null, v_main) r
   where r.supplier_id = v_sgd;
  perform pg_temp.check_true(
    'and the one we cannot is reported with a reason rather than '
    'taking the whole replenishment down',
    v_note like '%No exchange rate for SGD%');

  -- AND NO ROW FOR ITEMS THAT HAVE A SUPPLIER. Every item here has one,
  -- so the leftovers line must not appear at all -- a row saying "0
  -- item(s) have no supplier" is a row a buyer has to read and dismiss.
  perform pg_temp.check_eq('nothing is reported as having no supplier',
    (select count(*) from public.create_po_from_suggestions(
       v_a, null, null, v_main) r where r.supplier_id is null), 0);
end $$;

-- =====================================================================
-- 7. Two rules these lean on
-- =====================================================================
do $$
begin
  -- `run_inventory_forecast` scopes the forecast parameters by
  -- `p.org_id = i.org_id` and the stock read by `sl.org_id = p_org`, and
  -- `create_po_from_suggestions` scopes the price lookup by
  -- `l.org_id = p_org`. None of the three can be observed: every one of
  -- them is joined on an item id besides, and an item belongs to one
  -- company. The keys are asserted instead.
  perform pg_temp.check_true(
    'forecast parameters belong to their item''s company',
    exists (select 1 from pg_constraint
             where conrelid = 'public.item_forecast_params'::regclass
               and contype = 'f'
               and confrelid = 'public.items'::regclass));
  perform pg_temp.check_true('and so does a stock level',
    exists (select 1 from pg_constraint
             where conrelid = 'public.stock_levels'::regclass
               and contype = 'f'
               and confrelid = 'public.items'::regclass));
  perform pg_temp.check_true('and so does a purchase line',
    exists (select 1 from pg_constraint
             where conrelid = 'public.purchase_document_lines'::regclass
               and contype = 'f'
               and confrelid = 'public.items'::regclass));
end $$;

-- =====================================================================
-- 8. The boundaries of the ladder, and which run an order reads
-- =====================================================================
--
-- Three of the ladder's comparisons are `<=` where `<` would read the
-- same on every item that is not sitting exactly on the line. So the
-- fixture runs once to find out where the lines ARE, puts an item on
-- each of them, and runs again.
do $$
declare
  v_org uuid := pg_temp.fc_org('Sempadan Sdn Bhd');
  v_main uuid; v_sup uuid;
  v_a uuid; v_b uuid; v_c uuid; v_probe uuid;
  v_run uuid; v_ss numeric; v_rop numeric; v_mean numeric; v_review numeric;
  v_periods integer;
  v_asof date := (date_trunc('week', current_date) - interval '1 day')::date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-A', 'Ah Seng', 'supplier') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'ONSS',  'On its safety stock', 'stock', true, 'C62', 10, v_sup),
         (v_org, 'ONROP', 'On its reorder point', 'stock', true, 'C62', 10, v_sup),
         (v_org, 'ONSOON','On the soon line',     'stock', true, 'C62', 10, v_sup);
  select id into v_a from public.items where org_id = v_org and code = 'ONSS';
  select id into v_b from public.items where org_id = v_org and code = 'ONROP';
  select id into v_c from public.items where org_id = v_org and code = 'ONSOON';

  -- THE WINDOW IS ALIGNED TO WHOLE WEEKS, and the run is asked for a
  -- Sunday. Standing an item exactly ON a line needs the line to be a
  -- number the fixture can compute, and a partial first or last bucket
  -- makes the mean a recurring decimal that the stored figure rounds.
  -- Ten whole weeks, five of them selling one a day and five selling
  -- nothing, give a bucket mean of 3.5 and a daily mean of exactly 0.5
  -- -- and a spread that is not nought, so there is a safety stock to
  -- stand on.
  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'S' || it.code || '-' || d, 'sales_delivery', v_asof - d,
         it.id, v_main, -1, 0
    from generate_series(0, 69) d
    join public.items it on it.org_id = v_org
   where (d / 7) % 2 = 0;

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods,
     default_lead_time_days, service_level)
  -- Sixty-nine, not seventy: the window opens on `p_as_of -
  -- history_days`, and seventy days before a Sunday is another Sunday,
  -- which leaves a one-day bucket on the front.
  values (v_org, 'week', 2, 69, 4, 14, 0.9500)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 69,
        min_periods = 4, default_lead_time_days = 14,
        service_level = 0.9500;

  -- The first run, to find out where the lines are.
  v_run := public.run_inventory_forecast(v_org, v_main, v_asof);
  select l.safety_stock, l.reorder_point, l.mean_daily_demand, l.periods_used
    into v_ss, v_rop, v_mean, v_periods
    from public.forecast_lines l
   where l.run_id = v_run and l.item_id = v_a;
  v_review := 2 * 7;

  perform pg_temp.check_true('the lines are somewhere worth standing on',
    v_ss > 0 and v_rop > v_ss);
  perform pg_temp.check_eq(
    'and the daily mean is exact, so the lines are numbers rather than '
    'roundings', v_mean, 0.500000);

  -- THE SPREAD IS SCALED BY THE ROOT OF THE BUCKET, not by the bucket.
  -- Ten weekly buckets, five of seven and five of nought, so the sample
  -- spread across buckets is sqrt(122.5 / 9). Dividing that by seven
  -- instead of by its root understates the daily spread by a factor of
  -- 2.6 -- and safety stock with it, on exactly the intermittent items
  -- whose buffer matters most.
  perform pg_temp.check_eq(
    'the daily spread is the bucket''s divided by the ROOT of the '
    'bucket''s length',
    round((select l.stddev_daily_demand from public.forecast_lines l
            where l.run_id = v_run and l.item_id = v_a), 6),
    round((sqrt(122.5 / 9) / sqrt(7))::numeric, 6));

  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, reserved_quantity)
  values (v_org, v_a, v_main, v_ss, 0),
         (v_org, v_b, v_main, v_rop, 0),
         (v_org, v_c, v_main, v_rop + v_mean * v_review, 0)
  on conflict (item_id, warehouse_id) do update
    set quantity = excluded.quantity;

  v_run := public.run_inventory_forecast(v_org, v_main, v_asof);

  perform pg_temp.check_eq(
    'an item sitting exactly ON its safety stock has not fallen below '
    'it -- the buffer is the floor, and standing on a floor is not '
    'falling through it',
    (pg_temp.fc_line(v_run, v_a)).state::text, 'order_now');
  perform pg_temp.check_eq(
    'an item sitting exactly ON its reorder point is at the point where '
    'it reorders, which is what the point means',
    (pg_temp.fc_line(v_run, v_b)).state::text, 'order_now');
  perform pg_temp.check_eq(
    'and an item exactly one review period above it is due soon',
    (pg_temp.fc_line(v_run, v_c)).state::text, 'order_soon');

  -- HISTORY THAT IS EXACTLY ENOUGH. `min_periods` is how many periods
  -- the company insists on before it will forecast at all, and an item
  -- with exactly that many has enough -- "at least this many" is what
  -- the settings screen says.
  update public.forecast_settings set min_periods = v_periods
   where org_id = v_org;
  v_run := public.run_inventory_forecast(v_org, v_main, v_asof);
  perform pg_temp.check_true('history of exactly the length asked for is '
    'enough history',
    (pg_temp.fc_line(v_run, v_a)).skipped_reason is null);
  update public.forecast_settings set min_periods = v_periods + 1
   where org_id = v_org;
  v_run := public.run_inventory_forecast(v_org, v_main, v_asof);
  perform pg_temp.check_true('and one period short is not',
    (pg_temp.fc_line(v_run, v_a)).skipped_reason is not null);
end $$;

-- =====================================================================
-- 9. Which run, and which price
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.fc_org('Larian Terkini Sdn Bhd');
  v_main uuid; v_sup uuid; v_item uuid; v_ordered uuid; v_po uuid;
  v_run uuid; v_qty numeric; v_price numeric;
  v_d date := current_date;
begin
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main', true) returning id into v_main;
  insert into public.contacts (org_id, code, name, contact_type, currency)
  values (v_org, 'S-A', 'Ah Seng', 'supplier', 'MYR') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'AGAIN', 'Ordered again', 'stock', true, 'C62', 10, v_sup)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price,
     preferred_supplier_id)
  values (v_org, 'BPRICED', 'Priced off an order', 'stock', true, 'C62', 10,
          v_sup)
  returning id into v_ordered;

  insert into public.stock_movements
    (org_id, movement_no, movement_type, movement_date, item_id,
     warehouse_id, quantity, unit_cost)
  select v_org, 'S' || it.code || '-' || d, 'sales_delivery', v_d - d,
         it.id, v_main, -1, 0
    from generate_series(1, 84) d
    join public.items it on it.org_id = v_org;

  -- A PURCHASE ORDER already raised, at a price no bill carries. An
  -- order placed but not yet billed is the most recent thing this
  -- supplier has agreed to, and it is what the next order should say.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-AGREED', v_d - 1, v_sup, 'MYR', 1,
          'approved')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_po, 1, 'item', v_ordered, 'x', 1, 'C62', 17);
  -- And an older bill at a different price, so the two disagree.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'B-OLD', v_d - 60, v_sup, 'MYR', 1, 'posted');
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  select v_org, d.id, 1, 'item', v_ordered, 'x', 1, 'C62', 9
    from public.purchase_documents d
   where d.org_id = v_org and d.doc_no = 'B-OLD';

  insert into public.forecast_settings
    (org_id, bucket, horizon_buckets, history_days, min_periods)
  values (v_org, 'week', 2, 84, 4)
  on conflict (org_id) do update
    set bucket = 'week', horizon_buckets = 2, history_days = 84,
        min_periods = 4;

  -- Nothing on the shelf, rather than the negative position that
  -- selling what was never bought in leaves behind: the order-up-to
  -- would then cover the hole as well as the target, and the quantity
  -- would not be a number anybody could check by hand.
  insert into public.stock_levels
    (org_id, item_id, warehouse_id, quantity, reserved_quantity)
  values (v_org, v_item, v_main, 0, 0), (v_org, v_ordered, v_main, 0, 0)
  on conflict (item_id, warehouse_id) do update
    set quantity = excluded.quantity;

  -- TWO RUNS, and the buyer changed their mind between them.
  --
  -- The first is backdated an hour by hand. `run_at` defaults to
  -- `now()`, which is the TRANSACTION's clock, so two runs inside this
  -- file share a timestamp and "the latest run" has nothing to sort on.
  -- In the product they are two requests an hour apart, which is what
  -- the backdating stands in for.
  insert into public.item_forecast_params
    (org_id, item_id, warehouse_id, min_quantity, max_quantity)
  values (v_org, v_item, v_main, 30, 30), (v_org, v_ordered, v_main, 5, 5);
  v_run := public.run_inventory_forecast(v_org, v_main);
  update public.forecast_runs set run_at = run_at - interval '1 hour'
   where id = v_run;

  update public.item_forecast_params set min_quantity = 70, max_quantity = 70
   where org_id = v_org and item_id = v_item;
  v_run := public.run_inventory_forecast(v_org, v_main);

  perform * from public.create_po_from_suggestions(v_org, null, null, v_main);

  select l.quantity, l.unit_price into v_qty, v_price
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
   where d.org_id = v_org and d.doc_type = 'purchase_order'
     and d.doc_no <> 'PO-AGREED' and l.item_id = v_item;
  perform pg_temp.check_eq(
    'the order is raised from the LATEST forecast, not the first one '
    'anybody ran -- a buyer who re-runs after changing a target expects '
    'the new number',
    v_qty, 70);

  select l.unit_price into v_price
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
   where d.org_id = v_org and d.doc_type = 'purchase_order'
     and d.doc_no <> 'PO-AGREED' and l.item_id = v_ordered;
  perform pg_temp.check_eq(
    'and the price is what was last AGREED, order or bill -- an order '
    'placed and not yet billed is the most recent price there is',
    v_price, 17);
end $$;

rollback;

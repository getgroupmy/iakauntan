-- =====================================================================
-- iAkauntan :: which batch left, and which batch came back
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/lot_allocation_shapes.sql
--
-- `app.materialise_movement_lots` decides which batch or serial number
-- every movement of a tracked item is against, and `app.pick_lots_fefo`
-- decides which one goes out when nobody has said. Between them they
-- are the whole of batch traceability: a recall, an expiry date on a
-- shelf, and the cost a sale is charged at all read off what these two
-- wrote.
--
-- A sweep of 43 one-line mutants killed 20 — THE WORST RESULT OF THIS
-- CAMPAIGN, on stock that people eat. What lived was of four kinds.
--
-- THE PICKER'S OWN ORDER AND SCOPE. `pick_lots_fefo` had never been
-- called directly, and the fixtures behind it hold one batch in one
-- warehouse — so earliest-expiry-first could not be told from
-- latest-expiry-first, a batch with no expiry date at all had never
-- been picked against one that has, and the warehouse filter had
-- nothing to exclude.
--
-- WHAT A LOT ALREADY ON FILE KEEPS. The upsert `coalesce`s three
-- columns against what is already there — the expiry, the manufacture
-- date and the supplier's own reference — and no fixture had ever named
-- the same batch twice, so all three could be replaced by the incoming
-- null.
--
-- WHOSE BATCHES A RETURN GOES BACK TO. Most-recently-taken first, and
-- only this sale's, and only this item's. One sale of one item in the
-- fixture, so none of the three was observable.
--
-- AND WHAT A CONVERSION'S OUTPUT INHERITS: one input batch's reference
-- when there was one, a made-up one when there were several, and the
-- EARLIEST expiry of what went in — because the safe direction is the
-- early one.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.la_item(
  p_org uuid, p_code text, p_tracking text default 'batch')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     cost_price, tracking)
  values (p_org, p_code, initcap(p_code), 'stock', true, 'C62', 10,
          p_tracking)
  returning id into v;
  return v;
end $$;

-- Stock arrives the only way a tracked item can: a posted bill whose
-- line names its batches.
create or replace function pg_temp.la_receive(
  p_org uuid, p_item uuid, p_wh uuid, p_lots jsonb,
  p_on date default date '2026-02-01')
returns uuid language plpgsql as $$
declare v_supp uuid; v_doc uuid; v_line uuid; v_qty numeric;
begin
  select id into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier' limit 1;
  if v_supp is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'S-001', 'Pembekal', 'supplier') returning id into v_supp;
  end if;
  select coalesce(sum((x ->> 'quantity')::numeric), 0) into v_qty
    from jsonb_array_elements(p_lots) x;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', 'BILL-' || substr(gen_random_uuid()::text, 1, 8),
          p_on, v_supp, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (p_org, v_doc, 1, 'item', p_item, 'Goods', v_qty, 'C62', 10, p_wh)
  returning id into v_line;
  perform public.set_line_lots('purchase_document_lines', v_line, p_lots);
  perform public.post_purchase_document(v_doc);
  return v_line;
end $$;

create or replace function pg_temp.la_lot(p_org uuid, p_item uuid, p_ref text)
returns uuid language sql stable as $$
  select l.id from public.stock_lots l
   where l.org_id = p_org and l.item_id = p_item and l.lot_ref = p_ref;
$$;

-- How much of a batch a movement is against.
create or replace function pg_temp.la_on(p_movement uuid, p_lot uuid)
returns numeric language sql stable as $$
  select coalesce(sum(sml.quantity), 0) from public.stock_movement_lots sml
   where sml.movement_id = p_movement and sml.lot_id = p_lot;
$$;

-- =====================================================================
-- 1. The picker, asked directly
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Pilih Batch Sdn Bhd');
  v_main uuid; v_shop uuid; v_item uuid;
  v_early uuid; v_late uuid; v_undated uuid; v_theirs uuid;
  v_taken numeric; v_first uuid; v_n integer;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main store', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'SHOP', 'The shop') returning id into v_shop;

  v_item := pg_temp.la_item(v_org, 'santan');

  -- Three batches in the main store: one expiring soon, one later, and
  -- one with no date on it at all -- a supplier who does not print one,
  -- which is ordinary. And a fourth batch of the same item sitting in
  -- the shop, which the main store cannot ship.
  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'LATE',  'quantity', 10,
                       'expiry_date', '2026-12-31'),
    jsonb_build_object('lot_ref', 'EARLY', 'quantity', 10,
                       'expiry_date', '2026-06-30'),
    jsonb_build_object('lot_ref', 'NODATE', 'quantity', 10)));
  perform pg_temp.la_receive(v_org, v_item, v_shop, jsonb_build_array(
    jsonb_build_object('lot_ref', 'SHOPONLY', 'quantity', 10,
                       'expiry_date', '2026-03-31')));

  v_early   := pg_temp.la_lot(v_org, v_item, 'EARLY');
  v_late    := pg_temp.la_lot(v_org, v_item, 'LATE');
  v_undated := pg_temp.la_lot(v_org, v_item, 'NODATE');
  v_theirs  := pg_temp.la_lot(v_org, v_item, 'SHOPONLY');

  -- FIRST EXPIRY OUT FIRST. The shop's batch expires before any of
  -- these and is not in the main store, so a picker that ignored the
  -- warehouse would reach for it first of all.
  select p.lot_id into v_first
    from app.pick_lots_fefo(v_item, v_main, -5) p limit 1;
  perform pg_temp.check_eq(
    'the batch that goes off first goes out first', v_first, v_early);

  perform pg_temp.check_eq('and only from the store being shipped from',
    (select count(*) from app.pick_lots_fefo(v_item, v_main, -30) p
      where p.lot_id = v_theirs), 0);
  perform pg_temp.check_eq('while that store can ship its own',
    (select p.take from app.pick_lots_fefo(v_item, v_shop, -4) p
      where p.lot_id = v_theirs), 4);

  -- A BATCH WITH NO DATE ON IT GOES LAST, not first. Nulls sort first
  -- by default in Postgres on an ascending order, and taking the
  -- undated batch ahead of one that expires in June is how something
  -- goes off on a shelf.
  perform pg_temp.check_eq(
    'a batch with no expiry printed on it is kept back, not shipped '
    'ahead of one that has a date',
    (select count(*) from app.pick_lots_fefo(v_item, v_main, -15) p
      where p.lot_id = v_undated), 0);
  perform pg_temp.check_eq('and the second batch out is the later-dated one',
    (select p.take from app.pick_lots_fefo(v_item, v_main, -15) p
      where p.lot_id = v_late), 5);
  perform pg_temp.check_eq('while a bigger order does reach it',
    (select p.take from app.pick_lots_fefo(v_item, v_main, -25) p
      where p.lot_id = v_undated), 5);

  -- NEVER MORE THAN A BATCH HOLDS, and never past the count.
  perform pg_temp.check_eq('a batch gives up no more than it holds',
    (select p.take from app.pick_lots_fefo(v_item, v_main, -25) p
      where p.lot_id = v_early), 10);
  perform pg_temp.check_eq('and asking for four takes four',
    (select coalesce(sum(p.take), 0)
       from app.pick_lots_fefo(v_item, v_main, -4) p), 4);
  perform pg_temp.check_eq('from one batch',
    (select count(*) from app.pick_lots_fefo(v_item, v_main, -4) p), 1);

  -- A WAREHOUSE THAT HAS ISSUED MORE OF A BATCH THAN IT EVER RECEIVED.
  -- A correction posted the wrong way round leaves a negative balance,
  -- and a negative balance is not stock to ship: `quantity > 0` is what
  -- keeps the picker from offering it and then taking a negative.
  -- Written the way `import_opening_stock` writes -- the one source
  -- this trigger stands aside for -- because the movement and its lot
  -- are both being keyed in on purpose.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table)
  values (v_org, 'SM-NEG', date '2026-02-02', 'adjustment_out', v_item,
          v_shop, -20, 10, 'opening_stock');
  insert into public.stock_movement_lots (org_id, movement_id, lot_id, quantity)
  select v_org, m.id, v_theirs, -20 from public.stock_movements m
   where m.org_id = v_org and m.movement_no = 'SM-NEG';

  perform pg_temp.check_eq(
    'a batch the warehouse is short of is not offered to be shipped',
    (select count(*) from app.pick_lots_fefo(v_item, v_shop, -5) p
      where p.lot_id = v_theirs), 0);
end $$;

-- =====================================================================
-- 2. What a batch already on file keeps
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Simpan Butiran Sdn Bhd');
  v_main uuid; v_item uuid; v_lot uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main store', true) returning id into v_main;
  v_item := pg_temp.la_item(v_org, 'ubat');

  -- The first delivery of batch B-1 comes with everything printed on
  -- the carton.
  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'B-1', 'quantity', 10,
                       'expiry_date', '2027-06-30',
                       'manufactured_on', '2026-01-15',
                       'supplier_lot_ref', 'ACME-77')));
  v_lot := pg_temp.la_lot(v_org, v_item, 'B-1');

  -- The second names the same batch and prints none of it -- a
  -- delivery note typed in a hurry, which is the ordinary case.
  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'B-1', 'quantity', 5)),
    date '2026-02-10');

  perform pg_temp.check_eq(
    'a second delivery that prints no expiry does not erase the one on '
    'file -- a batch with no expiry is a batch nobody will recall',
    (select l.expiry_date::text from public.stock_lots l where l.id = v_lot),
    '2027-06-30');
  perform pg_temp.check_eq('nor the date it was made',
    (select l.manufactured_on::text from public.stock_lots l
      where l.id = v_lot), '2026-01-15');
  perform pg_temp.check_eq('nor the supplier''s own reference for it',
    (select l.supplier_lot_ref from public.stock_lots l where l.id = v_lot),
    'ACME-77');
  perform pg_temp.check_eq('while both deliveries are against it',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml where sml.lot_id = v_lot), 15);

  -- The control: a delivery that DOES print a date sets one where there
  -- was none. Without it the three assertions above are also satisfied
  -- by an upsert that never updates anything.
  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'B-2', 'quantity', 5)),
    date '2026-02-11');
  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'B-2', 'quantity', 5,
                       'expiry_date', '2027-01-31')),
    date '2026-02-12');
  perform pg_temp.check_eq('and one that does print one fills the gap',
    (select l.expiry_date::text from public.stock_lots l
      where l.org_id = v_org and l.item_id = v_item and l.lot_ref = 'B-2'),
    '2027-01-31');
end $$;

-- =====================================================================
-- 3. A stocktake's own batches, and an invoice's missing ones
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Kira Stok Sdn Bhd');
  v_main uuid; v_item uuid; v_lot uuid; v_adj uuid; v_line uuid;
  v_cust uuid; v_doc uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main store', true) returning id into v_main;
  v_item := pg_temp.la_item(v_org, 'santan');

  perform pg_temp.la_receive(v_org, v_item, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'B-1', 'quantity', 20,
                       'expiry_date', '2026-06-30')));
  v_lot := pg_temp.la_lot(v_org, v_item, 'B-1');

  -- A STOCKTAKE THAT FINDS FIVE MISSING, and says which batch they were
  -- from. `stock_adjustments` is the third arm of the first loop and
  -- the only one no fixture had ever reached, so deleting it changed
  -- nothing anybody was watching -- and what it changes is that a
  -- stocktake on a tracked item cannot be posted at all.
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason,
     adjustment_type, status)
  values (v_org, 'ADJ-1', date '2026-03-01', v_main, 'Stocktake',
          'stock_take', 'draft')
  returning id into v_adj;
  insert into public.stock_adjustment_lines
    (org_id, adjustment_id, line_no, item_id, system_quantity,
     counted_quantity, difference, unit_cost, total_cost)
  values (v_org, v_adj, 1, v_item, 20, 15, -5, 10, -50)
  returning id into v_line;
  perform public.set_line_lots('stock_adjustment_lines', v_line,
    jsonb_build_array(jsonb_build_object('lot_ref', 'B-1', 'quantity', 5)));
  perform public.post_stock_adjustment(v_adj);

  perform pg_temp.check_eq(
    'a stocktake says which batch was short, and it comes off that one',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_table = 'stock_adjustments' and sml.lot_id = v_lot), -5);

  -- AN INVOICE LINE WITH NO BATCHES NAMED IS REFUSED, not picked for.
  -- That is on purpose and the function says so: putting
  -- `sales_documents` in the FEFO list would quietly start choosing
  -- batches for every invoice somebody forgot to name them on, and a
  -- recall would then name whatever the picker happened to reach for.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pembeli', 'customer') returning id into v_cust;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-NOLOTS', date '2026-03-05', v_cust, 'MYR',
          1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_doc, 1, 'item', v_item, 'Goods', 5, 'C62', 20, v_main);

  perform pg_temp.check_refused(
    'an invoice for a tracked item with no batch named is refused rather '
    'than having one chosen for it',
    format('select public.post_sales_document(%L)', v_doc),
    '%has to be named before this can be posted%');
end $$;

-- =====================================================================
-- 4. Where a return goes back to
-- =====================================================================
--
-- The ingredient goes out through a RECIPE, which is one of the two
-- ways a batch-tracked item reaches the counter. The other is selling
-- the tracked thing ITSELF, which was refused outright until 0540 and
-- is now an earliest-expiry-first pick written onto the counter
-- invoice; `supabase/tests/pos_tracked_item_sale.sql` is that half.
do $$
declare
  v_org uuid := pg_temp.test_org('Pulang Batch Sdn Bhd');
  v_kitchen uuid; v_walkin uuid; v_outlet uuid; v_reg uuid; v_cash uuid;
  v_milk uuid; v_juice uuid; v_nasi uuid; v_jus uuid;
  v_first uuid; v_second uuid; v_sixth uuid; v_juice_lot uuid;
  v_sale uuid; v_other uuid; v_ret uuid; v_line uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Kitchen', true) returning id into v_kitchen;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter', 'customer') returning id into v_walkin;

  v_milk  := pg_temp.la_item(v_org, 'santan');
  v_juice := pg_temp.la_item(v_org, 'jus');

  -- Two dishes, so the sale carries two tracked ingredients. The second
  -- is what tells "this sale's batches" from "this sale's batches OF
  -- THIS ITEM".
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00)
  returning id into v_nasi;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'AIR', 'Air jus', 'service', false, 'C62', 5.00)
  returning id into v_jus;

  -- SIX BATCHES OF THE INGREDIENT, one unit each, a month apart. Six
  -- rather than two, and one unit each rather than a heap, for two
  -- reasons.
  --
  -- The first is that the fault this file was written against was a
  -- RANDOM tie-break -- `sml.lot_id`, a uuid -- on the order a return
  -- goes back in. A random order cannot be caught by a test that offers
  -- it two batches to choose between: it gets the answer right half the
  -- time. With five batches on one movement and two units coming back,
  -- it has to guess the right two in the right order.
  --
  -- The second is that the juice sits BETWEEN two of them. A return
  -- that read every ingredient on the sale, rather than this one, would
  -- reach the juice on its second unit -- so the assertion catches it
  -- rather than being satisfied by an order that never got that far.
  perform pg_temp.la_receive(v_org, v_milk, v_kitchen, jsonb_build_array(
    jsonb_build_object('lot_ref', 'M-1', 'quantity', 1,
                       'expiry_date', '2026-01-31'),
    jsonb_build_object('lot_ref', 'M-2', 'quantity', 1,
                       'expiry_date', '2026-02-28'),
    jsonb_build_object('lot_ref', 'M-3', 'quantity', 1,
                       'expiry_date', '2026-03-31'),
    jsonb_build_object('lot_ref', 'M-4', 'quantity', 1,
                       'expiry_date', '2026-04-30'),
    jsonb_build_object('lot_ref', 'M-5', 'quantity', 1,
                       'expiry_date', '2026-05-31'),
    jsonb_build_object('lot_ref', 'M-6', 'quantity', 1,
                       'expiry_date', '2026-06-30')));
  perform pg_temp.la_receive(v_org, v_juice, v_kitchen, jsonb_build_array(
    jsonb_build_object('lot_ref', 'J-1', 'quantity', 2,
                       'expiry_date', '2026-05-15')));

  v_first     := pg_temp.la_lot(v_org, v_milk, 'M-4');
  v_second    := pg_temp.la_lot(v_org, v_milk, 'M-5');
  v_sixth     := pg_temp.la_lot(v_org, v_milk, 'M-6');
  v_juice_lot := pg_temp.la_lot(v_org, v_juice, 'J-1');

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_kitchen,
          v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id) values (v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true)
  returning id into v_cash;
  perform public.open_pos_shift(v_reg, 100.00);

  -- One of each ingredient per plate.
  perform public.upsert_pos_recipe(v_org, v_nasi, 1, jsonb_build_array(
    jsonb_build_object('item', v_milk, 'quantity', 1, 'uom', 'C62')));
  perform public.upsert_pos_recipe(v_org, v_jus, 1, jsonb_build_array(
    jsonb_build_object('item', v_juice, 'quantity', 1, 'uom', 'C62')));

  -- A sale that empties the early batch and starts the late one, and
  -- pours some juice besides.
  -- Five plates and a glass: the five oldest batches of the ingredient
  -- go, and the sixth is left standing.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_nasi, 5, 12.00);
  perform public.add_pos_sale_line(v_sale, v_jus, 1, 5.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 65.00)));

  -- A second sale, which takes the sixth. It is the LATEST-dated batch
  -- of all, so a return that read every sale rather than this one would
  -- reach for it first of all.
  v_other := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_other, v_nasi, 1, 12.00);
  perform public.complete_pos_sale(v_other, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 12.00)));

  perform pg_temp.check_eq('the first sale emptied five batches',
    (select count(distinct sml.lot_id)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_id = v_sale and m.item_id = v_milk), 5);
  perform pg_temp.check_eq('and the sixth went on the second sale',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_id = v_other and sml.lot_id = v_sixth), -1);

  -- TWO OF THE FIVE COME BACK, to the last two batches taken.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table, source_id)
  values (v_org, 'SM-RET', date '2026-03-10', 'sales_return', v_milk,
          v_kitchen, 2, 10, 'pos_sales', v_sale)
  returning id into v_ret;

  perform pg_temp.check_eq(
    'what comes back goes to the batch taken LAST', 
    pg_temp.la_on(v_ret, v_second), 1);
  perform pg_temp.check_eq('and then to the one before it',
    pg_temp.la_on(v_ret, v_first), 1);

  -- AND ONLY THIS SALE'S BATCHES, AND ONLY THIS ITEM'S. The juice
  -- expires between those two, and the sixth batch of the ingredient
  -- went out on the other sale and is later-dated than any of them --
  -- so either mistake reaches for something before the second unit is
  -- placed.
  perform pg_temp.check_eq(
    'nothing goes back against the other ingredient on the same sale',
    pg_temp.la_on(v_ret, v_juice_lot), 0);
  perform pg_temp.check_eq('nor against the batch the other sale took',
    pg_temp.la_on(v_ret, v_sixth), 0);
  perform pg_temp.check_eq('and the whole return is accounted for',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
      where sml.movement_id = v_ret), 2);

  -- A SECOND RETURN OF THE SAME BATCH ADDS TO THE FIRST rather than
  -- replacing it. Two lines of one credit note against one batch is
  -- ordinary, and a replace loses the first of them.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table, source_id)
  values (v_org, 'SM-RET2', date '2026-03-11', 'sales_return', v_milk,
          v_kitchen, 1, 10, 'pos_sales', v_sale)
  returning id into v_line;
  perform pg_temp.check_eq('a further return goes back to the last batch',
    pg_temp.la_on(v_line, v_second), 1);

  -- THE RULE THE `on conflict ... + excluded.quantity` LEANS ON. It
  -- cannot be observed either: the recipe depletion writes ONE movement
  -- per item per sale, so each batch appears once in the loop above and
  -- the conflict never fires. Adding rather than replacing is what the
  -- day a second movement appears will need, and this is the sentence
  -- that will fail when it does.
  perform pg_temp.check_eq(
    'a sale takes each ingredient out on one movement, so a batch is '
    'named once',
    (select count(*) from public.stock_movements m
      where m.source_id = v_sale and m.item_id = v_milk
        and m.quantity < 0), 1);

  -- AND STOCK COMING IN IS NEVER PICKED FOR. A credit note against a
  -- sale that never took this ingredient has nothing to go back to, and
  -- the answer is a refusal -- not a pick, which would take the batch
  -- OUT of the warehouse on a movement that is putting stock in.
  perform pg_temp.check_refused(
    'a return with nothing to go back to is refused rather than picked '
    'for',
    format($fmt$insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, unit_cost, source_table, source_id)
     values (%L, 'SM-RET3', date '2026-03-12', 'sales_return', %L, %L,
             1, 10, 'pos_sales', %L)$fmt$,
      v_org, v_juice, v_kitchen, v_other),
    '%has to be named before this can be posted%');
end $$;

-- =====================================================================
-- 5. What a conversion's output inherits
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Potong Ayam Sdn Bhd');
  v_kitchen uuid; v_chicken uuid; v_breast uuid; v_other uuid;
  v_third uuid; v_conv uuid; v_conv2 uuid; v_conv3 uuid;
  v_ref text; v_exp date;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Kitchen', true) returning id into v_kitchen;

  v_chicken := pg_temp.la_item(v_org, 'ayam');
  v_breast  := pg_temp.la_item(v_org, 'dada');
  v_other   := pg_temp.la_item(v_org, 'kepak');
  v_third   := pg_temp.la_item(v_org, 'peha');

  -- Two batches of chicken with different expiry dates, so the output
  -- can inherit the wrong one.
  perform pg_temp.la_receive(v_org, v_chicken, v_kitchen, jsonb_build_array(
    jsonb_build_object('lot_ref', 'A-EARLY', 'quantity', 3,
                       'expiry_date', '2026-06-30'),
    jsonb_build_object('lot_ref', 'A-LATE', 'quantity', 5,
                       'expiry_date', '2026-12-31')));

  v_conv := public.upsert_item_conversion(
    null, v_org, 'CUT', 'Cut a chicken up', v_chicken, 1, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_breast, 'quantity', 2,
                                         'share', 100)), true);

  -- ONE CHICKEN, ONE BATCH. The pieces belong to the bird they came
  -- off, and the batch reference is the bird's own.
  perform public.run_item_conversion(v_conv, 1, v_kitchen);
  select l.lot_ref, l.expiry_date into v_ref, v_exp
    from public.stock_lots l
   where l.org_id = v_org and l.item_id = v_breast;
  perform pg_temp.check_eq(
    'pieces off one bird carry that bird''s batch, so a recall on the '
    'bird reaches the pieces', v_ref, 'A-EARLY');
  perform pg_temp.check_eq('and its expiry date', v_exp::text, '2026-06-30');

  -- SEVERAL BATCHES IN ONE POT. Four birds now, and only two of the
  -- early batch are left, so the pot holds two of each. There is no one
  -- bird to name, so the output gets a batch of its own -- and it
  -- carries the EARLIEST expiry of what went in, because the safe
  -- direction is the early one.
  v_conv2 := public.upsert_item_conversion(
    null, v_org, 'CUT2', 'Cut several up', v_chicken, 4, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_other, 'quantity', 8,
                                         'share', 100)), true);
  perform public.run_item_conversion(v_conv2, 1, v_kitchen);

  select l.lot_ref, l.expiry_date into v_ref, v_exp
    from public.stock_lots l
   where l.org_id = v_org and l.item_id = v_other;
  perform pg_temp.check_true(
    'several batches in one pot get a batch of their own rather than '
    'one of theirs', v_ref like 'CONV-%');
  perform pg_temp.check_eq(
    'carrying the earliest expiry of what went in, not the latest',
    v_exp::text, '2026-06-30');

  -- And the first conversion's output is untouched by the second.
  perform pg_temp.check_eq('the first conversion''s batch still stands',
    (select l.lot_ref from public.stock_lots l
      where l.org_id = v_org and l.item_id = v_breast), 'A-EARLY');

  -- A THIRD RUN, off what is left -- which is the late batch only. Its
  -- output takes THAT batch's reference, and the two runs before it
  -- must not be read: between them they took from both batches, so a
  -- lookup that forgot which run it was asking about would count two
  -- and invent a reference instead.
  v_conv3 := public.upsert_item_conversion(
    null, v_org, 'CUT3', 'Cut the rest up', v_chicken, 2, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_third, 'quantity', 4,
                                         'share', 100)), true);
  perform public.run_item_conversion(v_conv3, 1, v_kitchen);

  select l.lot_ref into v_ref from public.stock_lots l
   where l.org_id = v_org and l.item_id = v_third;
  perform pg_temp.check_eq(
    'a run off one batch carries that batch, whatever the runs before '
    'it took from', v_ref, 'A-LATE');
end $$;

-- =====================================================================
-- 6. A van with two lines on it, and a short delivery
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Van Batch Sdn Bhd');
  v_main uuid; v_shop uuid; v_flour uuid; v_sugar uuid;
  v_f_early uuid; v_f_late uuid; v_s_lot uuid;
  v_t uuid; v_fline uuid; v_arrival uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Central store', true) returning id into v_main;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'SHOP', 'The shop') returning id into v_shop;

  v_flour := pg_temp.la_item(v_org, 'tepung');
  v_sugar := pg_temp.la_item(v_org, 'gula');

  perform pg_temp.la_receive(v_org, v_flour, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'F-EARLY', 'quantity', 2,
                       'expiry_date', '2026-06-30'),
    jsonb_build_object('lot_ref', 'F-LATE', 'quantity', 5,
                       'expiry_date', '2026-12-31')));
  perform pg_temp.la_receive(v_org, v_sugar, v_main, jsonb_build_array(
    jsonb_build_object('lot_ref', 'S-1', 'quantity', 5,
                       'expiry_date', '2026-09-30')));

  v_f_early := pg_temp.la_lot(v_org, v_flour, 'F-EARLY');
  v_f_late  := pg_temp.la_lot(v_org, v_flour, 'F-LATE');
  v_s_lot   := pg_temp.la_lot(v_org, v_sugar, 'S-1');

  -- TWO LINES ON ONE VAN. The flour line spans two batches; the sugar
  -- line is what tells "the batches this line's own dispatch carried"
  -- from "the batches this transfer carried".
  v_t := public.upsert_stock_transfer(
    null, v_org, v_main, v_shop, date '2026-03-01',
    jsonb_build_array(
      jsonb_build_object('item', v_flour, 'quantity', 4, 'uom', 'C62'),
      jsonb_build_object('item', v_sugar, 'quantity', 3, 'uom', 'C62')),
    'Monday run');
  perform public.send_stock_transfer(v_t);

  select l.id into v_fline from public.stock_transfer_lines l
   where l.transfer_id = v_t and l.item_id = v_flour;

  perform pg_temp.check_eq('the van took the early flour first',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_line_id = v_fline and m.quantity < 0
        and sml.lot_id = v_f_early), -2);
  perform pg_temp.check_eq('and made up the rest from the later batch',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_line_id = v_fline and m.quantity < 0
        and sml.lot_id = v_f_late), -2);

  -- THREE OF THE FOUR ARRIVE. What is left behind is the shortfall the
  -- receipt writes off, and what arrives is taken from the batches the
  -- van carried, earliest-expiry first -- because the shop will sell it
  -- in that order too.
  perform public.receive_stock_transfer(v_t, jsonb_build_array(
    jsonb_build_object('line', v_fline, 'quantity', 3)));

  select m.id into v_arrival from public.stock_movements m
   where m.source_line_id = v_fline and m.quantity > 0;

  perform pg_temp.check_eq(
    'the whole of the early batch arrived, because it goes off first',
    pg_temp.la_on(v_arrival, v_f_early), 2);
  perform pg_temp.check_eq('and one of the later one made up the count',
    pg_temp.la_on(v_arrival, v_f_late), 1);
  perform pg_temp.check_eq(
    'and not a grain of the sugar on the same van -- a line arrives '
    'carrying its own line''s batches',
    pg_temp.la_on(v_arrival, v_s_lot), 0);
  perform pg_temp.check_eq('three arrived in all',
    (select coalesce(sum(sml.quantity), 0)
       from public.stock_movement_lots sml
      where sml.movement_id = v_arrival), 3);

  -- THE RULE THE `m.quantity < 0` ON THAT LOOKUP LEANS ON. It cannot be
  -- observed: a transfer line is received once, so there is one arrival
  -- and it is the row being written -- whose own lots do not exist yet
  -- when this runs. Dropping the condition therefore reads nothing
  -- extra.
  perform pg_temp.check_eq('a transfer line arrives once',
    (select count(*) from public.stock_movements m
      where m.source_line_id = v_fline and m.quantity > 0), 1);
end $$;

-- =====================================================================
-- 7. Two rules the first loop leans on
-- =====================================================================
do $$
begin
  -- The first loop reads `document_line_lots` through three arms, each
  -- pairing a source table with its own column. Deleting the source
  -- table from an arm changes no answer, because the three columns are
  -- foreign keys to three different tables and a line id from one is
  -- never a line id from another. So the keys are asserted instead of
  -- the arms.
  -- An item always says how it is tracked, so `v_track is null` cannot
  -- happen: the column is NOT NULL and defaults to 'none'. The null arm
  -- is a belt on a pair of braces, and what is asserted is the braces.
  perform pg_temp.check_eq('an item always says how it is tracked',
    (select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'items'
        and column_name = 'tracking'), 'NO');
  perform pg_temp.check_eq('and says none when it is not',
    (select column_default from information_schema.columns
      where table_schema = 'public' and table_name = 'items'
        and column_name = 'tracking'), '''none''::text');

  perform pg_temp.check_true(
    'a document line lot names one kind of line, and a foreign key on '
    'each of the three columns says which -- so a line id from one of '
    'those tables is never a line id from another, and an arm that '
    'reads the wrong column finds nothing rather than the wrong thing',
    (select count(distinct confrelid) from pg_constraint
      where conrelid = 'public.document_line_lots'::regclass
        and contype = 'f'
        and confrelid in ('public.sales_document_lines'::regclass,
                          'public.purchase_document_lines'::regclass,
                          'public.stock_adjustment_lines'::regclass)) = 3);
end $$;

rollback;

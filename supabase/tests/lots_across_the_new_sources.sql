-- =====================================================================
-- The batch a recipe took, the batch that went in the van, and the
-- batch a chicken's pieces belong to
--
-- 0106 promised that a tracked item has every unit of every movement
-- named, and enforced it. 0264 and 0265 then wrote movements from three
-- places it had never heard of. This file is the regression that would
-- have caught it, plus the behaviour that replaced the raise.
--
-- The first block is the bug itself, written as the thing that used to
-- fail: a batch-tracked ingredient, a recipe, and a customer who has
-- already paid. Before 0267 that raised inside the completion trigger
-- and took the whole settled sale down with it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_kitchen uuid;
  v_shop   uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;

  v_milk   uuid;   -- batch tracked, and an ingredient
  v_rice   uuid;   -- untracked, and an ingredient
  v_dish   uuid;
  v_chicken uuid;  -- batch tracked, and cut up
  v_breast uuid;
  v_wing   uuid;

  v_bill   uuid;
  v_bline  uuid;
  v_sale   uuid;
  v_t      uuid;
  v_conv   uuid;
  v_line   uuid;
  v_msg    text;
  v_n      numeric;
  v_doc    uuid;
begin
  v_org := pg_temp.test_org('Dapur Batch Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Central kitchen', true) returning id into v_kitchen;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'KEDAI', 'The shop') returning id into v_shop;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price, tracking)
  values (v_org, 'SANTAN', 'Santan', 'stock', true, 'LTR', 6.00, 'batch')
  returning id into v_milk;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'BERAS', 'Beras', 'stock', true, 'KGM', 4.00)
  returning id into v_rice;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00)
  returning id into v_dish;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price, tracking)
  values (v_org, 'AYAM', 'Ayam sebiji', 'stock', true, 'C62', 12.00, 'batch')
  returning id into v_chicken;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, tracking)
  values (v_org, 'DADA', 'Dada ayam', 'stock', true, 'C62', 'batch')
  returning id into v_breast;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, tracking)
  values (v_org, 'KEPAK', 'Kepak ayam', 'stock', true, 'C62', 'batch')
  returning id into v_wing;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_kitchen, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id) values (v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;
  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- Batched stock in, the only way a tracked item can arrive: a bill
  -- that names its batches.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_walkin, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_milk, 'Santan', 10, 'LTR', 6.00, v_kitchen)
  returning id into v_bline;
  perform public.set_line_lots('purchase_document_lines', v_bline,
    '[{"lot_ref":"S-MAR","quantity":4,"expiry_date":"2026-09-30"},
      {"lot_ref":"S-APR","quantity":6,"expiry_date":"2026-12-31"}]'::jsonb);

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 2, 'item', v_chicken, 'Ayam', 10, 'C62', 12.00, v_kitchen)
  returning id into v_line;
  perform public.set_line_lots('purchase_document_lines', v_line,
    '[{"lot_ref":"A-2891","quantity":10,"expiry_date":"2026-09-01"}]'::jsonb);

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 3, 'item', v_rice, 'Beras', 100, 'KGM', 4.00, v_kitchen);

  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('two batches of santan are on hand',
    (select sum(b.quantity) from public.v_lot_balances b where b.item_id = v_milk),
    10::numeric);

  -- ------------------------------------------------------------------
  -- 1. The bug: a recipe with a batch-tracked ingredient
  -- ------------------------------------------------------------------
  -- 180g of rice and 40ml of santan per plate.
  perform public.upsert_pos_recipe(v_org, v_dish, 1, jsonb_build_array(
    jsonb_build_object('item', v_rice, 'quantity', 180, 'uom', 'GRM'),
    jsonb_build_object('item', v_milk, 'quantity', 40,  'uom', 'MLT')));

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_dish, 2, 12.00);

  -- Before 0267 this raised inside the completion trigger, after the
  -- invoice was posted and the money taken.
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 24.00)));

  perform pg_temp.check_eq('a settled sale completes with a batched ingredient',
    (select s.status::text from public.pos_sales s where s.id = v_sale),
    'completed');
  perform pg_temp.check_eq('and 80ml of santan left the store',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_milk and sl.warehouse_id = v_kitchen),
    9.92::numeric);

  -- Taken from the batch that goes off first, which is the rule a
  -- kitchen already follows.
  perform pg_temp.check_eq('out of the batch that expires first',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_milk and b.lot_ref = 'S-MAR'), 3.92::numeric);
  perform pg_temp.check_eq('leaving the later one untouched',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_milk and b.lot_ref = 'S-APR'), 6::numeric);
  perform pg_temp.check_eq('and every unit of the movement is named',
    (select round(sum(sml.quantity), 4)
       from public.stock_movement_lots sml
       join public.stock_movements m on m.id = sml.movement_id
      where m.source_table = 'pos_sales' and m.item_id = v_milk),
    -0.08::numeric);

  -- ------------------------------------------------------------------
  -- 2. A recipe cannot take more batch than there is
  -- ------------------------------------------------------------------
  -- Empty the santan down to a tenth of a litre and sell ten plates,
  -- which would want 0.4.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'bill', 'BILL-X', current_date, v_walkin, 'MYR', 1, 'draft')
  returning id into v_doc;

  perform pg_temp.check_true('there is santan to run down',
    (select sum(b.quantity) from public.v_lot_balances b
      where b.item_id = v_milk) > 9);

  -- Sell almost all of it: 245 plates is 9.8 litres.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_dish, 245, 12.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 2940.00)));

  perform pg_temp.check_eq('which leaves a tenth of a litre',
    (select round(sum(b.quantity), 4) from public.v_lot_balances b
      where b.item_id = v_milk), 0.12::numeric);

  -- Now ten more plates, wanting 0.4 and finding 0.12.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_dish, 10, 12.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 120.00)));

  perform pg_temp.check_eq('the sale still completes',
    (select s.status::text from public.pos_sales s where s.id = v_sale),
    'completed');
  perform pg_temp.check_eq(
    'the batch is emptied and not taken past nothing',
    (select round(coalesce(sum(b.quantity), 0), 4) from public.v_lot_balances b
      where b.item_id = v_milk), 0::numeric);
  perform pg_temp.check_true(
    'while the untracked rice goes wherever the recipe says',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_kitchen) < 100);

  -- ------------------------------------------------------------------
  -- 3. A batch that goes in the van keeps its name and its date
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_chicken, 'quantity', 4, 'uom', 'C62')));
  perform public.send_stock_transfer(v_t);
  select l.id into v_line from public.stock_transfer_lines l where l.transfer_id = v_t;
  perform public.receive_stock_transfer(v_t);

  perform pg_temp.check_eq('the shop has four of them',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_chicken and sl.warehouse_id = v_shop), 4::numeric);
  perform pg_temp.check_eq('under the batch they left the kitchen as',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_chicken and b.warehouse_id = v_shop
        and b.lot_ref = 'A-2891'), 4::numeric);
  perform pg_temp.check_true('carrying the expiry date across the journey',
    (select l.expiry_date from public.stock_lots l
      where l.item_id = v_chicken and l.lot_ref = 'A-2891')
      = date '2026-09-01');
  perform pg_temp.check_eq('and the kitchen is down to six',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_chicken and b.warehouse_id = v_kitchen
        and b.lot_ref = 'A-2891'), 6::numeric);

  -- A short delivery leaves the difference behind rather than
  -- inventing a batch for it.
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_chicken, 'quantity', 4, 'uom', 'C62')));
  perform public.send_stock_transfer(v_t);
  select l.id into v_line from public.stock_transfer_lines l where l.transfer_id = v_t;
  perform public.receive_stock_transfer(v_t,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 3)));

  perform pg_temp.check_eq('three of the four arrive',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_chicken and b.warehouse_id = v_shop
        and b.lot_ref = 'A-2891'), 7::numeric);
  perform pg_temp.check_eq('and the company is one chicken lighter',
    (select round(sum(b.quantity), 4) from public.v_lot_balances b
      where b.item_id = v_chicken), 9::numeric);

  -- And it will not ship a batch it has not got.
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_chicken, 'quantity', 50, 'uom', 'C62')));
  begin
    perform public.send_stock_transfer(v_t);
    perform pg_temp.check_true('a van cannot carry a batch nobody has', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a van cannot carry a batch nobody has',
      v_msg like '%not that much%' or v_msg like '%batch nobody has%');
  end;

  -- ------------------------------------------------------------------
  -- 4. The pieces of one chicken are that chicken
  -- ------------------------------------------------------------------
  v_conv := public.upsert_item_conversion(
    null, v_org, 'AYAM2', 'Potong ayam', v_chicken, 1, 'C62',
    jsonb_build_array(
      jsonb_build_object('item', v_breast, 'quantity', 2, 'share', 70),
      jsonb_build_object('item', v_wing,   'quantity', 2, 'share', 30)));

  perform public.run_item_conversion(v_conv, 2, v_kitchen);

  perform pg_temp.check_eq('four breasts arrive',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_breast and sl.warehouse_id = v_kitchen), 4::numeric);
  perform pg_temp.check_eq('under the batch of the chicken they came off',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_breast and b.lot_ref = 'A-2891'), 4::numeric);
  perform pg_temp.check_true('with that chicken''s expiry date on them',
    (select l.expiry_date from public.stock_lots l
      where l.item_id = v_breast and l.lot_ref = 'A-2891')
      = date '2026-09-01');
  perform pg_temp.check_eq('and the wings too',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_wing and b.lot_ref = 'A-2891'), 4::numeric);

  raise notice 'ok   lots_across_the_new_sources';
end $$;

rollback;

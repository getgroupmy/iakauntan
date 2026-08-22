-- =====================================================================
-- Crediting an invoice, and the ingredients that come back with it
--
-- Two things, and the second is the one that was quietly wrong.
--
--   1. A credit note now knows which invoice it credits. Nothing has
--      ever written `original_invoice_id` — it has existed since 0005
--      and no migration, no Dart and no edge function has ever set it —
--      so a credit note has been a document floating free of the sale
--      it reverses. Without the link nothing can be capped, reported or
--      traced.
--
--   2. A credited plate puts its ingredients back, at the price they
--      left at, into the batches they came out of, and never more than
--      went out. Before this the rice stayed gone and the food cost
--      stayed charged against a sale that did not happen.
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
  v_wh     uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;

  v_rice   uuid;
  v_milk   uuid;   -- batch tracked
  v_dish   uuid;

  v_bill   uuid;
  v_bline  uuid;
  v_sale   uuid;
  v_inv    uuid;
  v_note   uuid;
  v_line   uuid;
  v_r      record;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Warung Pulang Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Kitchen', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'BERAS', 'Beras', 'stock', true, 'KGM', 4.00)
  returning id into v_rice;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price, tracking)
  values (v_org, 'SANTAN', 'Santan', 'stock', true, 'LTR', 6.00, 'batch')
  returning id into v_milk;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00)
  returning id into v_dish;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;
  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- Rice straight in; santan through a bill so it carries a batch.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'OB-1', current_date, 'opening_balance', v_rice, v_wh, 100, 4.00);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_walkin, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_milk, 'Santan', 10, 'LTR', 6.00, v_wh)
  returning id into v_bline;
  perform public.set_line_lots('purchase_document_lines', v_bline,
    '[{"lot_ref":"S-MAR","quantity":4,"expiry_date":"2026-09-30"},
      {"lot_ref":"S-APR","quantity":6,"expiry_date":"2026-12-31"}]'::jsonb);
  perform public.post_purchase_document(v_bill);

  -- 180g rice and 40ml santan a plate.
  perform public.upsert_pos_recipe(v_org, v_dish, 1, jsonb_build_array(
    jsonb_build_object('item', v_rice, 'quantity', 180, 'uom', 'GRM'),
    jsonb_build_object('item', v_milk, 'quantity', 40,  'uom', 'MLT')));

  -- ------------------------------------------------------------------
  -- 1. Two plates sold
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_dish, 2, 12.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 24.00)));

  select s.invoice_id into v_inv from public.pos_sales s where s.id = v_sale;

  perform pg_temp.check_eq('two plates took 360g of rice',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 99.64::numeric);
  perform pg_temp.check_eq('and 80ml of santan, off the earlier batch',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_milk and b.lot_ref = 'S-MAR'), 3.92::numeric);

  -- ------------------------------------------------------------------
  -- 2. The link that never existed
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('nothing is credited yet',
    (select r.credited from public.invoice_credit_remaining(v_inv) r), 0::numeric);
  perform pg_temp.check_eq('and both plates are creditable',
    (select r.remaining from public.invoice_credit_remaining(v_inv) r), 2::numeric);

  select r.line_id into v_line from public.invoice_credit_remaining(v_inv) r;

  -- More than was sold is refused rather than rounded away.
  begin
    perform public.credit_sales_invoice(v_inv,
      jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 5)));
    perform pg_temp.check_true('more cannot be credited than was sold', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'more cannot be credited than was sold, and it says so plainly',
      v_msg like '%invent a return%');
  end;

  v_note := public.credit_sales_invoice(v_inv,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 1)),
    'Customer sent it back');

  perform pg_temp.check_eq('a credit note now names the invoice it credits',
    (select d.original_invoice_id from public.sales_documents d
      where d.id = v_note), v_inv);
  perform pg_temp.check_eq('and it is posted',
    (select d.status::text from public.sales_documents d where d.id = v_note),
    'posted');
  perform pg_temp.check_eq('for one plate',
    (select l.quantity from public.sales_document_lines l
      where l.document_id = v_note), 1::numeric);
  perform pg_temp.check_eq('leaving one still creditable',
    (select r.remaining from public.invoice_credit_remaining(v_inv) r),
    1::numeric);

  -- ------------------------------------------------------------------
  -- 3. And the rice comes back
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('one plate of rice is back on the shelf',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 99.82::numeric);
  perform pg_temp.check_eq('at the price it left at, so the average holds',
    (select round(i.average_cost, 4) from public.items i where i.id = v_rice),
    4.00::numeric);
  perform pg_temp.check_eq('and the santan too',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_milk and sl.warehouse_id = v_wh), 9.96::numeric);
  perform pg_temp.check_eq('into the batch it came out of',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_milk and b.lot_ref = 'S-MAR'), 3.96::numeric);
  perform pg_temp.check_eq('and not into the one it did not',
    (select round(b.quantity, 4) from public.v_lot_balances b
      where b.item_id = v_milk and b.lot_ref = 'S-APR'), 6::numeric);

  -- The ledger. Two plates cost 1.92 in food; one came back, so 0.96
  -- of cost of sales is released and 0.96 is left charged against the
  -- plate the customer ate.
  perform pg_temp.check_eq('the returning plate releases its food cost',
    (select round(sum(gl.credit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_table = 'pos_sales' and e.source_id = v_sale
        and a.code = '5200'), 0.96::numeric);
  perform pg_temp.check_eq('leaving the eaten one still charged',
    (select round(sum(gl.debit - gl.credit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_table = 'pos_sales' and e.source_id = v_sale
        and a.code = '5200'), 0.96::numeric);
  perform pg_temp.check_eq('and the same value back into inventory',
    (select round(sum(gl.debit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_table = 'pos_sales' and e.source_id = v_sale
        and a.code = '1310'), 0.96::numeric);

  -- ------------------------------------------------------------------
  -- 4. Never more than went out
  -- ------------------------------------------------------------------
  v_note := public.credit_sales_invoice(v_inv);
  perform pg_temp.check_eq('crediting the rest takes the second plate',
    (select l.quantity from public.sales_document_lines l
      where l.document_id = v_note), 1::numeric);
  perform pg_temp.check_eq('and every grain of rice is back',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 100::numeric);
  perform pg_temp.check_eq('and all the santan',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_milk and sl.warehouse_id = v_wh), 10::numeric);
  perform pg_temp.check_eq('the food cost nets to nothing',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_table = 'pos_sales' and e.source_id = v_sale
        and a.code = '5200'), 0::numeric);

  -- A third credit note has nothing left to credit.
  begin
    perform public.credit_sales_invoice(v_inv);
    perform pg_temp.check_true('and there is nothing left to credit', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and there is nothing left to credit',
      v_msg like '%nothing left to credit%');
  end;

  perform pg_temp.check_eq(
    'so the store is exactly where it started, not further',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 100::numeric);

  -- ------------------------------------------------------------------
  -- 5. What is not a counter sale is left alone
  -- ------------------------------------------------------------------
  -- An ordinary invoice, credited, must post its ordinary reversal and
  -- move no ingredients: there is no recipe and no sale behind it.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-ZZ', current_date, current_date, v_walkin,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_rice, 'Beras', 5, 'KGM', 6.00, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('an ordinary invoice moves its own stock',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 95::numeric);

  v_note := public.credit_sales_invoice(v_inv);
  perform pg_temp.check_eq(
    'and crediting it returns that stock the way it always did',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_wh), 100::numeric);
  perform pg_temp.check_eq('with no recipe movement invented for it',
    (select count(*)::integer from public.stock_movements sm
      where sm.source_table = 'pos_sales' and sm.source_line_id = v_note), 0);

  raise notice 'ok   credit_note_return';
end $$;

rollback;

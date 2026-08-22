-- =====================================================================
-- The gift set that is six other things
--
-- One assertion matters more than the rest: selling a bundle takes its
-- parts off the shelf and books their cost. `item_type = 'bundle'` has
-- existed since 0003 with nothing behind it, and because a bundle keeps
-- no stock of its own, `post_sales_document` skipped the line entirely
-- — so a shop selling a hundred gift sets moved nothing and booked no
-- cost of sale at all. The margin on those hundred was the whole
-- selling price.
--
-- The rest: the parts costing what they are carried at, a credit note
-- putting them back, a batch-tracked part being picked earliest-expiry
-- first through the one source this migration adds, a bundle that keeps
-- its own stock being refused, and a bundle that ends up containing
-- itself being refused.
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
  v_cust   uuid;
  v_sup    uuid;

  v_mug    uuid;   -- a part, plain
  v_tin    uuid;   -- a part, batch tracked
  v_spoon  uuid;   -- a part
  v_set    uuid;   -- the bundle
  v_inner  uuid;   -- a bundle inside the bundle

  v_bill   uuid;
  v_inv    uuid;
  v_cn     uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Hadiah Raya Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','sales','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A gift shop', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A supplier', 'supplier') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'MUG', 'A mug', 'stock', true, 'C62', 12)
  returning id into v_mug;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'TIN', 'Biscuit tin', 'stock', true, 'C62', 20)
  returning id into v_tin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SPOON', 'A spoon', 'stock', true, 'C62', 4)
  returning id into v_spoon;

  -- The bundle itself holds no stock: its parts do.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SET', 'Raya gift set', 'non_stock', false, 'C62', 60)
  returning id into v_set;

  -- Buy the parts: mugs at 10, tins at 15, spoons at 2.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_mug,   'Mugs',   100, 10, v_wh),
         (v_org, v_bill, 2, 'item', v_tin,   'Tins',   100, 15, v_wh),
         (v_org, v_bill, 3, 'item', v_spoon, 'Spoons', 200,  2, v_wh);
  perform public.post_purchase_document(v_bill);

  -- ------------------------------------------------------------------
  -- 1. Defining one
  -- ------------------------------------------------------------------
  perform public.upsert_item_bundle(v_org, v_set, jsonb_build_array(
    jsonb_build_object('item', v_mug,   'quantity', 1),
    jsonb_build_object('item', v_tin,   'quantity', 1),
    jsonb_build_object('item', v_spoon, 'quantity', 2)));

  perform pg_temp.check_eq('the item is a bundle now, and says so',
    (select i.item_type from public.items i where i.id = v_set), 'bundle');
  perform pg_temp.check_eq('three parts',
    (select count(*) from public.item_bundle_for(v_set)), 3::numeric);
  -- A mug at 10, a tin at 15, two spoons at 2.
  perform pg_temp.check_eq('and it costs what the parts are carried at',
    (select round(sum(b.line_cost), 2)
       from public.item_bundle_for(v_set) b),
    29::numeric);
  perform pg_temp.check_eq('which leaves thirty-one on a sixty ringgit set',
    (select m.margin from public.bundle_margin(v_set) m), 31::numeric);
  -- A hundred mugs, a hundred tins, two hundred spoons at two a set:
  -- every part is good for exactly a hundred sets.
  perform pg_temp.check_eq('a hundred sets can be made out of what is there',
    (select a.can_make from public.bundle_availability(v_set, v_wh) a),
    100::numeric);

  -- ------------------------------------------------------------------
  -- 2. The assertion this migration is built around
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_set, 'Ten gift sets', 10, 60, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('ten mugs left the shelf',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_mug),
    90::numeric);
  perform pg_temp.check_eq('ten tins',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    90::numeric);
  perform pg_temp.check_eq('and twenty spoons, because a set holds two',
    (select round(i.quantity_on_hand, 4) from public.items i
      where i.id = v_spoon), 180::numeric);
  perform pg_temp.check_eq('the bundle itself moved nothing, having none',
    (select count(*) from public.stock_movements sm where sm.item_id = v_set),
    0::numeric);

  -- Ten sets at twenty-nine.
  perform pg_temp.check_eq('the cost of sale is what the parts cost',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.gl_entries e on e.id = gl.entry_id
      join public.accounts a on a.id = gl.account_id
     where e.source_id = v_inv and a.code = '5200'), 290::numeric);
  perform pg_temp.check_eq('and inventory is relieved of the same',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.gl_entries e on e.id = gl.entry_id
      join public.accounts a on a.id = gl.account_id
     where e.source_id = v_inv and a.code = '1310'), 290::numeric);
  perform pg_temp.check_eq('the customer is billed for the set, not the parts',
    (select d.total_amount from public.sales_documents d where d.id = v_inv),
    600::numeric);

  -- ------------------------------------------------------------------
  -- 3. A credit note puts the parts back
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, original_invoice_id)
  values (v_org, 'credit_note', 'CN-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft', v_inv)
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_cn, 1, 'item', v_set, 'Two came back', 2, 60, v_wh);
  perform public.post_sales_document(v_cn);

  perform pg_temp.check_eq('two mugs are back',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_mug),
    92::numeric);
  perform pg_temp.check_eq('and four spoons with them',
    (select round(i.quantity_on_hand, 4) from public.items i
      where i.id = v_spoon), 184::numeric);
  perform pg_temp.check_eq('the cost of sale is credited back',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.gl_entries e on e.id = gl.entry_id
      join public.accounts a on a.id = gl.account_id
     where e.source_id = v_cn and a.code = '5200'), 58::numeric);

  -- ------------------------------------------------------------------
  -- 4. A batch-tracked part, picked earliest expiry first
  -- ------------------------------------------------------------------
  --
  -- The one arm this migration adds to the lot invariant. Without it a
  -- tracked part inside a bundle raises and the whole invoice fails.
  update public.items set tracking = 'batch' where id = v_tin;
  insert into public.stock_lots (org_id, item_id, lot_ref, kind, expiry_date)
  values (v_org, v_tin, 'OLD', 'batch', current_date + 30),
         (v_org, v_tin, 'NEW', 'batch', current_date + 300);
  insert into public.stock_movement_lots (org_id, movement_id, lot_id, quantity)
  select v_org, sm.id, l.id, 90
    from public.stock_movements sm
    join public.stock_lots l on l.item_id = sm.item_id and l.lot_ref = 'OLD'
   where sm.item_id = v_tin and sm.source_id = v_bill;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_set, 'Five more', 5, 60, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq(
    'a batch-tracked part inside a bundle comes off a named batch',
    (select count(*) from public.stock_movement_lots sml
      join public.stock_movements sm on sm.id = sml.movement_id
     where sm.source_table = 'sales_bundles' and sm.source_id = v_inv),
    1::numeric);
  perform pg_temp.check_eq('and it is the one that expires first',
    (select l.lot_ref from public.stock_movement_lots sml
      join public.stock_movements sm on sm.id = sml.movement_id
      join public.stock_lots l on l.id = sml.lot_id
     where sm.source_table = 'sales_bundles' and sm.source_id = v_inv),
    'OLD');

  -- ------------------------------------------------------------------
  -- 5. A bundle inside a bundle
  -- ------------------------------------------------------------------
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'INNER', 'Mug and spoon', 'non_stock', false, 'C62', 18)
  returning id into v_inner;
  perform public.upsert_item_bundle(v_org, v_inner, jsonb_build_array(
    jsonb_build_object('item', v_mug,   'quantity', 1),
    jsonb_build_object('item', v_spoon, 'quantity', 1)));

  -- And the outer one containing it: the explosion has to reach the
  -- mug and the spoon, not stop at the inner bundle.
  perform public.upsert_item_bundle(v_org, v_set, jsonb_build_array(
    jsonb_build_object('item', v_inner, 'quantity', 1),
    jsonb_build_object('item', v_tin,   'quantity', 1),
    jsonb_build_object('item', v_spoon, 'quantity', 1)));

  perform pg_temp.check_eq(
    'the explosion reaches through the inner bundle to the parts',
    (select count(*) from public.item_bundle_for(v_set)), 3::numeric);
  perform pg_temp.check_eq('and adds the spoons from both levels',
    (select b.quantity from public.item_bundle_for(v_set) b
      where b.code = 'SPOON'), 2::numeric);

  -- ------------------------------------------------------------------
  -- 6. What it refuses
  -- ------------------------------------------------------------------
  begin
    perform public.upsert_item_bundle(v_org, v_inner, jsonb_build_array(
      jsonb_build_object('item', v_set, 'quantity', 1)));
    perform pg_temp.check_true('a bundle can contain itself round a loop', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a bundle that ends up inside itself is refused',
      v_msg like '%a part of itself%');
  end;

  begin
    perform public.upsert_item_bundle(v_org, v_mug, jsonb_build_array(
      jsonb_build_object('item', v_spoon, 'quantity', 1)));
    perform pg_temp.check_true('an item that keeps stock can be a bundle', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'an item that keeps its own stock would come off the shelf twice',
      v_msg like '%off the shelf twice%');
  end;

  begin
    perform public.upsert_item_bundle(v_org, v_set, '[]'::jsonb);
    perform pg_temp.check_true('an empty bundle is a bundle', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a bundle with nothing in it is not one',
      v_msg like '%is an ordinary item%');
  end;

  begin
    perform public.upsert_item_bundle(v_org, v_set, jsonb_build_array(
      jsonb_build_object('item', v_mug, 'quantity', 0)));
    perform pg_temp.check_true('a part of nothing is a part', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a part has to be some of something',
      v_msg like '%some of something%');
  end;

  perform pg_temp.check_eq('and the list finds them',
    (select count(*) from public.item_bundles_list(v_org)), 2::numeric);

  raise notice 'ok   item_bundles';
end $$;

rollback;

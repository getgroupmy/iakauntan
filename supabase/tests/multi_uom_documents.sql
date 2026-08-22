-- =====================================================================
-- Sell in cartons, stock in pieces
--
-- One assertion matters more than the rest, and it is the purchase
-- unit cost. Buying two cartons of twenty-four for RM 480 puts
-- forty-eight pieces on the shelf at RM 10 each. Dividing the money by
-- the *carton* count would make it RM 240 each, and a weighted average
-- that is out by the pack size poisons the cost of every subsequent
-- sale of that item — silently, and for as long as the item exists.
--
-- The rest: the money is per the line's own unit and does not convert,
-- the stock is per piece and does, and a unit nobody has defined is
-- refused while somebody is still typing.
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
  v_tin    uuid;   -- stocked in pieces, bought by the carton
  v_rice   uuid;   -- stocked in kilograms, bought by the sack

  v_bill   uuid;
  v_inv    uuid;
  v_line   uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Pemborong Kotak Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A customer', 'customer') returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'MILO', 'Milo tin', 'stock', true, 'C62', 18.50)
  returning id into v_tin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'BERAS', 'Beras', 'stock', true, 'KGM', 6.00)
  returning id into v_rice;

  -- A carton of this shop's Milo is twenty-four.
  perform public.upsert_item_uom_pack(v_tin, 'CT', 24);

  -- ------------------------------------------------------------------
  -- 1. The line converts when it is saved
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_bill;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_tin, 'Milo by the carton',
          2, 'CT', 240.00, v_wh)
  returning id into v_line;

  perform pg_temp.check_eq('two cartons is forty-eight pieces',
    (select l.base_quantity from public.purchase_document_lines l
      where l.id = v_line), 48::numeric);
  perform pg_temp.check_eq('while the line still says two cartons',
    (select l.quantity from public.purchase_document_lines l
      where l.id = v_line), 2::numeric);
  perform pg_temp.check_eq(
    'and the money is per carton, which is what the supplier billed',
    (select l.line_total from public.purchase_document_lines l
      where l.id = v_line), 480::numeric);

  -- ------------------------------------------------------------------
  -- 2. The assertion this migration is built around
  -- ------------------------------------------------------------------
  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('forty-eight tins arrive on the shelf',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    48::numeric);
  perform pg_temp.check_eq(
    'at ten ringgit each, not two hundred and forty',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tin),
    10::numeric);
  perform pg_temp.check_eq('the movement is in pieces too',
    (select round(sm.quantity, 4) from public.stock_movements sm
      where sm.source_id = v_bill and sm.item_id = v_tin), 48::numeric);
  perform pg_temp.check_eq('and the stock is worth what was paid for it',
    (select round(sl.value, 2) from public.stock_levels sl
      where sl.item_id = v_tin and sl.warehouse_id = v_wh), 480::numeric);

  -- ------------------------------------------------------------------
  -- 3. Selling by the piece out of what was bought by the carton
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_tin, 'Milo', 10, 'C62', 18.50, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('ten tins leave',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    38::numeric);
  perform pg_temp.check_eq('costing ten ringgit each',
    (select round(sum(gl.debit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_id = v_inv and a.code = '5200'), 100::numeric);

  -- ------------------------------------------------------------------
  -- 4. And selling by the carton out of the same shelf
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_tin, 'Milo', 1, 'CT', 300.00, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('a carton takes twenty-four off the shelf',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    14::numeric);
  perform pg_temp.check_eq('the customer is billed for one carton',
    (select d.total_amount from public.sales_documents d where d.id = v_inv),
    300::numeric);
  perform pg_temp.check_eq('and the cost is twenty-four pieces of it',
    (select round(sum(gl.debit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_id = v_inv and a.code = '5200'), 240::numeric);

  -- ------------------------------------------------------------------
  -- 5. A dimension converts without anybody setting a pack
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-2', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  -- The price is per the line's own unit, always. Six ringgit a kilo is
  -- six-tenths of a sen a gram, and the line is worth RM 3.00. Only the
  -- stock converts; the money is what the supplier wrote down.
  values (v_org, v_bill, 1, 'item', v_rice, 'Beras', 500, 'GRM', 0.006, v_wh);

  perform pg_temp.check_eq('500 grams into a kilogram store is half a kilo',
    (select l.base_quantity from public.purchase_document_lines l
      where l.document_id = v_bill), 0.5::numeric);
  perform pg_temp.check_eq('and the bill is for what the grams cost',
    (select d.total_amount from public.purchase_documents d where d.id = v_bill),
    3::numeric);
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('and RM 3.00 for half a kilo is RM 6.00 a kilo',
    (select round(i.average_cost, 4) from public.items i where i.id = v_rice),
    6::numeric);

  -- ------------------------------------------------------------------
  -- 6. A unit nobody has defined is refused while it is being typed
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-3', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_bill;
  begin
    insert into public.purchase_document_lines
      (org_id, document_id, line_no, line_type, item_id, description,
       quantity, uom_code, unit_price, warehouse_id)
    values (v_org, v_bill, 1, 'item', v_rice, 'Beras', 1, 'PF', 500.00, v_wh);
    perform pg_temp.check_true('a pallet of rice means nothing yet', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a pallet of rice means nothing until somebody says what one holds',
      v_msg like '%no way to turn%');
  end;

  -- And a line that is not an item needs no conversion at all.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity)
  values (v_org, v_bill, 9, 'description', 'Thank you for your business', 1);
  perform pg_temp.check_eq('a description line carries its own quantity',
    (select l.base_quantity from public.purchase_document_lines l
      where l.document_id = v_bill and l.line_no = 9), 1::numeric);

  -- ------------------------------------------------------------------
  -- 7. A pack corrected later does not rewrite what was invoiced
  -- ------------------------------------------------------------------
  perform public.upsert_item_uom_pack(v_tin, 'CT', 12);
  perform pg_temp.check_eq(
    'the bill still says the forty-eight it was posted for',
    (select l.base_quantity from public.purchase_document_lines l
      where l.id = v_line), 48::numeric);
  perform pg_temp.check_eq('and the shelf is untouched by the correction',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    14::numeric);

  -- ------------------------------------------------------------------
  -- Taking a pack size away again
  --
  -- `delete_item_uom_pack` was called by nothing. It answers with
  -- whether it removed anything rather than raising, because the screen
  -- deletes a row somebody may already have deleted on another device,
  -- and it resolves the company from the item so that a pack belonging
  -- to another company's item cannot be reached by naming it.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the pack is there to start with',
    exists (select 1 from public.item_uom_packs
             where item_id = v_tin and uom_code = 'CT'));
  perform pg_temp.check_true('deleting it says it deleted something',
    public.delete_item_uom_pack(v_tin, 'CT'));
  perform pg_temp.check_true('and it is gone',
    not exists (select 1 from public.item_uom_packs
                 where item_id = v_tin and uom_code = 'CT'));

  -- Twice is not an error. It is the second device catching up.
  perform pg_temp.check_true('deleting it again says it deleted nothing',
    not public.delete_item_uom_pack(v_tin, 'CT'));
  -- Same answer for an item nobody has, rather than a lookup failure
  -- that reads like a bug to whoever is holding the phone.
  perform pg_temp.check_true('and an item that does not exist is the same answer',
    not public.delete_item_uom_pack(gen_random_uuid(), 'CT'));

  -- The other pack is untouched, so the delete was the one named.
  perform public.upsert_item_uom_pack(v_tin, 'CT', 24);
  perform public.upsert_item_uom_pack(v_tin, 'BX', 6);
  perform pg_temp.check_true('one pack size goes without taking the other',
    public.delete_item_uom_pack(v_tin, 'BX'));
  perform pg_temp.check_eq('leaving the one that was not named',
    (select count(*) from public.item_uom_packs where item_id = v_tin), 1);

  -- Somebody outside the company cannot reach it by naming the item.
  perform pg_temp.sign_in_as(pg_temp.another_user('nosy@kotak.test'));
  begin
    perform public.delete_item_uom_pack(v_tin, 'CT');
    perform pg_temp.check_true('a stranger cannot delete a pack size', false);
  exception when sqlstate '42501' then
    perform pg_temp.check_true('a stranger cannot delete a pack size', true);
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('and it is still there',
    (select count(*) from public.item_uom_packs where item_id = v_tin), 1);

  raise notice 'ok   multi_uom_documents';
end $$;

rollback;

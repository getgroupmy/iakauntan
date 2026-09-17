-- =====================================================================
-- iAkauntan :: crediting a supplier's bill against the bill
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bill_credit.sql
--
-- `purchase_documents.original_bill_id` has been a column since `0006`,
-- declared beside `parent_id` with the same intent as the sales side's
-- `original_invoice_id`, and nothing ever wrote it. `0269` closed that
-- hole one table over and said why it is worse than a missing feature: a
-- credit note naming no document cannot be capped at what it reverses
-- and cannot be reported against it.
--
-- Three claims here, and the third is the one an assessment asks about:
--
--   1. The credit note names the bill, so what is left owing is
--      arithmetic rather than two lists read side by side.
--   2. Crediting more than was billed is refused. That is not a return,
--      it is a claim for goods the supplier never sent.
--   3. The stock goes out once. The goods are going back to the
--      supplier, and `0097`'s posting path already moves them — a second
--      movement here would take them out twice.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_wh    uuid;
  v_sup   uuid;
  v_item  uuid;
  v_bill  uuid;
  v_line  uuid;
  v_note  uuid;
  v_draft uuid;
  v_msg   text;
  v_stock numeric;
begin
  v_org := pg_temp.test_org('Pulang Barang Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Simen Sdn Bhd', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'CEMENT', 'Cement', 'stock', true, 'C62', 20.00)
  returning id into v_item;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_item, 'Cement, 50kg', 100, 'C62',
          20.00, v_wh)
  returning id into v_line;
  perform public.post_purchase_document(v_bill);

  select round(sl.quantity, 4) into v_stock from public.stock_levels sl
   where sl.item_id = v_item and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq('a hundred bags came in', v_stock, 100::numeric);

  -- ------------------------------------------------------------------
  -- The link that never existed
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('nothing is credited yet',
    (select r.credited from public.bill_credit_remaining(v_bill) r),
    0::numeric);
  perform pg_temp.check_eq('and the whole line is creditable',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    100::numeric);

  -- More than was billed is a claim for goods that were never sent.
  begin
    perform public.credit_purchase_bill(v_bill,
      jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 150)));
    perform pg_temp.check_true('more cannot be credited than was billed',
      false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'more cannot be credited than was billed, and it says why',
      v_msg like '%never sent%');
  end;
  -- And the refusal left nothing behind: the raise unwinds the note row
  -- inserted before the loop. Asserted as the outcome rather than as a
  -- delete, because the delete would be dead code — see the migration.
  perform pg_temp.check_eq('and the refusal leaves no half-built note',
    (select count(*) from public.purchase_documents d
      where d.org_id = v_org and d.doc_type = 'purchase_credit_note'),
    0);

  -- A credit note somebody typed by hand and has not posted. It can
  -- exist: `0160` gave purchase_credit_note a row in the document table,
  -- so the generic editor raises one. It must not reduce what is left
  -- creditable — a draft is a document that may never be posted, and
  -- counting it would let a typed draft block a real return.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, original_bill_id)
  values (v_org, 'purchase_credit_note', 'PCN-DRAFT', current_date, v_sup,
          'MYR', 1, 'draft', v_bill)
  returning id into v_draft;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_draft, 1, 'item', v_item, 'Cement, 50kg', 100, 'C62',
          20.00, v_wh);
  perform pg_temp.check_eq('a draft credit note credits nothing yet',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    100::numeric);
  delete from public.purchase_documents where id = v_draft;

  v_note := public.credit_purchase_bill(v_bill,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 20)),
    'Twenty bags split in transit');

  perform pg_temp.check_eq('a credit note now names the bill it credits',
    (select d.original_bill_id from public.purchase_documents d
      where d.id = v_note), v_bill);
  perform pg_temp.check_eq('and it is posted',
    (select d.status::text from public.purchase_documents d where d.id = v_note),
    'posted');
  perform pg_temp.check_eq('for twenty bags',
    (select l.quantity from public.purchase_document_lines l
      where l.document_id = v_note), 20::numeric);
  perform pg_temp.check_eq('leaving eighty still creditable',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    80::numeric);
  perform pg_temp.check_eq('with the reason kept',
    (select d.notes from public.purchase_documents d where d.id = v_note),
    'Twenty bags split in transit');

  -- ------------------------------------------------------------------
  -- The goods went back once
  -- ------------------------------------------------------------------
  select round(sl.quantity, 4) into v_stock from public.stock_levels sl
   where sl.item_id = v_item and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq('twenty bags left the store, once', v_stock,
    80::numeric);

  -- ------------------------------------------------------------------
  -- And the rest, then nothing
  -- ------------------------------------------------------------------
  perform public.credit_purchase_bill(v_bill);
  perform pg_temp.check_eq('crediting the rest takes the line to nothing',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    0::numeric);
  select round(sl.quantity, 4) into v_stock from public.stock_levels sl
   where sl.item_id = v_item and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq('and the store is back to empty', v_stock,
    0::numeric);

  begin
    perform public.credit_purchase_bill(v_bill);
    perform pg_temp.check_true('a fully credited bill has nothing left',
      false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a fully credited bill says so',
      v_msg like '%nothing left to credit%');
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Two lines for the same item are two things to credit
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_wh   uuid;
  v_sup  uuid;
  v_item uuid;
  v_bill uuid;
  v_a    uuid;
  v_b    uuid;
  -- Named `v_r` rather than `r`: a record variable called `r` shadows a
  -- table alias `r` in the where clause, and the row is silently never
  -- assigned.
  v_r    record;
begin
  v_org := pg_temp.test_org('Dua Baris Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'A supplier', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'CEMENT', 'Cement', 'stock', true, 'C62', 20.00)
  returning id into v_item;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  -- Same item, different descriptions: the good pallet and the damaged
  -- one. Collapsing them would let a credit against one exhaust the
  -- other, and the supplier is only taking the damaged pallet back.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_item, 'Cement, sound', 60, 'C62',
          20.00, v_wh)
  returning id into v_a;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 2, 'item', v_item, 'Cement, damaged', 40, 'C62',
          20.00, v_wh)
  returning id into v_b;
  perform public.post_purchase_document(v_bill);

  perform public.credit_purchase_bill(v_bill,
    jsonb_build_array(jsonb_build_object('line', v_b, 'quantity', 40)));

  select * into v_r from public.bill_credit_remaining(v_bill) r
   where r.line_id = v_a;
  perform pg_temp.check_eq('the sound pallet is untouched', v_r.remaining,
    60::numeric);
  select * into v_r from public.bill_credit_remaining(v_bill) r
   where r.line_id = v_b;
  perform pg_temp.check_eq('and the damaged one is fully credited',
    v_r.remaining, 0::numeric);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What is not a credit, and at what rate
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_wh    uuid;
  v_sup   uuid;
  v_item  uuid;
  v_bill  uuid;
  v_line  uuid;
  v_debit uuid;
  v_note  uuid;
begin
  v_org := pg_temp.test_org('Nota Debit Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'An importer', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'WIDGET', 'Widget', 'stock', true, 'C62', 10.00)
  returning id into v_item;

  -- Bought in dollars at 4.50, which is the rate the money was recorded
  -- at. A credit re-resolved at today's rate would book an FX gain on a
  -- return, every time the ringgit moved.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-USD', current_date, v_sup, 'USD', 4.50,
          'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_item, 'Widget', 10, 'C62', 10.00, v_wh)
  returning id into v_line;
  perform public.post_purchase_document(v_bill);

  -- The supplier's own debit note against the same bill: an undercharge
  -- they are billing us for. It points at the bill and it is not a
  -- credit, and counting it as one would reduce what we may return.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, original_bill_id)
  values (v_org, 'purchase_debit_note', 'PDN-1', current_date, v_sup,
          'USD', 4.50, 'posted', v_bill)
  returning id into v_debit;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_debit, 1, 'item', v_item, 'Widget', 10, 'C62', 2.00, v_wh);

  perform pg_temp.check_eq('a debit note against the bill is not a credit',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    10::numeric);

  v_note := public.credit_purchase_bill(v_bill,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 4)));
  perform pg_temp.check_eq('and the credit takes the bill''s own rate',
    (select d.exchange_rate from public.purchase_documents d
      where d.id = v_note), 4.50::numeric);
  perform pg_temp.check_eq('in the bill''s own currency',
    (select d.currency from public.purchase_documents d where d.id = v_note),
    'USD');
  perform pg_temp.check_eq('leaving six',
    (select r.remaining from public.bill_credit_remaining(v_bill) r),
    6::numeric);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('crediting a bill is closed to anon',
    not has_function_privilege('anon',
      'public.credit_purchase_bill(uuid, jsonb, text)', 'execute'));
  perform pg_temp.check_true('and reading what is left',
    not has_function_privilege('anon',
      'public.bill_credit_remaining(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may try',
    has_function_privilege('authenticated',
      'public.credit_purchase_bill(uuid, jsonb, text)', 'execute'));
end $$;

rollback;

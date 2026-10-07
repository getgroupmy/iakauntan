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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);

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
  values (v_org, 'bill', 'BILL-1', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
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
  values (v_org, 'purchase_credit_note', 'PCN-DRAFT', pg_temp.today(), v_sup,
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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
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
  values (v_org, 'bill', 'BILL-1', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
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
  values (v_org, 'bill', 'BILL-USD', pg_temp.today(), v_sup, 'USD', 4.50,
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
  values (v_org, 'purchase_debit_note', 'PDN-1', pg_temp.today(), v_sup,
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


-- ---------------------------------------------------------------------
-- The buying side, rule by rule
--
-- A sweep of `0440`'s `credit_purchase_bill` left thirteen mutants
-- alive where `credit_note_return.sql` kills every one of the selling
-- side's. Nothing here tried to credit a purchase order, a bill that is
-- not there, a draft, or a bill already paid in full (`completed`, which
-- `apply_allocation` sets and the guard has to admit); nobody without
-- the right to post tried; and no bill carried shipping, a discount, a
-- tax code or an account of its own, so a credit could drop all four.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sup uuid; v_svc uuid; v_acct uuid; v_tax uuid;
  v_bill uuid; v_line uuid; v_note uuid; v_po uuid; v_draft uuid;
  v_whole uuid; v_whole_note uuid; v_paid uuid; v_other uuid;
begin
  v_org := pg_temp.test_org('Kredit Pembekal Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'Servis', 'service', false, 'C62', 20.00)
  returning id into v_svc;
  select id into v_acct from public.accounts
   where org_id = v_org and code = '6100';
  insert into public.tax_codes (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'SV6K', 'Service tax 6%', '02', 6, 'purchase')
  returning id into v_tax;

  -- 40 at 20 = 800, carrying RM100 shipping and a RM40 discount, taxed
  -- and charged to an account of the line's own.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, shipping_amount, discount_amount)
  values (v_org, 'bill', 'BILL-K', pg_temp.today(), v_sup, 'MYR', 1, 'draft',
          100, 40)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
  values (v_org, v_bill, 1, 'item', v_svc, 'Servis bulanan', 40, 'C62',
          20.00, v_tax, (select rate from public.tax_codes where id = v_tax),
          v_acct)
  returning id into v_line;
  perform public.post_purchase_document(v_bill);

  -- A quarter of it back.
  v_note := public.credit_purchase_bill(v_bill,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 10)));
  perform pg_temp.check_true('a credit line keeps the bill''s price',
    (select unit_price = 20.00 from public.purchase_document_lines
      where document_id = v_note));
  perform pg_temp.check_true('and its tax',
    (select tax_code_id = v_tax and tax_rate > 0
       from public.purchase_document_lines where document_id = v_note));
  perform pg_temp.check_true('and the account it was charged to',
    (select account_id = v_acct from public.purchase_document_lines
      where document_id = v_note));
  perform pg_temp.check_eq('a quarter of the goods takes a quarter of the shipping',
    (select shipping_amount from public.purchase_documents where id = v_note), 25.00);
  perform pg_temp.check_eq('and a quarter of the discount',
    (select discount_amount from public.purchase_documents where id = v_note), 10.00);

  -- The whole of a second bill: the note is the bill, charges and all,
  -- which it only is if the totals were worked out AFTER the charges.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, shipping_amount, discount_amount)
  values (v_org, 'bill', 'BILL-W', pg_temp.today(), v_sup, 'MYR', 1, 'draft',
          30, 12)
  returning id into v_whole;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  values (v_org, v_whole, 1, 'item', v_svc, 'Servis', 5, 'C62', 20.00, v_acct);
  perform public.post_purchase_document(v_whole);
  v_whole_note := public.credit_purchase_bill(v_whole);
  perform pg_temp.check_eq('a whole credit comes to what the bill came to',
    (select total_amount from public.purchase_documents where id = v_whole_note),
    (select total_amount from public.purchase_documents where id = v_whole));

  -- A bill whose lines net to nothing still carried its delivery.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, shipping_amount)
  values (v_org, 'bill', 'BILL-0', pg_temp.today(), v_sup, 'MYR', 1, 'draft', 18)
  returning id into v_other;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  values (v_org, v_other, 1, 'item', v_svc, 'Percuma', 1, 'C62', 0, v_acct);
  perform public.post_purchase_document(v_other);
  -- Into a variable first: called inside a WHERE it runs once per row,
  -- and the second call finds nothing left to credit.
  v_note := public.credit_purchase_bill(v_other);
  perform pg_temp.check_eq('a free line credited whole gives back all the delivery',
    (select shipping_amount from public.purchase_documents where id = v_note), 18.00);

  -- Paid in full, and still creditable.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-P', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
  returning id into v_paid;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  values (v_org, v_paid, 1, 'item', v_svc, 'Servis', 2, 'C62', 20.00, v_acct);
  perform public.post_purchase_document(v_paid);
  update public.purchase_documents set status = 'completed' where id = v_paid;
  perform pg_temp.check_true('a bill paid in full can still be credited',
    public.credit_purchase_bill(v_paid) is not null);

  -- What is not a bill to credit.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-K', pg_temp.today(), v_sup, 'MYR', 1, 'posted')
  returning id into v_po;
  -- EQUIVALENT, for the sweep: dropping `credit_purchase_bill`'s own
  -- `doc_type = 'bill'`. `bill_credit_remaining`, which it calls before
  -- a line is written, asks the same and refuses in the same words, and
  -- the raise unwinds the note header inserted before it.
  perform pg_temp.check_refused('a purchase order is not a bill',
    format('select public.credit_purchase_bill(%L)', v_po),
    '%No such bill%', 'P0002');
  perform pg_temp.check_refused('nor is a bill that is not there',
    format('select public.credit_purchase_bill(%L)', gen_random_uuid()),
    '%No such bill%', 'P0002');
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-D', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
  returning id into v_draft;
  perform pg_temp.check_refused('a draft bill has nothing in the ledger to credit',
    format('select public.credit_purchase_bill(%L)', v_draft),
    '%That bill is draft%', '23514');
  perform pg_temp.sign_in_as(pg_temp.another_user('luar@kredit.test'));
  perform pg_temp.check_refused('and somebody without the right to post credits nothing',
    format('select public.credit_purchase_bill(%L)', v_bill),
    '%needs permission%', '42501');
  perform pg_temp.sign_out();
end $$;


-- ---------------------------------------------------------------------
-- A bill's discount comes off its costs  (0759)
--
-- Until 0759 a bill with a header discount could not be posted at all:
-- the total took the discount off what was owed and the posting put it
-- nowhere, so the journal was short by exactly the discount. It now
-- comes off the lines, by each one's share of the net, the LARGEST
-- taking what rounding leaves -- so 100.01 off 600 / 300 / 100 is 30.00
-- and 10.00 off the smaller two and 60.01 off the rent.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sup uuid; v_bill uuid; v_entry uuid; v_note uuid;
  v_rent uuid; v_util uuid; v_print uuid;
begin
  v_org := pg_temp.test_org('Diskaun Bil Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Tuan Rumah', 'supplier') returning id into v_sup;
  select id into v_rent  from public.accounts where org_id = v_org and code = '6200';
  select id into v_util  from public.accounts where org_id = v_org and code = '6210';
  select id into v_print from public.accounts where org_id = v_org and code = '6230';

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, discount_amount)
  values (v_org, 'bill', 'BILL-DSK', pg_temp.today(), v_sup, 'MYR', 1, 'draft',
          100.01)
  returning id into v_bill;
  -- Smallest first, so "the first line" and "the largest" differ.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, account_id)
  values (v_org, v_bill, 1, 'item', 'Cetak',   1, 100, v_print),
         (v_org, v_bill, 2, 'item', 'Utiliti', 1, 300, v_util),
         (v_org, v_bill, 3, 'item', 'Sewa',    1, 600, v_rent);

  v_entry := public.post_purchase_document(v_bill);
  perform pg_temp.check_true('a bill with a discount posts',
    v_entry is not null);
  -- The total is rounded to five sen and the odd sen goes to 4990, so
  -- the payable is read against the bill's own total, not 899.99.
  perform pg_temp.check_eq('owing what the bill says is owed',
    (select sum(l.credit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '2110'),
    (select total_amount from public.purchase_documents where id = v_bill));
  perform pg_temp.check_eq('which is the thousand less the discount, to five sen',
    (select total_amount from public.purchase_documents where id = v_bill), 900.00);
  perform pg_temp.check_eq('the rent, the largest, takes the sen left over',
    (select sum(debit) from public.gl_lines
      where entry_id = v_entry and account_id = v_rent), 539.99);
  perform pg_temp.check_eq('utilities their own share',
    (select sum(debit) from public.gl_lines
      where entry_id = v_entry and account_id = v_util), 270.00);
  perform pg_temp.check_eq('and printing theirs',
    (select sum(debit) from public.gl_lines
      where entry_id = v_entry and account_id = v_print), 90.00);

  -- Five sen off the same three, where rounding DOES leave something:
  -- 0.005, 0.015 and 0.03 round to 0.01, 0.02 and 0.03, which is 0.06.
  -- The largest takes what is left of the 0.05 after the other two --
  -- 0.02 -- rather than its own rounded 0.03, and nobody is short.
  declare v_small uuid; v_small_entry uuid;
  begin
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency,
       exchange_rate, status, discount_amount)
    values (v_org, 'bill', 'BILL-SEN', pg_temp.today(), v_sup, 'MYR', 1, 'draft', 0.05)
    returning id into v_small;
    insert into public.purchase_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id)
    values (v_org, v_small, 1, 'item', 'Cetak',   1, 100, v_print),
           (v_org, v_small, 2, 'item', 'Utiliti', 1, 300, v_util),
           (v_org, v_small, 3, 'item', 'Sewa',    1, 600, v_rent);
    v_small_entry := public.post_purchase_document(v_small);
    perform pg_temp.check_eq('of five sen, the rent takes the two left over',
      (select sum(debit) from public.gl_lines
        where entry_id = v_small_entry and account_id = v_rent), 599.98);
    perform pg_temp.check_eq('and printing its own one, not the remainder',
      (select sum(debit) from public.gl_lines
        where entry_id = v_small_entry and account_id = v_print), 99.99);
  end;

  -- In dollars, the discount is converted with everything else: USD10
  -- off USD100 at 4.50 is RM45 off RM450.
  declare v_usd uuid; v_usd_entry uuid;
  begin
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency,
       exchange_rate, status, discount_amount)
    values (v_org, 'bill', 'BILL-USD', pg_temp.today(), v_sup, 'USD', 4.5, 'draft', 10)
    returning id into v_usd;
    insert into public.purchase_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id)
    values (v_org, v_usd, 1, 'item', 'Sewa luar negara', 1, 100, v_rent);
    v_usd_entry := public.post_purchase_document(v_usd);
    perform pg_temp.check_eq('a dollar discount is taken off in ringgit',
      (select sum(debit) from public.gl_lines
        where entry_id = v_usd_entry and account_id = v_rent), 405.00);
  end;

  -- Credited whole, it all comes back: the note carries the whole
  -- discount and is posted by the same rule, the other way.
  v_note := public.credit_purchase_bill(v_bill);
  perform pg_temp.check_eq('a whole credit takes the rent back to nothing',
    (select sum(l.debit - l.credit) from public.gl_lines l
      join public.purchase_documents d on d.gl_entry_id = l.entry_id
     where d.id in (v_bill, v_note) and l.account_id = v_rent), 0);
  perform pg_temp.check_eq('and the supplier is owed nothing',
    (select sum(l.credit - l.debit) from public.gl_lines l
      join public.purchase_documents d on d.gl_entry_id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where d.id in (v_bill, v_note) and a.code = '2110'), 0);
  perform pg_temp.sign_out();
end $$;

rollback;

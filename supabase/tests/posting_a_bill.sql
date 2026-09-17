-- =====================================================================
-- iAkauntan :: what posting a supplier's bill puts in the ledger
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posting_a_bill.sql
--
-- A mutation sweep of `app.post_purchase_document_internal` read 14
-- survivors out of 24, against eleven test files that touch the buy
-- side. The sell side, swept the same way an hour earlier, read five
-- out of twenty-five. The difference is not that the buy side is
-- simpler -- it is the same shape, and it decides the same three things
-- (what the ledger says, what the stock report says, what the SST
-- return claims). It is that nothing had asserted most of it.
--
-- What survived, and is asserted here:
--
--   - a purchase order or a goods-received note posted to the ledger
--   - a stock item expensed to 5100 instead of capitalised to 1310
--   - the item's own inventory account ignored
--   - the item's own purchase account ignored
--   - the input tax never posted at all
--   - the input tax posted to 2410, the account OUTPUT tax is owed from
--   - freight the supplier charged never posted
--   - the rounding difference never posted
--   - the journal dated today rather than the bill's own date
--   - a credit note filed under the same journal source as a bill
--   - stock received twice, for a bill a goods-received note delivered
--   - stock moved the wrong way for a purchase return
--
-- The input tax pair is the one that reaches a statutory return.
-- `1410` is SST input tax, recoverable; `2410` is output tax, owed. A
-- bill that posts its input tax to `2410` does not merely mislabel a
-- row -- it turns tax the company can claim back into tax it appears
-- to owe, and `sst_return_declares_what_was_charged` reads the same
-- accounts.
--
-- With this file in place the sweep reads 1 survivor out of 24, and the
-- one that survives is recorded rather than worked around.
--
-- "The same bill posted twice" is asserted below and the assertion
-- passes, but removing the function's own `gl_entry_id is not null`
-- guard changes nothing a caller can see. That was checked rather than
-- assumed: with the guard removed, the second post is refused by
-- `app.refuse_posted_document_change` at line 117, whose message also
-- contains "is already posted". The guard is redundant, not untested.
-- The assertion stays because it pins what a caller sees; it does not
-- prove that line is load-bearing, and nothing short of dropping the
-- trigger would. The identical thing was found and recorded on the
-- sales side in `posting_an_invoice_refuses.sql`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_sup    uuid;
  v_stock  uuid;   -- an item that is held on the shelf
  v_serv   uuid;   -- an item that is not
  v_own    uuid;   -- its own inventory account, not 1310
  v_ownexp uuid;   -- its own purchase account, not 5100
  v_bill   uuid;
  v_po     uuid;
  v_grn    uuid;
  v_child  uuid;
  v_note   uuid;
  v_entry  uuid;
  v_msg    text;
  v_tax    uuid;
  v_n      numeric;
  v_t      text;
begin
  v_org := pg_temp.test_org('Beli Barang Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal Sdn Bhd', 'supplier') returning id into v_sup;

  -- Its own accounts, so "the item's own account" can be told apart
  -- from the fallback. A test that leaves these null cannot see the
  -- difference between resolving them and defaulting.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1315', 'Stok Simen', 'asset', 'inventory')
  returning id into v_own;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '5150', 'Belian Khidmat', 'expense', 'cost_of_sales')
  returning id into v_ownexp;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
     inventory_account_id)
  values (v_org, 'SIMEN', 'Simen', 'stock', true, 'C62', 20.00, v_own)
  returning id into v_stock;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
     purchase_account_id)
  values (v_org, 'KHIDMAT', 'Khidmat', 'service', false, 'EA', 300.00,
          v_ownexp)
  returning id into v_serv;

  -- ------------------------------------------------------------------
  -- 1. A document type that does not post
  --
  -- A purchase order is a promise and a goods-received note is a
  -- delivery. Neither is a liability, and posting one puts a payable on
  -- the books for money nobody has been billed for yet.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-1', current_date, v_sup, 'MYR', 1,
          'draft')
  returning id into v_po;

  begin
    perform public.post_purchase_document(v_po);
    perform pg_temp.check_true('a purchase order does not post', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a purchase order does not post, and it says which type: ' || v_msg,
      v_msg = 'Document type purchase_order does not post to the ledger');
  end;

  -- ------------------------------------------------------------------
  -- 2. The bill itself, with everything on it
  --
  -- One stock line and one service line, so the two account paths are
  -- both exercised and can be told apart; SST at 8% on the goods;
  -- freight the supplier charged; and a rounding adjustment.
  -- ------------------------------------------------------------------
  -- The figures are not written onto the document by hand.
  -- `recalc_purchase_totals` recomputes subtotal, tax, rounding and
  -- total from the lines on every line write, so anything set directly
  -- is overwritten before the post ever runs -- which is how the first
  -- draft of this file asserted a tax of 160 against an actual 0. The
  -- tax has to come from the line's own tax_rate -- `calc_document_line`
  -- reads that, not the rate on the code it names -- and the rounding
  -- from a total that is not a whole five sen.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'SR-8', 'SST 8%', '01', 8, 'purchase')
  returning id into v_tax;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, shipping_amount, supplier_doc_no)
  values (v_org, 'bill', 'BILL-1', current_date - 3, v_sup, 'MYR', 1,
          'draft', 50, 'INV-THEIRS-1')
  returning id into v_bill;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_stock, 'Simen, 50kg', 100, 'C62',
          20.00, v_tax, 8, v_wh);
  -- Three sen off a round number, so the org's nearest-five-cent
  -- rounding has something to do. Without it `rounding_amount` is zero
  -- and the assertion below cannot tell a posted rounding line from a
  -- missing one.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_bill, 2, 'item', v_serv, 'Pemasangan', 1, 'EA',
          300.03);
  -- A line worth nothing. It should not reach the journal at all: a
  -- zero-sided line is not a posting, and `assert_balanced` would not
  -- notice it because zero balances against zero.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_bill, 3, 'item', v_serv, 'Diskaun penuh', 1, 'EA', 0);

  v_entry := public.post_purchase_document(v_bill);

  -- The stock line capitalises into the item's OWN inventory account,
  -- not 1310 and not an expense.
  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
   where l.entry_id = v_entry and l.account_id = v_own;
  perform pg_temp.check_eq(
    'the stock line lands in the item''s own inventory account',
    v_n, 2000::numeric);

  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '1310';
  perform pg_temp.check_eq(
    'and 1310, the default it would have fallen back to, gets nothing',
    v_n, 0::numeric);

  -- The service line expenses to the item's OWN purchase account.
  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
   where l.entry_id = v_entry and l.account_id = v_ownexp;
  perform pg_temp.check_eq(
    'the service line lands in the item''s own purchase account',
    v_n, 300.03::numeric);

  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '5100';
  perform pg_temp.check_eq(
    'and 5100 gets nothing either', v_n, 0::numeric);

  -- The input tax, and the account it is claimed from. 1410 is
  -- recoverable input tax; 2410 is output tax the company OWES. Posting
  -- one to the other turns a claim into a liability.
  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '1410';
  perform pg_temp.check_eq('the SST the supplier charged is claimable',
    v_n, 160::numeric);

  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '2410';
  perform pg_temp.check_eq(
    'and nothing of it reaches the account output tax is owed from',
    v_n, 0::numeric);

  -- Freight and rounding.
  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '5400';
  perform pg_temp.check_eq('the freight the supplier charged is posted',
    v_n, 50::numeric);

  select coalesce(sum(l.debit - l.credit), 0) into v_n
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '4990';
  -- 2300.03 + 160 tax + 50 freight is 2510.03, and the company rounds
  -- to the nearest five sen, so it pays 2510.05 and the two sen it
  -- rounded UP is a cost.
  perform pg_temp.check_eq('and the two sen the invoice rounded off',
    v_n, 0.02::numeric);

  -- The zero line is not a line.
  select count(*) into v_n from public.gl_lines l
   where l.entry_id = v_entry and l.debit = 0 and l.credit = 0;
  perform pg_temp.check_eq('a line worth nothing is not posted at all',
    v_n, 0::numeric);

  -- The journal's own date and source. A bill entered on Monday for
  -- goods delivered last Friday belongs in Friday's period, and
  -- `report_trial_balance` and the fiscal period lock both read
  -- entry_date.
  select entry_date::text, source::text into v_t, v_msg
    from public.gl_entries where id = v_entry;
  perform pg_temp.check_eq('the journal carries the bill''s own date',
    v_t, (current_date - 3)::text);
  perform pg_temp.check_true(
    'and is filed as a purchase bill: ' || v_msg,
    v_msg = 'purchase_bill');

  -- The stock arrived once, in pieces.
  select round(sl.quantity, 4) into v_n from public.stock_levels sl
   where sl.item_id = v_stock and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq('a hundred bags came in', v_n, 100::numeric);

  select count(*) into v_n from public.stock_movements m
   where m.source_id = v_bill and m.item_id = v_serv;
  perform pg_temp.check_eq(
    'and the service was not put on a shelf', v_n, 0::numeric);

  -- ------------------------------------------------------------------
  -- 3. Posting it again
  -- ------------------------------------------------------------------
  begin
    perform public.post_purchase_document(v_bill);
    perform pg_temp.check_true('a posted bill does not post twice', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a posted bill does not post twice: ' || v_msg,
      v_msg like '%already posted%');
  end;

  -- ------------------------------------------------------------------
  -- 4. A bill for goods a goods-received note already received
  --
  -- The GRN moves the stock when it is delivered. The bill that follows
  -- is the money, not the goods -- receiving them again would put the
  -- delivery on the shelf twice and value it twice.
  --
  -- ## This assertion used to hold for the wrong reason
  --
  -- Until `0609` the note below was an EMPTY document, created draft
  -- and never posted, and the assertion was that the bill moved no
  -- stock. It passed -- and it would have passed just as well if the
  -- GRN had never existed, because nothing in the schema had ever
  -- received stock on one. Ten units bought through a receiving note
  -- reached the shelf nowhere, and this test said so was correct.
  --
  -- So the premise is now established rather than assumed: the note
  -- carries the lines, it is posted, and the stock it moved is
  -- asserted BEFORE the bill is raised. The bill then adds nothing,
  -- which is what "already received" means.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v_org, 'goods_received', 'GRN-1', current_date, v_sup, 'MYR', 1,
          'draft', 200, 200, 200, 200)
  returning id into v_grn;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total,
     warehouse_id)
  values (v_org, v_grn, 1, 'item', v_stock, 'Simen, 50kg', 10, 'C62',
          20.00, 200, 200, v_wh);

  perform public.post_goods_received(v_grn);

  select round(sl.quantity, 4) into v_n from public.stock_levels sl
   where sl.item_id = v_stock and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq(
    'the goods received note is what puts the delivery on the shelf',
    v_n, 110::numeric);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount, parent_id)
  values (v_org, 'bill', 'BILL-2', current_date, v_sup, 'MYR', 1, 'draft',
          200, 200, 200, 200, v_grn)
  returning id into v_child;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total,
     warehouse_id)
  values (v_org, v_child, 1, 'item', v_stock, 'Simen, 50kg', 10, 'C62',
          20.00, 200, 200, v_wh);

  v_entry := public.post_purchase_document(v_child);

  select round(sl.quantity, 4) into v_n from public.stock_levels sl
   where sl.item_id = v_stock and sl.warehouse_id = v_wh;
  perform pg_temp.check_eq(
    'a bill for goods a receiving note already received moves no stock',
    v_n, 110::numeric);

  -- And the bill clears what the note accrued rather than capitalising
  -- the same stock a second time. 2118 nets to nothing across the two
  -- documents; inventory carries the 200 once.
  perform pg_temp.check_eq(
    'the bill debits goods received not invoiced, not inventory again',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2118'), 200.00);
  perform pg_temp.check_eq(
    'so the accrual the note raised is back to nothing',
    (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where a.org_id = v_org and a.code = '2118'), 0.00);

  -- ------------------------------------------------------------------
  -- 5. Sending it back
  --
  -- A purchase credit note is the return. The stock goes OUT, and the
  -- journal is filed as a credit note rather than a bill -- which is
  -- what the purchase day book and the SST return group by.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount, original_bill_id)
  values (v_org, 'purchase_credit_note', 'PCN-1', current_date, v_sup,
          'MYR', 1, 'draft', 400, 400, 400, 400, v_bill)
  returning id into v_note;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total,
     warehouse_id)
  values (v_org, v_note, 1, 'item', v_stock, 'Simen rosak', 20, 'C62',
          20.00, 400, 400, v_wh);

  v_entry := public.post_purchase_document(v_note);

  select round(sl.quantity, 4) into v_n from public.stock_levels sl
   where sl.item_id = v_stock and sl.warehouse_id = v_wh;
  -- Ninety, not eighty. A hundred came in on BILL-1 and ten more on
  -- GRN-1 -- which is new: before `0609` the receiving note above put
  -- nothing on the shelf, so this file's running total was ten short
  -- from section 4 onwards and nobody could see it, because every
  -- figure after it was written to match.
  perform pg_temp.check_eq('twenty bags went back to the supplier',
    v_n, 90::numeric);

  select m.movement_type::text into v_t from public.stock_movements m
   where m.source_id = v_note limit 1;
  perform pg_temp.check_true(
    'and the movement says it was a return, not a receipt: ' || v_t,
    v_t = 'purchase_return');

  select source::text into v_msg from public.gl_entries where id = v_entry;
  perform pg_temp.check_true(
    'the journal is filed as a purchase credit note: ' || v_msg,
    v_msg = 'purchase_credit_note');

  raise notice 'posting a bill: the ledger, the shelf and the SST return';
end $$;

rollback;

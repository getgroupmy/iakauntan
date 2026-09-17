-- =====================================================================
-- iAkauntan :: the three documents the app could not raise
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_types.sql
--
-- `sales_doc_type` has eight values and `purchase_doc_type` seven. The
-- table the document editor is built from carried eleven of the fifteen,
-- and the four it did not were not four unfinished ideas:
--
--   * **refund_note** posts (`0013`), ages (`0096`), reports its output
--     tax (`report_sst_summary`) and is LHDN e-Invoice type **04**
--     (`0015`). MyInvois recognises four document types and a company
--     using this could issue three of them.
--   * **purchase_debit_note** posts, ages beside the bill it belongs to,
--     and carries input tax `report_sst_summary` counts — so the missing
--     row was a claimable tax credit with no way to enter it.
--   * **proforma** posts nothing, correctly, and `0081` has known
--     `proforma → invoice` all along. It was a transfer chain with no
--     way to start it.
--   * **purchase_return** is the one that really is unfinished, and it
--     stays out. No posting path accepts it; the word appears in the
--     migrations as a `stock_movement_type`, which is the goods going
--     back rather than a document.
--
-- `app/test/doc_types_test.dart` asserts the table now covers both
-- enums. This file asserts the other half: that pressing Post on each of
-- the three does what the row beside it in the menu implies.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_supp  uuid;
  v_item  uuid;
  v_tax   uuid;
  v_doc   uuid;
  v_entry uuid;
  v_ar    numeric;
  v_ap    numeric;
  v_refused boolean;
begin
  v_org := pg_temp.test_org('Dokumen Penuh Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'A customer', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'A supplier', 'supplier') returning id into v_supp;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'A service', 'service', false, 'C62', 1)
  returning id into v_item;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'SV6', 'Service tax 6%', '02', 6, 'both')
  returning id into v_tax;

  -- ------------------------------------------------------------------
  -- A refund note takes money back off the customer's account
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'refund_note', 'RN-1', v_cust, date '2026-03-25', 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Refunded', 1, 100, v_tax, 6);

  v_entry := public.post_sales_document(v_doc);
  perform pg_temp.check_true('a refund note posts at all', v_entry is not null);

  -- The sign, which is the whole of it. An invoice debits receivables;
  -- a refund note is money going back, so the same line has to be a
  -- credit. Getting this backwards does not fail — it produces a
  -- receivable balance that grows every time a customer is refunded.
  select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
    into v_ar
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '1210';
  perform pg_temp.check_eq(
    'and credits receivables rather than debiting them', v_ar, -106);

  -- ------------------------------------------------------------------
  -- A purchase debit note is the supplier billing for an undercharge
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'purchase_debit_note', 'PDN-1', v_supp,
          date '2026-03-26', 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Undercharged', 1, 200, v_tax, 6);

  v_entry := public.post_purchase_document(v_doc);
  perform pg_temp.check_true('a purchase debit note posts', v_entry is not null);

  -- It moves payables the same way a bill does: more owed, not less.
  -- The opposite sign would quietly reduce what the company owes on the
  -- strength of a document saying it owes more.
  select coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
    into v_ap
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '2110';
  perform pg_temp.check_eq('and credits payables, as a bill does', v_ap, 212);

  -- ------------------------------------------------------------------
  -- A proforma is a price in writing and not an accounting event
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'proforma', 'PF-1', v_cust, date '2026-03-27', 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Quoted', 1, 500, v_tax, 6);

  v_refused := false;
  begin
    perform public.post_sales_document(v_doc);
  exception when others then v_refused := true;
  end;
  -- The refusal is the assertion. A proforma that posted would be an
  -- invoice with a softer name, and the output tax on it would be
  -- declared to Customs for a supply that has not happened.
  perform pg_temp.check_true(
    'a proforma is refused by the ledger, which is why its row posts '
    'nothing', v_refused);

  -- And it can still become the invoice it is a preview of, which is
  -- the only thing it is for. `0081` has accepted this transfer since
  -- it was written and `transferTargets` in Dart has listed it — with
  -- no way to raise the source, so the path was never once walked.
  v_entry := public.transfer_document(v_doc, 'invoice');
  perform pg_temp.check_eq('but it may still be turned into an invoice',
    (select doc_type::text from public.sales_documents where id = v_entry),
    'invoice');
  perform pg_temp.check_eq('carrying the lines across',
    (select sum(quantity * unit_price) from public.sales_document_lines
      where document_id = v_entry), 500);

  perform pg_temp.sign_out();
end $$;

rollback;

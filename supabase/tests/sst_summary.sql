-- =====================================================================
-- iAkauntan :: the SST summary, and the credit notes it used to miss
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sst_summary.sql
--
-- report_sst_summary is what a company fills its SST-02 in from, so a
-- wrong number here is a wrong number filed with Customs. Until 0278
-- the report counted invoices and debit notes only: the ledger netted
-- credit notes off the tax accounts and the return did not, so every
-- period containing a credit note overstated the output tax due, and
-- every period containing a purchase credit note overstated the input
-- tax claimed.
--
-- The fixture below issues a credit note against every direction and
-- gives each tax type a different amount, so a report that drops the
-- credits, or nets them the wrong way, or attaches them to the wrong
-- tax type, produces a number that is visibly not the one asserted.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_cust  uuid;
  v_supp  uuid;
  v_item  uuid;
  v_st    uuid;   -- 01 sales tax, 10%
  v_svc   uuid;   -- 02 service tax, 6%
  v_tour  uuid;   -- 03 tourism tax, 10%
  v_doc   uuid;
  r       record;
  v_rows  integer;

begin
  v_org := pg_temp.test_org('Cukai Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

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
  values (v_org, 'ST10', 'Sales tax 10%',   '01', 10, 'both')
  returning id into v_st;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'SV6',  'Service tax 6%',  '02',  6, 'both')
  returning id into v_svc;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'TTX',  'Tourism tax 10%', '03', 10, 'both')
  returning id into v_tour;

  -- ------------------------------------------------------------------
  -- Sales tax (01): sold 1,000, credited 200, and a debit note of 50.
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-1', v_cust, date '2026-03-05', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Sold', 1, 1000, v_st, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     original_invoice_id)
  values (v_org, 'credit_note', 'CN-1', v_cust, date '2026-03-20',
          'posted', v_doc)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Credited', 1, 200, v_st, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'debit_note', 'DN-1', v_cust, date '2026-03-22', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Undercharged', 1, 50, v_st, 10);

  -- ------------------------------------------------------------------
  -- Service tax (02): billed 500, refunded 100. A refund note moves
  -- the ledger the same way a credit note does, so it must move the
  -- return the same way too.
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-2', v_cust, date '2026-03-08', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Serviced', 1, 500, v_svc, 6);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'refund_note', 'RN-1', v_cust, date '2026-03-25', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Refunded', 1, 100, v_svc, 6);

  -- ------------------------------------------------------------------
  -- Tourism tax (03): billed 300 and credited all of it.
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-3', v_cust, date '2026-03-09', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Stayed', 1, 300, v_tour, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     original_invoice_id)
  values (v_org, 'credit_note', 'CN-3', v_cust, date '2026-03-28',
          'posted', v_doc)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Cancelled', 1, 300, v_tour, 10);

  -- ------------------------------------------------------------------
  -- Purchases (01): bought 800, credited 300, and a debit note of 20.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'bill', 'BILL-1', v_supp, date '2026-03-06', 'posted')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Bought', 1, 800, v_st, 10);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'purchase_credit_note', 'PCN-1', v_supp,
          date '2026-03-21', 'posted')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Returned', 1, 300, v_st, 10);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'purchase_debit_note', 'PDN-1', v_supp,
          date '2026-03-23', 'posted')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Underbilled', 1, 20, v_st, 10);

  -- ------------------------------------------------------------------
  -- And four documents the return must not see: one still being typed,
  -- one voided, one in the next quarter, and a quotation, which is not
  -- a tax document however much tax its lines carry.
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-DRAFT', v_cust, date '2026-03-11', 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Not issued', 1, 9999, v_st, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-VOID', v_cust, date '2026-03-12', 'void')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Cancelled outright', 1, 7777, v_st, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-APR', v_cust, date '2026-04-02', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Next quarter', 1, 5555, v_st, 10);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'quotation', 'QUO-1', v_cust, date '2026-03-13', 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, v_item, 'Only offered', 1, 3333, v_st, 10);

  -- ==================================================================
  -- The return for the quarter
  -- ==================================================================

  -- 1,000 sold, 200 credited, 50 debited.
  select * into r from public.report_sst_summary(
    v_org, date '2026-03-01', date '2026-03-31')
   where tax_type_code = '01' and direction = 'output';
  perform pg_temp.check_eq('sales tax output is net of the credit note',
    r.taxable_amount, 850.00);
  perform pg_temp.check_eq('and so is the tax due', r.tax_amount, 85.00);
  perform pg_temp.check_eq('the tax type is named from the reference table',
    r.tax_type_name, 'Sales Tax');

  -- 500 billed, 100 refunded.
  select * into r from public.report_sst_summary(
    v_org, date '2026-03-01', date '2026-03-31')
   where tax_type_code = '02' and direction = 'output';
  perform pg_temp.check_eq('a refund note comes off service tax too',
    r.taxable_amount, 400.00);
  perform pg_temp.check_eq('service tax due', r.tax_amount, 24.00);

  -- Credited in full, and still on the return.
  select * into r from public.report_sst_summary(
    v_org, date '2026-03-01', date '2026-03-31')
   where tax_type_code = '03' and direction = 'output';
  perform pg_temp.check_true('a wholly credited invoice still has a line',
    r.tax_type_code is not null);
  perform pg_temp.check_eq('and it nets to nothing', r.taxable_amount, 0.00);
  perform pg_temp.check_eq('with no tax due', r.tax_amount, 0.00);

  -- 800 bought, 300 credited, 20 debited. The direction that costs the
  -- taxpayer money when it is wrong.
  select * into r from public.report_sst_summary(
    v_org, date '2026-03-01', date '2026-03-31')
   where tax_type_code = '01' and direction = 'input';
  perform pg_temp.check_eq('input tax is net of the purchase credit note',
    r.taxable_amount, 520.00);
  perform pg_temp.check_eq('and so is the tax claimed', r.tax_amount, 52.00);

  -- Nothing was bought under service or tourism tax, so there is no
  -- input line for either. A zero row would be a claim never made.
  perform pg_temp.check_eq('no input line for a tax nothing was bought under',
    (select count(*) from public.report_sst_summary(
       v_org, date '2026-03-01', date '2026-03-31')
      where direction = 'input'), 1);

  -- Three output lines and one input line, and nothing else: the
  -- draft, the void, April and the quotation are all absent. If any
  -- had been counted the sales tax figures above would already have
  -- failed, so this pins the shape rather than the arithmetic.
  select count(*) into v_rows from public.report_sst_summary(
    v_org, date '2026-03-01', date '2026-03-31');
  perform pg_temp.check_eq('four lines on the return', v_rows, 4);

  -- April on its own is the invoice the quarter above excluded.
  select * into r from public.report_sst_summary(
    v_org, date '2026-04-01', date '2026-04-30')
   where tax_type_code = '01' and direction = 'output';
  perform pg_temp.check_eq('April sees its own invoice and no other',
    r.taxable_amount, 5555.00);

  -- ==================================================================
  -- Somebody else's return is nobody else's business
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('outsider@example.test'));
  perform pg_temp.check_eq('a non-member sees no lines at all',
    (select count(*) from public.report_sst_summary(
       v_org, date '2026-03-01', date '2026-03-31')), 0);
  perform pg_temp.sign_out();
end $$;

rollback;

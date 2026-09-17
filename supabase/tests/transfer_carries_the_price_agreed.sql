-- =====================================================================
-- iAkauntan :: the invoice bills the price the quotation quoted
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transfer_carries_the_price_agreed.sql
--
-- `public.transfer_document` turns a quotation into an order and an
-- order into an invoice. It copied a whitelist of header columns and
-- the whitelist had no money on it, so a quotation for RM1000 of goods
-- with RM50 delivery and RM100 off the job was invoiced at RM1080
-- against RM1030 quoted -- the customer billed fifty ringgit more than
-- the price they agreed to, the discount gone and the delivery gone
-- with it.
--
-- `0417` apportions the header amounts the way the line loop in that
-- same function has always apportioned a line discount: proportional to
-- what is being taken. So the file asserts two things and the second is
-- the one that is easy to get wrong.
--
--   1. A whole transfer bills what was quoted. Asserted against the
--      source's own total rather than against 1030.00, so a change to
--      the tax rate keeps it honest.
--   2. **Two half transfers add back to one whole.** Invoicing a
--      quotation in two goes charges the delivery once, not twice and
--      not never. That is a property of apportioning against the
--      source's total instead of against what is left of it, and it is
--      the thing a plausible-looking implementation gets wrong.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_cust   uuid;
  v_supp   uuid;
  v_item   uuid;
  v_st8    uuid;
  v_branch uuid;
  v_q      uuid;
  v_po     uuid;
  v_inv    uuid;
  v_inv2   uuid;
  v_line   uuid;
  a        record;
  b        record;
  c        record;
begin
  v_org := pg_temp.test_org('Sebut Harga Tujuh Belas Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pembeli', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Pembekal', 'supplier') returning id into v_supp;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, sales_tax_code_id, purchase_tax_code_id)
  values (v_org, 'W', 'Widget', 'service', false, 'C62', 500.00, v_st8, v_st8)
  returning id into v_item;
  insert into public.branches (org_id, code, name)
  values (v_org, 'JB', 'Johor Bahru') returning id into v_branch;

  -- ------------------------------------------------------------------
  -- 1. The whole job, quoted and then invoiced
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, contact_id, currency,
     exchange_rate, status, shipping_amount, discount_amount, branch_id)
  values (v_org, 'quotation', 'QT-1', current_date, current_date + 30,
          v_cust, 'MYR', 1, 'draft', 50.00, 100.00, v_branch)
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_q, 1, 'item', v_item, 'Widget', 2, 'C62', 500.00, v_st8, 8)
  returning id into v_line;

  select * into a from public.sales_documents where id = v_q;
  perform pg_temp.check_eq('the quotation comes to 1030', a.total_amount, 1030.00);

  v_inv := public.transfer_document(v_q, 'invoice');
  select * into b from public.sales_documents where id = v_inv;

  perform pg_temp.check_eq('and the invoice bills what was quoted',
    b.total_amount, a.total_amount);
  perform pg_temp.check_eq('the delivery came across', b.shipping_amount, 50.00);
  perform pg_temp.check_eq('and the discount the customer negotiated',
    b.discount_amount, 100.00);
  perform pg_temp.check_true('on the branch that quoted it',
    b.branch_id = v_branch);
  perform pg_temp.check_true('and it is a draft with a number of its own',
    b.status = 'draft' and b.doc_no is distinct from a.doc_no);

  -- ------------------------------------------------------------------
  -- 2. The same quotation invoiced in two goes
  -- ------------------------------------------------------------------
  -- The property that separates apportioning against the source from
  -- apportioning against what is left: one delivery charge, split, not
  -- two whole ones and not none.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, contact_id, currency,
     exchange_rate, status, shipping_amount, discount_amount)
  values (v_org, 'quotation', 'QT-2', current_date, current_date + 30,
          v_cust, 'MYR', 1, 'draft', 50.00, 100.00)
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_q, 1, 'item', v_item, 'Widget', 2, 'C62', 500.00, v_st8, 8)
  returning id into v_line;
  select * into a from public.sales_documents where id = v_q;

  v_inv := public.transfer_document(v_q, 'invoice',
    jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 1)));
  select * into b from public.sales_documents where id = v_inv;

  perform pg_temp.check_eq('half the job carries half the delivery',
    b.shipping_amount, 25.00);
  perform pg_temp.check_eq('and half the discount',
    b.discount_amount, 50.00);

  v_inv2 := public.transfer_document(v_q, 'invoice',
    jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 1)));
  select * into c from public.sales_documents where id = v_inv2;

  perform pg_temp.check_eq('and so does the other half', c.shipping_amount, 25.00);
  perform pg_temp.check_eq('and its discount', c.discount_amount, 50.00);

  -- The assertion the two above exist for.
  perform pg_temp.check_eq(
    'so the customer is charged the delivery once, not twice and not never',
    b.shipping_amount + c.shipping_amount, a.shipping_amount);
  perform pg_temp.check_eq('and gets the discount once',
    b.discount_amount + c.discount_amount, a.discount_amount);
  perform pg_temp.check_eq(
    'and the two invoices together come to the quotation',
    b.total_amount + c.total_amount, a.total_amount);

  -- ------------------------------------------------------------------
  -- 3. The buying side
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, shipping_amount, discount_amount, branch_id)
  values (v_org, 'purchase_order', 'PO-1', current_date, current_date + 30,
          v_supp, 'MYR', 1, 'draft', 30.00, 20.00, v_branch)
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_po, 1, 'item', v_item, 'Widget', 2, 'C62', 500.00, v_st8, 8);

  select * into a from public.purchase_documents where id = v_po;
  v_inv := public.transfer_document(v_po, 'bill');
  select * into b from public.purchase_documents where id = v_inv;

  perform pg_temp.check_eq('the bill comes to the order',
    b.total_amount, a.total_amount);
  perform pg_temp.check_eq('the carriage the supplier charges came across',
    b.shipping_amount, 30.00);
  perform pg_temp.check_eq('and the discount they gave', b.discount_amount, 20.00);
  perform pg_temp.check_true('on the branch that ordered it',
    b.branch_id = v_branch);

  -- ------------------------------------------------------------------
  -- 4. A quotation whose goods are free and whose delivery is not
  -- ------------------------------------------------------------------
  -- There is no line value to apportion by. A whole transfer takes the
  -- charge; the alternative is a delivery nobody is billed for.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, contact_id, currency,
     exchange_rate, status, shipping_amount)
  values (v_org, 'quotation', 'QT-3', current_date, current_date + 30,
          v_cust, 'MYR', 1, 'draft', 40.00)
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_q, 1, 'item', v_item, 'Sample, free of charge', 1, 'C62', 0);

  v_inv := public.transfer_document(v_q, 'invoice');
  select * into b from public.sales_documents where id = v_inv;
  perform pg_temp.check_eq('a free sample is still delivered, and billed for',
    b.shipping_amount, 40.00);
  perform pg_temp.check_eq('and that is the whole of the invoice',
    b.total_amount, 40.00);
end $$;

rollback;

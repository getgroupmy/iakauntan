-- =====================================================================
-- iAkauntan :: what LHDN is told adds up to what was billed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_totals_reconcile.sql
--
-- `prepare_einvoice` copies six figures onto the MyInvois header, and
-- they are not independent:
--
--     excl_tax - discount + charges + tax + rounding = payable
--
-- `app.recalc_sales_totals` maintains that identity on the document.
-- The mapping has to preserve it, and until `0415` it did not: `0410`
-- added the service charge a Malaysian bill carries, put it in the
-- total and into the ledger, and left it out of `total_charges`. On a
-- RM100 bill with RM5 delivery and a RM10 service charge, LHDN was told
-- 113.00 and the customer was billed 123.00.
--
-- Nothing caught it because nothing had ever asserted the six
-- reconcile: `total_charges`, `total_excl_tax` and `payable_amount`
-- appeared in no test in this repository.
--
-- So this file asserts the **identity**, not six expected numbers. The
-- next charge added to a document fails it as well, which is the whole
-- reason for writing it that way.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Raises a posted invoice with whichever charges are asked for, prepares
-- its e-Invoice, and returns what LHDN would be told minus what was
-- billed. Zero is the only right answer.
create or replace function pg_temp.einvoice_gap(
  p_org uuid, p_contact uuid, p_item uuid, p_tax uuid, p_no text,
  p_price numeric, p_shipping numeric, p_service numeric,
  p_discount numeric)
returns numeric language plpgsql as $$
declare v_doc uuid; e record;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, shipping_amount, service_charge_amount,
     discount_amount)
  values (p_org, 'invoice', p_no, current_date, current_date, p_contact,
          'MYR', 1, 'draft', p_shipping, p_service, p_discount)
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (p_org, v_doc, 1, 'item', p_item, 'Set dinner', 1, 'C62',
          p_price, p_tax, 8);

  perform app.post_sales_document_internal(v_doc);
  perform public.prepare_einvoice(v_doc);

  select * into e from public.einvoice_documents where source_id = v_doc;
  return round(
    e.total_excl_tax - e.total_discount + e.total_charges + e.total_tax
      + e.rounding_amount - e.payable_amount, 2);
end $$;

do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_item uuid;
  v_st8  uuid;
  v_exempt uuid;
  v_doc  uuid;
  e      record;
begin
  v_org := pg_temp.test_org('Restoran Sepuluh Belas Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  -- e-Invoice has to be on, and the company has to be able to identify
  -- itself, or `prepare_einvoice` refuses before it maps anything.
  update public.organizations
     set einvoice_enabled = true, tin = 'C1234567890',
         registration_no = '202301000001', msic_code = '56101',
         business_activity = 'Restaurants'
   where id = v_org;

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Encik Pelanggan', 'customer') returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, sales_tax_code_id)
  values (v_org, 'SET', 'Set dinner', 'service', false, 'C62', 100.00, v_st8)
  returning id into v_item;

  -- ------------------------------------------------------------------
  -- The identity, across every shape a bill takes
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a plain invoice reconciles',
    pg_temp.einvoice_gap(v_org, v_cust, v_item, v_st8, 'INV-R1',
                         100.00, 0, 0, 0), 0);

  perform pg_temp.check_eq('one with delivery on it reconciles',
    pg_temp.einvoice_gap(v_org, v_cust, v_item, v_st8, 'INV-R2',
                         100.00, 5.00, 0, 0), 0);

  -- The one that was wrong. Before `0415` this returned -10.00: LHDN
  -- was told 113.00 for a bill of 123.00.
  perform pg_temp.check_eq(
    'and one with a service charge -- which is what a Malaysian '
    'restaurant bill is',
    pg_temp.einvoice_gap(v_org, v_cust, v_item, v_st8, 'INV-R3',
                         100.00, 5.00, 10.00, 0), 0);

  perform pg_temp.check_eq('with a discount as well',
    pg_temp.einvoice_gap(v_org, v_cust, v_item, v_st8, 'INV-R4',
                         100.00, 5.00, 10.00, 7.50), 0);

  -- An amount that rounds, so `rounding_amount` is not zero and is
  -- carrying its own weight in the identity above.
  perform pg_temp.check_eq('and one whose total had to be rounded',
    pg_temp.einvoice_gap(v_org, v_cust, v_item, v_st8, 'INV-R5',
                         99.99, 3.33, 7.77, 1.11), 0);

  -- ------------------------------------------------------------------
  -- And the charge is inside the charges, not hidden in the tax
  -- ------------------------------------------------------------------
  -- The identity alone can be satisfied by putting the service charge
  -- in the wrong column, and a document that balances while calling a
  -- service charge tax is a document that misreports the tax.
  select * into e from public.einvoice_documents ed
    join public.sales_documents d on d.id = ed.source_id
   where d.doc_no = 'INV-R3' and ed.source_id = d.id;

  perform pg_temp.check_eq('the charges are the delivery and the service charge',
    (select ed.total_charges from public.einvoice_documents ed
       join public.sales_documents d on d.id = ed.source_id
      where d.doc_no = 'INV-R3'), 15.00);

  perform pg_temp.check_eq('and the tax is the tax',
    (select ed.total_tax from public.einvoice_documents ed
       join public.sales_documents d on d.id = ed.source_id
      where d.doc_no = 'INV-R3'), 8.00);

  perform pg_temp.check_eq('and the goods are the goods',
    (select ed.total_excl_tax from public.einvoice_documents ed
       join public.sales_documents d on d.id = ed.source_id
      where d.doc_no = 'INV-R3'), 100.00);

  -- ------------------------------------------------------------------
  -- The mechanical version
  -- ------------------------------------------------------------------
  -- Everything above names a shape. This asks the question of every
  -- e-Invoice the file happened to raise, so a shape nobody thought of
  -- is covered by the same assertion.
  perform pg_temp.check_eq(
    'and every document this file prepared adds up to its own total',
    (select count(*) from public.einvoice_documents ed
      where ed.org_id = v_org
        and round(ed.total_excl_tax - ed.total_discount + ed.total_charges
                  + ed.total_tax + ed.rounding_amount
                  - ed.payable_amount, 2) <> 0), 0);

  perform pg_temp.check_true('on more than one of them',
    (select count(*) from public.einvoice_documents where org_id = v_org) >= 5);

  -- ------------------------------------------------------------------
  -- An exempt line says how much was exempted, and under what
  -- ------------------------------------------------------------------
  -- `einvoice_lines.tax_exempted_amount` has existed since `0007` and
  -- no function wrote it, so it was 0 on every line ever prepared. The
  -- UBL builder reads it and, before `0431`, substituted it for the
  -- taxable amount of the exempt subtotal whenever it was non-zero --
  -- so a future writer taking LHDN's "Amount Exempted from Tax" to
  -- mean the tax forgone would have sent 8.00 as the taxable amount of
  -- a RM100 exempt supply, silently. Measured against the real builder
  -- before the fix: writing the taxable base changed the payload not at
  -- all, writing the tax changed it.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_exempt, exemption_reason,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'EX', 'Exempt supply', 'E', 0, true,
          'Exempt under the Service Tax (Persons Exempted) Order 2018',
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_exempt;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-EX', app.today(), app.today(), v_cust,
          'MYR', 1, 'draft')
  returning id into v_doc;

  -- One exempt line and one taxed line on the same document, so the
  -- assertions below can tell "written for exempt lines" apart from
  -- "written for every line".
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values
    (v_org, v_doc, 1, 'item', v_item, 'Exempt service', 1, 'C62',
     100.00, v_exempt, 0),
    (v_org, v_doc, 2, 'item', v_item, 'Taxed service', 1, 'C62',
     50.00, v_st8, 8);

  perform app.post_sales_document_internal(v_doc);
  perform public.prepare_einvoice(v_doc);

  perform pg_temp.check_eq(
    'the exempt line says how much of the supply was exempted',
    (select el.tax_exempted_amount from public.einvoice_lines el
       join public.einvoice_documents ed on ed.id = el.einvoice_id
      where ed.source_id = v_doc and el.line_no = 1), 100.00);

  -- The number the UBL builder would otherwise send as the taxable
  -- amount of the exempt subtotal. They have to be the same figure, or
  -- the two ways of reading the column disagree about what LHDN is
  -- told about a supply that paid no tax.
  perform pg_temp.check_eq(
    'and it is the taxable amount of that line, not the tax forgone',
    (select el.tax_exempted_amount - el.total_excl_tax
       from public.einvoice_lines el
       join public.einvoice_documents ed on ed.id = el.einvoice_id
      where ed.source_id = v_doc and el.line_no = 1), 0);

  -- Writing the column unconditionally would satisfy both assertions
  -- above and tell LHDN that a taxed supply was exempted.
  perform pg_temp.check_eq(
    'and a line that paid tax was exempted from nothing',
    (select el.tax_exempted_amount from public.einvoice_lines el
       join public.einvoice_documents ed on ed.id = el.einvoice_id
      where ed.source_id = v_doc and el.line_no = 2), 0);

  -- The amount and the ground are one claim in two columns. Either
  -- without the other is an exemption LHDN cannot check.
  perform pg_temp.check_eq(
    'no line in this file claims an exemption without naming its ground',
    (select count(*) from public.einvoice_lines el
       join public.einvoice_documents ed on ed.id = el.einvoice_id
      where ed.org_id = v_org
        and (el.tax_exempted_amount <> 0) is distinct from
            (el.tax_exemption_reason is not null)), 0);

  perform pg_temp.check_true('and at least one of them claims one',
    (select count(*) from public.einvoice_lines el
       join public.einvoice_documents ed on ed.id = el.einvoice_id
      where ed.org_id = v_org and el.tax_exempted_amount <> 0) >= 1);
end $$;

rollback;

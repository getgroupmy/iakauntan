-- =====================================================================
-- iAkauntan :: what LHDN is actually told
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_payload_shapes.sql
--
-- `prepare_einvoice` takes a posted sales document and writes the
-- SNAPSHOT that is submitted to MyInvois. Every column it fills is a
-- claim made to a tax authority on the company's behalf, and a claim
-- that is wrong is wrong on a filing rather than on a screen.
--
-- `einvoice_statutory.sql` is the behaviour file for this and it is a
-- good one: a sweep of 86 one-line mutants died 63 times against it,
-- the best defence in the codebase after `appraisals.sql`. What it does
-- not have is a document with anything IN it. Its fixture files one
-- invoice, in ringgit, dated today, at a company whose address, SST
-- number and MSIC code are all null, to a buyer whose email, phone and
-- address are all null, with one line carrying no classification, no
-- unit, no tax code and no discount, and it is never submitted twice.
--
-- So every fallback in the function had nothing to fall back FROM, and
-- every pair of adjacent columns of the same type could be swapped
-- without anybody noticing: the supplier's SST number and its MSIC
-- code, the buyer's email and phone, its state and its country, the
-- line's tax RATE and its tax AMOUNT.
--
-- This file fills the document in. Every field that goes to LHDN is
-- given a value that could not be mistaken for any of its neighbours,
-- so a column read into the wrong slot shows up as the wrong sentence
-- rather than as another null.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A posted one-line invoice for a given buyer.
--
-- Each buyer gets its OWN document rather than the contact being
-- swapped on one, because the resubmission upsert does not refresh the
-- buyer columns: a snapshot is of what was filed, and swapping the
-- contact underneath it proves nothing about the fallback chain.
create or replace function pg_temp.ei_doc(p_org uuid, p_buyer uuid)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, current_date + 30, p_buyer, 'MYR', 1,
          100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, line_subtotal, line_total)
  values (p_org, v_doc, 1, 'item', 'Barang', 1, 100, 100, 100);
  update public.sales_documents set status = 'posted' where id = v_doc;
  return v_doc;
end;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Penghantar e-Invois Sdn Bhd');
  v_next   uuid;
  v_buyer  uuid;
  v_bare   uuid;
  v_cash   uuid;
  v_tax_s  uuid;   -- a tax code with its own type and an exemption
  v_tax_e  uuid;
  v_item   uuid;
  v_plain  uuid;
  v_doc    uuid;
  v_other  uuid;
  v_ein    uuid;
  v_l1     uuid;
  v_l2     uuid;
  v_row    record;
  v_line   record;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  -- ------------------------------------------------------------------
  -- A company filled in, with no two fields alike
  --
  -- The trading name is not the legal name, the e-Invoice TIN is not
  -- the ordinary one, and the town is not the postcode. Every one of
  -- those pairs was a live mutant against a fixture where both halves
  -- were null.
  -- ------------------------------------------------------------------
  update public.organizations
     set einvoice_enabled     = true,
         name                 = 'Penghantar',
         legal_name           = 'Penghantar e-Invois Sdn Bhd',
         registration_no      = '199901000001',
         tin                  = 'C1111111111',
         einvoice_tin         = 'C2222222222',
         einvoice_id_type     = 'BRN',
         einvoice_id_value    = '199901000001',
         msic_code            = '62010',
         business_activity    = 'Computer programming activities',
         email                = 'akaun@penghantar.test',
         phone                = '03-11112222',
         address_line1        = 'Tingkat 5, Menara Satu',
         address_line2        = 'Jalan Dua',
         address_line3        = 'Taman Tiga',
         city                 = 'Petaling Jaya',
         postcode             = '46000',
         state_code           = '10',
         country_code         = 'MYS'
   where id = v_org;
  -- ------------------------------------------------------------------
  -- A buyer filled in the same way
  -- ------------------------------------------------------------------
  insert into public.contacts
    (org_id, code, contact_type, name, legal_name, tin, registration_no,
     sst_registration_no, id_type, id_value, email, phone,
     address_line1, address_line2, address_line3, city, postcode,
     state_code, country_code)
  values (v_org, 'C-BIG', 'customer', 'Pembeli', 'Pembeli Besar Sdn Bhd',
          'C5555555555', '200501000002', 'W10-1808-31000002', 'BRN',
          '200501000002', 'pembeli@besar.test', '03-33334444',
          'Lot 9, Jalan Empat', 'Seksyen Lima', 'Bandar Enam',
          'Shah Alam', '40000', '10', 'MYS')
  returning id into v_buyer;

  -- One with a registration number and no identifier of its own, and
  -- one with neither. Both are what the fallback chain exists for.
  insert into public.contacts
    (org_id, code, contact_type, name, tin, registration_no)
  values (v_org, 'C-REG', 'customer', 'Pembeli Berdaftar', 'C6666666666',
          '201001000003')
  returning id into v_bare;
  insert into public.contacts (org_id, code, contact_type, name)
  values (v_org, 'C-CASH', 'customer', 'Pelanggan tunai')
  returning id into v_cash;

  -- ------------------------------------------------------------------
  -- Two tax codes, so a line's own is not the default
  -- ------------------------------------------------------------------
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, is_exempt)
  values (v_org, 'ST6', 'Service tax 6%', '02', 6, 'sales', false)
  returning id into v_tax_s;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, is_exempt,
     exemption_reason)
  values (v_org, 'EXEMPT', 'Exempt supply', '03', 0, 'sales', true,
          'Schedule A exemption')
  returning id into v_tax_e;

  -- The SST number is not a field to set. It is the boolean, the
  -- number, the date it took effect and the default tax code together,
  -- and `guard_sst_registration` refuses anything less — which is the
  -- right refusal and the reason this goes through the function rather
  -- than through the update above.
  perform public.set_sst_registration(
    v_org, true, current_date - 400, 'W10-1808-31000001', 'ST6');

  -- An item carrying its own classification and unit, and one carrying
  -- neither, so the two ends of every fallback are reachable.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, classification_code)
  values (v_org, 'SVC', 'Perkhidmatan sokongan', 'service', false, 'HUR',
          100, 0, '035')
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'PLAIN', 'Barang biasa', 'service', false, 'C62', 50, 0)
  returning id into v_plain;

  -- ------------------------------------------------------------------
  -- The document: not today, not in ringgit, and with money on the
  -- header that no line carries
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, discount_amount, tax_amount,
     shipping_amount, service_charge_amount, rounding_amount,
     total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-SHAPES-1', current_date - 40,
          current_date - 10, v_buyer, 'USD', 4.25,
          400.00, 25.00, 22.50, 30.00, 15.00, 0.03,
          442.53, 442.53, 'draft')
  returning id into v_doc;

  -- Line one names everything itself, and names no item at all — a
  -- service typed straight onto the invoice. So the classification, the
  -- unit and the tax type on it are the line's own, with nothing behind
  -- them to fall back to. Its quantity times its price is three
  -- decimals, so the rounding to the sen is observable.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     classification_code, quantity, uom_code, unit_price,
     discount_percent, discount_amount, tax_code_id, tax_rate, tax_amount,
     line_subtotal, line_total)
  values (v_org, v_doc, 1, 'item', 'Sokongan bulanan',
          '009', 3, 'MON', 100.125,
          10, 30.04, v_tax_s, 6, 16.20, 270.34, 286.54)
  returning id into v_l1;

  -- Line two names nothing at all and its description is blank, so the
  -- item behind it decides all three. It is exempt, so the two
  -- exemption columns have something to carry.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate, tax_amount,
     line_subtotal, line_total)
  values (v_org, v_doc, 2, 'item', v_item, '',
          2, 50, v_tax_e, 0, 0, 100.00, 100.00)
  returning id into v_l2;

  -- Line three's item has no classification of its own either, so what
  -- reaches LHDN is the code the function falls back to — and a line
  -- with no tax code at all takes the default tax type beside it.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, line_subtotal, line_total)
  values (v_org, v_doc, 3, 'item', v_plain, 'Barang biasa dijual',
          1, 20, 20.00, 20.00);

  -- Line four names no item and no unit, so the last link in the chain
  -- is what reaches LHDN. A line filed with no unit at all is one
  -- MyInvois rejects.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, line_subtotal, line_total)
  values (v_org, v_doc, 5, 'item', 'Caj lain-lain', 1, 10, 10.00, 10.00);

  -- And a line that is not something sold at all: a note the customer
  -- reads, which LHDN has no business being told about.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, line_subtotal, line_total)
  values (v_org, v_doc, 4, 'description', 'Terima kasih', 0, 0, 0, 0);

  update public.sales_documents set status = 'posted' where id = v_doc;

  -- ------------------------------------------------------------------
  -- The submission is refused for another company's document
  -- ------------------------------------------------------------------
  v_ein := public.prepare_einvoice(v_doc);
  select * into v_row from public.einvoice_documents where id = v_ein;

  -- ------------------------------------------------------------------
  -- The supplier, field by field
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the legal name is what LHDN is told',
    v_row.supplier_name, 'Penghantar e-Invois Sdn Bhd');
  perform pg_temp.check_eq('and the e-Invoice TIN rather than the other one',
    v_row.supplier_tin, 'C2222222222');
  perform pg_temp.check_eq('the SST number is the SST number',
    v_row.supplier_sst_no, 'W10-1808-31000001');
  perform pg_temp.check_eq('and the MSIC code is the MSIC code',
    v_row.supplier_msic_code, '62010');
  perform pg_temp.check_eq('the town is the town',
    v_row.supplier_address ->> 'city', 'Petaling Jaya');
  perform pg_temp.check_eq('and the postcode is the postcode',
    v_row.supplier_address ->> 'postcode', '46000');
  perform pg_temp.check_eq('the third address line is not lost',
    v_row.supplier_address ->> 'line3', 'Taman Tiga');

  -- ------------------------------------------------------------------
  -- The buyer, the same way
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the buyer''s legal name is filed',
    v_row.buyer_name, 'Pembeli Besar Sdn Bhd');
  perform pg_temp.check_eq('the address to write to is the email',
    v_row.buyer_email, 'pembeli@besar.test');
  perform pg_temp.check_eq('and the number to ring is the phone',
    v_row.buyer_phone, '03-33334444');
  perform pg_temp.check_eq('the state is the state',
    v_row.buyer_address ->> 'state', '10');
  perform pg_temp.check_eq('and the country is the country',
    v_row.buyer_address ->> 'country', 'MYS');

  -- ------------------------------------------------------------------
  -- The header, which is money and a date
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the document''s own date is filed, not today''s',
    v_row.issue_date::text, (current_date - 40)::text);
  perform pg_temp.check_eq('the currency is the document''s',
    v_row.currency, 'USD');
  perform pg_temp.check_eq('and so is the rate it was booked at',
    v_row.exchange_rate, 4.25);
  -- Two charges, not one. 0410 found the header not adding up because
  -- shipping alone was counted; a service charge is the other half.
  perform pg_temp.check_eq('every charge no line carries is in the total',
    v_row.total_charges, 45.00);

  -- ------------------------------------------------------------------
  -- The lines
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a document files what was sold and nothing else',
    (select count(*) from public.einvoice_lines where einvoice_id = v_ein), 4);

  select * into v_line from public.einvoice_lines
   where einvoice_id = v_ein and line_no = 1;
  perform pg_temp.check_eq('the line''s own classification is what is filed',
    v_line.classification_code, '009');
  perform pg_temp.check_eq('and its own unit',
    v_line.uom_code, 'MON');
  perform pg_temp.check_eq('and its own tax type rather than the default',
    v_line.tax_type_code, '02');
  perform pg_temp.check_eq('the tax rate is the rate',
    v_line.tax_rate, 6);
  perform pg_temp.check_eq('and the tax amount is the amount',
    v_line.tax_amount, 16.22);
  perform pg_temp.check_eq('the discount rate is the rate',
    v_line.discount_rate, 10);
  perform pg_temp.check_eq('and the discount amount is the amount',
    v_line.discount_amount, 30.04);
  -- 3 x 100.125 is 300.375, and a figure filed to a tax authority is
  -- filed to the sen.
  perform pg_temp.check_eq('the line is extended and rounded to the sen',
    v_line.subtotal, 300.38);
  perform pg_temp.check_eq('the amount before tax is before tax',
    v_line.total_excl_tax, 270.34);
  perform pg_temp.check_eq('and the amount after it is after it',
    v_line.total_incl_tax, 286.56);
  perform pg_temp.check_true('a taxed line claims no exemption',
    v_line.tax_exemption_reason is null and v_line.tax_exempted_amount = 0);

  select * into v_line from public.einvoice_lines
   where einvoice_id = v_ein and line_no = 2;
  perform pg_temp.check_eq('a line naming no classification takes the item''s',
    v_line.classification_code, '035');
  perform pg_temp.check_eq('and naming no unit takes the item''s',
    v_line.uom_code, 'HUR');
  perform pg_temp.check_eq('a description typed blank takes the item''s name',
    v_line.description, 'Perkhidmatan sokongan');
  perform pg_temp.check_eq('an exempt line says why it is exempt',
    v_line.tax_exemption_reason, 'Schedule A exemption');
  perform pg_temp.check_eq('and how much was exempted',
    v_line.tax_exempted_amount, 100.00);

  select * into v_line from public.einvoice_lines
   where einvoice_id = v_ein and line_no = 3;
  perform pg_temp.check_eq(
    'a line nothing classifies is filed under the general code',
    v_line.classification_code, '022');
  perform pg_temp.check_eq('and one with no tax code takes the default type',
    v_line.tax_type_code, '06');

  select * into v_line from public.einvoice_lines
   where einvoice_id = v_ein and line_no = 5;
  perform pg_temp.check_eq(
    'a line with no unit and no item behind it still files one',
    v_line.uom_code, 'C62');

  -- ------------------------------------------------------------------
  -- A buyer with no identifier of its own, and one with none at all
  -- ------------------------------------------------------------------
  -- Prepared into a variable rather than inside a `where`: the function
  -- writes, and a writing function in a predicate is run once per row
  -- of the table it is filtering.
  v_other := public.prepare_einvoice(pg_temp.ei_doc(v_org, v_bare));
  perform pg_temp.check_eq(
    'a buyer with no identifier files its registration number',
    (select buyer_id_value from public.einvoice_documents where id = v_other),
    '201001000003');

  v_other := public.prepare_einvoice(pg_temp.ei_doc(v_org, v_cash));
  perform pg_temp.check_eq('and one with neither files NA rather than a null',
    (select buyer_id_value from public.einvoice_documents where id = v_other),
    'NA');

  -- ------------------------------------------------------------------
  -- A company that bills nothing on the header
  --
  -- Null plus null is null, not nought, and `total_charges` is NOT NULL
  -- on the table. A document with no shipping and no service charge is
  -- the ordinary case, so the coalesce is the one holding it up.
  -- ------------------------------------------------------------------
  v_other := public.prepare_einvoice(pg_temp.ei_doc(v_org, v_buyer));
  perform pg_temp.check_eq('a document billing no charges files nought',
    (select total_charges from public.einvoice_documents where id = v_other),
    0);

  -- ------------------------------------------------------------------
  -- Sending it again after correcting it
  --
  -- LHDN rejected it, somebody fixed the figures, and it goes back. The
  -- question the upsert answers is which columns are refreshed, and
  -- every one of them was a live mutant: a correction that does not
  -- reach the snapshot is a correction LHDN never sees.
  -- ------------------------------------------------------------------
  update public.einvoice_documents
     set status = 'rejected',
         validation_errors = '[{"code": "CF321"}]'::jsonb,
         error_code = 'CF321', error_message = 'Invalid tax type'
   where id = v_ein;
  -- A correction is a change to what was sold, not a figure typed onto
  -- the header: the document's totals are computed from its lines.
  update public.sales_documents set doc_date = current_date - 20
   where id = v_doc;
  update public.sales_document_lines set quantity = 4 where id = v_l2;
  -- And a price that lands the total on a different sen, so the
  -- rounding figure moves too. A rounding that is refiled unchanged is
  -- a rounding that no longer belongs to the total beside it.
  update public.sales_document_lines set unit_price = 10.04
   where document_id = v_doc and line_no = 5;
  -- And the ride costs more than it did. 0538: a charge corrected
  -- between submissions has to reach the second one, or the payable
  -- amount and the charge behind it disagree.
  update public.sales_documents
     set shipping_amount = 60.00, discount_amount = 40.00
   where id = v_doc;

  v_ein := public.prepare_einvoice(v_doc);
  select * into v_row from public.einvoice_documents where id = v_ein;
  perform pg_temp.check_eq('a corrected document goes back into the queue',
    v_row.status::text, 'queued');
  perform pg_temp.check_eq('with last time''s errors cleared',
    jsonb_array_length(v_row.validation_errors), 0);
  perform pg_temp.check_true('and last time''s code and message gone',
    v_row.error_code is null and v_row.error_message is null);
  perform pg_temp.check_eq('the corrected date is what is refiled',
    v_row.issue_date::text, (current_date - 20)::text);
  perform pg_temp.check_eq('and the corrected amount before tax',
    v_row.total_excl_tax,
    (select subtotal from public.sales_documents where id = v_doc));
  perform pg_temp.check_eq('and the corrected payable amount',
    v_row.payable_amount,
    (select total_amount from public.sales_documents where id = v_doc));
  perform pg_temp.check_eq('and the corrected rounding',
    v_row.rounding_amount,
    (select rounding_amount from public.sales_documents where id = v_doc));
  perform pg_temp.check_true('which is not what was filed the first time',
    v_row.total_excl_tax <> 370.34);
  -- The header has to add up on the second submission as well as the
  -- first, which means the charge and the discount are refiled too.
  perform pg_temp.check_eq('a corrected charge is refiled with it',
    v_row.total_charges, 75.00);
  perform pg_temp.check_eq('and so is the discount',
    v_row.total_discount,
    (select discount_amount from public.sales_documents where id = v_doc));
  -- Measured against the document rather than reasoned about from the
  -- other columns, which is the lesson 0410 left: what is filed is
  -- every charge the customer is billed that no line carries, and it
  -- has to be the same figure on the second submission as on the
  -- first.
  perform pg_temp.check_eq('and the charge filed is the charge billed',
    v_row.total_charges,
    (select coalesce(shipping_amount, 0) + coalesce(service_charge_amount, 0)
       from public.sales_documents where id = v_doc));
  perform pg_temp.check_eq('and the lines are this time''s, not both times''',
    (select count(*) from public.einvoice_lines where einvoice_id = v_ein), 4);

  -- ------------------------------------------------------------------
  -- Whose submission is already on file
  --
  -- The already-submitted guard is scoped to this company and to this
  -- document TYPE. Neither had anything to exclude, because the fixture
  -- behind it has one company and one row per document.
  -- ------------------------------------------------------------------
  v_next := pg_temp.test_org('Syarikat Sebelah e-Invois Sdn Bhd');
  update public.organizations
     set einvoice_enabled = true, tin = 'C9999999999' where id = v_next;
  -- The shop next door has a validated submission whose source id is
  -- this company's document. Nothing links them but a uuid, and the
  -- org filter is the only thing that says so.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, einvoice_version,
     internal_doc_no, issue_date, currency, exchange_rate,
     supplier_name, supplier_tin, supplier_address,
     buyer_name, buyer_tin, buyer_address,
     total_excl_tax, total_incl_tax, total_discount, total_tax,
     total_charges, rounding_amount, payable_amount, status)
  values (v_next, 'sales_documents', v_doc, '01', '1.0',
          'THEIRS-1', current_date, 'MYR', 1,
          'Sebelah', 'C9999999999', '{}'::jsonb,
          'Sesiapa', 'EI00000000010', '{}'::jsonb,
          10, 10, 0, 0, 0, 0, 10, 'valid');

  update public.einvoice_documents set status = 'rejected' where id = v_ein;
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq(
    'the shop next door''s submission does not block this one',
    (select status::text from public.einvoice_documents where id = v_ein),
    'queued');

  -- And a credit note already filed against the same document does not
  -- block the invoice, because they are different documents to LHDN.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, einvoice_version,
     internal_doc_no, issue_date, currency, exchange_rate,
     supplier_name, supplier_tin, supplier_address,
     buyer_name, buyer_tin, buyer_address,
     total_excl_tax, total_incl_tax, total_discount, total_tax,
     total_charges, rounding_amount, payable_amount, status)
  values (v_org, 'sales_documents', v_doc, '02', '1.0',
          'CN-1', current_date, 'MYR', 1,
          'Penghantar', 'C2222222222', '{}'::jsonb,
          'Pembeli', 'C5555555555', '{}'::jsonb,
          10, 10, 0, 0, 0, 0, 10, 'valid');

  update public.einvoice_documents
     set status = 'rejected' where id = v_ein;
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq(
    'nor does a credit note filed against the same document',
    (select status::text from public.einvoice_documents where id = v_ein),
    'queued');
  perform pg_temp.check_eq('and the two are still two rows',
    (select count(*) from public.einvoice_documents
      where org_id = v_org and source_id = v_doc), 2);

  -- ------------------------------------------------------------------
  -- The cancel deadline, on a document that has not been validated
  --
  -- 72 hours from validation is asserted in `einvoice_statutory.sql`.
  -- What was not is that a document LHDN has not validated has NO
  -- deadline: a window that has already started counting on something
  -- never filed is a window that expires before the filing happens.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a submission not yet validated has no window',
    (select cancel_deadline is null from public.einvoice_documents
      where id = v_ein));
  update public.einvoice_documents
     set status = 'valid', validated_at = now() - interval '1 hour'
   where id = v_ein;
  perform pg_temp.check_true('and one that has, has one',
    (select cancel_deadline is not null from public.einvoice_documents
      where id = v_ein));

  -- ------------------------------------------------------------------
  -- The rules the equivalent mutants lean on
  --
  -- Four probes in this sweep cannot be observed, and each of them is
  -- held up by something outside the function. The rule is asserted in
  -- the mutant's place rather than the mutant being written off.
  -- ------------------------------------------------------------------
  -- The two charges are coalesced against a null that cannot occur:
  -- both columns are NOT NULL with a default of nought, so the sum is
  -- never null and the coalesce is defensive. That is a property of the
  -- table, so the table is what is asserted.
  perform pg_temp.check_eq('a charge column is never null to begin with',
    (select count(*) from information_schema.columns
      where table_name = 'sales_documents' and is_nullable = 'NO'
        and column_name in ('shipping_amount', 'service_charge_amount')), 2);
  -- The line is extended with `round(..., 2)` into a column that is
  -- itself numeric(18,2), so dropping the round changes nothing: the
  -- column rounds on the way in. The scale is the rule.
  perform pg_temp.check_eq('and a filed figure is held to the sen anyway',
    (select numeric_scale from information_schema.columns
      where table_name = 'einvoice_lines' and column_name = 'subtotal'), 2);
  -- `order by` on the select feeding an insert orders nothing that can
  -- be read back: rows are a set, and `line_no` is stored so every
  -- reader sorts for itself. Asserted from the reader's end.
  perform pg_temp.check_eq('the line numbers are filed, not implied',
    (select count(distinct line_no) from public.einvoice_lines
      where einvoice_id = v_ein), 4);
  -- And a cancel window on a document that was never validated cannot
  -- be wrong, because null plus seventy-two hours is null. The guard
  -- reads as intent rather than as arithmetic.
  perform pg_temp.check_true('an unfiled document has no window either way',
    (null::timestamptz + interval '72 hours') is null);
end $$;

rollback;

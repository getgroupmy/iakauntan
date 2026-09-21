-- =====================================================================
-- iAkauntan :: the invoice a supplier sent us
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/received_einvoice.sql
--
-- `0650` keeps a parsed MyInvois document and turns it into a draft
-- bill. The parse itself is asserted in Deno, against the builder that
-- writes the same binding; what is asserted HERE is everything that
-- happens after the parse, and most of it is about a document written
-- by somebody whose software we have never seen:
--
--   * the same document imported twice is one row, and the second
--     import answers with the first row rather than raising;
--   * a field that should be a number and is the word "later" costs
--     that field and not the import;
--   * line identifiers that repeat, or are absent, do not collide on
--     the unique constraint;
--   * a classification code we do not stock stays on the received line
--     and does not reach the bill, rather than refusing the import;
--   * the supplier is matched by IDENTIFIER and never by name;
--   * and the bill's total, which our own triggers compute, is
--     compared against what the supplier said was payable, with the
--     difference written down.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A document, in the shape `ubl_parse.ts` returns
-- ---------------------------------------------------------------------
create or replace function pg_temp.parsed(
  p_doc_no text default 'INV-9001',
  p_type   text default '01',
  p_tin    text default 'C1234567890')
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'docNo', p_doc_no,
    'issueDate', '2026-03-15',
    'issueTime', '10:30:00Z',
    'typeCode', p_type,
    'version', '1.1',
    'currency', 'MYR',
    'exchangeRate', 1,
    'supplier', jsonb_build_object(
      'name', 'Pembekal Jaya Sdn Bhd',
      'tin', p_tin,
      'idType', 'BRN',
      'idValue', '201901234567',
      'sstNo', 'W10-1808-31000001',
      'email', 'akaun@pembekaljaya.test',
      'phone', '+60312345678',
      'address', jsonb_build_object(
        'line1', '12 Jalan Perusahaan',
        'line2', 'Taman Industri',
        'line3', null,
        'city', 'Shah Alam',
        'postcode', '40000',
        'state', '10',
        'country', 'MYS')),
    'buyer', jsonb_build_object(
      'name', 'Kedai Kita Sdn Bhd',
      'tin', 'C9876543210',
      'idType', 'BRN',
      'idValue', '202001234567',
      'sstNo', null,
      'email', null,
      'phone', null,
      'address', '{}'::jsonb),
    'totalExclTax', 200.00,
    'totalInclTax', 212.00,
    'totalDiscount', 0,
    'totalCharges', 0,
    'totalTax', 12.00,
    'roundingAmount', 0,
    'payableAmount', 212.00,
    'originalDocNo', null,
    'originalUuid', null,
    'lines', jsonb_build_array(
      jsonb_build_object(
        'lineNo', 1,
        'classificationCode', '022',
        'description', 'Kertas A4 80gsm',
        'quantity', 10,
        'uomCode', 'C62',
        'unitPrice', 12.00,
        'discountAmount', 0,
        'taxTypeCode', '01',
        'taxRate', 6,
        'taxAmount', 7.20,
        'taxExemptionReason', null,
        'totalExclTax', 120.00,
        'totalInclTax', 127.20,
        'productTariffCode', null,
        'countryOfOrigin', 'MYS'),
      jsonb_build_object(
        'lineNo', 2,
        'classificationCode', '022',
        'description', 'Dakwat pencetak',
        'quantity', 2,
        'uomCode', 'C62',
        'unitPrice', 40.00,
        'discountAmount', 0,
        'taxTypeCode', '01',
        'taxRate', 6,
        'taxAmount', 4.80,
        'taxExemptionReason', null,
        'totalExclTax', 80.00,
        'totalInclTax', 84.80,
        'productTariffCode', null,
        'countryOfOrigin', 'MYS')),
    'problems', '[]'::jsonb);
$$;

do $$
declare
  v_me      uuid := pg_temp.test_user();
  v_org     uuid;
  v_res     jsonb;
  v_id      uuid;
  v_again   jsonb;
  v_contact uuid;
  v_bill    uuid;
  v_row     public.received_einvoices;
  v_count   integer;
  v_text    text;
  v_num     numeric;
begin
  v_org := pg_temp.test_org('Kedai Kita');
  perform pg_temp.sign_in_as(v_me);

  -- -------------------------------------------------------------------
  -- 1. It keeps what arrived
  -- -------------------------------------------------------------------
  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed(), pg_temp.parsed());
  v_id := (v_res ->> 'id')::uuid;

  perform pg_temp.check_true('first import is not a duplicate',
    (v_res ->> 'duplicate')::boolean is false);

  select * into v_row from public.received_einvoices where id = v_id;
  perform pg_temp.check_eq('document number', v_row.doc_no, 'INV-9001');
  perform pg_temp.check_eq('issue date', v_row.issue_date::text, '2026-03-15');
  perform pg_temp.check_eq('supplier name', v_row.supplier_name,
    'Pembekal Jaya Sdn Bhd');
  perform pg_temp.check_eq('supplier TIN', v_row.supplier_tin, 'C1234567890');
  perform pg_temp.check_eq('payable', v_row.payable_amount, 212.00);
  perform pg_temp.check_eq('status', v_row.status, 'received');
  perform pg_temp.check_true('the raw document is kept whole',
    v_row.raw -> 'lines' is not null);

  -- The time carried a zone suffix, which `time` cannot take. It must
  -- be trimmed rather than raising and losing the document.
  perform pg_temp.check_eq('issue time', v_row.issue_time::text, '10:30:00');

  select count(*) into v_count from public.received_einvoice_lines
   where received_id = v_id;
  perform pg_temp.check_eq('both lines kept', v_count, 2);

  select total_incl_tax into v_num from public.received_einvoice_lines
   where received_id = v_id and line_no = 2;
  perform pg_temp.check_eq('second line total', v_num, 84.80);

  -- -------------------------------------------------------------------
  -- 2. The same document twice is one row
  -- -------------------------------------------------------------------
  -- Somebody forwards the e-mail again. Two rows would become two
  -- draft bills and one supplier paid twice, so the second import must
  -- return the FIRST row rather than raising -- a duplicate is an
  -- answer, not an error.
  --
  -- (That the hash survives re-formatting is a property of the jsonb
  -- rendering and is asserted where it can be: the self-check at the
  -- foot of 0650, against two differently spaced literals. Once a
  -- document is jsonb the formatting is already gone.)
  v_again := public.record_received_einvoice(
    v_org,
    pg_temp.parsed(),
    jsonb_build_object('lines', pg_temp.parsed() -> 'lines')
      || (pg_temp.parsed() - 'lines'));

  perform pg_temp.check_true('a re-export is a duplicate',
    (v_again ->> 'duplicate')::boolean);
  perform pg_temp.check_eq('and it names the first row',
    (v_again ->> 'id'), v_id::text);

  select count(*) into v_count from public.received_einvoices where org_id = v_org;
  perform pg_temp.check_eq('still one row', v_count, 1);

  -- -------------------------------------------------------------------
  -- 3. A different document is a different row
  -- -------------------------------------------------------------------
  perform public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-9002'), pg_temp.parsed('INV-9002'));
  select count(*) into v_count from public.received_einvoices where org_id = v_org;
  perform pg_temp.check_eq('two documents, two rows', v_count, 2);

  -- -------------------------------------------------------------------
  -- 4. One unreadable field does not cost the document
  -- -------------------------------------------------------------------
  -- This is the whole argument for `app.received_num`. A producer who
  -- writes "later" where a number belongs must lose that number and
  -- nothing else, because the alternative is an import that fails with
  -- a cast error nobody can act on.
  v_res := public.record_received_einvoice(
    v_org,
    jsonb_set(
      jsonb_set(pg_temp.parsed('INV-9003'), '{payableAmount}', '"later"'::jsonb),
      '{issueDate}', '"15 March"'::jsonb),
    pg_temp.parsed('INV-9003'));
  select * into v_row from public.received_einvoices
   where id = (v_res ->> 'id')::uuid;
  perform pg_temp.check_eq('an unreadable amount is zero', v_row.payable_amount, 0);
  perform pg_temp.check_true('an unreadable date is null', v_row.issue_date is null);
  perform pg_temp.check_eq('and the rest arrived', v_row.doc_no, 'INV-9003');

  -- -------------------------------------------------------------------
  -- 5. Line identifiers are the document's opinion, not our key
  -- -------------------------------------------------------------------
  -- `ubl_parse.ts` reads `lineNo` straight out of the document's `ID`.
  -- A producer that numbers every line "1" would collide on
  -- (received_id, line_no) and take out the import, so the position is
  -- counted here and what the document said is kept beside it.
  v_res := public.record_received_einvoice(
    v_org,
    jsonb_set(
      jsonb_set(pg_temp.parsed('INV-9004'), '{lines,0,lineNo}', '"1"'::jsonb),
      '{lines,1,lineNo}', '"1"'::jsonb),
    pg_temp.parsed('INV-9004'));
  select count(*) into v_count from public.received_einvoice_lines
   where received_id = (v_res ->> 'id')::uuid;
  perform pg_temp.check_eq('both lines survive identical identifiers', v_count, 2);

  select string_agg(line_no::text || '/' || coalesce(source_line_no, '-'), ' '
                    order by line_no)
    into v_text
    from public.received_einvoice_lines
   where received_id = (v_res ->> 'id')::uuid;
  perform pg_temp.check_eq('position counted, opinion kept', v_text, '1/1 2/1');

  -- -------------------------------------------------------------------
  -- 6. The supplier is matched by identifier, never by name
  -- -------------------------------------------------------------------
  select * into v_row from public.received_einvoices where id = v_id;
  perform pg_temp.check_true('nothing matched yet', v_row.contact_id is null);

  -- A contact with the same NAME and no TIN. This must NOT match:
  -- "Pembekal Jaya" and "Pembekal Jaya Sdn Bhd" are two rows in most
  -- contact lists and a link nobody chose becomes a bill against the
  -- wrong supplier.
  insert into public.contacts (org_id, code, contact_type, name)
  values (v_org, 'S-NAME', 'supplier', 'Pembekal Jaya Sdn Bhd');

  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-9005'), pg_temp.parsed('INV-9005'));
  select * into v_row from public.received_einvoices
   where id = (v_res ->> 'id')::uuid;
  perform pg_temp.check_true('a name alone does not match',
    v_row.contact_id is null);

  -- The same name WITH the TIN does.
  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'S-TIN', 'supplier', 'Pembekal Jaya Sdn Bhd', 'C1234567890')
  returning id into v_contact;

  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-9006'), pg_temp.parsed('INV-9006'));
  select * into v_row from public.received_einvoices
   where id = (v_res ->> 'id')::uuid;
  perform pg_temp.check_eq('the TIN matches',
    v_row.contact_id::text, v_contact::text);

  -- -------------------------------------------------------------------
  -- 7. The client cannot edit what arrived
  -- -------------------------------------------------------------------
  -- There is no update policy AND no update grant. A record of what a
  -- supplier sent is worthless if the person who received it can change
  -- the figures.
  --
  -- Asked as `authenticated`, because the owner of the schema bypasses
  -- both barriers: run as postgres this passes with every grant and
  -- every policy deleted, which is the shape of a test that proves
  -- nothing.
  set local role authenticated;
  perform pg_temp.check_refused(
    'no direct update of a received document',
    format('update public.received_einvoices set payable_amount = 1 where id = %L', v_id),
    '%permission denied%');

  perform pg_temp.check_refused(
    'no direct insert either',
    format($q$insert into public.received_einvoices
              (org_id, raw, payload_hash) values (%L, '{}'::jsonb, 'x')$q$, v_org),
    '%permission denied%');

  -- Deleting the whole row IS allowed: "this was not for us". Also as
  -- `authenticated`, so it is the policy answering and not ownership.
  delete from public.received_einvoices
   where org_id = v_org and doc_no = 'INV-9005';
  select count(*) into v_count from public.received_einvoices
   where org_id = v_org and doc_no = 'INV-9005';
  perform pg_temp.check_eq('a document can be thrown away', v_count, 0);
  reset role;

  -- And the grants are what the sentences above claim they are, so a
  -- refusal that came from somewhere else cannot pass for this one.
  perform pg_temp.check_true('nothing may update it',
    not has_table_privilege('authenticated', 'public.received_einvoices', 'update'));
  perform pg_temp.check_true('nor insert into it',
    not has_table_privilege('authenticated', 'public.received_einvoices', 'insert'));
  perform pg_temp.check_true('and anon has none of it',
    not has_table_privilege('anon', 'public.received_einvoices', 'select'));

  -- -------------------------------------------------------------------
  -- 8. Status moves only where a function says it may
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused(
    'billed is not a status anybody can type',
    format('select public.set_received_einvoice_status(%L, %L)', v_id, 'billed'),
    '%received or ignored%', '22023');

  perform pg_temp.check_refused(
    'nor anything else',
    format('select public.set_received_einvoice_status(%L, %L)', v_id, 'paid'),
    '%received or ignored%', '22023');

  v_row := public.set_received_einvoice_status(v_id, 'ignored');
  perform pg_temp.check_eq('ignored sticks', v_row.status, 'ignored');
  v_row := public.set_received_einvoice_status(v_id, 'received');
  perform pg_temp.check_eq('and comes back', v_row.status, 'received');

  -- -------------------------------------------------------------------
  -- 9. Creating the supplier, once
  -- -------------------------------------------------------------------
  -- INV-9003 is the one with no contact and a supplier TIN that now
  -- exists on file, so it must LINK rather than make a second row.
  select id into v_id from public.received_einvoices
   where org_id = v_org and doc_no = 'INV-9003';
  v_contact := public.create_supplier_from_received_einvoice(v_id);
  select count(*) into v_count from public.contacts
   where org_id = v_org and tin = 'C1234567890';
  perform pg_temp.check_eq('a known TIN is linked, not duplicated', v_count, 1);

  -- A supplier genuinely not on file IS created, with what the document
  -- said about it.
  v_res := public.record_received_einvoice(
    v_org,
    pg_temp.parsed('INV-9007', '01', 'C5555555555'),
    pg_temp.parsed('INV-9007', '01', 'C5555555555'));
  v_id := (v_res ->> 'id')::uuid;
  v_contact := public.create_supplier_from_received_einvoice(v_id);

  select name into v_text from public.contacts where id = v_contact;
  perform pg_temp.check_eq('created with its name', v_text,
    'Pembekal Jaya Sdn Bhd');
  select sst_registration_no into v_text from public.contacts where id = v_contact;
  perform pg_temp.check_eq('and its SST number', v_text, 'W10-1808-31000001');
  select city into v_text from public.contacts where id = v_contact;
  perform pg_temp.check_eq('and its address', v_text, 'Shah Alam');
  select contact_type::text into v_text from public.contacts where id = v_contact;
  perform pg_temp.check_eq('as a supplier', v_text, 'supplier');

  -- A second call returns the same contact rather than a second row.
  perform pg_temp.check_eq('creating twice creates once',
    public.create_supplier_from_received_einvoice(v_id)::text, v_contact::text);

  -- -------------------------------------------------------------------
  -- 10. The draft bill
  -- -------------------------------------------------------------------
  v_bill := public.draft_bill_from_received_einvoice(v_id);

  select doc_type::text into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('type 01 becomes a bill', v_text, 'bill');
  select supplier_doc_no into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('carrying the supplier document number',
    v_text, 'INV-9007');
  select status::text into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('as a draft', v_text, 'draft');

  select count(*) into v_count from public.purchase_document_lines
   where document_id = v_bill;
  perform pg_temp.check_eq('with both lines', v_count, 2);

  -- Our own triggers computed this from the lines: 120 + 80 = 200, tax
  -- at 6% = 12, total 212. It agrees with the document, so there is
  -- nothing to explain.
  select total_amount into v_num from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('and it adds up to what was asked', v_num, 212.00);
  select internal_notes into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_true('no note when the figures agree', v_text is null);

  select * into v_row from public.received_einvoices where id = v_id;
  perform pg_temp.check_eq('the document is now billed', v_row.status, 'billed');
  perform pg_temp.check_eq('and names the bill', v_row.bill_id::text, v_bill::text);

  perform pg_temp.check_refused(
    'and will not be billed twice',
    format('select public.draft_bill_from_received_einvoice(%L)', v_id),
    '%already on a bill%', '22023');

  perform pg_temp.check_refused(
    'nor have its supplier changed underneath the bill',
    format('select public.link_received_einvoice_contact(%L, null)', v_id),
    '%already on a bill%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- The refusals, and the one difference that has to be written down
-- ---------------------------------------------------------------------
do $$
declare
  v_me      uuid := pg_temp.test_user();
  v_org     uuid;
  v_res     jsonb;
  v_id      uuid;
  v_bill    uuid;
  v_text    text;
  v_num     numeric;
  v_doc     jsonb;
begin
  v_org := pg_temp.test_org('Syarikat Kedua');
  perform pg_temp.sign_in_as(v_me);

  -- -------------------------------------------------------------------
  -- 11. A bill needs a supplier, a currency we know, and a type that
  --     has somewhere to go
  -- -------------------------------------------------------------------
  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-1'), pg_temp.parsed('INV-1'));
  v_id := (v_res ->> 'id')::uuid;

  perform pg_temp.check_refused(
    'no supplier, no bill',
    format('select public.draft_bill_from_received_einvoice(%L)', v_id),
    '%Link a supplier%', '22023');

  perform public.create_supplier_from_received_einvoice(v_id);

  -- A refund note (04) and a self-billed invoice (11) have no purchase
  -- document to become. Guessing one would post the wrong sign.
  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-2', '04'), pg_temp.parsed('INV-2', '04'));
  perform public.create_supplier_from_received_einvoice((v_res ->> 'id')::uuid);
  perform pg_temp.check_refused(
    'a refund note has no purchase document',
    format('select public.draft_bill_from_received_einvoice(%L)', (v_res ->> 'id')::uuid),
    '%type 04 has no purchase document%', '22023');

  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-3', '11'), pg_temp.parsed('INV-3', '11'));
  perform public.create_supplier_from_received_einvoice((v_res ->> 'id')::uuid);
  perform pg_temp.check_refused(
    'nor does a self-billed invoice we did not issue',
    format('select public.draft_bill_from_received_einvoice(%L)', (v_res ->> 'id')::uuid),
    '%type 11 has no purchase document%', '22023');

  -- A currency this company does not stock. Substituting ringgit would
  -- be a bill for the right number of the wrong money.
  v_doc := jsonb_set(pg_temp.parsed('INV-4'), '{currency}', '"ZZZ"'::jsonb);
  v_res := public.record_received_einvoice(v_org, v_doc, v_doc);
  perform public.create_supplier_from_received_einvoice((v_res ->> 'id')::uuid);
  perform pg_temp.check_refused(
    'an unknown currency is named, not substituted',
    format('select public.draft_bill_from_received_einvoice(%L)', (v_res ->> 'id')::uuid),
    '%ZZZ is not one this company knows%', '22023');

  -- A credit note DOES have one.
  v_res := public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-5', '02'), pg_temp.parsed('INV-5', '02'));
  perform public.create_supplier_from_received_einvoice((v_res ->> 'id')::uuid);
  v_bill := public.draft_bill_from_received_einvoice((v_res ->> 'id')::uuid);
  select doc_type::text into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('type 02 becomes a purchase credit note',
    v_text, 'purchase_credit_note');

  -- -------------------------------------------------------------------
  -- 12. A code we do not stock stays on the received line
  -- -------------------------------------------------------------------
  -- The foreign key on `purchase_document_lines.classification_code`
  -- would refuse the whole bill over a code nobody reads.
  v_doc := jsonb_set(
    jsonb_set(pg_temp.parsed('INV-6'), '{lines,0,classificationCode}', '"999"'::jsonb),
    '{lines,0,uomCode}', '"ZZZ"'::jsonb);
  v_res := public.record_received_einvoice(v_org, v_doc, v_doc);
  v_id := (v_res ->> 'id')::uuid;
  perform public.create_supplier_from_received_einvoice(v_id);

  select classification_code into v_text from public.received_einvoice_lines
   where received_id = v_id and line_no = 1;
  perform pg_temp.check_eq('what arrived is kept', v_text, '999');

  v_bill := public.draft_bill_from_received_einvoice(v_id);
  select classification_code into v_text from public.purchase_document_lines
   where document_id = v_bill and line_no = 1;
  perform pg_temp.check_true('and does not reach the bill', v_text is null);
  select uom_code into v_text from public.purchase_document_lines
   where document_id = v_bill and line_no = 1;
  perform pg_temp.check_true('same for a unit we do not stock', v_text is null);
  -- The recognised code on the OTHER line still does.
  select classification_code into v_text from public.purchase_document_lines
   where document_id = v_bill and line_no = 2;
  perform pg_temp.check_eq('a recognised code does', v_text, '022');

  -- -------------------------------------------------------------------
  -- 13. A total that does not agree is written down, not silently lost
  -- -------------------------------------------------------------------
  -- Our triggers recompute the bill from the lines, so the supplier's
  -- stated payable amount CANNOT be written onto it. That is right --
  -- the bill goes into our ledger -- but the difference is the one
  -- thing somebody about to pay this needs to see.
  v_doc := jsonb_set(pg_temp.parsed('INV-7'), '{payableAmount}', '250.00'::jsonb);
  v_res := public.record_received_einvoice(v_org, v_doc, v_doc);
  v_id := (v_res ->> 'id')::uuid;
  perform public.create_supplier_from_received_einvoice(v_id);
  v_bill := public.draft_bill_from_received_einvoice(v_id);

  select total_amount into v_num from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('the bill is what the lines come to', v_num, 212.00);

  select internal_notes into v_text from public.purchase_documents where id = v_bill;
  perform pg_temp.check_true('the difference is on the bill',
    v_text like '%212.00%' and v_text like '%250.00%' and v_text like '%-38.00%');

  -- -------------------------------------------------------------------
  -- 14. A document-level charge has somewhere to land
  -- -------------------------------------------------------------------
  -- `ubl_parse.ts` does not read line-level charges at all, so the
  -- charge total is the only record of that money.
  v_doc := jsonb_set(pg_temp.parsed('INV-8'), '{totalCharges}', '15.00'::jsonb);
  v_res := public.record_received_einvoice(v_org, v_doc, v_doc);
  v_id := (v_res ->> 'id')::uuid;
  perform public.create_supplier_from_received_einvoice(v_id);
  v_bill := public.draft_bill_from_received_einvoice(v_id);

  select shipping_amount into v_num from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('the charge is carried', v_num, 15.00);
  select total_amount into v_num from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('and is in the total', v_num, 227.00);
end $$;

-- ---------------------------------------------------------------------
-- Somebody else's company
-- ---------------------------------------------------------------------
do $$
declare
  v_me      uuid := pg_temp.test_user();
  v_other   uuid := pg_temp.another_user('outsider@iakauntan.test');
  v_org     uuid;
  v_id      uuid;
  v_count   integer;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Syarikat Ketiga');
  v_id := (public.record_received_einvoice(
    v_org, pg_temp.parsed('INV-X'), pg_temp.parsed('INV-X')) ->> 'id')::uuid;

  perform pg_temp.sign_in_as(v_other);

  perform pg_temp.check_refused(
    'an outsider cannot record against this company',
    format('select public.record_received_einvoice(%L, %L::jsonb, %L::jsonb)',
           v_org, '{}', '{"a":1}'),
    '%Not allowed to record%', '42501');

  set local role authenticated;
  select count(*) into v_count from public.received_einvoices where org_id = v_org;
  reset role;
  perform pg_temp.check_eq('nor read what is there', v_count, 0);

  -- These two DO find the row -- they are SECURITY DEFINER and read
  -- past row level security by design -- and then refuse on the
  -- permission. Asserted on the permission's own wording, so a future
  -- change that dropped the guard and happened to raise `P0002` for
  -- some other reason could not pass for this.
  perform pg_temp.check_refused(
    'nor draft a bill from it',
    format('select public.draft_bill_from_received_einvoice(%L)', v_id),
    '%Not allowed to create bills%', '42501');

  perform pg_temp.check_refused(
    'nor change its status',
    format('select public.set_received_einvoice_status(%L, %L)', v_id, 'ignored'),
    '%Not allowed to change%', '42501');

  -- A uuid that is not a document at all is told so, which is the
  -- branch the two above are NOT taking.
  perform pg_temp.check_refused(
    'and an unknown id is simply unknown',
    format('select public.set_received_einvoice_status(%L, %L)',
           gen_random_uuid(), 'ignored'),
    '%No such received e-Invoice%', 'P0002');
end $$;

rollback;

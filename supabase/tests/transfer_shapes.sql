-- =====================================================================
-- iAkauntan :: what a quotation carries into an invoice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transfer_shapes.sql
--
-- `public.transfer_document` turns a quotation into an order, an order
-- into a delivery note, and any of them into an invoice — and does the
-- same on the buying side. Every column it carries forward is a term
-- somebody agreed to, and every column it drops is a term that
-- quietly stops applying.
--
-- Five files exercised it before this one and between them they killed
-- 59 of 98 one-line mutants, which is a real defence: the money is well
-- covered, and `transfer_carries_the_price_agreed.sql` is the reason.
--
-- What none of them had is a document with anything OPTIONAL on it. The
-- quotations they transfer carry no reference, no subject, no notes, no
-- terms and conditions, no salesperson, no opportunity, no matter, no
-- branch, and their lines carry no unit, no classification, no
-- warehouse, no account and no project. So every one of those could be
-- dropped on the way across, or swapped with the column beside it, and
-- nothing would read differently.
--
-- This file quotes a job with all of it filled in, and with no two
-- fields alike, so a column carried into the wrong slot reads as the
-- wrong sentence rather than as another null. It also puts a duplicate
-- row in front of the right one on both the customer and the prospect,
-- because which of several matching rows is chosen is a tie-break that
-- no single-row fixture can see.
--
-- With it the same sweep kills 92 of 98. The six that live change
-- nothing observable and are written up in `docs/unreachable.md`.
--
-- Two of the refusals here are only visible on a document with NO
-- payment terms: `app.document_due_date_guard` fills a null due date
-- from the same terms this function reads, so on a document that has
-- them the trigger and the function reach the same answer and neither
-- can be told from the other.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A posted one-line quotation. Each expiry assertion below needs its
-- own, because transferring one consumes the quantity on its lines and
-- the next call would be refused for having nothing left rather than
-- for the reason under test.
create or replace function pg_temp.tq(
  p_org uuid, p_cust uuid, p_item uuid, p_valid date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, contact_id,
     currency, exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'quotation', 'QT-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, p_valid, p_cust, 'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item', p_item, 'Alat ganti', 1, 40);
  update public.sales_documents set status = 'posted' where id = v_id;
  return v_id;
end;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Pindah Dokumen Sdn Bhd');
  v_cust   uuid;
  v_supp   uuid;
  v_pros   uuid;
  v_pcust  uuid;
  v_person uuid;
  v_addr   uuid;
  v_pperson uuid;
  v_paddr  uuid;
  v_seller uuid;
  v_branch uuid;
  v_wh     uuid;
  v_acct   uuid;
  v_tax    uuid;
  v_item   uuid;
  v_plain  uuid;
  v_terms  uuid;
  v_q      uuid;
  v_so     uuid;
  v_inv    uuid;
  v_po     uuid;
  v_bill   uuid;
  v_l1     uuid;
  v_opp    uuid;
  v_pipe   uuid;
  v_stage  uuid;
  v_matter uuid;
  v_noterm uuid;
  v_dead   uuid;
  v_two    uuid;
  v_npo    uuid;
  v_pros2  uuid;
  v_pcust2 uuid;
  v_pperson2 uuid;
  v_paddr2 uuid;
  v_pros3  uuid;
  v_pcust3 uuid;
  v_pperson3 uuid;
  v_pq     uuid;
  v_t1     uuid;
  v_t2     uuid;
  v_t3     uuid;
  v_l2     uuid;
  v_doc    record;
  v_line   record;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  -- ------------------------------------------------------------------
  -- Everything a document can point at, each one distinguishable
  -- ------------------------------------------------------------------
  insert into public.branches (org_id, code, name)
  values (v_org, 'JB', 'Cawangan Johor') returning id into v_branch;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'GUDANG', 'Gudang utama') returning id into v_wh;
  insert into public.payment_terms (org_id, code, name, days, term_type)
  values (v_org, 'NET45', '45 days', 45, 'net') returning id into v_terms;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'ST6X', 'Service tax 6%', '02', 6, 'sales')
  returning id into v_tax;
  select id into v_acct from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group
     and deleted_at is null order by code limit 1;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-PINDAH', 'Pelanggan Pindah Sdn Bhd', 'customer')
  returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-PINDAH', 'Pembekal Pindah Sdn Bhd', 'supplier')
  returning id into v_supp;

  insert into public.contact_persons
    (org_id, contact_id, name, email, designation, is_primary)
  values (v_org, v_cust, 'Encik Rosli', 'rosli@pelanggan.test',
          'Pengurus Pembelian', true)
  returning id into v_person;
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode, city, is_default)
  values (v_org, v_cust, 'Gudang', '88 Jalan Hantar', '81100', 'Johor Bahru',
          true)
  returning id into v_addr;

  -- The same customer, twice on file. A duplicate row is what a
  -- contact list accumulates, and this one is the primary of the two
  -- while the quotation names the other. Nothing should re-resolve a
  -- customer's own person or door: the redirection below is for a
  -- prospect and for nobody else, and these duplicates are what makes
  -- that difference visible rather than a distinction without one.
  update public.contact_persons set is_primary = false where id = v_person;
  update public.contact_addresses set is_default = false where id = v_addr;
  insert into public.contact_persons
    (org_id, contact_id, name, email, designation, is_primary)
  values (v_org, v_cust, 'Encik Rosli', 'rosli@pelanggan.test',
          'Salinan pendua', true);
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode, city, is_default)
  values (v_org, v_cust, 'Gudang', '88 Jalan Hantar', '81100', 'Johor Bahru',
          true);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, classification_code)
  values (v_org, 'KERJA', 'Kerja penyelenggaraan', 'service', false, 'HUR',
          100, 0, '035')
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'ALAT', 'Alat ganti', 'service', false, 'C62', 40, 0)
  returning id into v_plain;

  insert into public.salespeople (org_id, code, name)
  values (v_org, 'SP1', 'Puan Salmah') returning id into v_seller;
  insert into public.pipelines (org_id, name, is_default)
  values (v_org, 'Jualan biasa', true) returning id into v_pipe;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, sort_order)
  values (v_org, v_pipe, 'Sebut harga dihantar', 60, 1)
  returning id into v_stage;
  insert into public.opportunities
    (org_id, opportunity_no, name, contact_id, pipeline_id, stage_id,
     amount, expected_close_date)
  values (v_org, 'OPP-PINDAH-1', 'Kontrak penyelenggaraan', v_cust,
          v_pipe, v_stage, 5000, current_date + 60)
  returning id into v_opp;

  -- A matter and an opportunity are two different pointers, and a
  -- document carries both. One standing in for the other is the
  -- mistake this pair is here to catch.
  insert into public.matters
    (org_id, matter_no, name, client_id, fee_earner,
     matter_type, practice_area)
  values (v_org, 'MTR-PINDAH-1', 'Perjanjian penyelenggaraan', v_cust,
          pg_temp.test_user(), 'advisory', 'Corporate')
  returning id into v_matter;

  -- ------------------------------------------------------------------
  -- The quotation, with every optional field on it
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, delivery_date,
     contact_id, contact_person_id, shipping_address_id,
     reference, subject, notes, terms_conditions,
     payment_term_id, salesperson_id, branch_id, opportunity_id, matter_id,
     currency, exchange_rate, subtotal, total_amount, balance_amount,
     shipping_amount, discount_amount, service_charge_amount, status)
  values (v_org, 'quotation', 'QT-SHAPES-1', current_date - 5,
          current_date + 30, current_date + 21,
          v_cust, v_person, v_addr,
          'PO ref: THEIRS-8891', 'Penyelenggaraan tahunan',
          'Bayar dalam empat puluh lima hari.',
          'Harga sah selagi kontrak berjalan.',
          v_terms, v_seller, v_branch, v_opp, v_matter,
          'SGD', 3.20, 0, 0, 0, 60.00, 45.00, 25.00, 'draft')
  returning id into v_q;

  -- Line one names everything itself and names no item, so the unit and
  -- the classification on it are the line's own with nothing behind
  -- them — which is what makes carrying them observable.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     classification_code, quantity, uom_code, unit_price,
     discount_percent, discount_amount, tax_code_id, tax_rate,
     is_tax_inclusive, warehouse_id, account_id, project_code,
     department_code, service_start, service_end)
  values (v_org, v_q, 1, 'item', 'Penyelenggaraan bulanan',
          '009', 10, 'MON', 120,
          5, 60.00, v_tax, 6, true, v_wh, v_acct, 'PROJ-A', 'DEPT-B',
          current_date + 1, current_date + 365)
  returning id into v_l1;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, tax_code_id, tax_rate)
  values (v_org, v_q, 2, 'item', v_plain, 'Alat ganti', 4, 40, v_tax, 6)
  returning id into v_l2;

  -- A note the customer reads, which is not something sold.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price)
  values (v_org, v_q, 3, 'description', 'Tertakluk kepada syarat', 0, 0);

  update public.sales_documents set status = 'posted' where id = v_q;

  -- ------------------------------------------------------------------
  -- What the invoice inherits
  -- ------------------------------------------------------------------
  v_inv := public.transfer_document(v_q, 'invoice');
  select * into v_doc from public.sales_documents where id = v_inv;

  perform pg_temp.check_eq('the customer''s own reference travels',
    v_doc.reference, 'PO ref: THEIRS-8891');
  perform pg_temp.check_eq('and what the job is called',
    v_doc.subject, 'Penyelenggaraan tahunan');
  perform pg_temp.check_eq('the note to the customer travels',
    v_doc.notes, 'Bayar dalam empat puluh lima hari.');
  perform pg_temp.check_eq('and the terms the deal was struck on',
    v_doc.terms_conditions, 'Harga sah selagi kontrak berjalan.');
  perform pg_temp.check_eq('who sold it is still who sold it',
    v_doc.salesperson_id, v_seller);
  perform pg_temp.check_eq('the branch that quoted it invoices it',
    v_doc.branch_id, v_branch);
  perform pg_temp.check_eq('the opportunity it came out of travels',
    v_doc.opportunity_id, v_opp);
  perform pg_temp.check_eq('and the matter it was opened under, which is not it',
    v_doc.matter_id, v_matter);
  perform pg_temp.check_true('and the two are not the same pointer',
    v_opp <> v_matter);
  -- An ordinary customer's own person and door travel untouched. The
  -- prospect block below is about a DIFFERENT contact answering; this
  -- is the line that says it does not fire for everybody.
  perform pg_temp.check_eq('an ordinary customer keeps its own person',
    v_doc.contact_person_id, v_person);
  perform pg_temp.check_eq('and its own delivery address',
    v_doc.shipping_address_id, v_addr);
  perform pg_temp.check_eq('the payment terms agreed travel',
    v_doc.payment_term_id, v_terms);
  perform pg_temp.check_eq('and the invoice is dated today, not the quote''s day',
    v_doc.doc_date::text, app.today()::text);
  perform pg_temp.check_true('which is not the day the quotation carries',
    v_doc.doc_date <> (current_date - 5));
  -- Forty-five days, because the customer's terms say so and not
  -- because thirty is the default.
  perform pg_temp.check_eq('the due date is the customer''s own terms',
    v_doc.due_date::text, (app.today() + 45)::text);
  perform pg_temp.check_eq('an invoice arrives as a draft somebody checks',
    v_doc.status::text, 'draft');
  perform pg_temp.check_true('an invoice inherits no delivery promise',
    v_doc.delivery_date is null);

  select * into v_line from public.sales_document_lines
   where document_id = v_inv and source_line_id = v_l1;
  perform pg_temp.check_eq('the unit quoted is the unit billed',
    v_line.uom_code, 'MON');
  perform pg_temp.check_eq('and the classification quoted',
    v_line.classification_code, '009');
  perform pg_temp.check_eq('the tax code travels',
    v_line.tax_code_id, v_tax);
  perform pg_temp.check_true('and a price quoted inclusive stays inclusive',
    v_line.is_tax_inclusive);
  perform pg_temp.check_eq('the warehouse it ships from travels',
    v_line.warehouse_id, v_wh);
  perform pg_temp.check_eq('the account it posts to travels',
    v_line.account_id, v_acct);
  perform pg_temp.check_eq('the project is the project',
    v_line.project_code, 'PROJ-A');
  perform pg_temp.check_eq('and the department is the department',
    v_line.department_code, 'DEPT-B');
  perform pg_temp.check_eq('the lines are numbered from one on the new paper',
    (select min(line_no) from public.sales_document_lines
      where document_id = v_inv), 1);
  -- And in the order they were quoted in. The quotation reads
  -- maintenance first and parts second; an invoice that reads them the
  -- other way round is a different document to the eye of the person
  -- checking it against the quote.
  perform pg_temp.check_eq('and they read in the order they were quoted',
    (select description from public.sales_document_lines
      where document_id = v_inv and line_no = 1), 'Penyelenggaraan bulanan');
  perform pg_temp.check_eq('with the second line second',
    (select description from public.sales_document_lines
      where document_id = v_inv and line_no = 2), 'Alat ganti');
  perform pg_temp.check_eq('a note the customer reads is not something sold',
    (select count(*) from public.sales_document_lines
      where document_id = v_inv and line_type <> 'item'), 0);

  -- ------------------------------------------------------------------
  -- A document nobody agreed terms on
  --
  -- `app.document_due_date_guard` fills a null due date from the
  -- payment terms, so on a document that HAS terms this function's own
  -- due-date block is invisible — the trigger would reach the same
  -- answer. The only thing that distinguishes them is the default when
  -- there are no terms at all, which is this function's thirty days and
  -- not the trigger's nothing.
  -- ------------------------------------------------------------------
  v_noterm := pg_temp.tq(v_org, v_cust, v_plain, null);
  v_inv := public.transfer_document(v_noterm, 'invoice');
  perform pg_temp.check_eq('a document with no terms falls due in thirty days',
    (select due_date::text from public.sales_documents where id = v_inv),
    (app.today() + 30)::text);

  -- ------------------------------------------------------------------
  -- A named list takes the lines it names, and only those
  --
  -- `p_lines` is how a customer is invoiced for half a job. Two things
  -- can go wrong quietly: a line nobody named comes across anyway, and
  -- the line that does come across keeps the number it had on the
  -- quotation rather than being numbered from one. Both leave a
  -- document that adds up, so only the shape gives them away.
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'quotation', 'QT-SHAPES-3', current_date, v_cust,
          'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_two;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_two, 1, 'item', v_plain, 'Yang pertama', 3, 40)
  returning id into v_t1;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_two, 2, 'item', v_plain, 'Yang kedua', 7, 40)
  returning id into v_t2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price)
  values (v_org, v_two, 3, 'description', 'Sila rujuk lampiran', 1, 0)
  returning id into v_t3;
  update public.sales_documents set status = 'posted' where id = v_two;

  v_inv := public.transfer_document(v_two, 'invoice',
    jsonb_build_array(jsonb_build_object('line_id', v_t2, 'quantity', 2)));
  perform pg_temp.check_eq('a named list brings across only what it names',
    (select count(*) from public.sales_document_lines
      where document_id = v_inv), 1);
  perform pg_temp.check_eq('and it is the line that was named',
    (select description from public.sales_document_lines
      where document_id = v_inv), 'Yang kedua');
  perform pg_temp.check_eq('for the quantity that was asked for',
    (select quantity from public.sales_document_lines
      where document_id = v_inv), 2);
  perform pg_temp.check_eq('numbered from one, not from where it sat before',
    (select line_no from public.sales_document_lines
      where document_id = v_inv), 1);
  perform pg_temp.check_eq('and the line it came from is remembered',
    (select source_line_id from public.sales_document_lines
      where document_id = v_inv), v_t2);
  perform pg_temp.check_eq('the line nobody named is untouched on the quote',
    (select quantity_invoiced from public.sales_document_lines
      where id = v_t1), 0);

  -- And what is left after that, taken whole. Line three is a note
  -- with a quantity on it, which nothing forbids and which the earlier
  -- quotation's zero-quantity note cannot show: a line that is not
  -- something sold has to arrive as a line that is not something sold.
  v_inv := public.transfer_document(v_two, 'invoice');
  perform pg_temp.check_eq('the rest of the quotation follows',
    (select count(*) from public.sales_document_lines
      where document_id = v_inv), 3);
  perform pg_temp.check_eq('and a note stays a note, not something sold',
    (select line_type from public.sales_document_lines
      where document_id = v_inv and source_line_id = v_t3), 'description');
  perform pg_temp.check_eq('the first line comes across in full',
    (select quantity from public.sales_document_lines
      where document_id = v_inv and source_line_id = v_t1), 3);
  perform pg_temp.check_eq('and the second only what was left of it',
    (select quantity from public.sales_document_lines
      where document_id = v_inv and source_line_id = v_t2), 5);

  -- ------------------------------------------------------------------
  -- The delivery promise, which belongs to the order and the note
  -- ------------------------------------------------------------------
  v_so := public.transfer_document(v_q, 'sales_order');
  perform pg_temp.check_eq('the day promised travels to the order',
    (select delivery_date::text from public.sales_documents where id = v_so),
    (current_date + 21)::text);

  -- ------------------------------------------------------------------
  -- A document somebody deleted
  --
  -- Deleted and voided are two states, not one, and a document in
  -- either is not a document to invoice from.
  -- ------------------------------------------------------------------
  v_dead := pg_temp.tq(v_org, v_cust, v_plain, null);
  update public.sales_documents set deleted_at = now() where id = v_dead;
  perform pg_temp.check_refused('a deleted quotation is not invoiced',
    format('select public.transfer_document(%L, ''invoice'')', v_dead),
    '% has been voided%', '23514');
  update public.sales_documents
     set deleted_at = null, status = 'void' where id = v_dead;
  perform pg_temp.check_refused('nor a voided one',
    format('select public.transfer_document(%L, ''invoice'')', v_dead),
    '% has been voided%', '23514');

  -- ------------------------------------------------------------------
  -- What cannot be transferred, and what has expired
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a quotation is not a purchase order',
    format('select public.transfer_document(%L, ''purchase_order'')', v_q),
    'A quotation cannot be transferred to a purchase_order%', '23514');
  perform pg_temp.check_refused('nor a delivery note a quotation',
    format('select public.transfer_document(%L, ''quotation'')', v_so),
    'A sales_order cannot be transferred to a quotation%', '23514');

  -- An offer is good on the day it says it is good until, and not the
  -- day after. Both sides of that line are asserted, because a `<` and
  -- a `<=` read the same on every day but one.
  perform pg_temp.check_true('an offer holds on its last day',
    public.transfer_document(
      pg_temp.tq(v_org, v_cust, v_plain, app.today()), 'invoice')
    is not null);
  perform pg_temp.check_refused('and is gone the day after',
    format('select public.transfer_document(%L, ''invoice'')',
           pg_temp.tq(v_org, v_cust, v_plain, app.today() - 1)),
    '% was only valid until %', '23514');

  -- A proforma is an offer with a date on it too.
  v_so := pg_temp.tq(v_org, v_cust, v_plain, app.today() - 1);
  update public.sales_documents set doc_type = 'proforma' where id = v_so;
  perform pg_temp.check_refused('a proforma expires the same way',
    format('select public.transfer_document(%L, ''invoice'')', v_so),
    '% was only valid until %', '23514');

  -- And an offer with no end date on it never expires.
  perform pg_temp.check_true('an offer with no end date does not expire',
    public.transfer_document(
      pg_temp.tq(v_org, v_cust, v_plain, null), 'invoice') is not null);

  -- ------------------------------------------------------------------
  -- A quotation to a prospect becomes an invoice to the customer record
  -- ------------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-BAKAL', 'Bakal Pelanggan Sdn Bhd', 'prospect')
  returning id into v_pros;
  insert into public.contact_persons
    (org_id, contact_id, name, email, is_primary)
  values (v_org, v_pros, 'Cik Aida', 'aida@bakal.test', true)
  returning id into v_pperson;
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode, is_default)
  values (v_org, v_pros, 'Pejabat', '1 Jalan Bakal', '50000', true)
  returning id into v_paddr;

  v_pcust := public.create_contact_as(v_pros, 'customer');
  -- `create_contact_as` copies the people and the addresses across, so
  -- the matching rows are already there. What is added here is what
  -- makes the MATCH observable: a person of the same name at a
  -- different address, a door of the same label in a different street,
  -- and a second copy of the right person who is not the primary one.
  -- Matching on name alone, or on label alone, picks a decoy.
  insert into public.contact_persons
    (org_id, contact_id, name, email, designation)
  values (v_org, v_pcust, 'Cik Aida', 'aida@lain.test', 'Umpan');
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode)
  values (v_org, v_pcust, 'Pejabat', '999 Jalan Lain', '99999');
  insert into public.contact_persons
    (org_id, contact_id, name, email, designation)
  values (v_org, v_pcust, 'Cik Aida', 'aida@bakal.test', 'Salinan kedua');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, contact_person_id,
     shipping_address_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'quotation', 'QT-SHAPES-2', current_date, v_pros,
          v_pperson, v_paddr, 'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_so;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_so, 1, 'item', v_plain, 'Alat ganti', 1, 40);
  update public.sales_documents set status = 'posted' where id = v_so;

  v_inv := public.transfer_document(v_so, 'invoice');
  select * into v_doc from public.sales_documents where id = v_inv;
  perform pg_temp.check_eq('an offer to a prospect is invoiced to the customer',
    v_doc.contact_id, v_pcust);
  perform pg_temp.check_true('and never to the prospect',
    v_doc.contact_id <> v_pros);
  perform pg_temp.check_eq('the same person, on the customer''s own row',
    (select c.contact_id from public.contact_persons c
      where c.id = v_doc.contact_person_id), v_pcust);
  perform pg_temp.check_eq('found by name AND email, not by name alone',
    (select c.email from public.contact_persons c
      where c.id = v_doc.contact_person_id), 'aida@bakal.test');
  perform pg_temp.check_true('and of two that match, the primary one',
    (select c.is_primary from public.contact_persons c
      where c.id = v_doc.contact_person_id));
  perform pg_temp.check_eq('the same door, on the customer''s own row',
    (select a.contact_id from public.contact_addresses a
      where a.id = v_doc.shipping_address_id), v_pcust);
  perform pg_temp.check_eq('and the right door of the two labelled alike',
    (select a.address_line1 from public.contact_addresses a
      where a.id = v_doc.shipping_address_id), '1 Jalan Bakal');

  -- ------------------------------------------------------------------
  -- Which of several matching rows is picked
  --
  -- The decoys above sit behind the real match in every ordering, so
  -- they say the match is narrow enough but not that the tie-break
  -- matters. These two prospects put a decoy in FRONT: on the first
  -- the wrong person and the wrong door are the primary ones, so a
  -- match on name alone or on label alone lands on them; on the second
  -- two rows match equally and the primary one is the later of the
  -- two, so a tie-break by age alone lands on the wrong copy.
  -- ------------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-UMPAN', 'Umpan Di Hadapan Sdn Bhd', 'prospect')
  returning id into v_pros2;
  insert into public.contact_persons
    (org_id, contact_id, name, email, is_primary)
  values (v_org, v_pros2, 'Cik Bee', 'bee@umpan.test', true)
  returning id into v_pperson2;
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode, is_default)
  values (v_org, v_pros2, 'Pejabat', '2 Jalan Umpan', '51000', true)
  returning id into v_paddr2;
  v_pcust2 := public.create_contact_as(v_pros2, 'customer');

  -- The copies stop being the ones in front, and a decoy takes their
  -- place: same name, different email; same label and same postcode,
  -- different street.
  update public.contact_persons set is_primary = false
   where contact_id = v_pcust2;
  update public.contact_addresses set is_default = false
   where contact_id = v_pcust2;
  insert into public.contact_persons
    (org_id, contact_id, name, email, designation, is_primary)
  values (v_org, v_pcust2, 'Cik Bee', 'bee@lain.test', 'Umpan', true);
  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, postcode, is_default)
  values (v_org, v_pcust2, 'Pejabat', '77 Jalan Lain', '51000', true);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, contact_person_id,
     shipping_address_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'quotation', 'QT-SHAPES-4', current_date, v_pros2,
          v_pperson2, v_paddr2, 'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_pq;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_pq, 1, 'item', v_plain, 'Alat ganti', 1, 40);
  update public.sales_documents set status = 'posted' where id = v_pq;

  v_inv := public.transfer_document(v_pq, 'invoice');
  select * into v_doc from public.sales_documents where id = v_inv;
  perform pg_temp.check_eq('the email decides, even when the decoy is first',
    (select c.email from public.contact_persons c
      where c.id = v_doc.contact_person_id), 'bee@umpan.test');
  perform pg_temp.check_eq('and the street, even when the decoy is default',
    (select a.address_line1 from public.contact_addresses a
      where a.id = v_doc.shipping_address_id), '2 Jalan Umpan');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-SALIN', 'Dua Salinan Sdn Bhd', 'prospect')
  returning id into v_pros3;
  insert into public.contact_persons
    (org_id, contact_id, name, email, is_primary)
  values (v_org, v_pros3, 'Cik Chah', 'chah@salin.test', true)
  returning id into v_pperson3;
  v_pcust3 := public.create_contact_as(v_pros3, 'customer');

  -- Two rows that match equally well. The one the customer record
  -- actually uses is the later of them, so age alone picks the wrong
  -- one and only "primary first" picks the right one.
  update public.contact_persons set is_primary = false
   where contact_id = v_pcust3;
  insert into public.contact_persons
    (org_id, contact_id, name, email, designation, is_primary)
  values (v_org, v_pcust3, 'Cik Chah', 'chah@salin.test',
          'Salinan yang digunakan', true);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, contact_person_id,
     currency, exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'quotation', 'QT-SHAPES-5', current_date, v_pros3,
          v_pperson3, 'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_pq;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_pq, 1, 'item', v_plain, 'Alat ganti', 1, 40);
  update public.sales_documents set status = 'posted' where id = v_pq;

  v_inv := public.transfer_document(v_pq, 'invoice');
  perform pg_temp.check_eq('of two equal matches, the one in use is taken',
    (select c.designation from public.contact_persons c
      where c.id = (select contact_person_id from public.sales_documents
                     where id = v_inv)), 'Salinan yang digunakan');

  -- ------------------------------------------------------------------
  -- The buying side
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, payment_term_id,
     branch_id, currency, exchange_rate, subtotal, total_amount,
     balance_amount, shipping_amount, discount_amount, status)
  values (v_org, 'purchase_order', 'PO-SHAPES-1', current_date - 3, v_supp,
          v_terms, v_branch, 'USD', 4.10, 0, 0, 0, 30.00, 20.00, 'draft')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_po, 1, 'item', v_plain, 'Alat ganti', 5, 30);
  update public.purchase_documents set status = 'posted' where id = v_po;

  v_bill := public.transfer_document(v_po, 'bill');
  perform pg_temp.check_eq('the supplier''s terms travel to the bill',
    (select payment_term_id from public.purchase_documents where id = v_bill),
    v_terms);
  perform pg_temp.check_eq('and the bill points at the order it came from',
    (select parent_id from public.purchase_documents where id = v_bill),
    v_po);
  perform pg_temp.check_eq('with the supplier''s own terms deciding the date',
    (select due_date::text from public.purchase_documents where id = v_bill),
    (app.today() + 45)::text);

  -- A supplier who agreed no terms. `app.document_due_date_guard` fills
  -- a null due date from the payment terms, so on the order above this
  -- function's own due-date block reaches the same answer the trigger
  -- would and is invisible. With no terms to fall back on, the trigger
  -- has nothing and this function's thirty days is the only thing
  -- standing between the bill and a debt that is never due.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'purchase_order', 'PO-SHAPES-2', current_date, v_supp,
          'MYR', 1, 0, 0, 0, 'draft')
  returning id into v_npo;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_npo, 1, 'item', v_plain, 'Alat ganti', 2, 30);
  update public.purchase_documents set status = 'posted' where id = v_npo;
  -- Assigned first: a function that writes belongs on the left of an
  -- assignment, not inside a WHERE that runs it once per row.
  v_bill := public.transfer_document(v_npo, 'bill');
  perform pg_temp.check_eq('a bill on no terms still falls due in thirty days',
    (select due_date::text from public.purchase_documents where id = v_bill),
    (app.today() + 30)::text);

  -- A purchase order that has been voided is not billed.
  update public.purchase_documents set deleted_at = now() where id = v_po;
  perform pg_temp.check_refused('a deleted purchase order is not billed',
    format('select public.transfer_document(%L, ''bill'')', v_po),
    '% has been voided%', '23514');
  update public.purchase_documents set deleted_at = null where id = v_po;

  -- ------------------------------------------------------------------
  -- Asking for more than is left, and asking for nothing
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('more cannot be billed than was ordered',
    format($q$select public.transfer_document(%L, 'bill', %L::jsonb)$q$,
           v_po,
           jsonb_build_array(jsonb_build_object(
             'line_id', (select id from public.purchase_document_lines
                          where document_id = v_po and line_no = 1),
             'quantity', 99))),
    'Line 1 has % outstanding; % was asked for.%', '23514');

  -- A named list that asks for nothing takes nothing, and an empty
  -- document is refused rather than left in the numbering.
  perform pg_temp.check_refused('a list that names no quantity takes nothing',
    format($q$select public.transfer_document(%L, 'bill', '[]'::jsonb)$q$,
           v_po),
    'Nothing left to transfer%', '23514');
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: the e-Invoice the buyer has to write
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/self_billed_einvoice.sql
--
-- Normally the seller files the e-Invoice. Where the seller cannot -- a
-- foreign supplier outside MyInvois, an individual who is not
-- registered -- LHDN requires the BUYER to file one on their behalf. A
-- Malaysian company buying software from abroad owes LHDN an e-Invoice
-- for a supply it did not make.
--
-- ## The assertion this file exists for
--
-- **The supplier block still holds the supplier.** It does not swap.
--
-- On a sale, `prepare_einvoice` puts this company in the SUPPLIER block
-- because we are the seller. The obvious mirror -- put the supplier
-- where the customer was -- is wrong in both halves: on a self-billed
-- invoice we are the BUYER, so we go in the buyer block and the foreign
-- supplier goes in the supplier block, which is the block it would have
-- used had it been able to file for itself.
--
-- Backwards, the document validates, balances, and reports our own
-- company as the vendor of a supply we bought. So both blocks are
-- asserted by name, in both directions, and the sales case is asserted
-- alongside it in the same file -- because "it is the other way round
-- from the sales one" is exactly the sort of thing that is
-- half-remembered.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company that can file an e-Invoice, with one foreign supplier and
-- one Malaysian one.
create or replace function pg_temp.sb_company(p_name text)
returns table (org uuid, foreign_supplier uuid, local_supplier uuid,
               item uuid, customer uuid, tax_code uuid)
language plpgsql as $$
declare v_org uuid; v_f uuid; v_l uuid; v_i uuid; v_c uuid; v_t uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', app.today())::date);

  update public.organizations
     set einvoice_enabled = true,
         tin = 'C12345678901',
         legal_name = p_name,
         registration_no = '202401234567',
         country_code = 'MYS'
   where id = v_org;

  insert into public.contacts
    (org_id, code, name, legal_name, contact_type, country_code, tin,
     id_type, id_value)
  values (v_org, 'F-1', 'Cloud Vendor Inc', 'Cloud Vendor Incorporated',
          'supplier', 'USA', 'EI00000000020', 'BRN', 'US-987654')
  returning id into v_f;

  insert into public.contacts
    (org_id, code, name, contact_type, country_code, tin)
  values (v_org, 'L-1', 'Pembekal Tempatan Sdn Bhd', 'supplier', 'MYS',
          'C99999999999')
  returning id into v_l;

  insert into public.contacts
    (org_id, code, name, contact_type, country_code, tin)
  values (v_org, 'C-1', 'Pelanggan Sdn Bhd', 'customer', 'MYS',
          'C88888888888')
  returning id into v_c;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SW', 'Lesen perisian', 'service', false, 'C62', 1000.00)
  returning id into v_i;

  -- A real tax code, and the RATE on the line as well as the code.
  -- The line triggers recompute the tax from `tax_rate`, not from the
  -- code: a figure typed into `tax_amount` is overwritten, and a
  -- `tax_code_id` on its own leaves the rate at zero. The first version
  -- of this file typed 80 into tax_amount and got 0; the second named
  -- the code and still got 0. Measured both times rather than reasoned
  -- about.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, is_default)
  values (v_org, 'ST8', 'Service Tax 8pc', '02', 8, 'both', false)
  returning id into v_t;

  org := v_org; foreign_supplier := v_f; local_supplier := v_l;
  item := v_i; customer := v_c; tax_code := v_t;
  return next;
end $$;

create or replace function pg_temp.sb_bill(
  p_org uuid, p_supplier uuid, p_item uuid, p_no text,
  p_tax uuid default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, tax_amount, total_amount,
     base_total_amount, balance_amount)
  values (p_org, 'bill', p_no, app.today(), p_supplier, 'MYR', 1,
          'draft', 1000, 80, 1080, 1080, 1080)
  returning id into v_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (p_org, v_id, 1, 'item', p_item, 'Lesen perisian', 1, 'C62',
          1000, p_tax, case when p_tax is null then 0 else 8 end);
  update public.purchase_documents set status = 'posted' where id = v_id;
  return v_id;
end $$;

-- =====================================================================
-- Which bills owe one
-- =====================================================================
do $$
declare
  v    record;
  v_f  uuid;
  v_l  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into v from pg_temp.sb_company('Beli Dari Luar Sdn Bhd');

  v_f := pg_temp.sb_bill(v.org, v.foreign_supplier, v.item, 'BILL-F');
  v_l := pg_temp.sb_bill(v.org, v.local_supplier, v.item, 'BILL-L');

  perform pg_temp.check_true(
    'a bill from a supplier outside Malaysia owes a self-billed e-Invoice',
    (select requires_self_billed from public.purchase_documents
      where id = v_f));

  -- CONTROL. Almost every bill in the country is this one, and marking
  -- them all would put an e-Invoice obligation on the whole ledger.
  perform pg_temp.check_true(
    'while a bill from a Malaysian supplier does not',
    not (select requires_self_billed from public.purchase_documents
          where id = v_l));

  -- Somebody can still say. An unregistered individual in Malaysia owes
  -- one too, and the trigger cannot know that.
  perform pg_temp.check_true(
    'and somebody can say so by hand',
    public.set_requires_self_billed(v_l, true));
  perform pg_temp.check_true(
    'which sticks',
    (select requires_self_billed from public.purchase_documents
      where id = v_l));

  perform pg_temp.check_true(
    'and can be taken off again',
    public.set_requires_self_billed(v_l, false));
  perform pg_temp.check_true(
    'which also sticks',
    not (select requires_self_billed from public.purchase_documents
          where id = v_l));
end $$;

-- =====================================================================
-- A supplier nobody gave a country to is Malaysian
--
-- Not because the trigger says so -- because the schema does.
-- `contacts.country_code` is `not null default 'MYS'`, so a supplier
-- somebody typed in a hurry is already Malaysian by the time the
-- trigger sees it, and an unfilled field cannot put an e-Invoice
-- obligation on most of the bills in the database.
--
-- Written as an assertion about the COLUMN rather than about the
-- trigger, because the first attempt at this test tried to insert a
-- contact with a null country and could not: the constraint is the
-- thing doing the work, and a test that reached around it would have
-- been asserting a branch that never runs.
-- =====================================================================
do $$
declare
  v       record;
  v_blank uuid;
  v_bill  uuid;
  v_null  text;
  v_def   text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.sb_company('Negara Kosong Sdn Bhd');

  select is_nullable, column_default into v_null, v_def
    from information_schema.columns
   where table_schema = 'public' and table_name = 'contacts'
     and column_name = 'country_code';
  perform pg_temp.check_eq(
    'a contact must have a country', v_null, 'NO');
  perform pg_temp.check_true(
    'and it is Malaysia unless somebody says otherwise: ' || coalesce(v_def, ''),
    v_def like '%MYS%');

  -- And the behaviour that follows from it.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v.org, 'B-1', 'Ditaip Cepat', 'supplier')
  returning id into v_blank;

  v_bill := pg_temp.sb_bill(v.org, v_blank, v.item, 'BILL-B');
  perform pg_temp.check_true(
    'so a supplier typed without one owes no self-billed e-Invoice',
    not (select requires_self_billed from public.purchase_documents
          where id = v_bill));
end $$;

-- =====================================================================
-- THE assertion: which company is in which block
-- =====================================================================
do $$
declare
  v      record;
  v_bill uuid;
  v_inv  uuid;
  v_ei   public.einvoice_documents;
  v_sei  public.einvoice_documents;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.sb_company('Dua Arah Sdn Bhd');

  -- Buying from abroad.
  v_bill := pg_temp.sb_bill(v.org, v.foreign_supplier, v.item, 'BILL-X');
  perform public.prepare_self_billed_einvoice(v_bill);
  select * into v_sei from public.einvoice_documents
   where source_table = 'purchase_documents' and source_id = v_bill;

  perform pg_temp.check_eq(
    'on a self-billed invoice the SUPPLIER block holds the supplier',
    v_sei.supplier_name, 'Cloud Vendor Incorporated');
  perform pg_temp.check_eq(
    'and the BUYER block holds this company, because we are the buyer',
    v_sei.buyer_name, 'Dua Arah Sdn Bhd');
  perform pg_temp.check_true(
    'and the document says it is self-billed', v_sei.is_self_billed);
  perform pg_temp.check_eq(
    'under the code for a buyer''s own invoice, not a seller''s',
    v_sei.einvoice_type_code, '11');

  -- Selling. The same company, in the other block.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, tax_amount, total_amount,
     base_total_amount, balance_amount)
  values (v.org, 'invoice', 'INV-X', app.today(), v.customer, 'MYR', 1,
          'posted', 1000, 80, 1080, 1080, 1080)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v.org, v_inv, 1, 'item', v.item, 'Lesen perisian', 1, 'C62',
          1000, v.tax_code, 8);

  perform public.prepare_einvoice(v_inv);
  select * into v_ei from public.einvoice_documents
   where source_table = 'sales_documents' and source_id = v_inv;

  perform pg_temp.check_eq(
    'while on a sale the same company is in the SUPPLIER block',
    v_ei.supplier_name, 'Dua Arah Sdn Bhd');
  perform pg_temp.check_eq(
    'and the customer is the buyer',
    v_ei.buyer_name, 'Pelanggan Sdn Bhd');
  perform pg_temp.check_true(
    'and that one is not self-billed', not v_ei.is_self_billed);

  -- The two together. This company appears as supplier on what it sold
  -- and as buyer on what it bought, which is the whole distinction and
  -- is a single expression either way round would fail.
  perform pg_temp.check_true(
    'so this company is the supplier of what it sold and the buyer of '
    'what it bought',
    v_ei.supplier_name = v_sei.buyer_name
      and v_ei.supplier_name <> v_sei.supplier_name);
end $$;

-- =====================================================================
-- What it carries over
-- =====================================================================
do $$
declare
  v      record;
  v_bill uuid;
  v_id   uuid;
  v_ei   public.einvoice_documents;
  v_line public.einvoice_lines;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.sb_company('Angka Betul Sdn Bhd');
  v_bill := pg_temp.sb_bill(v.org, v.foreign_supplier, v.item, 'BILL-N',
                            v.tax_code);
  v_id := public.prepare_self_billed_einvoice(v_bill);

  select * into v_ei from public.einvoice_documents where id = v_id;
  perform pg_temp.check_eq('the amount payable is the bill''s total',
    v_ei.payable_amount, 1080::numeric);
  perform pg_temp.check_eq('the tax is the bill''s tax',
    v_ei.total_tax, 80::numeric);
  perform pg_temp.check_eq('and the net is the bill''s net',
    v_ei.total_excl_tax, 1000::numeric);

  select * into v_line from public.einvoice_lines where einvoice_id = v_id;
  perform pg_temp.check_eq('the line came across', v_line.description,
    'Lesen perisian');
  perform pg_temp.check_eq('with its net', v_line.total_excl_tax,
    1000::numeric);

  perform pg_temp.check_eq(
    'and the bill now points at the e-Invoice it owes',
    (select einvoice_id from public.purchase_documents where id = v_bill),
    v_id);
  perform pg_temp.check_eq(
    'and says it is pending',
    (select einvoice_status from public.purchase_documents where id = v_bill),
    'pending');

  -- Preparing it again while it is queued is refused. Two e-Invoices
  -- for one bill is two filings, and the sales side refuses the same
  -- way for the same reason.
  perform pg_temp.check_refused(
    'preparing it again while it is queued is refused',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_bill),
    '%already queued%', '55000');

  -- But a REJECTED one is prepared again onto the same row rather than
  -- beside it. That is the resubmit path: LHDN refused it, somebody
  -- fixed the bill, and the second attempt has to be the same document
  -- or the company has two of them.
  update public.einvoice_documents set status = 'rejected' where id = v_id;
  perform pg_temp.check_eq(
    'while a rejected one is prepared again onto the same row',
    public.prepare_self_billed_einvoice(v_bill), v_id);
  perform pg_temp.check_eq(
    'and there is still only one of it',
    (select count(*)::integer from public.einvoice_documents
      where source_table = 'purchase_documents' and source_id = v_bill), 1);
end $$;

-- =====================================================================
-- What it refuses
-- =====================================================================
do $$
declare
  v        record;
  v_local  uuid;
  v_draft  uuid;
  v_noTin  uuid;
  v_bill   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.sb_company('Enggan Fail Sdn Bhd');

  -- A bill from a supplier who files their own.
  v_local := pg_temp.sb_bill(v.org, v.local_supplier, v.item, 'BILL-L2');
  perform pg_temp.check_refused(
    'a bill nobody said owes one is refused',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_local),
    '%not marked as owing a self-billed e-Invoice%', '22023');

  -- A draft. Nothing has been posted, so nothing is owed yet.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount, requires_self_billed)
  values (v.org, 'bill', 'BILL-D', app.today(), v.foreign_supplier, 'MYR',
          1, 'draft', 100, 100, 100, 100, true)
  returning id into v_draft;
  perform pg_temp.check_refused(
    'and a draft is refused until it is posted',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_draft),
    '%Post BILL-D before submitting it%');

  -- A supplier with no TIN. The refusal names the field rather than
  -- inventing a number into a statutory filing.
  insert into public.contacts
    (org_id, code, name, contact_type, country_code, tin)
  values (v.org, 'F-2', 'Tanpa TIN Ltd', 'supplier', 'SGP', null)
  returning id into v_noTin;
  v_bill := pg_temp.sb_bill(v.org, v_noTin, v.item, 'BILL-T');
  perform pg_temp.check_refused(
    'a supplier with no TIN is refused, and the message says where to put one',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_bill),
    '%needs the supplier%s TIN%', '23514');

  -- And a placeholder is not a TIN. `0481` reduced "N/A", "NIL" and a
  -- dash to null for exactly this.
  update public.contacts set tin = 'N/A' where id = v_noTin;
  perform pg_temp.check_refused(
    'nor is N/A a TIN',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_bill),
    '%needs the supplier%s TIN%', '23514');

  -- And one of LHDN's general TINs IS a TIN here, which is the whole
  -- point: a foreign supplier has no Malaysian one and that is what
  -- LHDN says to use.
  --
  -- `app.identifying_number` reduces those to null, deliberately --
  -- `0481` built it to decide whether two contacts are the same
  -- company, and a number issued to nobody in particular cannot say
  -- they are. Reusing it here refused exactly the case this migration
  -- exists for, which is what this assertion is guarding.
  update public.contacts set tin = 'EI00000000020' where id = v_noTin;
  perform pg_temp.check_true(
    'a general TIN is a TIN here, even though it identifies nobody',
    public.prepare_self_billed_einvoice(v_bill) is not null);
  perform pg_temp.check_true(
    'and the de-duplication rule still says it identifies nobody',
    app.identifying_number('EI00000000020') is null);
end $$;

-- =====================================================================
-- Once it is with LHDN
-- =====================================================================
do $$
declare
  v      record;
  v_bill uuid;
  v_id   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.sb_company('Sudah Hantar Sdn Bhd');
  v_bill := pg_temp.sb_bill(v.org, v.foreign_supplier, v.item, 'BILL-S');
  v_id := public.prepare_self_billed_einvoice(v_bill);

  update public.einvoice_documents set status = 'valid' where id = v_id;
  update public.purchase_documents set einvoice_status = 'valid'
   where id = v_bill;

  perform pg_temp.check_refused(
    'a filed e-Invoice is not un-ticked here, it is cancelled at MyInvois',
    format($q$ select public.set_requires_self_billed(%L, false) $q$, v_bill),
    '%already with LHDN%', '55000');

  perform pg_temp.check_refused(
    'and it is not prepared again over the top of itself',
    format($q$ select public.prepare_self_billed_einvoice(%L) $q$, v_bill),
    '%already valid%', '55000');
end $$;

rollback;

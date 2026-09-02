-- =====================================================================
-- iAkauntan :: the quotation a prospect accepted
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/prospect_quotation.sql
--
-- A quotation is what you send somebody you have not sold to yet, so
-- a prospect may hold one. When it is taken forward -- to an order, a
-- delivery order or an invoice -- the sale is the company's *customer*
-- record's, the C- record 0477 makes from the P- one, and the
-- quotation stays the prospect's. Where there is no customer record
-- the transfer is refused and says what to do; it does not make one.
--
-- The mutants 0478 names are killed here, each by the assertion it
-- names.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- `transfer_document` as the new document's id, or 'refused: ' and
-- the reason.
create or replace function pg_temp.pq_transfer(p_src uuid, p_to text)
returns text language plpgsql as $$
declare v_new uuid; v_msg text;
begin
  v_new := public.transfer_document(p_src, p_to);
  return v_new::text;
exception when others then
  get stacked diagnostics v_msg = message_text;
  return 'refused: ' || v_msg;
end $$;

-- The hint on the refusal, or '' where the transfer went through.
create or replace function pg_temp.pq_hint(p_src uuid, p_to text)
returns text language plpgsql as $$
declare v_new uuid; v_hint text;
begin
  v_new := public.transfer_document(p_src, p_to);
  return '';
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return coalesce(v_hint, '');
end $$;

-- A quotation for two widgets to whoever is passed, made out to a
-- person and a delivery address where given.
create or replace function pg_temp.pq_quote(
  p_org uuid, p_no text, p_contact uuid, p_item uuid,
  p_person uuid default null, p_address uuid default null)
returns uuid language plpgsql as $$
declare v_q uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, valid_until, contact_id,
     contact_person_id, shipping_address_id, currency, exchange_rate,
     status)
  values (p_org, 'quotation', p_no, current_date, current_date + 30,
          p_contact, p_person, p_address, 'MYR', 1, 'draft')
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (p_org, v_q, 1, 'item', p_item, 'Widget', 2, 'C62', 500.00);
  return v_q;
end $$;

-- ---------------------------------------------------------------------
-- Which record the sale goes on
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_both uuid;
  v_pros uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Rekod Pelanggan Sdn Bhd');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-A', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-B', 'Dua Hala', 'both') returning id into v_both;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-A', 'Bakal', 'prospect') returning id into v_pros;

  perform pg_temp.check_eq('a customer is its own customer record',
    app.customer_record_of(v_cust), v_cust);
  perform pg_temp.check_eq('and so is a customer-and-supplier',
    app.customer_record_of(v_both), v_both);
  perform pg_temp.check_true('a prospect on its own has none',
    app.customer_record_of(v_pros) is null);

  -- Made from the prospect, the customer record is the answer -- and
  -- the answer is the same asked from either side.
  v_cust := public.create_contact_as(v_pros, 'customer');
  perform pg_temp.check_eq('made from the prospect, it is the answer',
    app.customer_record_of(v_pros), v_cust);
  perform pg_temp.check_eq('asked from the customer record, itself',
    app.customer_record_of(v_cust), v_cust);
end $$;

-- ---------------------------------------------------------------------
-- The transfer
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid;
  v_item    uuid;
  v_pros    uuid;
  v_supp    uuid;
  v_cust    uuid;
  v_person  uuid;
  v_addr    uuid;
  v_later   uuid;
  v_q       uuid;
  v_q2      uuid;
  v_said    text;
  v_new     uuid;
  d         public.sales_documents;
  p         public.contact_persons;
  a         public.contact_addresses;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Sebut Harga Bakal Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'W', 'Widget', 'service', false, 500.00)
  returning id into v_item;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-2026-00001', 'Al Hardware Sdn Bhd', 'prospect')
  returning id into v_pros;
  insert into public.contact_persons
    (org_id, contact_id, name, email, is_primary)
  values (v_org, v_pros, 'Encik Ali', 'ali@alhardware.example', true)
  returning id into v_person;
  insert into public.contact_addresses
    (org_id, contact_id, label, address_type, address_line1, postcode, city)
  values (v_org, v_pros, 'Warehouse', 'shipping', '12 Jalan Besi', '81200',
          'Johor Bahru')
  returning id into v_addr;

  v_q := pg_temp.pq_quote(v_org, 'QT-1', v_pros, v_item, v_person, v_addr);

  -- ------------------------------------------------------------------
  -- 1. No customer record: refused, and the remedy named
  -- ------------------------------------------------------------------
  v_said := pg_temp.pq_transfer(v_q, 'invoice');
  perform pg_temp.check_true('refused without a customer record',
    v_said like 'refused: %');
  perform pg_temp.check_true('and the remedy is named',
    v_said like '%Create a Customer record%');
  perform pg_temp.check_true('and where to find it',
    pg_temp.pq_hint(v_q, 'invoice') like '%Records%');
  perform pg_temp.check_true('nothing was made out to the prospect',
    not exists (select 1 from public.sales_documents
                 where contact_id = v_pros and doc_type <> 'quotation'));
  perform pg_temp.check_true('and no customer record was made behind their back',
    not exists (select 1 from public.contacts
                 where org_id = v_org and contact_type = 'customer'));

  -- A supplier record of the same company is not a customer record.
  v_supp := public.create_contact_as(v_pros, 'supplier');
  v_said := pg_temp.pq_transfer(v_q, 'invoice');
  perform pg_temp.check_true('a supplier record is not a customer record',
    v_said like 'refused: %Create a Customer record%');

  -- ------------------------------------------------------------------
  -- 2. With one: the order is the customer record's
  -- ------------------------------------------------------------------
  v_cust := public.create_contact_as(v_pros, 'customer');
  perform pg_temp.check_true('the customer record is coded C-',
    (select code from public.contacts where id = v_cust) like 'C-%');

  v_said := pg_temp.pq_transfer(v_q, 'sales_order');
  perform pg_temp.check_true('the transfer goes through',
    v_said not like 'refused: %');
  v_new := v_said::uuid;

  select * into d from public.sales_documents where id = v_new;
  perform pg_temp.check_eq('the order is the customer record''s',
    d.contact_id, v_cust);
  perform pg_temp.check_eq('and it is an order',
    d.doc_type::text, 'sales_order');
  perform pg_temp.check_eq('the quotation is still the prospect''s',
    (select contact_id from public.sales_documents where id = v_q), v_pros);
  perform pg_temp.check_eq('and still a quotation, under its own number',
    (select doc_no from public.sales_documents where id = v_q), 'QT-1');
  perform pg_temp.check_eq('the order comes to what was quoted',
    d.total_amount, 1000.00);

  -- The person and the door, on the customer record's own rows.
  select * into p from public.contact_persons where id = d.contact_person_id;
  perform pg_temp.check_eq('the person came along, on the customer record',
    p.contact_id, v_cust);
  perform pg_temp.check_eq('and is the same person',
    p.name, 'Encik Ali');
  perform pg_temp.check_true('not the prospect''s row',
    d.contact_person_id <> v_person);

  select * into a from public.contact_addresses where id = d.shipping_address_id;
  perform pg_temp.check_eq('the delivery address came along, on the customer record',
    a.contact_id, v_cust);
  perform pg_temp.check_eq('and is the same door',
    a.address_line1, '12 Jalan Besi');
  perform pg_temp.check_true('not the prospect''s row either',
    d.shipping_address_id <> v_addr);

  -- ------------------------------------------------------------------
  -- 3. A person added to the prospect after the customer record was
  --    made has no copy there: the field is left empty, not invented
  --    and not left pointing at the prospect's row.
  -- ------------------------------------------------------------------
  insert into public.contact_persons (org_id, contact_id, name)
  values (v_org, v_pros, 'Puan Aminah') returning id into v_later;
  update public.sales_documents
     set contact_person_id = v_later where id = v_q;

  -- The invoice counter is its own, so the quotation has its whole
  -- quantity left to invoice.
  v_said := pg_temp.pq_transfer(v_q, 'invoice');
  perform pg_temp.check_true('the invoice goes through',
    v_said not like 'refused: %');
  select * into d from public.sales_documents where id = v_said::uuid;
  perform pg_temp.check_eq('the invoice is the customer record''s',
    d.contact_id, v_cust);
  perform pg_temp.check_true('and an unmatched one is left empty',
    d.contact_person_id is null);
  perform pg_temp.check_true('the address still matched',
    d.shipping_address_id is not null
    and (select contact_id from public.contact_addresses
          where id = d.shipping_address_id) = v_cust);
  perform pg_temp.check_true('and the invoice has a due date',
    d.due_date is not null);

  -- ------------------------------------------------------------------
  -- 4. A deleted customer record does not count
  -- ------------------------------------------------------------------
  update public.contacts set deleted_at = now() where id = v_cust;
  v_q2 := pg_temp.pq_quote(v_org, 'QT-2', v_pros, v_item);
  v_said := pg_temp.pq_transfer(v_q2, 'invoice');
  perform pg_temp.check_true('a deleted customer record does not count',
    v_said like 'refused: %Create a Customer record%');
  update public.contacts set deleted_at = null where id = v_cust;
end $$;

-- ---------------------------------------------------------------------
-- Another organization's customer record is nobody's
-- ---------------------------------------------------------------------
do $$
declare
  v_org1 uuid; v_org2 uuid; v_item uuid; v_pros uuid; v_cust uuid; v_q uuid;
  v_said text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org1 := pg_temp.test_org('Syarikat Satu Sdn Bhd');
  v_org2 := pg_temp.test_org('Syarikat Dua Sdn Bhd');
  perform public.create_fiscal_year(v_org1, date_trunc('year', current_date)::date);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org1, 'W', 'Widget', 'service', false, 500.00)
  returning id into v_item;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org1, 'P-1', 'Bakal', 'prospect') returning id into v_pros;
  -- A record in the other organization claiming the same party.
  insert into public.contacts (org_id, code, name, contact_type, party_id)
  values (v_org2, 'C-1', 'Bakal', 'customer', v_pros) returning id into v_cust;

  v_q := pg_temp.pq_quote(v_org1, 'QT-1', v_pros, v_item);
  v_said := pg_temp.pq_transfer(v_q, 'invoice');
  perform pg_temp.check_true('another organization''s record is not this company''s',
    v_said like 'refused: %Create a Customer record%');
end $$;

-- ---------------------------------------------------------------------
-- A customer's quotation transfers as before
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_item uuid; v_cust uuid; v_person uuid; v_q uuid; v_said text;
  d public.sales_documents;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Pelanggan Sedia Ada Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'W', 'Widget', 'service', false, 500.00)
  returning id into v_item;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli', 'customer') returning id into v_cust;
  insert into public.contact_persons (org_id, contact_id, name)
  values (v_org, v_cust, 'Cik Siti') returning id into v_person;

  v_q := pg_temp.pq_quote(v_org, 'QT-1', v_cust, v_item, v_person);
  v_said := pg_temp.pq_transfer(v_q, 'invoice');
  perform pg_temp.check_true('a customer''s quotation transfers as before',
    v_said not like 'refused: %');
  select * into d from public.sales_documents where id = v_said::uuid;
  perform pg_temp.check_eq('to the same customer', d.contact_id, v_cust);
  perform pg_temp.check_eq('with the same person, the same row',
    d.contact_person_id, v_person);
end $$;

rollback;

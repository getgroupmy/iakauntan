-- =====================================================================
-- iAkauntan :: each side's functions ask the side too (0881)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/each_side_by_its_functions.sql
--
-- `0878` refused a salesperson's purchase documents and a purchaser's
-- sales ones when the client wrote the table. Seven functions write
-- those tables as their owner, and asked only `can_write`: a salesperson
-- imported a supplier bill through one and a purchaser raised a
-- quotation through another. Each asks the side now. Asked with the
-- role `authenticated`, as the app asks.
--
-- Every refusal is paired with the same call made by the right side,
-- which either does the work or is stopped by the function's NEXT
-- question -- so the refusal cannot be any guard but this one.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sf (org uuid, seller uuid, buyer uuid, both_sides uuid,
  deal uuid, deal2 uuid, request uuid, quotation uuid, received uuid);
grant select on t_sf to authenticated;

-- What a call did, or the refusal it met.
create or replace function pg_temp.outcome(p_statement text)
returns text language plpgsql as $$
begin
  execute p_statement;
  return 'done';
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.sf_line(p_no text, p_contact text)
returns jsonb language sql stable as $$
  select jsonb_build_object('doc_no', p_no, 'contact_code', p_contact,
    'doc_date', pg_temp.today()::text, 'description', 'Barang',
    'quantity', '1', 'unit_price', '100');
$$;

do $$
declare
  r t_sf; v_type uuid; v_pipe uuid; v_stage uuid; v_cust uuid; v_supp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Dua Pintu Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  r.seller     := pg_temp.another_user('jual@duapintu.test');
  r.buyer      := pg_temp.another_user('beli@duapintu.test');
  r.both_sides := pg_temp.another_user('kedua@duapintu.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.seller, 'sales', 'active'),
         (r.org, r.buyer, 'purchaser', 'active'),
         (r.org, r.both_sides, 'purchaser', 'active');

  -- A purchaser the company has given the sales side as well.
  insert into public.access_types (org_id, name)
  values (r.org, 'Buys and sells') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'sales', 'write'), (v_type, 'purchases', 'write'),
         (v_type, 'crm', 'write'), (v_type, 'contacts', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = r.org and user_id = r.both_sides;

  insert into public.contacts (org_id, contact_type, code, name)
  values (r.org, 'customer', 'C-1', 'Pembeli') returning id into v_cust;
  insert into public.contacts (org_id, contact_type, code, name)
  values (r.org, 'supplier', 'SUPP1', 'Pembekal') returning id into v_supp;

  insert into public.pipelines (org_id, name) values (r.org, 'Jualan')
  returning id into v_pipe;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, sort_order, probability, stage_type)
  values (r.org, v_pipe, 'Qualified', 1, 50, 'open') returning id into v_stage;
  insert into public.opportunities
    (org_id, opportunity_no, name, contact_id, pipeline_id, stage_id, amount, currency)
  values (r.org, 'OPP-1', 'Kerja', v_cust, v_pipe, v_stage, 5000, 'MYR')
  returning id into r.deal;
  insert into public.opportunities
    (org_id, opportunity_no, name, contact_id, pipeline_id, stage_id, amount, currency)
  values (r.org, 'OPP-2', 'Kerja lain', v_cust, v_pipe, v_stage, 3000, 'MYR')
  returning id into r.deal2;

  -- One of each side's documents to carry forward.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'purchase_request', 'PR-1', pg_temp.today(), v_supp, 'MYR', 1, 'draft')
  returning id into r.request;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (r.org, r.request, 1, 'item', 'Kerusi', 2, 300);
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'quotation', 'QT-1', pg_temp.today(), v_cust, 'MYR', 1, 'draft')
  returning id into r.quotation;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (r.org, r.quotation, 1, 'item', 'Meja', 1, 800);

  -- A received e-Invoice with no supplier linked yet.
  insert into public.received_einvoices (org_id, raw, payload_hash)
  values (r.org, '{}'::jsonb, 'sf-1') returning id into r.received;

  insert into t_sf select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The salesperson: the purchases side's functions refuse her
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select seller from t_sf));
set local role authenticated;

do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_refused('a salesperson imports no supplier bills',
    format('select public.import_purchase_transactions(%L, jsonb_build_array(%L::jsonb), true)',
           d.org, pg_temp.sf_line('BILL-S', 'SUPP1')),
    'A salesperson does not write purchase documents or supplier payments.%', '42501');
  perform pg_temp.check_refused('nor drafts a bill from a received e-Invoice',
    format('select public.draft_bill_from_received_einvoice(%L)', d.received),
    'A salesperson does not write purchase documents%', '42501');
  perform pg_temp.check_refused('nor raises purchase orders from the forecast',
    format('select public.create_po_from_suggestions(%L)', d.org),
    'A salesperson does not write purchase documents%', '42501');
  perform pg_temp.check_refused('nor accepts another company''s invoice as a bill',
    format('select public.accept_intercompany_bill(%L, %L)', gen_random_uuid(), d.org),
    'A salesperson does not write purchase documents%', '42501');
  perform pg_temp.check_refused('nor carries a requisition forward to an order',
    format('select public.transfer_document(%L, %L)', d.request, 'purchase_order'),
    'A salesperson does not write purchase documents%', '42501');

  -- Her own side, through its functions.
  perform pg_temp.check_eq('she imports a sales invoice',
    public.import_sales_transactions(d.org,
      jsonb_build_array(pg_temp.sf_line('INV-S', 'C-1')), true) ->> 'documents', '1');
  perform pg_temp.check_true('quotes a deal',
    public.quote_opportunity(d.deal) is not null);
  perform pg_temp.check_true('and carries a quotation forward to an order',
    public.transfer_document(d.quotation, 'sales_order') is not null);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The purchaser: the reverse
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select buyer from t_sf));
set local role authenticated;

do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_refused('a purchaser imports no sales invoices',
    format('select public.import_sales_transactions(%L, jsonb_build_array(%L::jsonb), true)',
           d.org, pg_temp.sf_line('INV-B', 'C-1')),
    'A purchaser does not write sales documents or receipts.%', '42501');
  perform pg_temp.check_refused('nor quotes a deal',
    format('select public.quote_opportunity(%L)', d.deal2),
    'A purchaser does not write sales documents%', '42501');
  perform pg_temp.check_refused('nor carries a quotation forward',
    format('select public.transfer_document(%L, %L)', d.quotation, 'sales_order'),
    'A purchaser does not write sales documents%', '42501');

  -- His own side: done, or stopped by the function's next question.
  perform pg_temp.check_eq('he imports a supplier bill',
    public.import_purchase_transactions(d.org,
      jsonb_build_array(pg_temp.sf_line('BILL-B', 'SUPP1')), true) ->> 'documents', '1');
  perform pg_temp.check_true('carries a requisition forward to an order',
    public.transfer_document(d.request, 'purchase_order') is not null);
  perform pg_temp.check_eq('is asked for the supplier before a bill is drafted',
    pg_temp.outcome(format('select public.draft_bill_from_received_einvoice(%L)', d.received)),
    'Link a supplier to this document before drafting a bill');
  perform pg_temp.check_eq('is asked for a forecast before orders are raised from one',
    pg_temp.outcome(format('select public.create_po_from_suggestions(%L)', d.org)),
    'No forecast has been run for this organization and location yet.');
  perform pg_temp.check_eq('and is told an unknown invoice is not addressed here',
    pg_temp.outcome(format('select public.accept_intercompany_bill(%L, %L)', gen_random_uuid(), d.org)),
    'That invoice is not addressed to this company, or has not been posted yet');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- An access type decides instead
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select both_sides from t_sf));
set local role authenticated;

do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_true('a purchaser given the sales side by an access type quotes a deal',
    public.quote_opportunity(d.deal2) is not null);
end $$;

reset role;

-- And what was made is what each side was allowed to make.
do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_eq('two quotations, one sales order, one sales invoice; one bill, one purchase order',
    (select string_agg(kind || ':' || n, ', ' order by kind) from (
       select doc_type::text as kind, count(*) n from public.sales_documents
        where org_id = d.org and doc_no <> 'QT-1' group by doc_type
       union all
       select doc_type::text, count(*) from public.purchase_documents
        where org_id = d.org and doc_no <> 'PR-1' group by doc_type) x),
    'bill:1, invoice:1, purchase_order:1, quotation:2, sales_order:1');
end $$;

rollback;

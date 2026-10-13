-- =====================================================================
-- iAkauntan :: what a supplier sent stays whole (0849)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/received_einvoice_kept.sql
--
-- A received e-invoice is kept as the supplier sent it (`0650`). Before
-- `0849` a client could delete its lines one by one, and delete the
-- document behind a posted bill. Asked as the owner with the role
-- `authenticated`, as the inbox screen asks.
--
-- The documents are dated today, so the bill drafted from one posts
-- into the year the fixture opens on any day the file runs.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.parsed(
  p_doc_no text default 'INV-9001',
  p_type   text default '01',
  p_tin    text default 'C1234567890')
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'docNo', p_doc_no,
    'issueDate', pg_temp.today()::text,
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


create temporary table t_rk (org uuid, posted uuid, drafted uuid, open uuid, gone uuid,
  posted_bill uuid, gone_bill uuid);
grant select on t_rk to authenticated;

do $$
declare r t_rk; v_bill uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Terima Utuh Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);

  -- Four documents from one supplier: one billed and the bill posted,
  -- one with a bill still a draft, one nobody has acted on, and one
  -- whose drafted bill is deleted below.
  r.posted  := (public.record_received_einvoice(r.org, pg_temp.parsed('INV-1'), pg_temp.parsed('INV-1')) ->> 'id')::uuid;
  r.drafted := (public.record_received_einvoice(r.org, pg_temp.parsed('INV-2'), pg_temp.parsed('INV-2')) ->> 'id')::uuid;
  r.open    := (public.record_received_einvoice(r.org, pg_temp.parsed('INV-3'), pg_temp.parsed('INV-3')) ->> 'id')::uuid;
  r.gone    := (public.record_received_einvoice(r.org, pg_temp.parsed('INV-4'), pg_temp.parsed('INV-4')) ->> 'id')::uuid;
  perform public.create_supplier_from_received_einvoice(r.posted);
  perform public.create_supplier_from_received_einvoice(r.drafted);
  perform public.create_supplier_from_received_einvoice(r.gone);
  r.posted_bill := public.draft_bill_from_received_einvoice(r.posted);
  perform public.post_purchase_document(r.posted_bill);
  perform public.draft_bill_from_received_einvoice(r.drafted);
  r.gone_bill := public.draft_bill_from_received_einvoice(r.gone);
  insert into t_rk select r.*;

  perform pg_temp.check_eq('the premise: a posted bill, a draft one, one unbilled, two lines each',
    (select (gl_entry_id is not null)::text from public.purchase_documents where id = r.posted_bill) || ' / ' ||
    (select status from public.received_einvoices where id = r.drafted) || ' / ' ||
    (select status from public.received_einvoices where id = r.open) || ' / ' ||
    (select count(*)::text from public.received_einvoice_lines where received_id = r.open),
    'true / billed / received / 2');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_rk; n int;
begin
  select * into d from t_rk;
  perform pg_temp.check_true('the owner, asking as a client who may write',
    current_user = 'authenticated' and app.can_write(d.org));

  -- What was measured.
  perform pg_temp.check_refused('a line of what a supplier sent is not deleted on its own',
    format('delete from public.received_einvoice_lines where received_id = %L and line_no = 2', d.open),
    'permission denied for table received_einvoice_lines', '42501');
  perform pg_temp.check_refused('nor the document behind a posted bill',
    format('delete from public.received_einvoices where id = %L', d.posted),
    'Supplier document INV-1 has a bill built from it, and is what that bill was checked '
    'against. It stays while the bill does.',
    '42501');
  perform pg_temp.check_refused('nor the one behind a bill still a draft',
    format('delete from public.received_einvoices where id = %L', d.drafted),
    'Supplier document INV-2 has a bill built from it%', '42501');

  -- A bill deleted lets its document go after it.
  delete from public.purchase_documents where id = d.gone_bill;
  delete from public.received_einvoices where id = d.gone;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('a document whose bill was deleted is deleted after it',
    n::text || ' / ' || (select count(*)::text from public.purchase_documents where id = d.gone_bill),
    '1 / 0');

  -- What the inbox does is as before: a document that was not for us
  -- goes, and its lines with it.
  delete from public.received_einvoices where id = d.open;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('a document nothing was built from is still deleted, lines and all',
    n::text || ' / ' || (select count(*)::text from public.received_einvoice_lines where received_id = d.open),
    '1 / 0');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: what deletes a document from inside a trigger is a
-- foreign key's cascade, which runs as the table's owner.
do $$
declare n int;
begin
  delete from public.received_einvoices where id = (select posted from t_rk);
  get diagnostics n = row_count;
  perform pg_temp.check_eq('the owner, at the top, is not refused', n::text, '1');
end $$;

rollback;

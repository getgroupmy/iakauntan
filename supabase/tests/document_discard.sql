-- =====================================================================
-- iAkauntan :: only a draft is discarded (0802)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_discard.sql
--
-- A posted invoice or bill set deleted by a client used to vanish from
-- every list while its journal stayed in the ledger and its e-Invoice
-- stayed queued for LHDN. Asked as the owner, with the role
-- `authenticated`, which is who the app is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_dd (
  org uuid, inv uuid, inv_draft uuid, bill uuid, bill_draft uuid, quote uuid);
grant select on t_dd to authenticated;

do $$
declare
  r      t_dd;
  v_cust uuid;
  v_supp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Buang Draf Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pembeli Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S-1', 'Pembekal Bhd', 'supplier') returning id into v_supp;

  -- An invoice and a bill each, posted and draft; and a quotation,
  -- approved, which posts nothing and is still past draft.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (r.org, 'invoice', 'INV-B1', pg_temp.today(), v_cust, 'MYR', 1, 100, 100, 100, 'draft'),
         (r.org, 'invoice', 'INV-B2', pg_temp.today(), v_cust, 'MYR', 1, 100, 100, 100, 'draft'),
         (r.org, 'quotation', 'QT-B1', pg_temp.today(), v_cust, 'MYR', 1, 100, 100, 100, 'draft');
  select id into r.inv from public.sales_documents where org_id = r.org and doc_no = 'INV-B1';
  select id into r.inv_draft from public.sales_documents where org_id = r.org and doc_no = 'INV-B2';
  select id into r.quote from public.sales_documents where org_id = r.org and doc_no = 'QT-B1';
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  select r.org, d, 1, 'Khidmat', 1, 100, 100 from unnest(array[r.inv, r.inv_draft, r.quote]) d;
  perform public.post_sales_document(r.inv);
  update public.sales_documents set status = 'approved' where id = r.quote;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (r.org, 'bill', 'BILL-B1', pg_temp.today(), v_supp, 'MYR', 1, 80, 80, 80, 'draft'),
         (r.org, 'bill', 'BILL-B2', pg_temp.today(), v_supp, 'MYR', 1, 80, 80, 80, 'draft');
  select id into r.bill from public.purchase_documents where org_id = r.org and doc_no = 'BILL-B1';
  select id into r.bill_draft from public.purchase_documents where org_id = r.org and doc_no = 'BILL-B2';
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  select r.org, d, 1, 'Bekalan', 1, 80 from unnest(array[r.bill, r.bill_draft]) d;
  perform public.post_purchase_document(r.bill);

  insert into t_dd select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_dd;
begin
  select * into d from t_dd;
  perform pg_temp.check_eq('the owner discards as a client', current_user, 'authenticated');

  perform pg_temp.check_refused('a posted invoice is not discarded',
    format('update public.sales_documents set deleted_at = now() where id = %L', d.inv),
    'INV-B1 is posted, and only a draft is discarded.%', '42501');
  perform pg_temp.check_refused('nor a posted bill',
    format('update public.purchase_documents set deleted_at = now() where id = %L', d.bill),
    'BILL-B1 is posted, and only a draft is discarded.%', '42501');
  perform pg_temp.check_refused('nor an approved quotation, which posted nothing',
    format('update public.sales_documents set deleted_at = now() where id = %L', d.quote),
    'QT-B1 is approved, and only a draft is discarded.%', '42501');

  -- What the app's Discard does, on what it offers it on.
  update public.sales_documents set deleted_at = now() where id = d.inv_draft;
  update public.purchase_documents set deleted_at = now() where id = d.bill_draft;
  perform pg_temp.check_true('a draft invoice and a draft bill are discarded',
    (select deleted_at is not null from public.sales_documents where id = d.inv_draft)
    and (select deleted_at is not null from public.purchase_documents where id = d.bill_draft));

  -- And brought back.
  update public.sales_documents set deleted_at = null where id = d.inv_draft;
  perform pg_temp.check_true('and a discarded draft can be brought back',
    (select deleted_at is null from public.sales_documents where id = d.inv_draft));

  -- The road a posted invoice takes.
  perform public.void_sales_document(d.inv, 'salah pelanggan');
  perform pg_temp.check_eq('a posted invoice is voided instead',
    (select status::text from public.sales_documents where id = d.inv), 'void');
end $$;

reset role;

-- The database's own statement passes: here the owner discards the
-- approved quotation, as a function running as its owner would. And
-- one discarded past draft -- before `0802`, or by the database -- can
-- be brought back by a client: the rule is about discarding, not about
-- what was discarded.
update public.sales_documents set deleted_at = now()
 where id = (select quote from t_dd);

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_dd;
begin
  select * into d from t_dd;
  perform pg_temp.check_true('the database discards what it decides to',
    (select deleted_at is not null from public.sales_documents where id = d.quote));
  update public.sales_documents set deleted_at = null where id = d.quote;
  perform pg_temp.check_true('and a client brings back what was discarded',
    (select deleted_at is null from public.sales_documents where id = d.quote));
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('the rule is on both tables',
    (select count(*)::integer from pg_trigger
      where tgname = 'a_draft_is_what_is_discarded'
        and tgrelid in ('public.sales_documents'::regclass,
                        'public.purchase_documents'::regclass)), 2);
end $$;

rollback;

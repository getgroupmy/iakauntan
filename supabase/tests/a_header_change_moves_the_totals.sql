-- =====================================================================
-- iAkauntan :: a header change moves the totals (0909)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_header_change_moves_the_totals.sql
--
-- A document's totals are worked out from its lines and from four
-- things on its header: the discount percentage, the discount amount,
-- the shipping and the exchange rate. Before `0909` a change to one of
-- those on its own moved nothing: shipping left the journal unbalanced,
-- a percentage was never taken off, and a new rate reached the ledger
-- but not `base_total_amount`. As the owner with the role
-- `authenticated`, as the app writes; and once as the owner itself,
-- whose own writes -- the till's -- keep their own figures.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_hc (org uuid, owner uuid, cust uuid, sup uuid, ac uuid, xc uuid);
grant select on t_hc to authenticated;

do $$
declare r t_hc;
begin
  r.owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.owner);
  r.org := pg_temp.test_org('Kepala Surat Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  select id into r.ac from public.accounts where org_id = r.org and code = '4100';
  select id into r.xc from public.accounts where org_id = r.org and code = '6100';
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CU', 'Pelanggan Kepala', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SU', 'Pembekal Kepala', 'supplier') returning id into r.sup;
  insert into t_hc select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.hc_inv(p_no text, p_cur text, p_rate numeric)
returns uuid language plpgsql as $$
declare d t_hc; v uuid;
begin
  select * into d from t_hc;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, p_cur, p_rate, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, account_id, tax_rate)
  values (d.org, v, 1, 'item', 'Khidmat', 1, 1000, d.ac, 0);
  return v;
end $$;

create or replace function pg_temp.hc_bill(p_no text, p_cur text, p_rate numeric)
returns uuid language plpgsql as $$
declare d t_hc; v uuid;
begin
  select * into d from t_hc;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', p_no, pg_temp.today(), pg_temp.today(), d.sup, p_cur, p_rate, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, account_id, tax_rate)
  values (d.org, v, 1, 'item', 'Bekalan', 1, 1000, d.xc, 0);
  return v;
end $$;

create or replace function pg_temp.hc_gl(p_doc uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || (l.debit - l.credit)::text, ', ' order by a.code)
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where l.entry_id = (select gl_entry_id from public.sales_documents where id = p_doc);
$$;

do $$
declare v uuid;
begin
  perform pg_temp.sign_in_as((select owner from t_hc));

  -- -------------------------------------------------------------------
  -- Invoices: each of the four, changed on the header alone
  -- -------------------------------------------------------------------
  v := pg_temp.hc_inv('INV-HANTAR', 'MYR', 1);
  update public.sales_documents set shipping_amount = 500 where id = v;
  perform pg_temp.check_eq('shipping on the header is in the total at once',
    (select total_amount from public.sales_documents where id = v), 1500.00::numeric);
  perform public.post_sales_document(v);
  perform pg_temp.check_eq('and the invoice posts, the shipping to its own account',
    pg_temp.hc_gl(v), '1210 1500.00, 4100 -1000.00, 4900 -500.00');

  v := pg_temp.hc_inv('INV-PERATUS', 'MYR', 1);
  update public.sales_documents set discount_percent = 10 where id = v;
  perform pg_temp.check_eq('a percentage on the header is taken off at once',
    (select discount_amount::text || ' / ' || total_amount::text
       from public.sales_documents where id = v), '100.00 / 900.00');
  perform public.post_sales_document(v);
  perform pg_temp.check_eq('and the invoice posts what it says',
    pg_temp.hc_gl(v), '1210 900.00, 4100 -1000.00, 4300 100.00');

  v := pg_temp.hc_inv('INV-POTONG', 'MYR', 1);
  update public.sales_documents set discount_amount = 50 where id = v;
  perform pg_temp.check_eq('so is an amount off, with no percentage',
    (select total_amount from public.sales_documents where id = v), 950.00::numeric);

  v := pg_temp.hc_inv('INV-KADAR', 'USD', 4.4);
  update public.sales_documents set exchange_rate = 4.6 where id = v;
  perform pg_temp.check_eq('a new rate moves the total in ringgit',
    (select base_total_amount from public.sales_documents where id = v), 4600.00::numeric);
  perform public.post_sales_document(v);
  perform pg_temp.check_eq('which is what the ledger takes',
    pg_temp.hc_gl(v), '1210 4600.00, 4100 -4600.00');

  -- -------------------------------------------------------------------
  -- Bills: the same, on the purchase side
  -- -------------------------------------------------------------------
  v := pg_temp.hc_bill('BIL-HANTAR', 'MYR', 1);
  update public.purchase_documents set shipping_amount = 200 where id = v;
  perform pg_temp.check_eq('a bill''s shipping is in its total at once',
    (select total_amount from public.purchase_documents where id = v), 1200.00::numeric);

  v := pg_temp.hc_bill('BIL-KADAR', 'USD', 4.4);
  update public.purchase_documents set exchange_rate = 4.5 where id = v;
  perform pg_temp.check_eq('and a new rate its total in ringgit',
    (select base_total_amount from public.purchase_documents where id = v), 4500.00::numeric);

  -- The rest of the header is written as it was.
  update public.purchase_documents set notes = 'Tiba minggu depan' where id = v;
  perform pg_temp.check_eq('a note changes nothing else',
    (select notes || ' / ' || base_total_amount::text from public.purchase_documents where id = v),
    'Tiba minggu depan / 4500.00');
end $$;

-- The database's own hand keeps its own figures: the till writes the
-- shipping and then the totals, the service charge's tax among them,
-- and runs as the owner.
reset role;
update public.sales_documents set shipping_amount = 300
 where doc_no = 'INV-POTONG' and org_id = (select org from t_hc);
select pg_temp.check_eq('the owner''s write of the header is not worked over',
  (select total_amount from public.sales_documents
    where doc_no = 'INV-POTONG' and org_id = (select org from t_hc)), 950.00::numeric);

rollback;

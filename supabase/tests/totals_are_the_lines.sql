-- =====================================================================
-- iAkauntan :: a document's totals are its lines' (0905)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/totals_are_the_lines.sql
--
-- Posting reads a document's header: the receivable or payable is its
-- total, the output or input tax its tax. Those are worked out from the
-- lines. Before `0905` a client could write them on a draft, and an
-- invoice whose line charged 80 of tax posted none. As the owner with
-- the role `authenticated`, as the app writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tl (org uuid, cust uuid, sup uuid, item uuid, st8 uuid);
grant select on t_tl to authenticated;

do $$
declare r t_tl;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Jumlah Baris Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Jujur', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Jujur', 'supplier') returning id into r.sup;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, sales_tax_account_id, purchase_tax_account_id)
  values (r.org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
          (select id from public.accounts where org_id = r.org and code = '2130'),
          (select id from public.accounts where org_id = r.org and code = '1410'))
  returning id into r.st8;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'SVC', 'Khidmat', 'service', false, 'C62', 1000) returning id into r.item;
  insert into t_tl select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.tl_totals(p_doc uuid) returns text language sql as $$
  select concat_ws(' / ', subtotal, tax_amount, total_amount)
    from public.sales_documents where id = p_doc;
$$;

do $$
declare d t_tl; v_inv uuid; v_bill uuid;
begin
  select * into d from t_tl;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-JB', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, tax_code_id, tax_rate)
  values (d.org, v_inv, 1, 'item', d.item, 'Khidmat', 1, 1000, d.st8, 8);
  perform pg_temp.check_eq('the lines give the totals',
    pg_temp.tl_totals(v_inv), '1000.00 / 80.00 / 1080.00');

  -- -------------------------------------------------------------------
  -- Written on the header: refused, each of the five
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('the tax is not written over',
    format('update public.sales_documents set tax_amount = 0 where id = %L', v_inv),
    'The tax amount of INV-JB is worked out from its lines, and is not written directly (80.00 -> 0.00)%',
    '42501');
  perform pg_temp.check_refused('nor the total',
    format('update public.sales_documents set total_amount = 1000 where id = %L', v_inv),
    'The total amount of INV-JB is worked out from its lines%', '42501');
  perform pg_temp.check_refused('nor the subtotal',
    format('update public.sales_documents set subtotal = 900 where id = %L', v_inv),
    'The subtotal of INV-JB is worked out from its lines%', '42501');
  perform pg_temp.check_refused('nor the rounding',
    format('update public.sales_documents set rounding_amount = 0.02 where id = %L', v_inv),
    'The rounding amount of INV-JB is worked out from its lines%', '42501');
  perform pg_temp.check_refused('nor the total in ringgit',
    format('update public.sales_documents set base_total_amount = 1 where id = %L', v_inv),
    'The base total amount of INV-JB is worked out from its lines%', '42501');

  -- -------------------------------------------------------------------
  -- Written through the lines: followed
  -- -------------------------------------------------------------------
  update public.sales_documents set notes = 'Dua hari kerja' where id = v_inv;
  update public.sales_document_lines set quantity = 2 where document_id = v_inv;
  perform pg_temp.check_eq('a line changed moves the totals, and the rest of the header is written',
    pg_temp.tl_totals(v_inv) || ' / ' || (select notes from public.sales_documents where id = v_inv),
    '2000.00 / 160.00 / 2160.00 / Dua hari kerja');
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('and posting charges the tax the lines charged',
    (select string_agg(a.code || ' ' || (l.debit - l.credit)::text, ', ' order by a.code)
       from public.gl_lines l join public.accounts a on a.id = l.account_id
      where l.entry_id = (select gl_entry_id from public.sales_documents where id = v_inv)),
    '1210 2160.00, 2130 -160.00, 4100 -2000.00');

  -- -------------------------------------------------------------------
  -- A bill: neither inserted with totals nor given them afterwards
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a bill is not inserted already owing tax',
    format('insert into public.purchase_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status,
               tax_amount, total_amount)
            values (%L, %L, %L, %L, %L, %L, 1, %L, 200, 200)',
           d.org, 'bill', 'BIL-CUKAI', pg_temp.today(), d.sup, 'MYR', 'draft'),
    'The tax amount of a new document is worked out from its lines as they are added%', '42501');
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-JB', pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, tax_code_id, tax_rate)
  values (d.org, v_bill, 1, 'item', d.item, 'Khidmat', 1, 1000, d.st8, 8);
  perform pg_temp.check_refused('nor is a bill''s tax raised by hand',
    format('update public.purchase_documents set tax_amount = 200, total_amount = 1200 where id = %L', v_bill),
    'The tax amount of BIL-JB is worked out from its lines%', '42501');
end $$;

-- The database's own hand still writes them: the recalculation and the
-- functions that post, transfer and import run as the owner.
reset role;
update public.purchase_documents set tax_amount = 81 where doc_no = 'BIL-JB';
select pg_temp.check_eq('the owner still writes the totals',
  (select tax_amount from public.purchase_documents where doc_no = 'BIL-JB'), 81::numeric);

rollback;

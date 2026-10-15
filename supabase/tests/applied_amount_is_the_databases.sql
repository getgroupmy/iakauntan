-- =====================================================================
-- iAkauntan :: what is set against an invoice is the database's (0907)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/applied_amount_is_the_databases.sql
--
-- `app.recalc_sales_totals_for` works an invoice's balance out as its
-- total less what was paid less `applied_amount`, and nothing writes
-- `applied_amount`. Before `0907` a client could, and an invoice of
-- RM1,080 posted owing RM80 to everything that reads the balance --
-- the credit limit among them -- while the receivable held RM1,080.
-- As the owner with the role `authenticated`, as the app writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ap (org uuid, cust uuid, sup uuid, item uuid, st8 uuid);
grant select on t_ap to authenticated;

do $$
declare r t_ap;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Baki Sebenar Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Berhutang', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Biasa', 'supplier') returning id into r.sup;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to, sales_tax_account_id, purchase_tax_account_id)
  values (r.org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
          (select id from public.accounts where org_id = r.org and code = '2130'),
          (select id from public.accounts where org_id = r.org and code = '1410'))
  returning id into r.st8;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'SVC', 'Khidmat', 'service', false, 'C62', 1000) returning id into r.item;
  insert into t_ap select r.*;
end $$;

set local role authenticated;

do $$
declare d t_ap; v_inv uuid; v_bill uuid;
begin
  select * into d from t_ap;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-AP', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, tax_code_id, tax_rate)
  values (d.org, v_inv, 1, 'item', d.item, 'Khidmat', 1, 1000, d.st8, 8);
  perform pg_temp.check_eq('the invoice owes what its lines come to',
    (select total_amount::text || ' / ' || balance_amount::text
       from public.sales_documents where id = v_inv), '1080.00 / 1080.00');

  -- -------------------------------------------------------------------
  -- Written on the invoice: refused
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('nothing is set against an invoice by hand',
    format('update public.sales_documents set applied_amount = 1000 where id = %L', v_inv),
    'The applied amount of INV-AP follows from what happened to it -- posting, voiding, payments -- and is not written directly (0.00 -> 1000.00)%',
    '42501');
  perform pg_temp.check_refused('nor is an invoice created with something already set against it',
    format('insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, applied_amount)
            values (%L, %L, %L, %L, %L, %L, 1, %L, 500)',
           d.org, 'invoice', 'INV-SUDAH', pg_temp.today(), d.cust, 'MYR', 'draft'),
    'A document is created with nothing set against it (this one said 500.00 applied)%', '42501');
  perform pg_temp.check_refused('nor with less than nothing, which would raise what it owes',
    format('insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, applied_amount)
            values (%L, %L, %L, %L, %L, %L, 1, %L, -200)',
           d.org, 'invoice', 'INV-TAMBAH', pg_temp.today(), d.cust, 'MYR', 'draft'),
    'A document is created with nothing set against it (this one said -200.00 applied)%', '42501');

  -- -------------------------------------------------------------------
  -- The rest of the invoice is still written, and it owes all of it
  -- -------------------------------------------------------------------
  update public.sales_documents set notes = 'Bayar dalam 30 hari' where id = v_inv;
  update public.sales_document_lines set quantity = 2 where document_id = v_inv;
  perform pg_temp.check_eq('a line changed moves the balance, and the rest of the header is written',
    (select balance_amount::text || ' / ' || notes from public.sales_documents where id = v_inv),
    '2160.00 / Bayar dalam 30 hari');
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('posted, the credit limit reads what the receivable holds',
    (public.customer_credit_status(d.cust) ->> 'outstanding')::numeric, 2160.00::numeric);

  -- -------------------------------------------------------------------
  -- A bill has no such column, and is not troubled by its absence
  -- -------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-AP', pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  update public.purchase_documents set notes = 'Untuk bulan ini' where id = v_bill;
  perform pg_temp.check_eq('a bill is created and written as before',
    (select doc_no || ' / ' || notes from public.purchase_documents where id = v_bill),
    'BIL-AP / Untuk bulan ini');
end $$;

do $$
declare d t_ap; v uuid;
begin
  select * into d from t_ap;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, applied_amount)
  values (d.org, 'invoice', 'INV-SIFAR', pg_temp.today(), d.cust, 'MYR', 1, 'draft', 0)
  returning id into v;
  perform pg_temp.check_true('an invoice that names nothing set against it is created',
    v is not null);
end $$;

-- The database's own hand still writes it: everything that runs as the
-- owner is not asked.
reset role;
update public.sales_documents set applied_amount = 5 where doc_no = 'INV-SIFAR';
select pg_temp.check_eq('the owner still writes it',
  (select applied_amount from public.sales_documents where doc_no = 'INV-SIFAR'), 5::numeric);

rollback;

-- =====================================================================
-- iAkauntan :: service tax is due when the money arrives
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/service_tax_on_payment.sql
--
-- Section 11 of the Service Tax Act 2018: service tax is due when
-- payment is received, and where payment is not received within twelve
-- months of the invoice, on the day following that period. Sales tax is
-- the other way -- due when the goods go -- so a company registered for
-- both has two bases in one return.
--
-- 0455 built the return on document dates, which is right for one of
-- the two. These are the assertions for the other, and they are written
-- as amounts in named periods rather than as totals, because the error
-- this guards against does not change what a company pays over its
-- life. It changes when, always in the same direction, out of money the
-- client has not sent.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A registered company with a service tax code, an invoice, and a way
-- of being paid for it.
create or replace function pg_temp.st_org(p_name text, p_from date)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));
  perform public.set_sst_registration(
    v_org, true, p_from, 'W10-1808-31000456', 'ST8');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer');
  return v_org;
end;
$$;

-- One invoice for RM1,000 plus RM80 service tax, dated as asked.
create or replace function pg_temp.st_invoice(
  p_org uuid, p_no text, p_date date, p_net numeric default 1000)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, p_date,
          (select id from public.contacts where org_id = p_org and code = 'C1'),
          'MYR', 1, 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (p_org, v_doc, 1, 'Khidmat perunding', 1, p_net,
          (select id from public.tax_codes where org_id = p_org and code = 'ST8'),
          8);
  return v_doc;
end;
$$;

-- Money received against it on a given day.
create or replace function pg_temp.st_pay(
  p_org uuid, p_doc uuid, p_on date, p_amount numeric, p_no text)
returns void language plpgsql as $$
declare v_rec uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, currency, exchange_rate,
     amount, status)
  values (p_org, p_no, p_on,
          (select id from public.contacts where org_id = p_org and code = 'C1'),
          'MYR', 1, p_amount, 'posted')
  returning id into v_rec;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount)
  values (p_org, v_rec, p_doc, p_amount);
end;
$$;

-- ---------------------------------------------------------------------
-- Invoiced in one period, paid in another
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Registered 15 January, so the periods are Jan-Feb, Mar-Apr,
  -- May-Jun, and so on.
  v_org := pg_temp.st_org('Perunding Bayar Sdn Bhd', date '2026-01-15');
  v_doc := pg_temp.st_invoice(v_org, 'INV-A', date '2026-03-20');

  -- Nothing paid: nothing due, however plainly the invoice was issued.
  perform pg_temp.check_eq('an unpaid invoice owes no service tax yet',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    0);

  perform pg_temp.st_pay(v_org, v_doc, date '2026-05-10', 1080, 'RC-1');

  perform pg_temp.check_eq('and still owes none in the period it was issued',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    0);

  perform pg_temp.check_eq('the whole tax falls due when the money arrives',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-05-01', date '2026-06-30')),
    80);

  perform pg_temp.check_eq('and the value with it',
    (select coalesce(sum(taxable_amount), 0)
       from app.sst_output_due(v_org, date '2026-05-01', date '2026-06-30')),
    1000);

  perform pg_temp.check_eq('on the basis the Act names',
    (select basis from app.sst_output_due(
       v_org, date '2026-05-01', date '2026-06-30') limit 1),
    'payment');
end $$;

-- ---------------------------------------------------------------------
-- Paid in instalments
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.st_org('Perunding Ansuran Sdn Bhd', date '2026-01-15');
  -- RM10,000 plus RM800, so half is exactly RM5,400.
  v_doc := pg_temp.st_invoice(v_org, 'INV-B', date '2026-03-20', 10000);

  perform pg_temp.st_pay(v_org, v_doc, date '2026-03-25', 5400, 'RC-1');
  perform pg_temp.st_pay(v_org, v_doc, date '2026-05-25', 5400, 'RC-2');

  perform pg_temp.check_eq('half the money declares half the tax',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    400);

  perform pg_temp.check_eq('and the rest lands in the period it lands in',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-05-01', date '2026-06-30')),
    400);

  -- The whole tax, once, across the life of the invoice. This is the
  -- assertion that would catch a period counted twice.
  perform pg_temp.check_eq('and the whole tax is declared exactly once',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-01-01', date '2027-12-31')),
    800);
end $$;

-- ---------------------------------------------------------------------
-- The invoice nobody pays
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.st_org('Perunding Tergantung Sdn Bhd', date '2026-01-15');
  v_doc := pg_temp.st_invoice(v_org, 'INV-C', date '2026-03-20');

  -- Eleven months later: still nothing, because nothing has been paid
  -- and the twelve months are not up.
  perform pg_temp.check_eq('eleven months on, still nothing is due',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2027-01-01', date '2027-02-28')),
    0);

  -- The day after the anniversary -- 21 March 2027 -- the whole
  -- remainder falls due whether the money comes or not.
  perform pg_temp.check_eq('twelve months on, the tax falls due anyway',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2027-03-01', date '2027-04-30')),
    80);

  perform pg_temp.check_eq('and says why it did',
    (select basis from app.sst_output_due(
       v_org, date '2027-03-01', date '2027-04-30') limit 1),
    'twelve months');

  -- And when the client finally pays, it is not declared a second time.
  perform pg_temp.st_pay(v_org, v_doc, date '2027-06-10', 1080, 'RC-1');
  perform pg_temp.check_eq('a late payment is not taxed twice',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2027-05-01', date '2027-06-30')),
    0);

  perform pg_temp.check_eq('and the whole tax is still declared exactly once',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-01-01', date '2027-12-31')),
    80);
end $$;

-- ---------------------------------------------------------------------
-- Half paid when the twelve months run out
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.st_org('Perunding Separuh Sdn Bhd', date '2026-01-15');
  v_doc := pg_temp.st_invoice(v_org, 'INV-D', date '2026-03-20', 10000);

  perform pg_temp.st_pay(v_org, v_doc, date '2026-04-25', 5400, 'RC-1');

  perform pg_temp.check_eq('the part that was paid is due when it was paid',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    400);

  perform pg_temp.check_eq(
    'and the part that never was is due at twelve months',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2027-03-01', date '2027-04-30')),
    400);

  perform pg_temp.check_eq('which is the whole of it, once',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-01-01', date '2027-12-31')),
    800);
end $$;

-- ---------------------------------------------------------------------
-- Sales tax is not service tax
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.st_org('Pengilang Sdn Bhd', date '2026-01-15');
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'SL10', 'Sales Tax 10%', '01', 10,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-E', date '2026-03-20',
          (select id from public.contacts where org_id = v_org and code = 'C1'),
          'MYR', 1, 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Barang', 1, 1000,
          (select id from public.tax_codes where org_id = v_org and code = 'SL10'),
          10);

  -- Nothing has been paid, and it does not matter: the goods went.
  perform pg_temp.check_eq('sales tax is due when the goods go',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    100);

  perform pg_temp.check_eq('on the basis it is due on',
    (select basis from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') limit 1),
    'invoice');
end $$;

-- ---------------------------------------------------------------------
-- A credit note is not a payment, and never becomes one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.st_org('Perunding Nota Sdn Bhd', date '2026-01-15');
  v_doc := pg_temp.st_invoice(v_org, 'INV-F', date '2026-03-20');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'credit_note', 'CN-1', date '2026-03-25',
          (select id from public.contacts where org_id = v_org and code = 'C1'),
          'MYR', 1, 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Pelarasan', 1, 250,
          (select id from public.tax_codes where org_id = v_org and code = 'ST8'),
          8);

  -- The reduction belongs to the period the note was issued in. Waiting
  -- for a payment that will never come would leave a company unable to
  -- claim a credit it has already given.
  perform pg_temp.check_eq('a credit note reduces the period it was issued in',
    (select coalesce(sum(tax_amount), 0)
       from app.sst_output_due(v_org, date '2026-03-01', date '2026-04-30')),
    -20);
end $$;

rollback;

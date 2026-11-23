-- =====================================================================
-- iAkauntan :: an account is described only to its own company (0925)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_account_is_described_only_to_its_own_company.sql
--
-- `0912` says what kind of account it refuses: "An item's sales account
-- may not be 1120 Bank Accounts, a bank account". Before `0925` it
-- looked the account up by id alone, so given another company's
-- account of the wrong kind it described that company's account. As
-- the owner of two companies, with the role `authenticated`, writing
-- in one and naming the other's accounts.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_oc (
  org uuid, other uuid, cust uuid, sup uuid, item uuid, inv uuid, bill uuid,
  own_bank uuid, own_head uuid,
  their_bank uuid, their_head uuid, their_ar uuid, their_sales uuid);
grant select on t_oc to authenticated;

do $$
declare r t_oc;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Syarikat Sendiri Sdn Bhd');
  r.other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'sales', 'purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  select id into r.own_bank from public.accounts where org_id = r.org and code = '1120';
  select id into r.own_head from public.accounts where org_id = r.org and code = '2100';
  -- The other company's chart, renamed so that a refusal which reads
  -- it cannot be mistaken for one that read this company's.
  update public.accounts set name = 'Bank Mereka' where org_id = r.other and code = '1120'
  returning id into r.their_bank;
  update public.accounts set name = 'Liabiliti Mereka' where org_id = r.other and code = '2100'
  returning id into r.their_head;
  update public.accounts set name = 'Penghutang Mereka' where org_id = r.other and code = '1210'
  returning id into r.their_ar;
  select id into r.their_sales from public.accounts where org_id = r.other and code = '4100';

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'ADA', 'Barang Ada', 'service', false, 'C62', 10) returning id into r.item;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'invoice', 'INV-SENDIRI-1', pg_temp.today(), pg_temp.today(), r.cust, 'MYR', 1, 'draft')
  returning id into r.inv;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-SENDIRI-1', pg_temp.today(), pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id into r.bill;
  insert into t_oc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_oc;
begin
  select * into d from t_oc;

  -- -------------------------------------------------------------------
  -- Another company's account is refused by the tenant key, unnamed
  -- -------------------------------------------------------------------
  -- Each of these is the wrong KIND for where it is put, which is what
  -- made `0912` describe it. The tenant key's refusal names a
  -- constraint and no account.
  perform pg_temp.check_refused('an item given another company''s bank account is told nothing of it',
    format('update public.items set sales_account_id = %L where id = %L', d.their_bank, d.item),
    'insert or update on table "items" violates foreign key constraint "items_sales_account_same_org"',
    '23503');
  perform pg_temp.check_refused('nor a customer given it as its receivable account',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.their_bank, d.cust),
    'insert or update on table "contacts" violates foreign key constraint "contacts_receivable_account_same_org"',
    '23503');
  perform pg_temp.check_refused('nor a supplier given another company''s receivables as its payable account',
    format('update public.contacts set payable_account_id = %L where id = %L', d.their_ar, d.sup),
    'insert or update on table "contacts" violates foreign key constraint "contacts_payable_account_same_org"',
    '23503');
  perform pg_temp.check_refused('nor an invoice line put on another company''s heading',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id) '
           'values (%L, %L, 1, %L, %L, 1, 100, 0, %L)', d.org, d.inv, 'item', 'Khidmat', d.their_head),
    'insert or update on table "sales_document_lines" violates foreign key constraint "sales_document_lines_account_same_org"',
    '23503');
  perform pg_temp.check_refused('nor a bill line put on another company''s receivables',
    format('insert into public.purchase_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id) '
           'values (%L, %L, 1, %L, %L, 1, 60, 0, %L)', d.org, d.bill, 'item', 'Belanja', d.their_ar),
    'insert or update on table "purchase_document_lines" violates foreign key constraint "purchase_document_lines_account_same_org"',
    '23503');
  -- And one of the right kind, which `0912` never described: the same
  -- answer as before.
  perform pg_temp.check_refused('another company''s sales account is refused the same way, as it always was',
    format('update public.items set sales_account_id = %L where id = %L', d.their_sales, d.item),
    'insert or update on table "items" violates foreign key constraint "items_sales_account_same_org"',
    '23503');

  -- An account that does not exist used to be "described" too: a
  -- contact naming one was told "<NULL> <NULL> is <NULL>".
  perform pg_temp.check_refused('an account that does not exist is the foreign key''s, not a sentence about nothing',
    format('update public.contacts set receivable_account_id = %L where id = %L', gen_random_uuid(), d.cust),
    'insert or update on table "contacts" violates foreign key constraint%', '23503');

  -- -------------------------------------------------------------------
  -- The company's own are described as before
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an item given its own company''s bank account is still told which and why',
    format('update public.items set sales_account_id = %L where id = %L', d.own_bank, d.item),
    'An item''s sales account may not be 1120 Bank Accounts, a bank account: money reaches a bank or a till through a receipt or a payment, where the reconciliation can see it.',
    '23514');
  perform pg_temp.check_refused('and a customer given it as its receivable account',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.own_bank, d.cust),
    'A customer''s receivable account is an active receivables account that is not a heading, and 1120 Bank Accounts is a bank account.%',
    '23514');
  perform pg_temp.check_refused('and an invoice line put on its own company''s heading',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id) '
           'values (%L, %L, 1, %L, %L, 1, 100, 0, %L)', d.org, d.inv, 'item', 'Khidmat', d.own_head),
    'A sales document line''s account may not be 2100 Current Liabilities, which is a heading:%',
    '23514');

  perform pg_temp.check_eq('after all of that nothing in the company names an account',
    (select count(*) from public.items where org_id = d.org and sales_account_id is not null)
    + (select count(*) from public.contacts where org_id = d.org
        and (receivable_account_id is not null or payable_account_id is not null))
    + (select count(*) from public.sales_document_lines where document_id = d.inv)
    + (select count(*) from public.purchase_document_lines where document_id = d.bill),
    0::bigint);
end $$;

reset role;
rollback;

-- =====================================================================
-- iAkauntan :: an account fits where it is used (0912)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_account_fits_where_it_is_used.sql
--
-- Posting takes a customer's receivable, a supplier's payable and every
-- line's account from what the rows name. Before `0912` a customer whose
-- receivable account was the bank posted an invoice of RM1,000 as
-- 1120 1,000 / 4100 -1,000, and a line coded to the bank or to 1210
-- moved either one with no receipt and no customer behind it. As the
-- owner with the role `authenticated`, as the app writes, and once as
-- the database's owner: the rule is for every writer.
--
-- Every fixture account here is a different row from the one the rule
-- would fall back to: the second receivables account is not 1210, and
-- the posting check names it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_af (org uuid, cust uuid, sup uuid, item uuid,
                             bank uuid, cash uuid, ar uuid, ap uuid, ar_head uuid,
                             ar_group uuid, ar2 uuid, ar_old uuid, ap2 uuid, deposit uuid,
                             other_income uuid, legacy uuid);
grant select on t_af to authenticated;

do $$
declare r t_af;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Akaun Muat Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  select id into r.bank    from public.accounts where org_id = r.org and code = '1120';
  select id into r.cash    from public.accounts where org_id = r.org and code = '1110';
  select id into r.ar      from public.accounts where org_id = r.org and code = '1210';
  select id into r.ap      from public.accounts where org_id = r.org and code = '2110';
  select id into r.ar_head from public.accounts where org_id = r.org and code = '1200';
  select id into r.deposit from public.accounts where org_id = r.org and code = '2120';
  select id into r.other_income from public.accounts where org_id = r.org and code = '4900';

  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  values (r.org, '1211', 'Penghutang Eksport', 'asset', 'accounts_receivable', r.ar_head)
  returning id into r.ar2;
  -- A heading OF receivables, so that refusing it says it is a heading
  -- and not merely the wrong kind: 1200 is a current asset, and is
  -- refused for that whether or not the heading is asked about.
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id, is_group)
  values (r.org, '1250', 'Penghutang Kumpulan', 'asset', 'accounts_receivable', r.ar_head, true)
  returning id into r.ar_group;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id, is_active)
  values (r.org, '1219', 'Penghutang Lama', 'asset', 'accounts_receivable', r.ar_head, false)
  returning id into r.ar_old;
  insert into public.accounts (org_id, code, name, account_type, account_subtype,
                               parent_id)
  values (r.org, '2111', 'Pemiutang Import', 'liability', 'accounts_payable',
          (select parent_id from public.accounts where id = r.ap))
  returning id into r.ap2;

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CU', 'Pelanggan Muat', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SU', 'Pembekal Muat', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'KHD', 'Khidmat', 'service', false, 'C62', 100) returning id into r.item;

  -- A contact that already named the bank before the rule, as a row in
  -- production could have.
  alter table public.contacts disable trigger an_account_fits_where_it_is_used;
  insert into public.contacts (org_id, code, name, contact_type, receivable_account_id)
  values (r.org, 'LAMA', 'Pelanggan Lama', 'customer', r.bank) returning id into r.legacy;
  alter table public.contacts enable trigger an_account_fits_where_it_is_used;

  insert into t_af select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.af_gl(p_doc uuid, p_table text) returns text
language plpgsql as $$
declare v text;
begin
  execute format(
    'select string_agg(a.code || '' '' || (l.debit - l.credit)::text, '', '' order by a.code)
       from public.gl_lines l join public.accounts a on a.id = l.account_id
      where l.entry_id = (select gl_entry_id from public.%I where id = %L)',
    p_table, p_doc) into v;
  return v;
end $$;

do $$
declare d t_af; v_inv uuid; v_bill uuid; v_line uuid;
begin
  select * into d from t_af;

  -- -------------------------------------------------------------------
  -- A contact's control account is an active one of its own kind
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a customer''s receivable account is not the bank',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.bank, d.cust),
    'A customer''s receivable account is an active receivables account that is not a heading, and 1120 Bank Accounts is a bank account. The aged listing reconciles against it%',
    '23514');
  perform pg_temp.check_refused('nor a heading of receivables',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.ar_group, d.cust),
    'A customer''s receivable account is an active receivables account that is not a heading, and 1250 Penghutang Kumpulan is a heading.%',
    '23514');
  perform pg_temp.check_refused('nor a receivables account that has been retired',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.ar_old, d.cust),
    'A customer''s receivable account is %, and 1219 Penghutang Lama is retired.%', '23514');
  perform pg_temp.check_refused('nor a payables account',
    format('update public.contacts set receivable_account_id = %L where id = %L', d.ap, d.cust),
    'A customer''s receivable account is %, and 2110 Accounts Payable is an accounts payable account.%',
    '23514');
  perform pg_temp.check_refused('a supplier''s payable account is not a receivables account',
    format('update public.contacts set payable_account_id = %L where id = %L', d.ar2, d.sup),
    'A supplier''s payable account is an active payables account that is not a heading, and 1211 Penghutang Eksport is an accounts receivable account.%',
    '23514');
  perform pg_temp.check_refused('nor does a customer arrive with the till as its receivable',
    format('insert into public.contacts (org_id, code, name, contact_type, receivable_account_id)
            values (%L, %L, %L, %L, %L)', d.org, 'BARU', 'Pelanggan Baru', 'customer', d.cash),
    'A customer''s receivable account is %, and 1110 Cash in Hand is a cash account.%', '23514');

  update public.contacts set receivable_account_id = d.ar2 where id = d.cust;
  update public.contacts set payable_account_id = d.ap2 where id = d.sup;
  perform pg_temp.check_eq('a second receivables account and a second payables account stand',
    (select count(*)::int from public.contacts
      where (id = d.cust and receivable_account_id = d.ar2)
         or (id = d.sup and payable_account_id = d.ap2)), 2);

  -- A row that named the bank before the rule is still written; it is
  -- asked only when the account is set or changed. Saved as the app
  -- saves a contact: `Contact.toJson` sends both control accounts back
  -- with every edit, so the trigger fires and has to see that the
  -- account did not move. Setting `name` alone would not fire it at all.
  update public.contacts
     set name = 'Pelanggan Lama Bhd', receivable_account_id = d.bank, payable_account_id = null
   where id = d.legacy;
  perform pg_temp.check_eq('a contact already naming an account is still written',
    (select name from public.contacts where id = d.legacy), 'Pelanggan Lama Bhd');

  -- -------------------------------------------------------------------
  -- A line posts to neither the money nor the control accounts
  -- -------------------------------------------------------------------
  insert into public.sales_documents (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
                                      currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-MUAT', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;

  perform pg_temp.check_refused('an invoice line is not coded to the bank',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type,
              description, quantity, unit_price, account_id, tax_rate)
            values (%L, %L, 1, %L, %L, 1, 1000, %L, 0)', d.org, v_inv, 'item', 'Khidmat', d.bank),
    'A sales document line''s account may not be 1120 Bank Accounts, a bank account: money reaches a bank or a till through a receipt or a payment%',
    '23514');
  perform pg_temp.check_refused('nor to the receivables control account',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type,
              description, quantity, unit_price, account_id, tax_rate)
            values (%L, %L, 1, %L, %L, 1, 1000, %L, 0)', d.org, v_inv, 'item', 'Khidmat', d.ar),
    'A sales document line''s account may not be 1210 Accounts Receivable, an accounts receivable account: a receivable or a payable is posted by the document it belongs to%',
    '23514');
  perform pg_temp.check_refused('nor to a heading',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type,
              description, quantity, unit_price, account_id, tax_rate)
            values (%L, %L, 1, %L, %L, 1, 1000, %L, 0)', d.org, v_inv, 'item', 'Khidmat', d.ar_head),
    'A sales document line''s account may not be 1200 Trade and Other Receivables, which is a heading%',
    '23514');

  -- A customer's deposit is a liability, and stands.
  insert into public.sales_document_lines (org_id, document_id, line_no, line_type,
                                           description, quantity, unit_price, account_id, tax_rate)
  values (d.org, v_inv, 1, 'item', 'Deposit', 1, 1000, d.deposit, 0)
  returning id into v_line;
  perform pg_temp.check_refused('nor is a line moved onto the bank afterwards',
    format('update public.sales_document_lines set account_id = %L where id = %L', d.bank, v_line),
    'A sales document line''s account may not be 1120 Bank Accounts, a bank account%', '23514');

  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('so the invoice posts to the customer''s own receivable and the line''s own account',
    pg_temp.af_gl(v_inv, 'sales_documents'), '1211 1000.00, 2120 -1000.00');

  insert into public.purchase_documents (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
                                         currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-MUAT', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  perform pg_temp.check_refused('a bill line is not coded to the payables control account',
    format('insert into public.purchase_document_lines (org_id, document_id, line_no, line_type,
              description, quantity, unit_price, account_id, tax_rate)
            values (%L, %L, 1, %L, %L, 1, 400, %L, 0)', d.org, v_bill, 'item', 'Bekalan', d.ap),
    'A purchase document line''s account may not be 2110 Accounts Payable, an accounts payable account%',
    '23514');
  perform pg_temp.check_refused('nor to the till',
    format('insert into public.purchase_document_lines (org_id, document_id, line_no, line_type,
              description, quantity, unit_price, account_id, tax_rate)
            values (%L, %L, 1, %L, %L, 1, 400, %L, 0)', d.org, v_bill, 'item', 'Bekalan', d.cash),
    'A purchase document line''s account may not be 1110 Cash in Hand, a cash account%', '23514');

  -- -------------------------------------------------------------------
  -- Nor does an item's account
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an item''s sales account is not the bank',
    format('update public.items set sales_account_id = %L where id = %L', d.bank, d.item),
    'An item''s sales account may not be 1120 Bank Accounts, a bank account%', '23514');
  perform pg_temp.check_refused('nor its purchase account a heading',
    format('update public.items set purchase_account_id = %L where id = %L', d.ar_head, d.item),
    'An item''s purchase account may not be 1200 Trade and Other Receivables, which is a heading%',
    '23514');
  perform pg_temp.check_refused('nor its stock account the receivables',
    format('update public.items set inventory_account_id = %L where id = %L', d.ar, d.item),
    'An item''s stock account may not be 1210 Accounts Receivable, an accounts receivable account%',
    '23514');
  perform pg_temp.check_refused('nor its cost of sales the payables',
    format('update public.items set cogs_account_id = %L where id = %L', d.ap, d.item),
    'An item''s cost of sales account may not be 2110 Accounts Payable, an accounts payable account%',
    '23514');
  update public.items set sales_account_id = d.other_income where id = d.item;
  perform pg_temp.check_eq('an item sold as other income stands',
    (select sales_account_id from public.items where id = d.item), d.other_income);
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.contacts set receivable_account_id = %L where id = %L',
         (select bank from t_af), (select cust from t_af)),
  'A customer''s receivable account is an active receivables account%', '23514');

rollback;

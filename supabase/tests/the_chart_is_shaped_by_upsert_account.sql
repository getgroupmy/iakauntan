-- =====================================================================
-- iAkauntan :: the chart is shaped by upsert_account (0920)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/the_chart_is_shaped_by_upsert_account.sql
--
-- `upsert_account` holds the chart's rules: a number the ledger posts
-- to stays, an account with postings keeps its kind and does not
-- become a heading, a kind and its subtype agree, a parent is a
-- heading. Before `0920` a direct write by the same person stepped
-- round every one: one update turned an account holding RM100 of
-- revenue into a liability, and the profit and loss showed nothing.
-- Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ch (org uuid, cust uuid, sales uuid, revenue uuid,
                             rent uuid, expenses uuid);
grant select on t_ch to authenticated;

do $$
declare r t_ch;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Carta Pintu Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'sales']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan', 'customer') returning id into r.cust;

  select id, parent_id into r.sales, r.revenue
    from public.accounts where org_id = r.org and code = '4100';
  select id, parent_id into r.rent, r.expenses
    from public.accounts where org_id = r.org and code = '6200';
  insert into t_ch select r.*;
end $$;

-- An account's shape, as one line.
create or replace function pg_temp.shape(p_id uuid) returns text language sql as $$
  select a.code || ' ' || a.account_type || '/' || a.account_subtype
         || case when a.is_group then ' heading' else '' end
         || ' under ' || coalesce((select p.code from public.accounts p where p.id = a.parent_id), 'nothing')
    from public.accounts a where a.id = p_id;
$$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ch; v uuid; v_service uuid; v_spare uuid;
begin
  select * into d from t_ch;

  -- -------------------------------------------------------------------
  -- The function opens an account, and holds what it holds
  -- -------------------------------------------------------------------
  v_service := public.upsert_account('4150', 'Jualan Khidmat', 'revenue', 'sales',
                                     null, d.revenue, false, null, d.org);
  perform pg_temp.check_eq('upsert_account opens an account under its heading',
    pg_temp.shape(v_service), '4150 revenue/sales under 4000');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'invoice', 'INV-CARTA-1', pg_temp.today(), pg_temp.today(), d.cust, 'draft', 'MYR', 1)
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v, 1, 'item', 'Khidmat', 1, 100, 0, v_service);
  perform public.post_sales_document(v);

  perform pg_temp.check_refused('upsert_account does not change the kind of an account with postings',
    format('select public.upsert_account(%L, %L, %L, %L, %L, %L)',
           '4150', 'Jualan Khidmat', 'liability', 'current_liability', v_service, d.revenue),
    'Account 4150 has postings, so what kind of account it is cannot change.%', '23514');

  -- -------------------------------------------------------------------
  -- A direct write opens nothing
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a direct insert opens no account',
    format('insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id) '
           'values (%L, %L, %L, %L, %L, %L)',
           d.org, '4160', 'Jualan Lain', 'revenue', 'sales', d.revenue),
    'An account is opened with upsert_account, which checks its number, its kind and where it is filed -- not by a direct write.',
    '42501');
  perform pg_temp.check_eq('and none was opened',
    (select count(*) from public.accounts where org_id = d.org and code = '4160'), 0::bigint);

  -- -------------------------------------------------------------------
  -- Nor changes an account's shape
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a direct update does not renumber 4100',
    format('update public.accounts set code = %L where id = %L', '4199', d.sales),
    'Account 4100: a direct write does not change its number. upsert_account does, and checks what the change does to the books.',
    '42501');
  perform pg_temp.check_refused('nor turn revenue with RM100 posted into a liability',
    format('update public.accounts set account_type = %L, account_subtype = %L where id = %L',
           'liability', 'current_liability', v_service),
    'Account 4150: a direct write does not change what kind of account it is or its subtype.%',
    '42501');
  perform pg_temp.check_refused('nor change the kind alone',
    format('update public.accounts set account_type = %L where id = %L', 'expense', v_service),
    'Account 4150: a direct write does not change what kind of account it is. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor give an expense the subtype sales',
    format('update public.accounts set account_subtype = %L where id = %L', 'sales', d.rent),
    'Account 6200: a direct write does not change its subtype. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor make an account with postings a heading',
    format('update public.accounts set is_group = true where id = %L', v_service),
    'Account 4150: a direct write does not change whether it is a heading. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor make a heading with accounts under it postable',
    format('update public.accounts set is_group = false where id = %L', d.revenue),
    'Account 4000: a direct write does not change whether it is a heading. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor file an account under one that is not a heading',
    format('update public.accounts set parent_id = %L where id = %L', d.sales, d.rent),
    'Account 6200: a direct write does not change what it is filed under. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor under itself',
    format('update public.accounts set parent_id = %L where id = %L', d.rent, d.rent),
    'Account 6200: a direct write does not change what it is filed under. upsert_account%',
    '42501');
  perform pg_temp.check_refused('nor under nothing',
    format('update public.accounts set parent_id = null where id = %L', d.rent),
    'Account 6200: a direct write does not change what it is filed under. upsert_account%',
    '42501');
  perform pg_temp.check_refused('and all five at once are named together',
    format('update public.accounts set code = %L, account_type = %L, account_subtype = %L, '
           'is_group = true, parent_id = null where id = %L',
           '6299', 'asset', 'current_asset', d.rent),
    'Account 6200: a direct write does not change its number or what kind of account it is or its subtype or whether it is a heading or what it is filed under. upsert_account%',
    '42501');

  perform pg_temp.check_eq('after all of that the four accounts are shaped as they were',
    pg_temp.shape(d.sales) || '; ' || pg_temp.shape(v_service) || '; '
      || pg_temp.shape(d.rent) || '; ' || pg_temp.shape(d.revenue),
    '4100 revenue/sales under 4000; 4150 revenue/sales under 4000; '
      || '6200 expense/operating_expense under 6000; 4000 revenue/sales heading under nothing');
  perform pg_temp.check_eq('and the RM100 is still revenue',
    (select string_agg(x.code || ' ' || x.amount::text, ', ' order by x.code)
       from public.report_profit_loss(d.org, pg_temp.today() - 1, pg_temp.today() + 1) x),
    '4150 100.00');

  -- -------------------------------------------------------------------
  -- What the row still takes directly
  -- -------------------------------------------------------------------
  update public.accounts set tax_treatment = 'entertainment' where id = d.rent;
  perform pg_temp.check_eq('the tax treatment, which is what the chart screen writes',
    (select tax_treatment from public.accounts where id = d.rent), 'entertainment');
  update public.accounts set name = 'Sewa Pejabat', description = 'Sewa bulanan' where id = d.rent;
  perform pg_temp.check_eq('a name and a description',
    (select name || ' / ' || description from public.accounts where id = d.rent),
    'Sewa Pejabat / Sewa bulanan');
  -- Saved whole, the five sent back as they were: the trigger fires and
  -- has to see that none of them moved.
  update public.accounts
     set name = 'Sewa', code = '6200', account_type = 'expense',
         account_subtype = 'operating_expense', is_group = false, parent_id = d.expenses
   where id = d.rent;
  perform pg_temp.check_eq('and a row saved whole with its shape sent back unchanged',
    (select name from public.accounts where id = d.rent), 'Sewa');

  -- -------------------------------------------------------------------
  -- And the functions still do what the direct write may not
  -- -------------------------------------------------------------------
  v_spare := public.upsert_account('6205', 'Sewa Stor', 'expense', 'operating_expense',
                                   null, d.expenses, false, null, d.org);
  perform public.upsert_account('6206', 'Sewa Gudang', 'expense', 'other_expense',
                                v_spare, d.expenses, false);
  perform pg_temp.check_eq('upsert_account renumbers an account and changes its subtype',
    pg_temp.shape(v_spare), '6206 expense/other_expense under 6000');
  perform public.upsert_account('6206', 'Sewa Gudang', 'expense', 'other_expense',
                                v_spare, d.expenses, true);
  perform pg_temp.check_eq('and makes one with nothing posted a heading',
    pg_temp.shape(v_spare), '6206 expense/other_expense heading under 6000');
  perform public.add_sub_account(v_spare, 'Gudang Utara');
  perform pg_temp.check_eq('add_sub_account opens an account under it',
    (select count(*) from public.accounts a where a.parent_id = v_spare and a.name = 'Gudang Utara'),
    1::bigint);
  perform public.upsert_bank_account('Bank Kedua', 'Maybank', null, '5123000011',
                                     p_org_id => d.org);
  perform pg_temp.check_eq('and upsert_bank_account opens a bank''s ledger account',
    (select count(*) from public.bank_accounts b join public.accounts a on a.id = b.account_id
      where b.org_id = d.org and b.name = 'Bank Kedua' and a.account_subtype = 'bank'),
    1::bigint);
end $$;

-- The rule is the client's door: the database's owner still writes the
-- chart, as the seeders and the fixtures of this suite do.
reset role;
update public.accounts set code = '6207'
 where org_id = (select org from t_ch) and code = '6206';
select pg_temp.check_eq('the database''s owner renumbers an account directly',
  (select count(*) from public.accounts
    where org_id = (select org from t_ch) and code = '6207'), 1::bigint);

rollback;

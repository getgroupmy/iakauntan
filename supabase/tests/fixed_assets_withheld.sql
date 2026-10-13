-- =====================================================================
-- iAkauntan :: the fixed asset register is the ledger's (0865)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixed_assets_withheld.sql
--
-- `report_depreciation_history` and `report_asset_movements` have
-- refused a member who does not read the ledger since `0156`. The
-- register they are built from, its depreciation runs and entries, the
-- preview and the capital allowance schedule answered every member with
-- the module, and any member who could write could register an asset
-- or capitalise a bill line. Asked with the role `authenticated`, as
-- the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_fa (org uuid, other uuid, sales uuid, buyer uuid,
  clerk uuid, auditor uuid, asset uuid, plant uuid, waiting uuid,
  to_capitalise uuid);
grant select on t_fa to authenticated;

-- A posted bill of one line, coded to a fixed asset account.
create or replace function pg_temp.fa_bill(p_org uuid, p_no text,
  p_supplier uuid, p_account uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_doc uuid; v_line uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, pg_temp.today(), p_supplier, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id)
  values (p_org, v_doc, 1, 'item', 'Forklift', 1, p_amount, p_account)
  returning id into v_line;
  perform public.post_purchase_document(v_doc);
  return v_line;
end $$;

do $$
declare r t_fa; v_sup uuid;
  v_last_year date := (date_trunc('year', pg_temp.today()) - interval '1 year')::date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Aset Tetap Sdn Bhd');
  r.other := pg_temp.test_org('Aset Lain Sdn Bhd');
  perform pg_temp.open_years(r.org, v_last_year);
  r.sales   := pg_temp.another_user('sales@asettetap.test');
  r.buyer   := pg_temp.another_user('buyer@asettetap.test');
  r.clerk   := pg_temp.another_user('clerk@asettetap.test');
  r.auditor := pg_temp.another_user('auditor@asettetap.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.buyer, 'purchaser', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.auditor, 'auditor', 'active'),
         -- Keeps this company's books, and sells for the other.
         (r.other, r.clerk, 'sales', 'active');

  insert into public.fixed_assets (org_id, asset_no, name, category,
     acquisition_date, cost, residual_value, method, useful_life_months,
     ca_class_code)
  values (r.org, 'FA-1', 'Director''s car', 'Motor vehicles', v_last_year,
          240000, 0, 'straight_line', 60, 'motor_200k')
  returning id into r.asset;
  perform public.run_depreciation(r.org,
    (date_trunc('year', pg_temp.today()) - interval '1 day')::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;
  select id into r.plant from public.accounts
   where org_id = r.org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;
  r.waiting := pg_temp.fa_bill(r.org, 'BILL-1', v_sup, r.plant, 12500);
  r.to_capitalise := pg_temp.fa_bill(r.org, 'BILL-2', v_sup, r.plant, 8000);
  insert into t_fa select r.*;
end $$;

-- Asked of a member past the module gate who does not read the ledger.
create or replace function pg_temp.register_withheld(p_who text)
returns void language plpgsql as $$
declare d t_fa;
  v_msg constant text := 'Insufficient privileges to read the ledger';
begin
  select * into d from t_fa;
  perform pg_temp.check_true(p_who || ': the premise -- a member past the module gate who does not read the ledger',
    app.is_org_member(d.org) and app.can_read_module(d.org, 'fixed_assets')
    and not app.can_read_ledger(d.org));
  perform pg_temp.check_eq(p_who || ': reads no asset, no depreciation run and no entry',
    (select count(*) from public.fixed_assets where org_id = d.org)::text || ' / '
      || (select count(*) from public.depreciation_runs where org_id = d.org)::text || ' / '
      || (select count(*) from public.depreciation_entries where org_id = d.org)::text,
    '0 / 0 / 0');
  perform pg_temp.check_refused(p_who || ': is refused the depreciation preview',
    format('select public.depreciation_preview(%L, %L)', d.org, pg_temp.today()),
    v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': and the capital allowance schedule',
    format('select public.capital_allowance_schedule(%L, %s)', d.org,
           extract(year from pg_temp.today())::int - 1),
    v_msg, '42501');
  perform pg_temp.check_eq(p_who || ': and is told of no bill waiting to be capitalised',
    (select count(*) from public.report_uncapitalised_purchases(d.org))::int, 0);
end $$;

select pg_temp.sign_in_as((select sales from t_fa));
set local role authenticated;
select pg_temp.register_withheld('the salesman');
reset role;

-- The purchaser writes, and still does not read the ledger: what goes
-- into the register is the ledger's too.
select pg_temp.sign_in_as((select buyer from t_fa));
set local role authenticated;
select pg_temp.register_withheld('the purchaser');

do $$
declare d t_fa;
begin
  select * into d from t_fa;
  perform pg_temp.check_true('the purchaser''s premise: may write',
    app.can_write(d.org));
  perform pg_temp.check_refused('the purchaser cannot register an asset',
    format($q$insert into public.fixed_assets (org_id, asset_no, name,
       acquisition_date, cost, residual_value, method, useful_life_months)
       values (%L, 'FA-9', 'Forklift', %L, 8000, 0, 'straight_line', 60)$q$,
       d.org, pg_temp.today()),
    '%row-level security%', '42501');
  perform pg_temp.check_refused('nor capitalise a bill line',
    format($q$select public.capitalise_bill_line(%L, 'FA-9', null, null,
       'straight_line', 60)$q$, d.to_capitalise),
    'not permitted to capitalise a purchase', '42501');
  -- No WHERE, so no select policy is asked: the update policy alone
  -- says which rows it reaches.
  update public.fixed_assets set location = 'Gudang belakang';
end $$;

reset role;

-- The clerk reads the ledger and writes, and posts nothing.
select pg_temp.sign_in_as((select clerk from t_fa));
set local role authenticated;

do $$
declare d t_fa; v_n int;
begin
  select * into d from t_fa;
  perform pg_temp.check_eq('the clerk reads the asset at cost, depreciated and at book value',
    (select cost || ' / ' || accumulated_depreciation || ' / '
            || (cost - accumulated_depreciation)
       from public.fixed_assets where id = d.asset),
    '240000.00 / 48000.00 / 192000.00');
  perform pg_temp.check_eq('and the run and its entry',
    (select string_agg(r.total_amount || ' / ' || e.amount, ',')
       from public.depreciation_runs r
       join public.depreciation_entries e on e.run_id = r.id
      where r.org_id = d.org),
    '48000.00 / 48000.00');
  perform pg_temp.check_eq('and the preview, one asset in use',
    (select count(*) from public.depreciation_preview(d.org, pg_temp.today()))::int, 1);
  perform pg_temp.check_eq('and both bills waiting to be capitalised',
    (select string_agg(doc_no, ',' order by doc_no)
       from public.report_uncapitalised_purchases(d.org)),
    'BILL-1,BILL-2');
  perform pg_temp.check_true('the purchaser''s update reached no asset',
    (select location from public.fixed_assets where id = d.asset) is null);

  perform pg_temp.check_true('the clerk capitalises a bill line',
    public.capitalise_bill_line(d.to_capitalise, 'FA-2', null, null,
      'straight_line', 60) is not null);
  insert into public.fixed_assets (org_id, asset_no, name,
     acquisition_date, cost, residual_value, method, useful_life_months)
  values (d.org, 'FA-3', 'Laptop', pg_temp.today(), 4800, 0, 'straight_line', 36);
  update public.fixed_assets set location = 'Pejabat';
  get diagnostics v_n = row_count;
  perform pg_temp.check_eq('registers one by hand, and edits all three',
    (select string_agg(asset_no, ',' order by asset_no) from public.fixed_assets
      where org_id = d.org)
      || ' / ' || v_n,
    'FA-1,FA-2,FA-3 / 3');
  -- What an edit leaves behind is asked too: the other company is one
  -- whose ledger the clerk does not read. No WHERE, again -- with one,
  -- the new row is held to the select policy as well, and that would
  -- refuse the move whatever the update policy said.
  perform pg_temp.check_refused('and cannot move them into a company whose ledger the clerk does not read',
    format('update public.fixed_assets set org_id = %L', d.other),
    '%row-level security%', '42501');
end $$;

reset role;

-- The auditor reads the ledger and writes nothing.
select pg_temp.sign_in_as((select auditor from t_fa));
set local role authenticated;

do $$
declare d t_fa;
begin
  select * into d from t_fa;
  perform pg_temp.check_eq('the auditor reads the register',
    (select string_agg(asset_no, ',' order by asset_no) from public.fixed_assets
      where org_id = d.org),
    'FA-1,FA-2,FA-3');
  perform pg_temp.check_eq('and the capital allowance schedule for last year',
    (select string_agg(asset_no, ',') from public.capital_allowance_schedule(
       d.org, extract(year from pg_temp.today())::int - 1)),
    'FA-1');
  perform pg_temp.check_refused('and registers nothing',
    format($q$insert into public.fixed_assets (org_id, asset_no, name,
       acquisition_date, cost, residual_value, method, useful_life_months)
       values (%L, 'FA-8', 'Printer', %L, 900, 0, 'straight_line', 36)$q$,
       d.org, pg_temp.today()),
    '%row-level security%', '42501');
  perform pg_temp.check_refused('nor capitalises a bill line',
    format($q$select public.capitalise_bill_line(%L, 'FA-7', null, null,
       'straight_line', 60)$q$, d.waiting),
    'not permitted to capitalise a purchase', '42501');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon reads none of the three',
    not has_table_privilege('anon', 'public.fixed_assets', 'select')
    and not has_table_privilege('anon', 'public.depreciation_runs', 'select')
    and not has_table_privilege('anon', 'public.depreciation_entries', 'select'));
end $$;

rollback;

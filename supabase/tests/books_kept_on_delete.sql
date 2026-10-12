-- =====================================================================
-- iAkauntan :: what is in the books stays (0840)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/books_kept_on_delete.sql
--
-- A posted manufacturing order is the reason for its journal and stock
-- movements; a depreciated asset is what the ledger's accumulated
-- depreciation explains; a lodged filing is the record of what went to
-- SSM. Before `0840` a client could delete each, leaving the journal,
-- the movements and the charge with nothing behind them. Asked as the
-- owner with the role `authenticated`; drafts asked alongside, since
-- those stay deletable.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bk (org uuid, wh uuid, flour uuid, bread uuid,
  bom uuid, mo uuid, mo_entry uuid, bank uuid);
grant select on t_bk to authenticated;

-- A posted journal, two lines, for the accounts to have something in.
create or replace function pg_temp.jv(
  p_org uuid, p_no text, p_date date,
  p_dr uuid, p_cr uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (p_org, p_no, p_date, 'manual', 'posted', p_no)
  returning id into v_entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_dr, p_amount, 0),
         (p_org, v_entry, 2, p_cr, 0, p_amount);
end $$;

create or replace function pg_temp.acct(p_org uuid, p_subtype text)
returns uuid language sql as $$
  select id from public.accounts
   where org_id = p_org and account_subtype = p_subtype::app.account_subtype
     and not is_group
   order by code limit 1;
$$;

do $$
declare r t_bk;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Buku Kekal Sdn Bhd',
    array['inventory', 'manufacturing', 'fixed_assets', 'mbrs']);
  perform public.create_fiscal_year(r.org, date '2025-01-01');
  perform public.create_fiscal_year(r.org, date_trunc('year', app.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', app.today())::date);
  perform pg_temp.jv(r.org, 'JV-1', date '2025-01-02',
    pg_temp.acct(r.org, 'bank'), pg_temp.acct(r.org, 'share_capital'), 100000);

  -- A posted manufacturing order: twenty kilos of flour into ten loaves.
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'KILANG', 'Factory', true) returning id into r.wh;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (r.org, 'TEPUNG', 'Flour', 'stock', true, 'KGM', 2.00) returning id into r.flour;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (r.org, 'ROTI', 'Bread', 'stock', true, 'C62') returning id into r.bread;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity, unit_cost)
  values (r.org, 'OPEN-1', app.today(), 'opening_balance', r.flour, r.wh, 100, 2.00);
  insert into public.bills_of_materials (org_id, item_id, code, name, output_quantity, is_active)
  values (r.org, r.bread, 'BOM-1', 'Bread', 10, true) returning id into r.bom;
  insert into public.bom_lines (org_id, bom_id, line_no, item_id, quantity)
  values (r.org, r.bom, 1, r.flour, 20);
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity, status)
  values (r.org, 'MO-1', r.bread, r.bom, r.wh, 10, 'draft') returning id into r.mo;
  insert into public.mo_components (org_id, mo_id, item_id, quantity_required)
  values (r.org, r.mo, r.flour, 20);
  perform public.confirm_manufacturing_order(r.mo);
  perform public.post_manufacturing_order(r.mo);
  select gl_entry_id into r.mo_entry from public.manufacturing_orders where id = r.mo;
  -- Where a disposal's proceeds go. Made as the session: since `0823` a
  -- client sets a bank up only through `upsert_bank_account`.
  r.bank := pg_temp.test_bank_account(r.org, 'Maybank current', 'current', 'MYR', 0, 0, '1234');
  insert into t_bk select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bk; v_draft uuid; v_van uuid; v_spare uuid; v_filing uuid; v_open uuid;
begin
  select * into d from t_bk;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- The manufacturing order.
  perform pg_temp.check_refused('a posted manufacturing order is not deleted',
    format('delete from public.manufacturing_orders where id = %L', d.mo),
    'Manufacturing order MO-1 is posted, and its journal and the stock it moved stand on it.%',
    '42501');
  perform pg_temp.check_true('so its journal and its movements still have it behind them',
    exists (select 1 from public.manufacturing_orders where id = d.mo and gl_entry_id = d.mo_entry)
    and (select count(*) from public.mo_components where mo_id = d.mo) = 1);
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-2', d.bread, d.bom, d.wh, 5) returning id into v_draft;
  delete from public.manufacturing_orders where id = v_draft;
  perform pg_temp.check_true('a draft order is still thrown away',
    not exists (select 1 from public.manufacturing_orders where id = v_draft));

  -- The fixed asset.
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (d.org, 'FA-1', 'Van', 'Motor Vehicles', date_trunc('year', app.today())::date,
          12000, 0, 'straight_line', 60)
  returning id into v_van;
  perform public.run_depreciation(d.org, (date_trunc('year', app.today()) + interval '3 months - 1 day')::date);
  perform pg_temp.check_refused('a depreciated asset is not deleted',
    format('delete from public.fixed_assets where id = %L', v_van),
    'Asset FA-1 has been depreciated or disposed of, and the ledger carries what that charged.%',
    '42501');
  perform pg_temp.check_eq('so its depreciation is still in the register',
    (select count(*)::integer from public.depreciation_entries where asset_id = v_van), 1);
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (d.org, 'FA-2', 'Laptop', 'Computers', app.today(), 4000, 0, 'straight_line', 36)
  returning id into v_spare;
  delete from public.fixed_assets where id = v_spare;
  perform pg_temp.check_true('an asset never depreciated is still taken off',
    not exists (select 1 from public.fixed_assets where id = v_spare));
  -- Nothing to depreciate -- its residual value is its cost -- and sold
  -- the day it was bought: a disposal posted and no depreciation entry,
  -- so the disposal alone says it is in the books.
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (d.org, 'FA-3', 'Forklift', 'Machinery', app.today(), 9000, 9000, 'straight_line', 60)
  returning id into v_spare;
  perform public.dispose_fixed_asset(v_spare, app.today(), 9000, d.bank);
  perform pg_temp.check_eq('-- with no depreciation entry',
    (select count(*)::integer from public.depreciation_entries where asset_id = v_spare), 0);
  perform pg_temp.check_refused('nor one disposed of',
    format('delete from public.fixed_assets where id = %L', v_spare),
    'Asset FA-3 has been depreciated or disposed of%', '42501');

  -- The filing.
  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (d.org, date '2025-01-01', date '2025-12-31', 'mpers', 'audited', 3)
  returning id into v_filing;
  update public.fs_filings
     set auditor_name = 'Tan & Partners', auditor_firm_no = 'AF 1234',
         opinion = 'unmodified', audit_report_date = date '2026-04-15',
         directors_approval_date = date '2026-04-15', circulated_on = date '2026-04-20'
   where id = v_filing;
  perform public.fs_freeze(v_filing);
  perform public.fs_lodge(v_filing, 'MBRS-2026-000123', date '2026-05-02');
  perform pg_temp.check_refused('a lodged filing is not deleted',
    format('delete from public.fs_filings where id = %L', v_filing),
    'These accounts have been lodged with SSM, and stay as the record of what was lodged.%',
    '42501');
  perform pg_temp.check_true('so what went to SSM is still recorded',
    exists (select 1 from public.fs_figures where filing_id = v_filing));
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status)
  values (d.org, date '2024-01-01', date '2024-12-31', 'audited') returning id into v_open;
  delete from public.fs_filings where id = v_open;
  perform pg_temp.check_true('a filing not lodged is still thrown away',
    not exists (select 1 from public.fs_filings where id = v_open));
end $$;

reset role;

-- The database itself, as the owner, is not a client: the platform's
-- teardown removes what it removes.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every function that deletes these is a definer,
-- and a cascade runs as the table's owner.
do $$
declare d t_bk;
begin
  select * into d from t_bk;
  delete from public.manufacturing_orders where id = d.mo;
  perform pg_temp.check_true('the owner, at the top, is not refused',
    not exists (select 1 from public.manufacturing_orders where id = d.mo));
end $$;

rollback;

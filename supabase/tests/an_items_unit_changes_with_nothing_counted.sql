-- =====================================================================
-- iAkauntan :: an item's unit changes with nothing counted in it (0917)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_items_unit_changes_with_nothing_counted.sql
--
-- An item's stock, its average cost and its pack sizes are all counted
-- in `items.uom_code`. Before `0917` ten litres at 25, their unit
-- changed to millilitres, read as ten millilitres at 25 each: one
-- litre sold took 1,000 of them, left -990 on hand and booked 25,000
-- of cost. As the owner with the role `authenticated`, as the app
-- writes, and once as the database's owner: the rule is for every
-- writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_un (org uuid, sup uuid, cust uuid, wh uuid, wh2 uuid,
                             oil uuid, tin uuid, empty uuid, split uuid);
grant select on t_un to authenticated;

do $$
declare r t_un;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Unit Stok Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'CAWANGAN', 'Cawangan', false) returning id into r.wh2;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Unit', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Unit', 'customer') returning id into r.cust;

  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'MINYAK', 'Minyak Masak', 'stock', true, 'LTR', 40) returning id into r.oil;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'TIN', 'Tin Sardin', 'stock', true, 'C62', 6) returning id into r.tin;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'KOSONG', 'Barang Kosong', 'stock', true, 'C62', 6) returning id into r.empty;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BELAH', 'Barang Terbelah', 'stock', true, 'C62', 6) returning id into r.split;

  -- Five in one warehouse and five short in the other: nothing on hand
  -- in all, and something in each.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
     unit_cost, total_cost, source_table)
  values
    (r.org, 'SM-BELAH-1', pg_temp.today(), 'adjustment_in', r.split, r.wh, 5, 10, 50, 'stock_adjustments'),
    (r.org, 'SM-BELAH-2', pg_temp.today(), 'adjustment_out', r.split, r.wh2, -5, 10, -50, 'stock_adjustments');
  insert into t_un select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.un_gl(p_org uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id;
$$;

create or replace function pg_temp.un_sell(p_no text, p_qty numeric, p_uom text, p_price numeric)
returns void language plpgsql as $$
declare d t_un; v uuid;
begin
  select * into d from t_un;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code,
     unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.oil, 'Minyak', p_qty, p_uom, p_price, d.wh, 0);
  perform public.post_sales_document(v);
end $$;

do $$
declare d t_un; v uuid;
begin
  select * into d from t_un;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-UNIT', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code,
     unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.oil, 'Minyak', 10, 'LTR', 25, d.wh, 0);
  perform public.post_purchase_document(v);
  perform public.upsert_item_uom_pack(d.tin, 'CT', 24);

  -- -------------------------------------------------------------------
  -- The unit stays while something is counted in it
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('litres do not become millilitres with ten on hand',
    format('update public.items set uom_code = %L where id = %L', 'MLT', d.oil),
    'Minyak Masak (MINYAK) still has stock on hand (10 at MAIN), counted in LTR, so its unit stays LTR. The quantity on hand and its cost would be read as MLT without either changing.%',
    '23514');
  perform pg_temp.check_refused('nor for one with stock in one warehouse and short in another',
    format('update public.items set uom_code = %L where id = %L', 'DZN', d.split),
    'Barang Terbelah (BELAH) still has stock on hand (-5 at CAWANGAN, 5 at MAIN), counted in C62%',
    '23514');
  perform pg_temp.check_refused('nor with a pack size set, though nothing is on hand',
    format('update public.items set uom_code = %L where id = %L', 'DZN', d.tin),
    'Tin Sardin (TIN) has pack sizes counted in C62 (CT = 24 C62), so its unit stays C62. Each would become that many DZN without changing.%',
    '23514');

  -- Saved as the app saves an item: whole, the unit sent back as it
  -- was. The trigger fires and has to see that it did not change.
  update public.items set name = 'Minyak Masak Tulen', uom_code = 'LTR' where id = d.oil;
  perform pg_temp.check_eq('the rest of the item is still written',
    (select name from public.items where id = d.oil), 'Minyak Masak Tulen');

  -- -------------------------------------------------------------------
  -- So a litre is still a litre
  -- -------------------------------------------------------------------
  perform pg_temp.un_sell('INV-UNIT-1', 1, 'LTR', 40);
  perform pg_temp.check_eq('a litre sold takes one of the ten, at its cost',
    pg_temp.un_gl(d.org), '1210 40.00, 1310 225.00, 2110 -250.00, 4100 -40.00, 5200 25.00');
  perform pg_temp.un_sell('INV-UNIT-2', 500, 'MLT', 0.04);
  perform pg_temp.check_eq('and five hundred millilitres takes half of one',
    (select sum(quantity) from public.stock_movements where item_id = d.oil), 8.5000::numeric);

  -- -------------------------------------------------------------------
  -- And changes once nothing is counted in it
  -- -------------------------------------------------------------------
  perform pg_temp.un_sell('INV-UNIT-3', 8.5, 'LTR', 40);
  update public.items set uom_code = 'MLT' where id = d.oil;
  perform pg_temp.check_eq('with none left, litres become millilitres',
    (select uom_code from public.items where id = d.oil), 'MLT');

  perform public.delete_item_uom_pack(d.tin, 'CT');
  update public.items set uom_code = 'DZN' where id = d.tin;
  perform pg_temp.check_eq('and with its pack size removed, pieces become dozens',
    (select uom_code from public.items where id = d.tin), 'DZN');

  update public.items set uom_code = 'KGM' where id = d.empty;
  perform pg_temp.check_eq('an item with nothing counted in it changes freely',
    (select uom_code from public.items where id = d.empty), 'KGM');
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.items set uom_code = %L where id = %L', 'DZN', (select split from t_un)),
  'Barang Terbelah (BELAH) still has stock on hand%', '23514');

rollback;

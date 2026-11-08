-- =====================================================================
-- iAkauntan :: an item with stock keeps tracking it (0914)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_item_with_stock_keeps_tracking_it.sql
--
-- Posting moves stock and books cost of sales only for an item that
-- tracks inventory. Before `0914` an item holding ten could have its
-- tracking switched off, and selling all ten then moved nothing and
-- booked no cost: ten still on hand, 1310 still holding their value.
-- As the owner with the role `authenticated`, as the app writes, and
-- once as the database's owner: the rule is for every writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ik (org uuid, sup uuid, cust uuid, item uuid, split uuid,
                             service uuid, wh uuid, wh2 uuid);
grant select on t_ik to authenticated;

do $$
declare r t_ik;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Jejak Stok Sdn Bhd');
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
  values (r.org, 'SUP', 'Pembekal Stok', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Stok', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 40) returning id into r.item;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BELAH', 'Barang Terbelah', 'stock', true, 'C62', 40) returning id into r.split;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'KHD', 'Khidmat', 'service', false, 'C62', 100) returning id into r.service;

  -- Five in one warehouse and five short in the other, as the ledger
  -- can hold them: nothing on hand in all, and something in each.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
     unit_cost, total_cost, source_table)
  values
    (r.org, 'SM-BELAH-1', pg_temp.today(), 'adjustment_in', r.split, r.wh, 5, 10, 50, 'stock_adjustments'),
    (r.org, 'SM-BELAH-2', pg_temp.today(), 'adjustment_out', r.split, r.wh2, -5, 10, -50, 'stock_adjustments');
  -- And a service that holds three it never tracked, as an import could
  -- leave one: posting cannot, so it is written here directly. Turning
  -- tracking on is never asked, whatever the item holds.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
     unit_cost, total_cost, source_table)
  values (r.org, 'SM-KHD-1', pg_temp.today(), 'opening_balance', r.service, r.wh, 3, 10, 30,
          'stock_adjustments');
  insert into t_ik select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.ik_gl(p_org uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id;
$$;

do $$
declare d t_ik; v uuid;
begin
  select * into d from t_ik;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-STOK', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.item, 'Barang', 10, 25, d.wh, 0);
  perform public.post_purchase_document(v);
  perform pg_temp.check_eq('ten bought and on hand',
    (select sum(quantity) from public.stock_movements where item_id = d.item), 10.0000::numeric);

  -- -------------------------------------------------------------------
  -- An item holding stock keeps tracking it
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('its tracking is not switched off',
    format('update public.items set track_inventory = false where id = %L', d.item),
    'Barang (BRG) still has stock on hand (10 at MAIN), so it keeps tracking it.%', '23514');
  perform pg_temp.check_refused('nor is it made a service',
    format('update public.items set item_type = %L where id = %L', 'service', d.item),
    'Barang (BRG) still has stock on hand (10 at MAIN)%', '23514');
  perform pg_temp.check_refused('nor a non-stock item, as the item screen saves one',
    format('update public.items set item_type = %L, track_inventory = false where id = %L',
           'non_stock', d.item),
    'Barang (BRG) still has stock on hand%', '23514');
  perform pg_temp.check_refused('nor one with stock in one warehouse and short in another',
    format('update public.items set track_inventory = false where id = %L', d.split),
    'Barang Terbelah (BELAH) still has stock on hand (-5 at CAWANGAN, 5 at MAIN)%', '23514');

  update public.items set name = 'Barang Baik', unit_price = 45 where id = d.item;
  perform pg_temp.check_eq('the rest of the item is still written',
    (select name || ' ' || unit_price::text from public.items where id = d.item), 'Barang Baik 45.0000');

  -- -------------------------------------------------------------------
  -- So a sale takes the goods out and books their cost
  -- -------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-STOK', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.item, 'Barang', 10, 40, d.wh, 0);
  perform public.post_sales_document(v);
  perform pg_temp.check_eq('sold, the ten leave the shelf',
    (select sum(quantity) from public.stock_movements where item_id = d.item), 0.0000::numeric);
  perform pg_temp.check_eq('and their cost leaves 1310',
    pg_temp.ik_gl(d.org), '1210 400.00, 2110 -250.00, 4100 -400.00, 5200 250.00');

  -- With nothing on hand, it may stop.
  update public.items set item_type = 'service', track_inventory = false where id = d.item;
  perform pg_temp.check_eq('with none left, it may become a service',
    (select item_type || ' ' || track_inventory::text from public.items where id = d.item), 'service false');

  -- Turning tracking on is not asked.
  update public.items set item_type = 'stock', track_inventory = true where id = d.service;
  perform pg_temp.check_true('a service holding stock may start tracking it',
    (select track_inventory from public.items where id = d.service));
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.items set track_inventory = false where id = %L', (select split from t_ik)),
  'Barang Terbelah (BELAH) still has stock on hand%', '23514');

rollback;

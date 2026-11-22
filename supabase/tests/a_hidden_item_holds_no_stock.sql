-- =====================================================================
-- iAkauntan :: a hidden item holds no stock (0918)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_hidden_item_holds_no_stock.sql
--
-- The stock listing leaves out an item that is switched off or
-- soft-deleted. Before `0918` an item holding ten could be hidden, and
-- a bill could bring ten into one already hidden: either way the
-- listing showed less than account 1310 held. As the owner with the
-- role `authenticated`, as the app writes, and as the database's
-- owner: both rules are for every writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_hd (org uuid, sup uuid, cust uuid, wh uuid, wh2 uuid,
                             held uuid, off uuid, gone uuid, split uuid, legacy uuid);
grant select on t_hd to authenticated;

create or replace function pg_temp.hd_buy(p_item uuid, p_no text, p_qty numeric)
returns void language plpgsql as $$
declare d t_hd; v uuid;
begin
  select * into d from t_hd;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', p_no, pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', p_item, 'Barang', p_qty, 25, d.wh, 0);
  perform public.post_purchase_document(v);
end $$;

create or replace function pg_temp.hd_sell(p_item uuid, p_no text, p_qty numeric, p_wh uuid)
returns void language plpgsql as $$
declare d t_hd; v uuid;
begin
  select * into d from t_hd;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', p_item, 'Barang', p_qty, 40, p_wh, 0);
  perform public.post_sales_document(v);
end $$;

do $$
declare r t_hd;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Barang Sorok Sdn Bhd');
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
  values (r.org, 'SUP', 'Pembekal Sorok', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Sorok', 'customer') returning id into r.cust;

  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'ADA', 'Barang Ada', 'stock', true, 'C62', 40) returning id into r.held;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, is_active)
  values (r.org, 'TUTUP', 'Barang Tutup', 'stock', true, 'C62', 40, false) returning id into r.off;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, deleted_at)
  values (r.org, 'BUANG', 'Barang Buang', 'stock', true, 'C62', 40, now()) returning id into r.gone;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BELAH', 'Barang Terbelah', 'stock', true, 'C62', 40) returning id into r.split;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'LAMA', 'Barang Lama', 'stock', true, 'C62', 40) returning id into r.legacy;
  insert into t_hd select r.*;

  -- Five in one warehouse and five short in the other: nothing on hand
  -- in all, and something in each.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
     unit_cost, total_cost, source_table)
  values
    (r.org, 'SM-BELAH-1', pg_temp.today(), 'adjustment_in', r.split, r.wh, 5, 10, 50, 'stock_adjustments'),
    (r.org, 'SM-BELAH-2', pg_temp.today(), 'adjustment_out', r.split, r.wh2, -5, 10, -50, 'stock_adjustments');

  -- An item hidden while it held ten, as one hidden before `0918` would
  -- be: bought, then switched off with the rule out of the way. What it
  -- holds has to be able to leave, and nothing more.
  perform pg_temp.hd_buy(r.legacy, 'BIL-LAMA', 10);
  alter table public.items disable trigger an_item_holding_stock_is_not_hidden;
  update public.items set is_active = false where id = r.legacy;
  alter table public.items enable trigger an_item_holding_stock_is_not_hidden;
end $$;

set local role authenticated;

create or replace function pg_temp.hd_1310(p_org uuid) returns numeric language sql as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = p_org and a.code = '1310';
$$;

do $$
declare d t_hd;
begin
  select * into d from t_hd;
  perform pg_temp.hd_buy(d.held, 'BIL-ADA', 10);

  -- -------------------------------------------------------------------
  -- An item holding stock is not hidden
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an item with ten on hand is not switched off',
    format('update public.items set is_active = false where id = %L', d.held),
    'Barang Ada (ADA) still has stock on hand (10 at MAIN), so it stays in use. The stock listing leaves out an item that is switched off or removed%',
    '23514');
  perform pg_temp.check_refused('nor soft-deleted',
    format('update public.items set deleted_at = now() where id = %L', d.held),
    'Barang Ada (ADA) still has stock on hand (10 at MAIN), so it stays in use.%', '23514');
  perform pg_temp.check_refused('nor one with stock in one warehouse and short in another',
    format('update public.items set is_active = false where id = %L', d.split),
    'Barang Terbelah (BELAH) still has stock on hand (-5 at CAWANGAN, 5 at MAIN)%', '23514');

  -- Saved as the app saves an item: whole, `is_active` sent back as it
  -- was. The trigger fires and has to see that nothing was hidden.
  update public.items set name = 'Barang Ada Lagi', is_active = true, deleted_at = null
   where id = d.held;
  perform pg_temp.check_eq('the rest of the item is still written',
    (select name from public.items where id = d.held), 'Barang Ada Lagi');

  -- -------------------------------------------------------------------
  -- And a hidden item takes no stock
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a bill does not bring ten into an item that is switched off',
    format('select pg_temp.hd_buy(%L, %L, 10)', d.off, 'BIL-TUTUP'),
    'Barang Tutup (TUTUP) has been switched off and takes no more stock: this would take it from 0 to 10 at MAIN.%',
    '23514');
  perform pg_temp.check_refused('nor into one that has been removed',
    format('select pg_temp.hd_buy(%L, %L, 10)', d.gone, 'BIL-BUANG'),
    'Barang Buang (BUANG) has been removed and takes no more stock: this would take it from 0 to 10 at MAIN.%',
    '23514');

  -- What a hidden item already holds can still leave it.
  perform pg_temp.hd_sell(d.legacy, 'INV-LAMA-1', 4, d.wh);
  perform pg_temp.check_eq('four of the ten a hidden item holds are sold',
    (select sum(quantity) from public.stock_movements where item_id = d.legacy), 6.0000::numeric);
  perform pg_temp.check_refused('but it is not sold past nothing',
    format('select pg_temp.hd_sell(%L, %L, 7, %L)', d.legacy, 'INV-LAMA-2', d.wh),
    'Barang Lama (LAMA) has been switched off and takes no more stock: this would take it from 6 to -1 at MAIN.%',
    '23514');
  perform pg_temp.check_refused('nor topped up',
    format('select pg_temp.hd_buy(%L, %L, 5)', d.legacy, 'BIL-LAMA-2'),
    'Barang Lama (LAMA) has been switched off and takes no more stock: this would take it from 6 to 11 at MAIN.%',
    '23514');
  perform pg_temp.check_refused('nor sold from a warehouse where it has none',
    format('select pg_temp.hd_sell(%L, %L, 3, %L)', d.legacy, 'INV-LAMA-3', d.wh2),
    'Barang Lama (LAMA) has been switched off and takes no more stock: this would take it from 0 to -3 at CAWANGAN.%',
    '23514');
  perform pg_temp.hd_sell(d.legacy, 'INV-LAMA-4', 6, d.wh);
  perform pg_temp.check_eq('with the last of it gone, the listing agrees with the books',
    (select sum(s.value) from public.stock_on_hand(d.org) s), pg_temp.hd_1310(d.org));
  perform pg_temp.check_eq('at the ten still on the shelf',
    pg_temp.hd_1310(d.org), 250.00::numeric);

  -- -------------------------------------------------------------------
  -- Emptied, an item is hidden; switched on, it takes stock again
  -- -------------------------------------------------------------------
  perform pg_temp.hd_sell(d.held, 'INV-ADA', 10, d.wh);
  update public.items set is_active = false where id = d.held;
  perform pg_temp.check_true('sold out, the item is switched off',
    (select not is_active from public.items where id = d.held));

  update public.items set is_active = true where id = d.off;
  perform pg_temp.hd_buy(d.off, 'BIL-TUTUP-2', 10);
  perform pg_temp.check_eq('and one switched back on takes stock again',
    (select sum(quantity) from public.stock_movements where item_id = d.off), 10.0000::numeric);
end $$;

-- Both rules are for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner does not hide an item with stock either',
  format('update public.items set is_active = false where id = %L', (select split from t_hd)),
  'Barang Terbelah (BELAH) still has stock on hand%', '23514');
select pg_temp.check_refused('nor write stock into a hidden one',
  format('insert into public.stock_movements
            (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
             unit_cost, total_cost, source_table)
          values (%L, %L, %L, %L, %L, %L, 3, 10, 30, %L)',
         (select org from t_hd), 'SM-BUANG-1', pg_temp.today(), 'adjustment_in',
         (select gone from t_hd), (select wh from t_hd), 'stock_adjustments'),
  'Barang Buang (BUANG) has been removed and takes no more stock: this would take it from 0 to 3 at MAIN.%',
  '23514');

-- A movement of no units is not asked: a landed cost adds value to what
-- is there and moves nothing.
insert into public.stock_movements
  (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
   unit_cost, total_cost, source_table)
select org, 'SM-LAMA-0', pg_temp.today(), 'landed_cost', legacy, wh, 0, 0, 0, 'landed_cost_runs'
  from t_hd;
select pg_temp.check_eq('a movement of no units into a hidden item passes',
  (select count(*)::int from public.stock_movements where movement_no = 'SM-LAMA-0'), 1);

rollback;

-- =====================================================================
-- iAkauntan :: how an item is tracked changes with none on hand (0916)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tracking_changes_with_none_on_hand.sql
--
-- Once an item is tracked by batch or serial, every movement names its
-- units, and the batch balances are what a recall list reads. Before
-- `0916` tracking turned ON with ten on hand left ten that could not be
-- sold, named or unnamed; turned OFF with ten in a batch, the ten sold
-- unnamed and the batch went on saying they were on the shelf. As the
-- owner with the role `authenticated`, as the app writes, and once as
-- the database's owner: the rule is for every writer.
--
-- The lot check is a deferred constraint, so each posting here is
-- taken as far as it (`set constraints all immediate`): a posting that
-- only a commit would refuse proves nothing in a file that rolls back.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tk (org uuid, sup uuid, cust uuid, wh uuid, wh2 uuid,
                             plain uuid, lotted uuid, empty uuid, split uuid, ghost uuid);
grant select on t_tk to authenticated;

create or replace function pg_temp.tk_buy(p_item uuid, p_no text, p_qty numeric, p_lots jsonb)
returns void language plpgsql as $$
declare d t_tk; v uuid; l uuid;
begin
  select * into d from t_tk;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', p_no, pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', p_item, 'Barang', p_qty, 25, d.wh, 0) returning id into l;
  if p_lots is not null then
    perform public.set_line_lots('purchase_document_lines', l, p_lots);
  end if;
  perform public.post_purchase_document(v);
  set constraints all immediate;
  set constraints all deferred;
end $$;

create or replace function pg_temp.tk_sell(p_item uuid, p_no text, p_qty numeric, p_lots jsonb)
returns void language plpgsql as $$
declare d t_tk; v uuid; l uuid;
begin
  select * into d from t_tk;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', p_item, 'Barang', p_qty, 40, d.wh, 0) returning id into l;
  if p_lots is not null then
    perform public.set_line_lots('sales_document_lines', l, p_lots);
  end if;
  perform public.post_sales_document(v);
  set constraints all immediate;
  set constraints all deferred;
end $$;

do $$
declare r t_tk;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Jejak Lot Sdn Bhd');
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
  values (r.org, 'SUP', 'Pembekal Lot', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Lot', 'customer') returning id into r.cust;

  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BIASA', 'Barang Biasa', 'stock', true, 'C62', 40) returning id into r.plain;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, tracking)
  values (r.org, 'LOT', 'Barang Berlot', 'stock', true, 'C62', 40, 'batch') returning id into r.lotted;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'KOSONG', 'Barang Kosong', 'stock', true, 'C62', 40) returning id into r.empty;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BELAH', 'Barang Terbelah', 'stock', true, 'C62', 40) returning id into r.split;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, tracking)
  values (r.org, 'HANTU', 'Barang Hantu', 'stock', true, 'C62', 40, 'batch') returning id into r.ghost;
  insert into t_tk select r.*;

  -- Five in one warehouse and five short in the other: nothing on hand
  -- in all, and something in each.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity,
     unit_cost, total_cost, source_table)
  values
    (r.org, 'SM-BELAH-1', pg_temp.today(), 'adjustment_in', r.split, r.wh, 5, 10, 50, 'stock_adjustments'),
    (r.org, 'SM-BELAH-2', pg_temp.today(), 'adjustment_out', r.split, r.wh2, -5, 10, -50, 'stock_adjustments');

  -- A batch that says it holds three with nothing on hand: what `0916`
  -- stops happening, made here the way it used to happen -- three in
  -- by batch, tracking turned off with the trigger out of the way,
  -- three out unnamed. The on-hand rule cannot see this one, so the
  -- batch rule has a case that is its alone.
  perform pg_temp.tk_buy(r.ghost, 'BIL-HANTU', 3, '[{"lot_ref":"HANTU-1","quantity":3}]'::jsonb);
  alter table public.items disable trigger tracking_changes_with_none_on_hand;
  update public.items set tracking = 'none' where id = r.ghost;
  alter table public.items enable trigger tracking_changes_with_none_on_hand;
  perform pg_temp.tk_sell(r.ghost, 'INV-HANTU', 3, null);
end $$;

set local role authenticated;

do $$
declare d t_tk;
begin
  select * into d from t_tk;

  perform pg_temp.tk_buy(d.plain, 'BIL-BIASA', 10, null);
  perform pg_temp.tk_buy(d.lotted, 'BIL-LOT', 10,
    '[{"lot_ref":"LOT-MAC","quantity":10,"expiry_date":"2027-03-31"}]'::jsonb);
  perform pg_temp.check_eq('the fixture''s ghost has none on hand and three in its batch',
    (select coalesce(sum(quantity), 0)::text from public.stock_movements where item_id = d.ghost)
      || ' / ' || (select sum(quantity)::text from public.v_lot_balances where item_id = d.ghost),
    '0.0000 / 3.0000');

  -- -------------------------------------------------------------------
  -- Tracking is not turned on for stock that carries no number
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('batch tracking is not turned on with ten on hand',
    format('update public.items set tracking = %L where id = %L', 'batch', d.plain),
    'Barang Biasa (BIASA) still has stock on hand (10 at MAIN), so it stays not tracked by batch or serial number. Units received before the change carry no batch or serial number%',
    '23514');
  perform pg_temp.check_refused('nor serial numbers',
    format('update public.items set tracking = %L where id = %L', 'serial', d.plain),
    'Barang Biasa (BIASA) still has stock on hand (10 at MAIN)%', '23514');
  perform pg_temp.check_refused('nor for one with stock in one warehouse and short in another',
    format('update public.items set tracking = %L where id = %L', 'batch', d.split),
    'Barang Terbelah (BELAH) still has stock on hand (-5 at CAWANGAN, 5 at MAIN)%', '23514');

  -- -------------------------------------------------------------------
  -- Nor turned off, or changed, for stock that carries one
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('batch tracking is not turned off with ten in a batch',
    format('update public.items set tracking = %L where id = %L', 'none', d.lotted),
    'Barang Berlot (LOT) still has stock on hand (10 at MAIN), so it stays tracked by batch. Its batch and serial records would go on saying those units are on the shelf%',
    '23514');
  perform pg_temp.check_refused('nor changed from batch to serial',
    format('update public.items set tracking = %L where id = %L', 'serial', d.lotted),
    'Barang Berlot (LOT) still has stock on hand (10 at MAIN), so it stays tracked by batch.%', '23514');
  perform pg_temp.check_refused('nor is it turned back on while a batch still says it holds some',
    format('update public.items set tracking = %L where id = %L', 'batch', d.ghost),
    'Barang Hantu (HANTU) has nothing on hand, but its batch and serial records still say 3 in HANTU-1 -- so it stays not tracked by batch or serial number%',
    '23514');

  -- Saved as the app saves an item: whole, `tracking` sent back as it
  -- was. The trigger fires and has to see that it did not change.
  update public.items set name = 'Barang Biasa Baik', tracking = 'none' where id = d.plain;
  perform pg_temp.check_eq('the rest of the item is still written',
    (select name from public.items where id = d.plain), 'Barang Biasa Baik');

  -- -------------------------------------------------------------------
  -- So the stock leaves the way it came, and the setting changes after
  -- -------------------------------------------------------------------
  perform pg_temp.tk_sell(d.plain, 'INV-BIASA', 10, null);
  perform pg_temp.check_eq('the ten unnumbered units still sell',
    (select sum(quantity) from public.stock_movements where item_id = d.plain), 0.0000::numeric);
  update public.items set tracking = 'batch' where id = d.plain;
  perform pg_temp.check_eq('and with none left, batch tracking is turned on',
    (select tracking from public.items where id = d.plain), 'batch');

  perform pg_temp.tk_sell(d.lotted, 'INV-LOT', 10, '[{"lot_ref":"LOT-MAC","quantity":10}]'::jsonb);
  perform pg_temp.check_eq('the ten in LOT-MAC sell by name, and the batch is empty',
    (select count(*)::int from public.v_lot_balances where item_id = d.lotted), 0);
  update public.items set tracking = 'none' where id = d.lotted;
  perform pg_temp.check_eq('and with its batch empty, tracking is turned off',
    (select tracking from public.items where id = d.lotted), 'none');

  update public.items set tracking = 'serial' where id = d.empty;
  perform pg_temp.check_eq('an item that never held stock changes freely',
    (select tracking from public.items where id = d.empty), 'serial');
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.items set tracking = %L where id = %L', 'batch', (select split from t_tk)),
  'Barang Terbelah (BELAH) still has stock on hand%', '23514');

rollback;

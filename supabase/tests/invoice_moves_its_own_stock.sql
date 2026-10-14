-- =====================================================================
-- iAkauntan :: an invoice moves its own stock (0902)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/invoice_moves_its_own_stock.sql
--
-- Before `0902`, measured rather than inferred: ten bought at 10; three
-- sold quotation -> invoice, 7 on hand and 1310 at 70; three more sold
-- quotation -> delivery order -> invoice, still 7 on hand and 1310 at
-- 40. Posting skipped the stock movement for an invoice raised from a
-- delivery order, as if the delivery order had sent the goods. Nothing
-- has ever moved stock on one.
--
-- Sold both ways here, with different quantities so that neither path
-- can pass on the other's figure, and the stock compared with the
-- ledger after each step. As the owner with the role `authenticated`,
-- through `transfer_document`, as the app sells.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ms (org uuid, cust uuid, item uuid, wh uuid);
grant select on t_ms to authenticated;

do $$
declare r t_ms; v_sup uuid; v_bill uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Hantar Barang Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Tetap', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Barang', 'supplier') returning id into v_sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 25) returning id into r.item;

  -- Ten on the shelf at 10 each.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-1', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (r.org, v_bill, 1, 'item', r.item, 'Barang', 10, 10, r.wh);
  perform public.post_purchase_document(v_bill);
  insert into t_ms select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.ms_quote(p_no text, p_qty numeric)
returns uuid language plpgsql as $$
declare d t_ms; v uuid;
begin
  select * into d from t_ms;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'quotation', p_no, pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, v, 1, 'item', d.item, 'Barang', p_qty, 25, d.wh);
  return v;
end $$;

-- On the shelf, and what the ledger holds for it.
create or replace function pg_temp.ms_on_hand() returns numeric language sql as $$
  select round(coalesce(sum(quantity), 0), 2) from public.stock_levels
   where item_id = (select item from t_ms);
$$;
create or replace function pg_temp.ms_1310() returns numeric language sql as $$
  select round(coalesce(sum(l.debit - l.credit), 0), 2)
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = (select org from t_ms) and a.code = '1310';
$$;

do $$
declare v_q uuid; v_do uuid; v_inv uuid; v_cn uuid;
begin
  perform pg_temp.check_eq('ten bought at 10 are on the shelf and in 1310',
    pg_temp.ms_on_hand() || ' / ' || pg_temp.ms_1310(), '10.00 / 100.00');

  -- Straight from the quotation: the path that always worked.
  v_q := pg_temp.ms_quote('SH-A', 3);
  v_inv := public.transfer_document(v_q, 'invoice');
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('three invoiced straight from a quotation leave the shelf and the ledger',
    pg_temp.ms_on_hand() || ' / ' || pg_temp.ms_1310(), '7.00 / 70.00');

  -- Through a delivery order.
  v_q := pg_temp.ms_quote('SH-B', 2);
  v_do := public.transfer_document(v_q, 'delivery_order');
  perform pg_temp.check_eq('a delivery order moves nothing itself',
    (select count(*) from public.stock_movements where source_id = v_do)::int, 0);
  v_inv := public.transfer_document(v_do, 'invoice');
  perform pg_temp.check_true('the invoice is the delivery order''s',
    (select parent_id from public.sales_documents where id = v_inv) = v_do);
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('two invoiced through a delivery order leave the shelf as well as the ledger',
    pg_temp.ms_on_hand() || ' / ' || pg_temp.ms_1310(), '5.00 / 50.00');

  -- And crediting it puts back only what left.
  v_cn := public.credit_sales_invoice(v_inv, null, 'Dipulangkan');
  perform pg_temp.check_eq('crediting it puts back the two that left, no more',
    pg_temp.ms_on_hand() || ' / ' || pg_temp.ms_1310(), '7.00 / 70.00');
end $$;

reset role;

rollback;

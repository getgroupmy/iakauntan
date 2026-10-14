-- =====================================================================
-- iAkauntan :: one road per order line (0903)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/one_road_per_order_line.sql
--
-- Before `0903`, measured rather than inferred: ten ordered at 25 and
-- received on a goods received note, then billed straight from the
-- order -- 20 on hand, 1310 at 500, and the 250 the note accrued in
-- 2118 never cleared. A note and a direct bill each receive the goods,
-- and the two were counted apart.
--
-- The split order here is four on a note and six billed straight from
-- the order, so that neither counter alone, nor the larger of the two,
-- gives the answer the sum does. As the owner with the role
-- `authenticated`, through `transfer_document`, as the app buys.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_or (org uuid, sup uuid, item uuid, wh uuid);
grant select on t_or to authenticated;

do $$
declare r t_or;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Satu Jalan Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Alat', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'ALAT', 'Alat ganti', 'stock', true, 'C62', 40) returning id into r.item;
  insert into t_or select r.*;
end $$;

set local role authenticated;

-- A purchase order for ten at 25.
create or replace function pg_temp.or_order(p_no text)
returns uuid language plpgsql as $$
declare d t_or; v uuid;
begin
  select * into d from t_or;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'purchase_order', p_no, pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, v, 1, 'item', d.item, 'Alat ganti', 10, 25, d.wh);
  return v;
end $$;

create or replace function pg_temp.or_line(p_doc uuid)
returns uuid language sql as $$
  select id from public.purchase_document_lines where document_id = p_doc and line_no = 1;
$$;

-- On the shelf, and what three accounts hold.
create or replace function pg_temp.or_state() returns text language sql as $$
  select (select round(coalesce(sum(quantity), 0), 2) from public.stock_levels
           where item_id = (select item from t_or))::text
    || ' / ' || string_agg(a.code || ' ' || (select round(coalesce(sum(l.debit - l.credit), 0), 2)
                                              from public.gl_lines l where l.account_id = a.id)::text,
                           ', ' order by a.code)
    from public.accounts a
   where a.org_id = (select org from t_or) and a.code in ('1310', '2110', '2118');
$$;

do $$
declare v_po uuid; v_grn uuid; v_bill uuid; r record;
begin
  -- -------------------------------------------------------------------
  -- Received on a note: billed from the note, not the order
  -- -------------------------------------------------------------------
  v_po := pg_temp.or_order('PO-A');
  v_grn := public.transfer_document(v_po, 'goods_received');
  perform public.post_goods_received(v_grn);
  perform pg_temp.check_refused('an order received on a note is not billed again from the order',
    format('select public.transfer_document(%L, %L)', v_po, 'bill'),
    'PO-A has been received on a goods received note. Bill it from the note, which clears what the note accrued.',
    '23514');
  select * into r from public.transfer_outstanding(v_po, 'bill');
  perform pg_temp.check_eq('and the dialog offers none of it to bill',
    r.taken || ' / ' || r.outstanding, '10.0000 / 0.0000');
  v_bill := public.transfer_document(v_grn, 'bill');
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('billed from the note, the ten arrive once and the accrual clears',
    pg_temp.or_state(), '10.00 / 1310 250.00, 2110 -250.00, 2118 0.00');

  -- -------------------------------------------------------------------
  -- Split: four on a note, the rest billed from the order
  -- -------------------------------------------------------------------
  v_po := pg_temp.or_order('PO-B');
  v_grn := public.transfer_document(v_po, 'goods_received',
    jsonb_build_array(jsonb_build_object('line_id', pg_temp.or_line(v_po), 'quantity', 4)));
  perform public.post_goods_received(v_grn);
  select * into r from public.transfer_outstanding(v_po, 'bill');
  perform pg_temp.check_eq('with four on a note, six are left to bill from the order',
    r.taken || ' / ' || r.outstanding, '4.0000 / 6.0000');
  perform pg_temp.check_refused('and no more than six',
    format('select public.transfer_document(%L, %L, %L::jsonb)', v_po, 'bill',
           jsonb_build_array(jsonb_build_object('line_id', pg_temp.or_line(v_po), 'quantity', 10))),
    'Line 1 has 6%outstanding; 10%was asked for.', '23514');
  v_bill := public.transfer_document(v_po, 'bill');
  perform pg_temp.check_eq('billing the order takes the six',
    (select quantity from public.purchase_document_lines where document_id = v_bill), 6::numeric);
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('and the order is done when the two together took it',
    (select fulfilment_status::text from public.purchase_documents where id = v_po), 'fulfilled');
  select * into r from public.transfer_outstanding(v_po, 'goods_received');
  perform pg_temp.check_eq('so nothing is left to receive on a note either',
    r.outstanding, 0::numeric);
  v_bill := public.transfer_document(v_grn, 'bill');
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('the ten arrive once, and the books close on the same figures as the note',
    pg_temp.or_state(), '20.00 / 1310 500.00, 2110 -500.00, 2118 0.00');

  -- -------------------------------------------------------------------
  -- Billed from the order first: no note after it
  -- -------------------------------------------------------------------
  v_po := pg_temp.or_order('PO-C');
  v_bill := public.transfer_document(v_po, 'bill');
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_refused('an order billed straight through is not received again on a note',
    format('select public.transfer_document(%L, %L)', v_po, 'goods_received'),
    'PO-C has been billed straight from the order, and that bill received the goods.',
    '23514');
  perform pg_temp.check_eq('the bill received its ten',
    pg_temp.or_state(), '30.00 / 1310 750.00, 2110 -750.00, 2118 0.00');
end $$;

reset role;

rollback;

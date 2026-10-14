-- =====================================================================
-- iAkauntan :: what was taken forward is the database's (0904)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/what_was_taken_forward.sql
--
-- The counters on document lines and `fulfilment_status` on the header
-- are kept by the refresh functions from the documents raised from each
-- line, and they cap what `transfer_document` will take forward. Before
-- `0904` a client could zero them and take the same quantity forward
-- again. As the owner with the role `authenticated`, as the app writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tf (org uuid, sup uuid, cust uuid, item uuid, wh uuid);
grant select on t_tf to authenticated;

do $$
declare r t_tf;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Dibawa Ke Depan Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Tetap', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Tetap', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 40) returning id into r.item;
  insert into t_tf select r.*;
end $$;

set local role authenticated;

do $$
declare d t_tf; v_po uuid; v_grn uuid; v_q uuid; v_inv uuid; v_doc uuid;
begin
  select * into d from t_tf;

  -- -------------------------------------------------------------------
  -- An order received in full on a note
  -- -------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'purchase_order', 'PO-TF', pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, v_po, 1, 'item', d.item, 'Barang', 10, 25, d.wh);
  v_grn := public.transfer_document(v_po, 'goods_received');
  perform public.post_goods_received(v_grn);

  perform pg_temp.check_refused('what an order has received is not reset by hand',
    format('update public.purchase_document_lines set quantity_received = 0 where document_id = %L', v_po),
    'quantity_received is kept by the database from the documents raised from this one%', '42501');
  perform pg_temp.check_refused('nor what it has billed',
    format('update public.purchase_document_lines set quantity_billed = 3 where document_id = %L', v_po),
    'quantity_billed is kept by the database%', '42501');
  perform pg_temp.check_refused('nor is the order marked open again',
    format('update public.purchase_documents set fulfilment_status = %L where id = %L', 'pending', v_po),
    'fulfilment_status is kept by the database%', '42501');
  perform pg_temp.check_refused('so it is still not billed again from the order',
    format('select public.transfer_document(%L, %L)', v_po, 'bill'),
    'PO-TF has been received on a goods received note.%', '23514');

  -- Writing the rest of the line is still writing the line.
  update public.purchase_document_lines set description = 'Barang ganti'
   where document_id = v_po;
  perform pg_temp.check_eq('the rest of a counted line is still written',
    (select description || ' / ' || quantity_received::text
       from public.purchase_document_lines where document_id = v_po),
    'Barang ganti / 10.0000');

  -- -------------------------------------------------------------------
  -- Nor does a line or a document start out already counted
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a line does not arrive with room made on it',
    format('insert into public.purchase_document_lines
              (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, quantity_billed)
            values (%L, %L, 2, %L, %L, %L, 5, 25, -5)', d.org, v_po, 'item', d.item, 'Barang'),
    'quantity_billed is kept by the database%', '42501');
  perform pg_temp.check_refused('nor a document already fulfilled',
    format('insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, fulfilment_status)
            values (%L, %L, %L, %L, %L, %L, 1, %L, %L)',
           d.org, 'quotation', 'QT-SIAP', pg_temp.today(), d.cust, 'MYR', 'draft', 'fulfilled'),
    'fulfilment_status is kept by the database%', '42501');
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, fulfilment_status)
  values (d.org, 'quotation', 'QT-TF', pg_temp.today(), d.cust, 'MYR', 1, 'draft', 'pending')
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price,
     warehouse_id, quantity_invoiced, quantity_fulfilled)
  values (d.org, v_q, 1, 'item', d.item, 'Barang', 3, 40, d.wh, 0, 0);
  perform pg_temp.check_eq('a line and a document that start where the database would are written',
    (select count(*) from public.sales_document_lines where document_id = v_q)::int, 1);

  -- -------------------------------------------------------------------
  -- A quotation invoiced: counted, and released only by the invoice
  -- -------------------------------------------------------------------
  v_inv := public.transfer_document(v_q, 'invoice');
  perform pg_temp.check_refused('what a quotation has invoiced is not reset by hand',
    format('update public.sales_document_lines set quantity_invoiced = 0 where document_id = %L', v_q),
    'quantity_invoiced is kept by the database%', '42501');
  perform pg_temp.check_refused('nor what it has delivered',
    format('update public.sales_document_lines set quantity_fulfilled = 3 where document_id = %L', v_q),
    'quantity_fulfilled is kept by the database%', '42501');
  perform pg_temp.check_refused('nor is it marked cancelled out of the database''s hands',
    format('update public.sales_documents set fulfilment_status = %L where id = %L', 'cancelled', v_q),
    'fulfilment_status is kept by the database%', '42501');

  delete from public.sales_document_lines where document_id = v_inv;
  perform pg_temp.check_eq('taking the invoice''s lines away gives the quantity back',
    (select l.quantity_invoiced::text || ' / ' || d2.fulfilment_status
       from public.sales_document_lines l join public.sales_documents d2 on d2.id = l.document_id
      where l.document_id = v_q), '0.0000 / pending');
end $$;

-- The database's own hand still writes them: the refresh functions and
-- every copy path run as the owner.
reset role;
update public.sales_document_lines set quantity_fulfilled = 2
 where document_id = (select id from public.sales_documents where doc_no = 'QT-TF');
select pg_temp.check_eq('the owner still writes what was taken forward',
  (select quantity_fulfilled from public.sales_document_lines
    where document_id = (select id from public.sales_documents where doc_no = 'QT-TF')),
  2::numeric);

rollback;

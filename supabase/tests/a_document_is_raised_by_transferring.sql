-- =====================================================================
-- iAkauntan :: a document is raised from another by transferring (0911)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_document_is_raised_by_transferring.sql
--
-- A bill raised from a goods received note clears what the note accrued
-- and moves no stock; posting decides that from the bill's `parent_id`.
-- Before `0911` a client could cut a bill from its note with one UPDATE,
-- and posting it received the goods a second time: 20 on hand for 10
-- bought, 1310 RM500 for RM250, and the note's accrual never cleared.
-- As the owner with the role `authenticated`, as the app writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_rt (org uuid, sup uuid, cust uuid, item uuid, wh uuid);
grant select on t_rt to authenticated;

do $$
declare r t_rt;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Induk Tetap Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Induk', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Induk', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 40) returning id into r.item;
  insert into t_rt select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.rt_gl(p_org uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id;
$$;

do $$
declare d t_rt; v_po uuid; v_grn uuid; v_bill uuid; v_q uuid;
begin
  select * into d from t_rt;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'purchase_order', 'PO-INDUK', pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, v_po, 1, 'item', d.item, 'Barang', 10, 25, d.wh);
  v_grn := public.transfer_document(v_po, 'goods_received');
  perform public.post_goods_received(v_grn);
  v_bill := public.transfer_document(v_grn, 'bill');
  perform pg_temp.check_true('the bill is raised from the note',
    (select parent_id = v_grn from public.purchase_documents where id = v_bill));

  -- -------------------------------------------------------------------
  -- What a document was raised from is not changed by hand
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a bill is not cut from its note',
    format('update public.purchase_documents set parent_id = null where id = %L', v_bill),
    'What % was raised from is set when it is transferred or credited, and is not changed by hand (% -> null). How it posts depends on it%',
    '42501');
  perform pg_temp.check_refused('nor pointed at the order instead',
    format('update public.purchase_documents set parent_id = %L where id = %L', v_po, v_bill),
    'What % was raised from is set when it is transferred or credited%', '42501');

  -- -------------------------------------------------------------------
  -- Nor does a document arrive naming one
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a bill does not arrive naming somebody''s note',
    format('insert into public.purchase_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, parent_id)
            values (%L, %L, %L, %L, %L, %L, 1, %L, %L)',
           d.org, 'bill', 'BIL-PINJAM', pg_temp.today(), d.sup, 'MYR', 'draft', v_grn),
    'A document is raised from another by transferring or crediting it, and does not arrive naming one (BIL-PINJAM named %',
    '42501');
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'quotation', 'QT-INDUK', pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_q;
  perform pg_temp.check_refused('nor an invoice naming a quotation',
    format('insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status, parent_id)
            values (%L, %L, %L, %L, %L, %L, 1, %L, %L)',
           d.org, 'invoice', 'INV-PINJAM', pg_temp.today(), d.cust, 'MYR', 'draft', v_q),
    'A document is raised from another by transferring or crediting it, and does not arrive naming one (INV-PINJAM named %',
    '42501');

  -- -------------------------------------------------------------------
  -- So the bill posts as what it is
  -- -------------------------------------------------------------------
  update public.purchase_documents set notes = 'Invois pembekal 4471' where id = v_bill;
  perform pg_temp.check_eq('the rest of the bill is still written',
    (select notes from public.purchase_documents where id = v_bill), 'Invois pembekal 4471');
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('posted from its note, it receives nothing again',
    (select sum(quantity) from public.stock_movements where item_id = d.item), 10.0000::numeric);
  perform pg_temp.check_eq('and clears what the note accrued',
    pg_temp.rt_gl(d.org), '1310 250.00, 2110 -250.00');
end $$;

-- The transfer and the credit functions run as the owner and set it.
reset role;
update public.purchase_documents set parent_id = null
 where doc_no = 'BIL-PINJAM' or (org_id = (select org from t_rt) and doc_type = 'bill');
select pg_temp.check_eq('the owner still writes it',
  (select count(*)::int from public.purchase_documents
    where org_id = (select org from t_rt) and doc_type = 'bill' and parent_id is null), 1);

rollback;

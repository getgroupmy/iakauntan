-- =====================================================================
-- iAkauntan :: a line carries forward a line of its parent (0913)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_line_carries_its_parents_line.sql
--
-- The progress counters, and so what `transfer_document` still lets go
-- forward, are counted from the lines that name a line. Before `0913` a
-- bill typed by hand, its line naming a posted note's line, marked the
-- note fully billed and refused its billing, and then received the
-- goods a second time itself. As the owner with the role
-- `authenticated`, as the app writes -- including the app's own save,
-- which deletes a draft's lines and inserts them again.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_lp (org uuid, sup uuid, cust uuid, item uuid, wh uuid,
                             po uuid, po_line uuid, grn uuid, grn_line uuid,
                             typed uuid, typed_line uuid);
grant select, update on t_lp to authenticated;

do $$
declare r t_lp;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Pautan Induk Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Pautan', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Pautan', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 40) returning id into r.item;
  insert into t_lp select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.lp_gl(p_org uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id;
$$;

do $$
declare d t_lp; v_bill uuid; v_rows jsonb; v_q uuid; v_q_line uuid; v_inv uuid; v_count int;
begin
  select * into d from t_lp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'purchase_order', 'PO-PAUTAN', pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into d.po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, d.po, 1, 'item', d.item, 'Barang', 10, 25, d.wh)
  returning id into d.po_line;
  d.grn := public.transfer_document(d.po, 'goods_received');
  perform public.post_goods_received(d.grn);
  select id into d.grn_line from public.purchase_document_lines where document_id = d.grn;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-TAIP', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into d.typed;

  -- -------------------------------------------------------------------
  -- A document typed by hand carries nothing forward
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a typed bill''s line does not name the note''s line',
    format('insert into public.purchase_document_lines
              (org_id, document_id, line_no, line_type, item_id, description, quantity,
               unit_price, warehouse_id, source_line_id)
            values (%L, %L, 1, %L, %L, %L, 10, 25, %L, %L)',
           d.org, d.typed, 'item', d.item, 'Barang', d.wh, d.grn_line),
    'BIL-TAIP was not raised from another document, so none of its lines carries one forward (this one named a line of GRN-%',
    '42501');

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id)
  values (d.org, d.typed, 1, 'item', d.item, 'Barang', 10, 25, d.wh)
  returning id into d.typed_line;
  perform pg_temp.check_refused('nor is a typed line pointed at it afterwards',
    format('update public.purchase_document_lines set source_line_id = %L where id = %L',
           d.grn_line, d.typed_line),
    'BIL-TAIP was not raised from another document%', '42501');

  perform pg_temp.check_eq('so the note is still unbilled',
    (select quantity_billed from public.purchase_document_lines where id = d.grn_line),
    0.0000::numeric);

  -- -------------------------------------------------------------------
  -- A document raised from another carries forward its lines, and only
  -- its lines
  -- -------------------------------------------------------------------
  v_bill := public.transfer_document(d.grn, 'bill');
  perform pg_temp.check_true('the note is billed by transferring it',
    (select source_line_id = d.grn_line from public.purchase_document_lines where document_id = v_bill));

  -- Saved as the app saves a draft: every line deleted and inserted
  -- again, each with the link it was loaded with.
  select jsonb_agg(to_jsonb(l)) into v_rows
    from public.purchase_document_lines l where l.document_id = v_bill;
  delete from public.purchase_document_lines where document_id = v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity,
     unit_price, warehouse_id, source_line_id)
  select d.org, v_bill, (r ->> 'line_no')::int, 'item', (r ->> 'item_id')::uuid,
         r ->> 'description', (r ->> 'quantity')::numeric, (r ->> 'unit_price')::numeric,
         (r ->> 'warehouse_id')::uuid, (r ->> 'source_line_id')::uuid
    from jsonb_array_elements(v_rows) r;
  perform pg_temp.check_eq('re-saved, the bill keeps its link to the note',
    (select count(*)::int from public.purchase_document_lines
      where document_id = v_bill and source_line_id = d.grn_line), 1);

  -- A charge of its own, linked to nothing, is still a line it may have.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, account_id)
  values (d.org, v_bill, 2, 'item', 'Penghantaran', 1, 0,
          (select id from public.accounts where org_id = d.org and code = '5100'));
  perform pg_temp.check_eq('and a line of its own beside it',
    (select count(*)::int from public.purchase_document_lines where document_id = v_bill), 2);

  perform pg_temp.check_refused('but not a line carrying forward the order the note came from',
    format('insert into public.purchase_document_lines
              (org_id, document_id, line_no, line_type, item_id, description, quantity,
               unit_price, warehouse_id, source_line_id)
            values (%L, %L, 3, %L, %L, %L, 10, 25, %L, %L)',
           d.org, v_bill, 'item', d.item, 'Barang', d.wh, d.po_line),
    'BILL-% was raised from GRN-%, so a line of it carries forward a line of GRN-% and of nothing else (this one named a line of PO-PAUTAN)%',
    '42501');
  perform pg_temp.check_refused('nor is its linked line moved onto the typed bill',
    -- A line number of its own on the typed bill, so that nothing but
    -- the link can refuse the move.
    format('update public.purchase_document_lines set document_id = %L, line_no = 9
             where document_id = %L and source_line_id is not null', d.typed, v_bill),
    'BIL-TAIP was not raised from another document%', '42501');

  -- So the bill posts as what it is: the note's goods, billed once.
  delete from public.purchase_document_lines where document_id = d.typed;
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('posted, the bill moves no stock the note moved',
    (select sum(quantity) from public.stock_movements where item_id = d.item), 10.0000::numeric);
  perform pg_temp.check_eq('and clears what the note accrued',
    pg_temp.lp_gl(d.org), '1310 250.00, 2110 -250.00');

  -- -------------------------------------------------------------------
  -- The same on the sales side
  -- -------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'quotation', 'QT-PAUTAN', pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate)
  values (d.org, v_q, 1, 'item', 'Khidmat', 5, 100, 0) returning id into v_q_line;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-TAIP', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  perform pg_temp.check_refused('a typed invoice does not mark a quotation invoiced',
    format('insert into public.sales_document_lines
              (org_id, document_id, line_no, line_type, description, quantity, unit_price,
               tax_rate, source_line_id)
            values (%L, %L, 1, %L, %L, 1, 1, 0, %L)', d.org, v_inv, 'item', 'Lain', v_q_line),
    'INV-TAIP was not raised from another document, so none of its lines carries one forward (this one named a line of QT-PAUTAN)%',
    '42501');
  perform pg_temp.check_eq('so the quotation is still waiting',
    (select fulfilment_status from public.sales_documents where id = v_q), 'pending');

  v_inv := public.transfer_document(v_q, 'invoice');
  select jsonb_agg(to_jsonb(l)) into v_rows
    from public.sales_document_lines l where l.document_id = v_inv;
  delete from public.sales_document_lines where document_id = v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate,
     source_line_id)
  select d.org, v_inv, (r ->> 'line_no')::int, 'item', r ->> 'description',
         (r ->> 'quantity')::numeric, (r ->> 'unit_price')::numeric, 0,
         (r ->> 'source_line_id')::uuid
    from jsonb_array_elements(v_rows) r;
  get diagnostics v_count = row_count;
  perform pg_temp.check_eq('an invoice raised from the quotation is re-saved with its link',
    (select count(*)::int from public.sales_document_lines
      where document_id = v_inv and source_line_id = v_q_line), v_count);
  perform pg_temp.check_eq('and the quotation counts it',
    (select quantity_invoiced from public.sales_document_lines where id = v_q_line), 5.0000::numeric);

  update t_lp set po = d.po, po_line = d.po_line, typed = d.typed;
end $$;

-- What runs as the owner -- the transfer, the demo seeders -- is not
-- asked.
reset role;
insert into public.purchase_document_lines
  (org_id, document_id, line_no, line_type, description, quantity, unit_price, source_line_id)
select org, typed, 1, 'item', 'Pautan pemilik', 1, 1, po_line from t_lp;
select pg_temp.check_eq('the owner still links a line by hand',
  (select count(*)::int from public.purchase_document_lines l join t_lp t on l.document_id = t.typed
    where l.source_line_id = t.po_line), 1);

rollback;

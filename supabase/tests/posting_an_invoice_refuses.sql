-- =====================================================================
-- iAkauntan :: what posting a sales document refuses, and what it
-- leaves alone
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posting_an_invoice_refuses.sql
--
-- `app.post_sales_document_internal` is the largest posting function in
-- the system and the best covered: sweeping it killed twenty of
-- twenty-five mutants outright. Every figure it computes -- the
-- receivable, the revenue, the deferral, the tax, the rounding, the
-- service charge, the shipping, the cost of sales in the item's own
-- unit, the stock movement in the item's own unit, both directions for
-- a credit note -- is already asserted somewhere in the suite.
--
-- These are the five that were not. Four of them are the same shape as
-- everywhere else in this project: the arithmetic is nailed down and
-- the conditions around it are open.
--
--   * a quotation posted to the ledger
--   * the same invoice posted twice
--   * cost of sales taken for an item that carries no stock
--   * a header discount that never reached 4300
--   * stock moved a second time for an invoice a delivery order had
--     already delivered
--
-- The double-post case is asserted here but its mutant SURVIVES, and
-- that is recorded rather than worked around, because the guard is
-- genuinely redundant rather than untested.
--
-- `app.refuse_posted_document_change` -- the `refuse_posted_change`
-- trigger on `sales_documents` -- raises the SAME wording, "is already
-- posted", and it fires on exactly the same condition: it reads
-- `OLD.gl_entry_id` and returns early when that is null, which is the
-- function's own `if v_doc.gl_entry_id is not null`. So neither the
-- SQLSTATE nor the message can tell the two apart.
--
-- Every route was tried before concluding that. With the function's
-- check disabled the call still refuses, from the trigger, on the
-- closing UPDATE; the second journal it built along the way never
-- survives, because the whole statement rolls back -- asserted below as
-- "one journal for it, not two", which passes either way. There is no
-- input reaching the function's check that does not also reach the
-- trigger's, including a document inserted with `gl_entry_id` already
-- set and a status of draft: the trigger reads the column, not the
-- status.
--
-- The assertion is kept because it pins the behaviour a caller sees. It
-- does not prove the function's own line is load-bearing, and nothing
-- short of dropping the trigger would.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_cust   uuid; v_wh uuid;
  v_barang uuid; v_servis uuid;
  v_quote  uuid; v_inv uuid; v_inv2 uuid; v_disc uuid;
  v_do     uuid; v_inv_do uuid;
  v_entry  uuid;
  v_msg    text;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Jual Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Puan Aminah', 'customer') returning id into v_cust;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The store', true) returning id into v_wh;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'BARANG', 'Widget', 'stock', true, 'C62', 50, 20)
  returning id into v_barang;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
     quantity, unit_cost)
  values (v_org, 'JS-0001', current_date, 'opening_balance', v_barang, v_wh, 100, 20);

  -- A service, with an average cost written on it. A service never has
  -- one in practice; it is here because the guard being tested is
  -- `track_inventory`, and a guard that reads a column which is always
  -- zero cannot be observed. 0270's arithmetic would take four times
  -- twenty-five off the books as cost of sales.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SERVIS', 'Installation', 'service', false, 'C62', 300)
  returning id into v_servis;
  update public.items set average_cost = 25 where id = v_servis;

  -- ------------------------------------------------------------------
  -- 1. A quotation is not a posting document
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'quotation', 'QT-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_quote, 1, 'item', v_barang, 'Widgets', 2, 50, v_wh);

  begin
    perform public.post_sales_document(v_quote);
    raise exception 'FAIL posted a quotation to the ledger';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a quotation does not reach the ledger',
      v_msg like '%does not post to the ledger%');
  end;
  perform pg_temp.check_eq('and it wrote no journal',
    (select count(*)::integer from public.gl_entries
      where source_table = 'sales_documents' and source_id = v_quote), 0);

  -- ------------------------------------------------------------------
  -- 2. Posted once, and only once
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_barang, 'Widgets', 2, 50, v_wh);
  v_entry := public.post_sales_document(v_inv);

  begin
    perform public.post_sales_document(v_inv);
    raise exception 'FAIL posted the same invoice twice';
  exception when others then
    -- Pins what a caller sees. See the header: the trigger raises the
    -- same words on the same condition, so this cannot attribute the
    -- refusal to the function's own check.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an invoice is posted once',
      v_msg like '%is already posted%');
  end;
  perform pg_temp.check_eq('so there is one journal for it, not two',
    (select count(*)::integer from public.gl_entries
      where source_table = 'sales_documents' and source_id = v_inv), 1);

  -- ------------------------------------------------------------------
  -- 3. A service carries no stock, so it carries no cost of sales
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv2, 1, 'item', v_servis, 'Installation', 4, 300);
  v_entry := public.post_sales_document(v_inv2);

  perform pg_temp.check_eq('installing something costs no inventory',
    (select coalesce(sum(gl.debit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '5200'), 0::numeric);
  perform pg_temp.check_eq('and takes nothing off the shelf',
    (select count(*)::integer from public.stock_movements
      where source_table = 'sales_documents' and source_id = v_inv2), 0);

  -- ------------------------------------------------------------------
  -- 4. A discount taken on the header still reaches the ledger
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, discount_amount)
  values (v_org, 'invoice', 'INV-3', current_date, current_date, v_cust,
          'MYR', 1, 'draft', 100)
  returning id into v_disc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_disc, 1, 'item', v_barang, 'Widgets', 20, 50, v_wh);
  v_entry := public.post_sales_document(v_disc);

  perform pg_temp.check_eq('the hundred taken off is charged to 4300',
    (select coalesce(sum(gl.debit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '4300'), 100::numeric);
  perform pg_temp.check_eq('and the customer is billed the net',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '1210'), 900::numeric);

  -- ------------------------------------------------------------------
  -- 5. Goods a delivery order already sent do not leave twice
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'delivery_order', 'DO-1', current_date, current_date,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_do;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, parent_id)
  values (v_org, 'invoice', 'INV-DO', current_date, current_date, v_cust,
          'MYR', 1, 'draft', v_do)
  returning id into v_inv_do;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (v_org, v_inv_do, 1, 'item', v_barang, 'Widgets', 5, 50, v_wh);
  perform public.post_sales_document(v_inv_do);

  perform pg_temp.check_eq(
    'an invoice behind a delivery order moves no stock of its own',
    (select count(*)::integer from public.stock_movements
      where source_table = 'sales_documents' and source_id = v_inv_do), 0);
  -- And the ordinary invoice above did, so the assertion above is not
  -- passing because nothing ever moves.
  perform pg_temp.check_eq('while an invoice standing alone does',
    (select count(*)::integer from public.stock_movements
      where source_table = 'sales_documents' and source_id = v_inv), 1);

  perform pg_temp.sign_out();
end $$;

rollback;

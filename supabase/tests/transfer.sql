-- =====================================================================
-- iAkauntan :: document transfer tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transfer.sql
--
-- A transfer that takes too much, or that forgets what it took, produces
-- a document set that balances perfectly and ships the goods twice. None
-- of the other suites would notice: the ledger is not involved until the
-- invoice posts, and by then the delivery order has already gone out.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A customer and one quotation for ten widgets at RM 100, with a
-- RM 50 discount on the line, used by most of what follows.
create or replace function pg_temp.quote_for(p_org uuid, p_qty numeric default 10)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-' || substr(gen_random_uuid()::text, 1, 8), 'Widget Buyer', 'customer')
  returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (p_org, 'quotation', 'QT-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, discount_amount)
  values (p_org, v_doc, 1, 'Widget', p_qty, 100, 50);

  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- The whole document, forward one step
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Transfer Test Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_order uuid;
  v_line public.sales_document_lines;
begin
  v_order := public.transfer_document(v_quote, 'sales_order');

  perform pg_temp.check_true('the order knows where it came from',
    (select parent_id from public.sales_documents where id = v_order) = v_quote);

  select * into v_line from public.sales_document_lines where document_id = v_order;

  perform pg_temp.check_eq('quantity carried', v_line.quantity, 10);
  perform pg_temp.check_eq('price carried', v_line.unit_price, 100);
  perform pg_temp.check_eq('discount carried whole on a full transfer',
    v_line.discount_amount, 50);
  perform pg_temp.check_true('and it remembers the line it came from',
    v_line.source_line_id is not null);

  perform pg_temp.check_eq('the quotation is spent',
    (select quantity_fulfilled from public.sales_document_lines
      where document_id = v_quote), 10);
  perform pg_temp.check_true('and says so on the header',
    (select fulfilment_status from public.sales_documents where id = v_quote)
      = 'fulfilled');

  -- Nothing is left, so a second transfer has nothing to make a document
  -- out of and must say so rather than producing an empty one.
  begin
    perform public.transfer_document(v_quote, 'sales_order');
    raise exception 'FAIL: a spent quotation was transferred twice';
  exception when sqlstate '23514' then
    raise notice 'ok   a spent document cannot be transferred again';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Part of it, twice
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Partial Transfer Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  v_first uuid;
  v_second uuid;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;

  v_first := public.transfer_document(v_quote, 'delivery_order',
    jsonb_build_array(jsonb_build_object('line_id', v_src, 'quantity', 4)));

  perform pg_temp.check_eq('four delivered',
    (select quantity from public.sales_document_lines where document_id = v_first), 4);
  perform pg_temp.check_eq('four counted against the quotation',
    (select quantity_fulfilled from public.sales_document_lines where id = v_src), 4);
  perform pg_temp.check_true('which is partial, not done',
    (select fulfilment_status from public.sales_documents where id = v_quote)
      = 'partial');

  -- The discount follows the quantity. Carrying RM 50 onto a delivery of
  -- four out of ten would discount the customer twice over the two
  -- documents.
  perform pg_temp.check_eq('discount apportioned',
    (select discount_amount from public.sales_document_lines
      where document_id = v_first), 20);

  -- Six left, and asking for seven is refused rather than clamped: a
  -- clamp would deliver six, report success, and the difference would
  -- surface when the customer counted the boxes.
  begin
    perform public.transfer_document(v_quote, 'delivery_order',
      jsonb_build_array(jsonb_build_object('line_id', v_src, 'quantity', 7)));
    raise exception 'FAIL: more was transferred than remained';
  exception when sqlstate '23514' then
    raise notice 'ok   asking for more than remains is refused';
  end;

  v_second := public.transfer_document(v_quote, 'delivery_order');

  perform pg_temp.check_eq('the rest goes with no quantities named',
    (select quantity from public.sales_document_lines where document_id = v_second), 6);
  perform pg_temp.check_eq('and the quotation is spent',
    (select quantity_fulfilled from public.sales_document_lines where id = v_src), 10);
  perform pg_temp.check_true('and reads as fulfilled',
    (select fulfilment_status from public.sales_documents where id = v_quote)
      = 'fulfilled');
end $$;

-- ---------------------------------------------------------------------
-- Deleting what was transferred gives the quantity back
--
-- The property the whole design rests on. Counters are recomputed from
-- the children rather than added to at transfer time, so a delivery
-- order that is thrown away releases its quantity with no correction
-- step. Accumulating would leave the order claiming goods had gone out
-- when the document saying so no longer exists.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Release Test Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  v_do uuid;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;
  v_do := public.transfer_document(v_quote, 'delivery_order');

  perform pg_temp.check_eq('taken', (select quantity_fulfilled
    from public.sales_document_lines where id = v_src), 10);

  delete from public.sales_document_lines where document_id = v_do;

  perform pg_temp.check_eq('and given back when the delivery order goes',
    (select quantity_fulfilled from public.sales_document_lines where id = v_src), 0);
  perform pg_temp.check_true('the quotation is open again',
    (select fulfilment_status from public.sales_documents where id = v_quote)
      = 'pending');
end $$;

-- ---------------------------------------------------------------------
-- Voiding has the same effect, without deleting anything
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Void Release Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  v_do uuid;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;
  v_do := public.transfer_document(v_quote, 'delivery_order');

  -- Nothing on the line changes here, which is the point: only the
  -- header moves, so the release has to be driven from the header.
  update public.sales_documents set status = 'void' where id = v_do;

  perform pg_temp.check_eq('a voided delivery order holds nothing',
    (select quantity_fulfilled from public.sales_document_lines where id = v_src), 0);
end $$;

-- ---------------------------------------------------------------------
-- Delivering and invoicing are counted separately
--
-- A delivery order that has been invoiced has not stopped being
-- deliverable against its own order. If one counter bounded the other,
-- an order delivered in full could never be invoiced.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Two Counters Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  v_order uuid;
  v_order_line uuid;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;
  v_order := public.transfer_document(v_quote, 'sales_order');
  select id into v_order_line from public.sales_document_lines
   where document_id = v_order;

  perform public.transfer_document(v_order, 'delivery_order');
  perform public.transfer_document(v_order, 'invoice');

  perform pg_temp.check_eq('delivered in full',
    (select quantity_fulfilled from public.sales_document_lines
      where id = v_order_line), 10);
  perform pg_temp.check_eq('and invoiced in full',
    (select quantity_invoiced from public.sales_document_lines
      where id = v_order_line), 10);
end $$;

-- ---------------------------------------------------------------------
-- Only the transitions that exist
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Rules Test Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
begin
  begin
    perform public.transfer_document(v_quote, 'credit_note');
    raise exception 'FAIL: a quotation became a credit note';
  exception when sqlstate '23514' then
    raise notice 'ok   a quotation cannot become a credit note';
  end;

  begin
    perform public.transfer_document(v_quote, 'bill');
    raise exception 'FAIL: a sales document crossed into the purchase cycle';
  exception when sqlstate '23514' then
    raise notice 'ok   the two cycles do not cross';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The purchase side, and the currency it was ordered in
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Purchase Chain Sdn Bhd');
  v_supp uuid;
  v_po uuid;
  v_po_line uuid;
  v_grn uuid;
  v_bill uuid;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.70, current_date, 'manual');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Overseas Supplier', 'supplier') returning id into v_supp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-001', current_date, v_supp, 'USD', 4.70, 'draft')
  returning id into v_po;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_po, 1, 'Imported part', 20, 25)
  returning id into v_po_line;

  v_grn := public.transfer_document(v_po, 'goods_received',
    jsonb_build_array(jsonb_build_object('line_id', v_po_line, 'quantity', 12)));

  perform pg_temp.check_eq('twelve received',
    (select quantity_received from public.purchase_document_lines
      where id = v_po_line), 12);
  perform pg_temp.check_eq('and nothing billed yet',
    (select quantity_billed from public.purchase_document_lines
      where id = v_po_line), 0);

  -- The currency the order was placed in, and the rate it was placed at,
  -- follow the goods. A goods received note that quietly reverts to
  -- ringgit would receive USD 300 of parts as RM 300.
  perform pg_temp.check_true('currency carried',
    (select currency from public.purchase_documents where id = v_grn) = 'USD');
  perform pg_temp.check_eq('rate carried',
    (select exchange_rate from public.purchase_documents where id = v_grn), 4.70);

  v_bill := public.transfer_document(v_grn, 'bill');

  perform pg_temp.check_eq('the bill takes what was received',
    (select quantity from public.purchase_document_lines where document_id = v_bill), 12);
  perform pg_temp.check_true('and the note is done',
    (select fulfilment_status from public.purchase_documents where id = v_grn)
      = 'fulfilled');
  perform pg_temp.check_true('while the order still has eight to come',
    (select fulfilment_status from public.purchase_documents where id = v_po)
      = 'partial');

  perform pg_temp.check_eq('the bill totals what it took',
    (select total_amount from public.purchase_documents where id = v_bill), 300);
end $$;

-- ---------------------------------------------------------------------
-- What the dialog reads before it offers anything
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Outstanding Test Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  r record;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;
  perform public.transfer_document(v_quote, 'delivery_order',
    jsonb_build_array(jsonb_build_object('line_id', v_src, 'quantity', 3)));

  select * into r from public.transfer_outstanding(v_quote, 'delivery_order');
  perform pg_temp.check_eq('taken reported', r.taken, 3);
  perform pg_temp.check_eq('outstanding reported', r.outstanding, 7);

  -- The same line, asked about as an invoice, has had nothing invoiced.
  select * into r from public.transfer_outstanding(v_quote, 'invoice');
  perform pg_temp.check_eq('and invoicing is a separate question',
    r.outstanding, 10);
end $$;

-- ---------------------------------------------------------------------
-- A transferred line cannot be re-keyed underneath its children
--
-- `saveDocument` deletes and re-inserts a document's lines so the totals
-- triggers recompute. On a transferred document that would hand the
-- children new parents — that is, none — and the quotation already
-- turned into an order would read as untouched and could be ordered
-- again. 0082 refuses the delete; the editor is closed so nobody meets
-- the error, and the error is here so nobody can route around the
-- editor.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Chain Lock Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_src uuid;
  v_do uuid;
begin
  select id into v_src from public.sales_document_lines where document_id = v_quote;
  v_do := public.transfer_document(v_quote, 'delivery_order');

  begin
    delete from public.sales_document_lines where id = v_src;
    raise exception 'FAIL: a transferred line was deleted';
  exception when sqlstate '23514' then
    raise notice 'ok   a transferred line cannot be deleted';
  end;

  -- Voiding the child first is the way out, and then it can go.
  update public.sales_documents set status = 'void' where id = v_do;
  delete from public.sales_document_lines where id = v_src;
  raise notice 'ok   and can once the document built from it is void';
end $$;

-- ---------------------------------------------------------------------
-- The service period goes forward with the line
--
-- 0309 defers a line that carries `service_start` and `service_end`: it
-- credits deferred revenue and releases it month by month. The period is
-- usually agreed at the quotation and only becomes money at the invoice,
-- so a transfer that drops it turns a twelve-month contract into income
-- earned on the day — silently, with no error and a line that still
-- looks right. 0311 carries it; this is what says so.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Deferred Transfer Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_order uuid;
  v_inv   uuid;
  v_line  public.sales_document_lines;
begin
  update public.sales_document_lines
     set service_start = date '2026-01-01',
         service_end   = date '2026-12-31'
   where document_id = v_quote;

  v_order := public.transfer_document(v_quote, 'sales_order');
  select * into v_line
    from public.sales_document_lines where document_id = v_order;

  perform pg_temp.check_eq('the period reaches the order start',
    v_line.service_start::text, '2026-01-01');
  perform pg_temp.check_eq('and the order end',
    v_line.service_end::text, '2026-12-31');

  -- Two steps, because the period has to survive the whole cycle and
  -- not just the first hop. The invoice is the document that defers.
  v_inv := public.transfer_document(v_order, 'invoice');
  select * into v_line
    from public.sales_document_lines where document_id = v_inv;

  perform pg_temp.check_eq('and the invoice start',
    v_line.service_start::text, '2026-01-01');
  perform pg_temp.check_eq('and the invoice end',
    v_line.service_end::text, '2026-12-31');
end $$;

-- A line with no period must arrive with no period. Carrying the
-- columns must not invent a value for the lines — almost all of them —
-- that are earned on the day they are invoiced.
do $$
declare
  v_org   uuid := pg_temp.test_org('Undeferred Transfer Sdn Bhd');
  v_quote uuid := pg_temp.quote_for(v_org);
  v_order uuid;
  v_line  public.sales_document_lines;
begin
  v_order := public.transfer_document(v_quote, 'sales_order');
  select * into v_line
    from public.sales_document_lines where document_id = v_order;

  perform pg_temp.check_true('a line with no period keeps none',
    v_line.service_start is null and v_line.service_end is null);
end $$;

-- ---------------------------------------------------------------------
-- Neither function is reachable without a key, and the definer helpers
-- are not reachable at all
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('transfer is closed to anon',
    not has_function_privilege('anon',
      'public.transfer_document(uuid, text, jsonb)', 'execute'));
  perform pg_temp.check_true('and open to a signed-in member',
    has_function_privilege('authenticated',
      'public.transfer_document(uuid, text, jsonb)', 'execute'));
  perform pg_temp.check_true('the progress helpers are internal',
    not has_function_privilege('authenticated',
      'app.refresh_sales_progress(uuid)', 'execute'));
end $$;

rollback;

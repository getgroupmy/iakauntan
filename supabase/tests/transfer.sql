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


-- ---------------------------------------------------------------------
-- The thirteen a mutation sweep found
-- ---------------------------------------------------------------------
-- Thirty one-line mutants of `transfer_document` against fifteen test
-- files. Thirteen survived, and eleven of the thirteen fall into two
-- groups that between them describe how this function was tested.
--
-- THE PURCHASE BRANCH. `transfer_document` is written twice -- once for
-- the selling cycle, once for the buying one -- and FIVE rules are
-- asserted on the sales side and on neither the buying side:
--
--   taking more forward than is outstanding
--   counting what has already been billed
--   prorating a line discount onto a part transfer
--   apportioning the carriage
--   apportioning the header discount
--
-- Every one of those has a sales twin in this file that is asserted and
-- dies. This is the third function in a row with the shape, and it is
-- the most complete example of it: the buying half of a two-cycle
-- function is where a fault lives longest, because the tests were
-- written while thinking about selling.
--
-- THE FRONT DOOR. Four refusals at the top -- a voided source on either
-- side, a source that does not exist, and a caller who may not write --
-- none asserted. Every sweep this session has found this.
--
-- The other two are a payment term that is never read (so every
-- transferred invoice falls due in thirty days whatever the customer
-- agreed) and a currency that is not carried (so a quotation in USD
-- becomes an invoice in ringgit at par).
do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_cust   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_term   uuid;
  v_quote  uuid;
  v_po     uuid;
  v_bill   uuid;
  v_inv    uuid;
  v_new    uuid;
  v_line   uuid;
  v_pline  uuid;
  v_zero   uuid;
  v_usd    uuid;
  v_who    uuid;
  v_msg    text;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Pindah Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', app.today())::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Pembeli', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Pembekal', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 100)
  returning id into v_item;
  insert into public.payment_terms (org_id, code, name, days, term_type)
  values (v_org, 'N60', 'Net 60', 60, 'net') returning id into v_term;

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.transfer_document(gen_random_uuid(), 'sales_order');
    raise exception 'a document that does not exist was transferred';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a source that is not there is refused',
      v_msg like 'Document % not found');
  end;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'quotation', 'QT-VOID', app.today(), v_cust, 'MYR', 1, 'void')
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_quote, 1, 'item', v_item, 'Withdrawn', 10, 100);

  begin
    perform public.transfer_document(v_quote, 'sales_order');
    raise exception 'a voided quotation was transferred';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a voided quotation cannot be taken forward',
      v_msg, 'Document QT-VOID has been voided');
  end;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'purchase_order', 'PO-VOID', app.today(), v_sup, 'MYR', 1, 'void')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_po, 1, 'item', v_item, 'Cancelled', 10, 100);

  begin
    perform public.transfer_document(v_po, 'bill');
    raise exception 'a voided purchase order was transferred';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('nor a voided purchase order',
      v_msg, 'Document PO-VOID has been voided');
  end;

  -- And by somebody who may not write at all.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status, payment_term_id)
  values (v_org, 'quotation', 'QT-OK', app.today(), v_cust, 'MYR', 1, 'draft',
          v_term)
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, discount_amount)
  values (v_org, v_quote, 1, 'item', v_item, 'Advice', 10, 100, 60);

  v_who := pg_temp.another_user('transfer-outsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_who);
  begin
    perform public.transfer_document(v_quote, 'sales_order');
    raise exception 'somebody outside the company transferred its quotation';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('and not by somebody who may not write here',
      v_msg, 'Insufficient privileges to transfer');
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ==================================================================
  -- 2. The due date is the one the customer agreed
  --
  -- The term is read off the source and its days added; drop the lookup
  -- and every transferred invoice falls due in thirty days whatever was
  -- agreed. Net 60 here, so thirty would be visible.
  -- ==================================================================
  v_inv := public.transfer_document(v_quote, 'invoice');
  perform pg_temp.check_true('an invoice falls due on the agreed terms',
    (select due_date = app.today() + 60 from public.sales_documents
      where id = v_inv));
  perform pg_temp.check_true('which is not the thirty-day default',
    (app.today() + 60) <> (app.today() + 30));

  -- ==================================================================
  -- 3. A foreign quotation becomes a foreign invoice
  --
  -- Nothing in this file leaves ringgit, so the currency and the rate
  -- could both be replaced by the company's own at par -- turning a
  -- quotation for USD 1,000 into an invoice for RM 1,000, which is not
  -- the price anybody agreed.
  -- ==================================================================
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.70, app.today() - 7, 'manual');
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'quotation', 'QT-USD', app.today(), v_cust, 'USD', 4.70, 'draft')
  returning id into v_usd;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_usd, 1, 'item', v_item, 'Exported advice', 10, 100);

  v_new := public.transfer_document(v_usd, 'sales_order');
  perform pg_temp.check_eq('a foreign quotation keeps its currency',
    (select currency::text from public.sales_documents where id = v_new), 'USD');
  perform pg_temp.check_eq('and the rate it was struck at',
    (select exchange_rate from public.sales_documents where id = v_new),
    4.70::numeric);

  -- ==================================================================
  -- 4. The buying cycle, rule for rule
  --
  -- Five rules whose selling twins are asserted above and whose buying
  -- copies were asserted nowhere. A purchase order for ten, with
  -- carriage and a discount on the header and a discount on the line,
  -- billed in two halves.
  -- ==================================================================
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status, shipping_amount, discount_amount)
  values (v_org, 'purchase_order', 'PO-1', app.today(), v_sup, 'MYR', 1,
          'draft', 80, 40)
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, discount_amount)
  values (v_org, v_po, 1, 'item', v_item, 'Contract work', 10, 100, 60)
  returning id into v_pline;

  -- Half of it, billed.
  v_bill := public.transfer_document(v_po, 'bill',
    jsonb_build_array(jsonb_build_object('line_id', v_pline, 'quantity', 5)));

  perform pg_temp.check_eq('half a purchase order takes half the carriage',
    (select shipping_amount from public.purchase_documents where id = v_bill),
    40::numeric);
  perform pg_temp.check_eq('and half the header discount',
    (select discount_amount from public.purchase_documents where id = v_bill),
    20::numeric);
  perform pg_temp.check_eq('and half the line discount, not all of it',
    (select discount_amount from public.purchase_document_lines
      where document_id = v_bill), 30::numeric);

  -- What is already billed is counted, so only five are left.
  begin
    perform public.transfer_document(v_po, 'bill',
      jsonb_build_array(jsonb_build_object('line_id', v_pline, 'quantity', 6)));
    raise exception 'a purchase order was billed for more than it has left';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a bill cannot take more than the order has left',
      v_msg like 'Line 1 has 5%outstanding; 6%was asked for.');
  end;

  -- The rest of it goes, and then there is nothing.
  v_new := public.transfer_document(v_po, 'bill');
  perform pg_temp.check_eq('the remaining half bills',
    (select quantity from public.purchase_document_lines
      where document_id = v_new), 5::numeric);
  perform pg_temp.check_eq('taking the other half of the carriage',
    (select shipping_amount from public.purchase_documents where id = v_new),
    40::numeric);

  -- ==================================================================
  -- 5. The service charge, the one header amount only sales has
  -- ==================================================================
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status, service_charge_amount)
  values (v_org, 'quotation', 'QT-SVC', app.today(), v_cust, 'MYR', 1, 'draft', 100)
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_quote, 1, 'item', v_item, 'Served', 10, 100)
  returning id into v_line;

  v_new := public.transfer_document(v_quote, 'sales_order',
    jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 4)));
  perform pg_temp.check_eq(
    'two fifths of a quotation takes two fifths of the service charge',
    (select service_charge_amount from public.sales_documents where id = v_new),
    40::numeric);

  -- ==================================================================
  -- 6. A document whose lines come to nothing
  --
  -- The function's comment calls all-on-a-whole and none-on-a-partial
  -- the only defensible answers. The whole half was asserted; the
  -- partial half was not, and inverting it puts the entire delivery
  -- charge on a transfer of one line out of two.
  -- ==================================================================
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status, shipping_amount)
  values (v_org, 'quotation', 'QT-ZERO', app.today(), v_cust, 'MYR', 1,
          'draft', 90)
  returning id into v_zero;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, discount_amount)
  values (v_org, v_zero, 1, 'item', v_item, 'Swapped out', 1, 100, 100),
         (v_org, v_zero, 2, 'item', v_item, 'Swapped in',  1, 100, 100);
  perform pg_temp.check_eq('the quotation nets to nothing',
    (select coalesce(subtotal, 0) from public.sales_documents where id = v_zero),
    0::numeric);

  select l.id into v_line from public.sales_document_lines l
   where l.document_id = v_zero and l.line_no = 1;
  v_new := public.transfer_document(v_zero, 'sales_order',
    jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', 1)));
  perform pg_temp.check_eq(
    'a partial transfer of it takes none of the delivery charge',
    (select shipping_amount from public.sales_documents where id = v_new),
    0::numeric);

  raise notice 'ok   transfer: the thirteen a sweep found';
end $$;

rollback;

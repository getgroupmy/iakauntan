-- =====================================================================
-- iAkauntan :: serial numbers, batches and expiry
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/serial_and_batch.sql
--
-- What is being asserted is not that batch numbers can be stored. It is
-- that they cannot be wrong in the four ways that would make a recall
-- list worse than no recall list at all:
--
--   * stock leaving with nothing named;
--   * a line broken down into more or fewer units than the line;
--   * a batch shipped that was never received;
--   * one serial number on hand twice.
--
-- And one regression, asserted first, because it is what would be
-- quietly destroyed: an untracked item goes on costing exactly as it did.
--
-- The deferred check needs `set constraints ... immediate` to reach it
-- at all — a file that rolls back never commits, so a constraint that
-- fires at commit would otherwise never fire here. That the triggers are
-- numbered rather than named is what makes this safe: with constraints
-- immediate they run in name order, and the check has to come second.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.stock_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Main store', true);
  return v_org;
end;
$$;

create or replace function pg_temp.item(
  p_org uuid, p_code text, p_tracking text default 'none')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking, cost_price)
  values (p_org, p_code, initcap(p_code), 'stock', true, p_tracking, 10)
  returning id into v_id;
  return v_id;
end;
$$;

-- A posted bill, which is how stock arrives. Returns the line id so the
-- caller can name lots against it before posting.
create or replace function pg_temp.bill_line(
  p_org uuid, p_item uuid, p_qty numeric, p_cost numeric,
  p_on date default date '2026-02-01')
returns uuid language plpgsql as $$
declare v_supp uuid; v_doc uuid; v_line uuid;
begin
  select id into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier' limit 1;
  if v_supp is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'S-001', 'Supplier', 'supplier') returning id into v_supp;
  end if;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'bill', 'BILL-' || substr(gen_random_uuid()::text, 1, 8),
          p_on, v_supp, 'MYR', 1,
          p_qty * p_cost, p_qty * p_cost, p_qty * p_cost, 'draft')
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_doc, 1, 'item', p_item, 'Goods', p_qty, p_cost)
  returning id into v_line;

  return v_line;
end;
$$;

create or replace function pg_temp.post_bill(p_line uuid)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  select document_id into v_doc from public.purchase_document_lines where id = p_line;
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

create or replace function pg_temp.invoice_line(
  p_org uuid, p_item uuid, p_qty numeric, p_price numeric,
  p_on date default date '2026-03-01')
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid; v_line uuid;
begin
  select id into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer' limit 1;
  if v_cust is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'C-001', 'Buyer', 'customer') returning id into v_cust;
  end if;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-' || substr(gen_random_uuid()::text, 1, 8),
          p_on, v_cust, 'MYR', 1,
          p_qty * p_price, p_qty * p_price, p_qty * p_price, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_doc, 1, 'item', p_item, 'Goods', p_qty, p_price)
  returning id into v_line;

  return v_line;
end;
$$;

create or replace function pg_temp.post_invoice(p_line uuid)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  select document_id into v_doc from public.sales_document_lines where id = p_line;
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- The regression: an untracked item is untouched
--
-- Asserted before anything else. The whole of this migration is worth
-- less than nothing if it moved the weighted average by a sen.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.stock_org('Untracked Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'plain');
  v_line uuid;
begin
  v_line := pg_temp.bill_line(v_org, v_item, 100, 10);
  perform pg_temp.post_bill(v_line);
  v_line := pg_temp.bill_line(v_org, v_item, 100, 14);
  perform pg_temp.post_bill(v_line);

  -- 100 at 10 and 100 at 14 is 2,400 over 200, which is 12.
  perform pg_temp.check_eq('the weighted average is what it always was',
    (select average_cost from public.items where id = v_item), 12);
  perform pg_temp.check_eq('and the quantity',
    (select quantity_on_hand from public.items where id = v_item), 200);
  perform pg_temp.check_eq('with no lot detail invented for it',
    (select count(*) from public.stock_movement_lots sml
      join public.stock_movements m on m.id = sml.movement_id
     where m.org_id = v_org), 0);

  -- And it refuses to pretend otherwise.
  begin
    perform public.set_line_lots('purchase_document_lines', v_line,
      '[{"lot_ref":"B-1","quantity":100}]'::jsonb);
    raise exception 'FAIL: recorded a batch against an untracked item';
  exception when sqlstate '23514' then
    raise notice 'ok   an untracked item cannot carry batch detail';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Receiving and issuing a batch item
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.stock_org('Batches Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'milk', 'batch');
  v_bill uuid; v_inv uuid;
  r record;
begin
  v_bill := pg_temp.bill_line(v_org, v_item, 100, 10);
  perform pg_temp.check_eq('two batches named on one line',
    public.set_line_lots('purchase_document_lines', v_bill,
      '[{"lot_ref":"B-MAR","quantity":60,"expiry_date":"2026-06-30"},
        {"lot_ref":"B-APR","quantity":40,"expiry_date":"2026-09-30"}]'::jsonb), 2);
  perform pg_temp.post_bill(v_bill);

  perform pg_temp.check_eq('both batches are on hand',
    (select sum(quantity) from public.v_lot_balances where item_id = v_item), 100);
  perform pg_temp.check_eq('the earlier-dated one for what was received',
    (select quantity from public.v_lot_balances
      where item_id = v_item and lot_ref = 'B-MAR'), 60);
  perform pg_temp.check_true('and the expiry came across with it',
    (select expiry_date = date '2026-06-30' from public.stock_lots
      where item_id = v_item and lot_ref = 'B-MAR'));

  -- First expired, first out: June before September, whatever order they
  -- arrived in.
  select * into r from public.suggest_lots(v_item, null, 70) limit 1;
  perform pg_temp.check_true('the suggestion takes the shortest-dated first',
    r.lot_ref = 'B-MAR');
  perform pg_temp.check_eq('as much of it as there is', r.take, 60);

  perform pg_temp.check_eq('and the rest from the next one',
    (select take from public.suggest_lots(v_item, null, 70)
      where lot_ref = 'B-APR'), 10);

  -- Ship 70, drawn the way the suggestion said.
  v_inv := pg_temp.invoice_line(v_org, v_item, 70, 25);
  perform public.set_line_lots('sales_document_lines', v_inv,
    '[{"lot_ref":"B-MAR","quantity":60},{"lot_ref":"B-APR","quantity":10}]'::jsonb);
  perform pg_temp.post_invoice(v_inv);

  perform pg_temp.check_true('the exhausted batch is off the list',
    not exists (select 1 from public.v_lot_balances
                 where item_id = v_item and lot_ref = 'B-MAR'));
  perform pg_temp.check_eq('and the other one is down to what is left',
    (select quantity from public.v_lot_balances
      where item_id = v_item and lot_ref = 'B-APR'), 30);
  perform pg_temp.check_eq('which agrees with the stock ledger',
    (select quantity_on_hand from public.items where id = v_item), 30);
end $$;

-- ---------------------------------------------------------------------
-- The four ways it must not go wrong
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.stock_org('Refusals Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'pills', 'batch');
  v_bill uuid; v_inv uuid;
begin
  -- 1. Nothing named at all. Caught by the materialise trigger, so it
  --    lands at the posting call rather than at commit — which is the
  --    difference between a message somebody can act on and a 500.
  v_bill := pg_temp.bill_line(v_org, v_item, 50, 10);
  begin
    perform pg_temp.post_bill(v_bill);
    raise exception 'FAIL: posted a tracked item with nothing named';
  exception when sqlstate '23514' then
    raise notice 'ok   a tracked line will not post with nothing named';
  end;

  -- 2. Named, but not for the whole line. Refused where it is typed,
  --    not a week later at posting.
  v_bill := pg_temp.bill_line(v_org, v_item, 50, 10);
  begin
    perform public.set_line_lots('purchase_document_lines', v_bill,
      '[{"lot_ref":"B-1","quantity":30}]'::jsonb);
    raise exception 'FAIL: took a breakdown that did not add up';
  exception when sqlstate '23514' then
    raise notice 'ok   a partial breakdown is refused as it is entered';
  end;

  -- Receive properly so there is something to ship.
  perform public.set_line_lots('purchase_document_lines', v_bill,
    '[{"lot_ref":"B-1","quantity":50,"expiry_date":"2026-12-31"}]'::jsonb);
  perform pg_temp.post_bill(v_bill);

  -- 3. Shipping a batch that was never received. The quantities add up
  --    perfectly on the movement; it is the balance that gives it away.
  v_inv := pg_temp.invoice_line(v_org, v_item, 10, 30);
  perform public.set_line_lots('sales_document_lines', v_inv,
    '[{"lot_ref":"B-NEVER-SEEN","quantity":10}]'::jsonb);
  begin
    perform pg_temp.post_invoice(v_inv);
    set constraints public.stock_movements_lots_2_check immediate;
    raise exception 'FAIL: shipped a batch that was never received';
  exception when sqlstate '23514' then
    raise notice 'ok   a batch nobody received cannot be shipped';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Serial numbers
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.stock_org('Serials Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'laptop', 'serial');
  v_bill uuid; v_inv uuid;
begin
  v_bill := pg_temp.bill_line(v_org, v_item, 3, 3000);
  -- Quantities are not sent for a serial. One serial is one unit by
  -- definition, and a screen that could say otherwise eventually would.
  perform public.set_line_lots('purchase_document_lines', v_bill,
    '[{"lot_ref":"SN-001"},{"lot_ref":"SN-002"},{"lot_ref":"SN-003"}]'::jsonb);
  perform pg_temp.post_bill(v_bill);

  perform pg_temp.check_eq('three serials, one unit each',
    (select count(*) from public.v_lot_balances where item_id = v_item), 3);
  perform pg_temp.check_eq('and three units on hand',
    (select sum(quantity) from public.v_lot_balances where item_id = v_item), 3);

  -- Sell one.
  v_inv := pg_temp.invoice_line(v_org, v_item, 1, 4500);
  perform public.set_line_lots('sales_document_lines', v_inv,
    '[{"lot_ref":"SN-002"}]'::jsonb);
  perform pg_temp.post_invoice(v_inv);

  perform pg_temp.check_true('the one that was sold is gone',
    not exists (select 1 from public.v_lot_balances
                 where item_id = v_item and lot_ref = 'SN-002'));
  perform pg_temp.check_eq('two left', (select sum(quantity)
    from public.v_lot_balances where item_id = v_item), 2);

  -- 4. Selling it a second time. Two units under one serial number means
  --    one of them is mislabelled, and a warranty claim finds it first.
  v_inv := pg_temp.invoice_line(v_org, v_item, 1, 4500);
  perform public.set_line_lots('sales_document_lines', v_inv,
    '[{"lot_ref":"SN-002"}]'::jsonb);
  begin
    perform pg_temp.post_invoice(v_inv);
    set constraints public.stock_movements_lots_2_check immediate;
    raise exception 'FAIL: sold the same serial number twice';
  exception when sqlstate '23514' then
    raise notice 'ok   a serial cannot be sold twice';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Expiry, and the recall
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.stock_org('Recall Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'syrup', 'batch');
  v_bill uuid; v_inv uuid; v_lot uuid;
  r record;
  v_in integer; v_out integer;
begin
  v_bill := pg_temp.bill_line(v_org, v_item, 20, 10);
  perform public.set_line_lots('purchase_document_lines', v_bill,
    format('[{"lot_ref":"B-SOON","quantity":20,"expiry_date":"%s"}]',
           (current_date + 20)::text)::jsonb);
  perform pg_temp.post_bill(v_bill);

  select * into r from public.report_expiring_stock(v_org, 30) limit 1;
  perform pg_temp.check_true('what is about to expire is reported',
    r.lot_ref = 'B-SOON');
  perform pg_temp.check_eq('with the days left', r.days_to_expiry, 20);
  -- At the item's weighted average, which is what it is carried at.
  perform pg_temp.check_eq('and what would be written off', r.value_at_average, 200);

  perform pg_temp.check_true('and a longer horizon does not miss it',
    exists (select 1 from public.report_expiring_stock(v_org, 90)
             where lot_ref = 'B-SOON'));
  perform pg_temp.check_true('while a shorter one leaves it alone',
    not exists (select 1 from public.report_expiring_stock(v_org, 5)
                 where lot_ref = 'B-SOON'));

  -- Ship half of it, then ask the question a recall asks.
  v_inv := pg_temp.invoice_line(v_org, v_item, 12, 25);
  perform public.set_line_lots('sales_document_lines', v_inv,
    '[{"lot_ref":"B-SOON","quantity":12}]'::jsonb);
  perform pg_temp.post_invoice(v_inv);

  select id into v_lot from public.stock_lots
   where item_id = v_item and lot_ref = 'B-SOON';

  select count(*) filter (where direction = 'in'),
         count(*) filter (where direction = 'out')
    into v_in, v_out
    from public.trace_lot(v_org, v_lot);

  perform pg_temp.check_eq('the trace shows where it came from', v_in, 1);
  perform pg_temp.check_eq('and every place it went', v_out, 1);
  perform pg_temp.check_true('naming the customer who has it',
    exists (select 1 from public.trace_lot(v_org, v_lot)
             where direction = 'out' and contact_name = 'Buyer'
               and document_no like 'INV-%'));
  perform pg_temp.check_true('and the supplier it arrived from',
    exists (select 1 from public.trace_lot(v_org, v_lot)
             where direction = 'in' and contact_name = 'Supplier'));

  perform pg_temp.check_eq('with what is still on the shelf',
    (select quantity from public.v_lot_balances where lot_id = v_lot), 8);
end $$;

-- ---------------------------------------------------------------------
-- Telling somebody before they press the button
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.stock_org('Warnings Sdn Bhd');
  v_item uuid := pg_temp.item(v_org, 'tins', 'batch');
  v_plain uuid := pg_temp.item(v_org, 'nails');
  v_line uuid; v_doc uuid;
  r record;
begin
  v_line := pg_temp.bill_line(v_org, v_item, 25, 4);
  select document_id into v_doc from public.purchase_document_lines where id = v_line;

  select * into r from public.document_lot_problems(v_doc, 'purchase');
  perform pg_temp.check_true('an unnamed line is reported before posting',
    r.item_code = 'tins' and r.needed = 25 and r.allocated = 0);
  perform pg_temp.check_true('and says what is wrong in words',
    r.problem like '%nothing has been named%');

  perform public.set_line_lots('purchase_document_lines', v_line,
    '[{"lot_ref":"B-9","quantity":25}]'::jsonb);
  perform pg_temp.check_eq('once named there is nothing to report',
    (select count(*) from public.document_lot_problems(v_doc, 'purchase')), 0);

  -- An untracked line is never a problem, which is what keeps this
  -- usable for the businesses that will never turn tracking on.
  v_line := pg_temp.bill_line(v_org, v_plain, 5, 2);
  select document_id into v_doc from public.purchase_document_lines where id = v_line;
  perform pg_temp.check_eq('an untracked line is not a problem',
    (select count(*) from public.document_lot_problems(v_doc, 'purchase')), 0);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the lot balances view is not open to anon',
    not has_table_privilege('anon', 'public.v_lot_balances', 'select'));
  perform pg_temp.check_true('and it reads as the caller, not as its owner',
    (select 'security_invoker=true' = any(reloptions)
       from pg_class where relname = 'v_lot_balances'));

  -- A posting's consequences are not editable by hand. The way to change
  -- them is to reverse the document, which is the ledger's own rule.
  perform pg_temp.check_true('movement lots cannot be written by a user',
    not has_table_privilege('authenticated', 'public.stock_movement_lots', 'insert'));
  perform pg_temp.check_true('nor edited',
    not has_table_privilege('authenticated', 'public.stock_movement_lots', 'update'));
  perform pg_temp.check_true('nor deleted',
    not has_table_privilege('authenticated', 'public.stock_movement_lots', 'delete'));

  perform pg_temp.check_true('the triggers are not callable by hand',
    not has_function_privilege('authenticated',
      'app.materialise_movement_lots()', 'execute'));
  perform pg_temp.check_true('nor the check',
    not has_function_privilege('authenticated',
      'app.check_movement_lots()', 'execute'));

  perform pg_temp.check_true('the recall trace is closed to anon',
    not has_function_privilege('anon', 'public.trace_lot(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('and open to a signed-in user',
    has_function_privilege('authenticated', 'public.trace_lot(uuid, uuid)', 'execute'));

  -- The order matters and is not an accident: both fire AFTER INSERT on
  -- the same table, and PostgreSQL runs those in name order.
  perform pg_temp.check_true('the materialise trigger sorts before the check',
    'stock_movements_lots_1_materialise' < 'stock_movements_lots_2_check'
    and exists (select 1 from pg_trigger
                 where tgname = 'stock_movements_lots_1_materialise')
    and exists (select 1 from pg_trigger
                 where tgname = 'stock_movements_lots_2_check'));

  perform pg_temp.check_true('and the dead columns are gone',
    not exists (select 1 from information_schema.columns
                 where table_name = 'stock_movements'
                   and column_name in ('batch_no', 'serial_no', 'expiry_date')));
end $$;

rollback;

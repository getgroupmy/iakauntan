-- =====================================================================
-- iAkauntan :: the batch list somebody picks stock from
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/lot_report.sql
--
-- report_lot_balances is what the stock screen calls. The quantities it
-- returns come straight from v_lot_balances, and that view is already
-- asserted at length by serial_and_batch.sql and
-- lots_across_the_new_sources.sql -- what is on hand, what FEFO
-- consumed, a lot disappearing once it is exhausted. None of that is
-- repeated here.
--
-- Four things belong to the function rather than the view, and none was
-- tested:
--
--   the membership guard
--   the item and warehouse filters
--   days_to_expiry, the only arithmetic it does
--   the order it returns rows in
--
-- The last is not cosmetic. The list is ordered by expiry, soonest
-- first, with undated lots at the end, because that is the order stock
-- should be picked in -- and somebody reading the top of the screen and
-- shipping that batch is relying on it. Sorting by lot reference
-- instead would put B-APR above B-MAR and quietly send out the batch
-- that keeps longest.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.lot_org(p_name text)
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

create or replace function pg_temp.lot_item(
  p_org uuid, p_code text, p_tracking text default 'batch')
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

create or replace function pg_temp.lot_bill(
  p_org uuid, p_item uuid, p_qty numeric, p_wh uuid default null)
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
          date '2026-02-01', v_supp, 'MYR', 1,
          p_qty * 10, p_qty * 10, p_qty * 10, 'draft')
  returning id into v_doc;
  -- The warehouse is a property of the line, not the document: one
  -- delivery can be split across stores.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, warehouse_id)
  values (p_org, v_doc, 1, 'item', p_item, 'Goods', p_qty, 10, p_wh)
  returning id into v_line;
  return v_line;
end;
$$;

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_milk   uuid;
  v_flour  uuid;
  v_main   uuid;
  v_annex  uuid;
  v_line   uuid;
  r        record;
  v_rows   text;
  v_n      integer;
begin
  v_org := pg_temp.lot_org('Gudang Probe');
  perform pg_temp.sign_in_as(v_owner);
  select id into v_main from public.warehouses
   where org_id = v_org and code = 'MAIN';
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'ANNEX', 'The annex') returning id into v_annex;

  v_milk  := pg_temp.lot_item(v_org, 'milk');
  v_flour := pg_temp.lot_item(v_org, 'flour');

  -- Three batches of milk into the main store. B-APR sorts first by
  -- reference and last by expiry, which is what makes the ordering
  -- assertion below mean something.
  v_line := pg_temp.lot_bill(v_org, v_milk, 100, v_main);
  perform public.set_line_lots('purchase_document_lines', v_line,
    '[{"lot_ref":"B-MAR","quantity":60,"expiry_date":"2026-06-30"},
      {"lot_ref":"B-APR","quantity":40,"expiry_date":"2026-09-30"}]'::jsonb);
  perform public.post_purchase_document(
    (select document_id from public.purchase_document_lines where id = v_line));

  -- A batch with no expiry at all: long-life stock, which belongs at
  -- the end of a pick list rather than the front.
  v_line := pg_temp.lot_bill(v_org, v_milk, 25, v_main);
  perform public.set_line_lots('purchase_document_lines', v_line,
    '[{"lot_ref":"B-UHT","quantity":25}]'::jsonb);
  perform public.post_purchase_document(
    (select document_id from public.purchase_document_lines where id = v_line));

  -- And flour in the annex, so the filters have something to exclude.
  v_line := pg_temp.lot_bill(v_org, v_flour, 50, v_annex);
  perform public.set_line_lots('purchase_document_lines', v_line,
    '[{"lot_ref":"F-01","quantity":50,"expiry_date":"2027-01-31"}]'::jsonb);
  perform public.post_purchase_document(
    (select document_id from public.purchase_document_lines where id = v_line));

  -- ==================================================================
  -- What comes back
  -- ==================================================================
  perform pg_temp.check_eq('every live lot in the company',
    (select count(*) from public.report_lot_balances(v_org)), 4);

  select * into r from public.report_lot_balances(v_org, v_milk)
   where lot_ref = 'B-MAR';
  perform pg_temp.check_eq('a lot carries its item code', r.item_code, 'milk');
  perform pg_temp.check_eq('and its quantity', r.quantity, 60);
  perform pg_temp.check_eq('and the warehouse it sits in', r.warehouse,
    'Main store');
  perform pg_temp.check_eq('and what kind of tracking it is',
    r.kind, 'batch');

  -- ==================================================================
  -- days_to_expiry, the only sum the function does
  -- ==================================================================
  perform pg_temp.check_eq('days to expiry is counted from today',
    (select days_to_expiry from public.report_lot_balances(v_org, v_milk)
      where lot_ref = 'B-MAR'),
    (date '2026-06-30' - current_date)::integer);
  -- Null rather than a number. A lot that does not expire has no
  -- countdown, and zero would read as "expires today".
  --
  -- This one documents the behaviour rather than defending it: the
  -- function's `case when expiry_date is null then null` arm is
  -- redundant, because `null::date - current_date` is already null.
  -- Removing the arm changes nothing, so no test can catch its removal
  -- -- which is worth knowing before somebody trusts this line to
  -- protect the countdown.
  perform pg_temp.check_true('a lot with no expiry has no countdown',
    (select days_to_expiry is null
       from public.report_lot_balances(v_org, v_milk)
      where lot_ref = 'B-UHT'));

  -- ==================================================================
  -- The order stock should be picked in
  -- ==================================================================
  select string_agg(lot_ref, ',' order by ord) into v_rows
    from (select lot_ref, row_number() over () as ord
            from public.report_lot_balances(v_org, v_milk)) x;
  perform pg_temp.check_eq('soonest to expire first, undated last',
    v_rows, 'B-MAR,B-APR,B-UHT');

  -- Across items it is item code first, so one item's lots stay
  -- together rather than interleaving with another's by date.
  select string_agg(item_code || ':' || lot_ref, ',' order by ord) into v_rows
    from (select item_code, lot_ref, row_number() over () as ord
            from public.report_lot_balances(v_org)) x;
  perform pg_temp.check_eq('and one item''s lots stay together',
    v_rows, 'flour:F-01,milk:B-MAR,milk:B-APR,milk:B-UHT');

  -- ==================================================================
  -- The filters
  -- ==================================================================
  perform pg_temp.check_eq('narrowed to one item',
    (select count(*) from public.report_lot_balances(v_org, v_milk)), 3);
  perform pg_temp.check_eq('narrowed to one warehouse',
    (select count(*) from public.report_lot_balances(v_org, null, v_annex)), 1);
  perform pg_temp.check_eq('and to both at once',
    (select count(*) from public.report_lot_balances(v_org, v_milk, v_annex)), 0);
  perform pg_temp.check_eq('the annex holds the flour',
    (select item_code from public.report_lot_balances(v_org, null, v_annex)),
    'flour');

  -- A lot that has been emptied drops off the list rather than sitting
  -- at zero -- that is the view's `having sum(quantity) <> 0`, and
  -- serial_and_batch.sql already asserts it against v_lot_balances
  -- directly, so it is not repeated through the wrapper here.

  -- ==================================================================
  -- Not for somebody outside the company
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform * from public.report_lot_balances(v_org);
    raise exception 'FAIL: a stranger read the batch list';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot read what is in the warehouse';
  end;
  perform pg_temp.sign_out();
end $$;

rollback;

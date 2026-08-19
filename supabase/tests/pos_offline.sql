-- =====================================================================
-- Point of sale :: no signal
--
-- The defect this file rules out is not "the sale did not arrive". It
-- is "the sale arrived twice". A device whose request times out does
-- not know whether the server got it, so it sends again -- and without
-- an answer to that, a shop's takings sit somewhere between right and
-- double.
--
-- So the assertion that matters is: sending the same payload twice
-- lands one sale, one invoice, one receipt and one lot of stock, and
-- the second call answers plainly rather than erroring. An error is
-- something a device retries; a plain answer is something it can stop
-- retrying.
--
-- Two others carry weight:
--
--   * the price comes from the device. The till charged what it
--     charged, and re-pricing on the way in would put a different
--     number in the books from the one on the customer's receipt.
--
--   * one bad payload does not lose the good ones. A device coming back
--     online sends everything it has, and a sale naming an item
--     somebody deleted yesterday must be rejected alone.
-- =====================================================================
\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_item   uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_shift  uuid;
  v_c1     uuid := gen_random_uuid();
  v_c2     uuid := gen_random_uuid();
  v_c3     uuid := gen_random_uuid();
  v_batch  jsonb;
  v_sale   uuid;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Pasar Malam Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'The van') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'AYAM', 'Ayam percik', 'stock', true, 'C62', 15.00, 6.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'VAN', 'The stall', 'mobile', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'PHONE', 'A phone') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true) returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 50.00);

  -- ------------------------------------------------------------------
  -- Two sales taken with no signal
  -- ------------------------------------------------------------------
  -- The second one is priced at 14.00 rather than the list 15.00,
  -- because that is what the customer was charged before the price
  -- list moved. The books must agree with the receipt.
  v_batch := jsonb_build_array(
    jsonb_build_object(
      'client_uuid', v_c1,
      'sold_at', (now() - interval '20 minutes'),
      'lines', jsonb_build_array(
        jsonb_build_object('item_id', v_item, 'quantity', 2, 'unit_price', 15.00)),
      'tenders', jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 50.00))),
    jsonb_build_object(
      'client_uuid', v_c2,
      'sold_at', (now() - interval '10 minutes'),
      'lines', jsonb_build_array(
        jsonb_build_object('item_id', v_item, 'quantity', 1, 'unit_price', 14.00)),
      'tenders', jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 14.00))));

  perform pg_temp.check_eq('two sales land',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'landed'), 2);
  perform pg_temp.check_eq('two invoices exist',
    (select count(*) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'), 2);
  perform pg_temp.check_eq('the second was charged what the till charged',
    (select s.total_amount from public.pos_sales s where s.client_uuid = v_c2), 14.00);
  perform pg_temp.check_true('and the device''s clock is kept alongside the server''s',
    (select s.offline_sold_at < s.completed_at from public.pos_sales s
      where s.client_uuid = v_c1));

  -- ------------------------------------------------------------------
  -- The assertion this file exists for
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('sending the same batch again lands nothing',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'landed'), 0);
  perform pg_temp.check_eq('and says so, rather than failing',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'already'), 2);
  perform pg_temp.check_eq('there are still two sales, not four',
    (select count(*) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'), 2);
  perform pg_temp.check_eq('two invoices, not four',
    (select count(*) from public.sales_documents d
      where d.org_id = v_org and d.doc_type = 'invoice'), 2);
  perform pg_temp.check_eq('two receipts, not four',
    (select count(*) from public.receipts r where r.org_id = v_org), 2);
  -- The one that would be invisible on a screen and obvious in a
  -- stock count.
  perform pg_temp.check_eq('and three birds left the van, not six',
    (select -sum(m.quantity) from public.stock_movements m where m.org_id = v_org), 3);
  perform pg_temp.check_true('the retry returns the invoice the till already has',
    (select r.invoice_no from public.ingest_offline_sales(v_reg, v_batch) r
      where r.client_uuid = v_c1) =
    (select d.doc_no from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.client_uuid = v_c1));

  -- ------------------------------------------------------------------
  -- One bad payload, eleven good ones
  -- ------------------------------------------------------------------
  v_batch := jsonb_build_array(
    jsonb_build_object(
      'client_uuid', v_c3,
      'sold_at', now(),
      'lines', jsonb_build_array(
        -- An item that is not on this company's list. A device can
        -- easily be holding one: it was deleted while the van was out.
        jsonb_build_object('item_id', gen_random_uuid(), 'quantity', 1, 'unit_price', 9.00)),
      'tenders', jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 9.00))),
    jsonb_build_object(
      'client_uuid', gen_random_uuid(),
      'sold_at', now(),
      'lines', jsonb_build_array(
        jsonb_build_object('item_id', v_item, 'quantity', 1, 'unit_price', 15.00)),
      'tenders', jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 15.00))));

  perform pg_temp.check_eq('the bad one is rejected',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'rejected'), 1);
  perform pg_temp.check_eq('the good one still landed',
    (select count(*) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'), 3);

  -- Money crossed a counter for the rejected one, so it is kept.
  perform pg_temp.check_eq('and what failed is on a list somebody can read',
    (select count(*) from public.pos_offline_problems(v_org)), 1);
  perform pg_temp.check_eq('with what it was worth',
    (select p.total from public.pos_offline_problems(v_org) p), 9.00);

  -- A device that retries a doomed sale twelve times leaves one
  -- problem on the screen, not twelve.
  perform public.ingest_offline_sales(v_reg, v_batch);
  perform public.ingest_offline_sales(v_reg, v_batch);
  perform pg_temp.check_eq('retrying a doomed sale does not fill the screen',
    (select count(*) from public.pos_offline_problems(v_org)), 1);

  -- ------------------------------------------------------------------
  -- A counted drawer stays counted
  -- ------------------------------------------------------------------
  -- close_pos_shift wrote a variance against what was in the till at
  -- that moment. A cash sale landing afterwards would make that figure
  -- a lie about a count somebody signed for.
  perform * from public.close_pos_shift(v_shift, app.pos_expected_cash(v_shift));
  v_batch := jsonb_build_array(
    jsonb_build_object(
      'client_uuid', gen_random_uuid(),
      'sold_at', now(),
      'lines', jsonb_build_array(
        jsonb_build_object('item_id', v_item, 'quantity', 1, 'unit_price', 15.00)),
      'tenders', jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 15.00))));
  perform pg_temp.check_eq('a sale cannot land in a drawer that has been counted',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'rejected'), 1);
  perform pg_temp.check_eq('but it is parked rather than lost',
    (select count(*) from public.pos_offline_problems(v_org)), 2);

  -- And it lands when a drawer is open again, clearing the problem.
  v_shift := public.open_pos_shift(v_reg, 50.00);
  perform pg_temp.check_eq('the next shift takes it',
    (select count(*) from public.ingest_offline_sales(v_reg, v_batch) r
      where r.outcome = 'landed'), 1);
  perform pg_temp.check_eq('and it stops being a problem',
    (select count(*) from public.pos_offline_problems(v_org)), 1);

  raise notice 'point of sale offline: all assertions passed';
end;
$$;

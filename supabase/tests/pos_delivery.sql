-- =====================================================================
-- Point of sale :: an address, a fee and a driver
--
-- The assertion this file is built around is the one that decides
-- whether the shop or the customer pays for the ride: a delivery fee
-- has to survive every discount on the bill. A 100% staff discount on
-- the food still owes the courier six ringgit, and an arithmetic that
-- lets the fee be discounted away is a shop paying a rider out of its
-- own margin without anybody deciding to.
--
-- The second is the ledger's: the fee lands on the invoice header's
-- `shipping_amount`, which 0013 posts to 4900 by itself. If it were a
-- line item it would be food revenue, would be counted in the item
-- ranking, and would earn loyalty points on money the shop hands
-- straight to somebody else.
--
-- Everything else here is the state machine — nothing leaves the shop
-- without a driver on it, a failure says why, and finished is finished.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_junior uuid;
  v_type   uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_outlet uuid;
  v_out2   uuid;
  v_reg    uuid;
  v_reg2   uuid;
  v_shift  uuid;
  v_cash   uuid;
  v_z1     uuid;
  v_z2     uuid;
  v_sale   uuid;
  v_sale2  uuid;
  v_sale3  uuid;
  v_del    uuid;
  v_drv    uuid;
  v_drv2   uuid;
  v_r      record;
  v_b      record;
  v_msg    text;
  v_inv    uuid;
begin
  v_org := pg_temp.test_org('Kedai Hantar Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  v_junior := pg_temp.another_user('junior@hantar.test');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_junior, 'sales');

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00, 5.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'CAWANGAN', 'The branch', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_out2;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out2, 'C2', 'Branch counter') returning id into v_reg2;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;

  perform public.set_outlet_channel(v_outlet, 'delivery', true);
  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- Five digits, whatever was typed
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a postcode is its digits',
    app.pos_postcode('Kuala Lumpur 58200'), '58200');
  perform pg_temp.check_eq('however they were spaced',
    app.pos_postcode('58 200'), '58200');
  perform pg_temp.check_true('and nothing at all is null',
    app.pos_postcode('  ') is null);

  -- ------------------------------------------------------------------
  -- Two zones, one of them the catch-all
  -- ------------------------------------------------------------------
  v_z1 := public.upsert_pos_delivery_zone(
    null, v_outlet, 'Taman Sri', array['58 200', '58000'],
    5.00, 20.00, 60.00, 30, 1, true);
  v_z2 := public.upsert_pos_delivery_zone(
    null, v_outlet, 'Anywhere else', '{}',
    12.00, 0, null, 60, 2, true);

  perform pg_temp.check_eq('a zone stores its postcodes normalised',
    (select z.postcodes[1] from public.pos_delivery_zones z where z.id = v_z1),
    '58000');
  perform pg_temp.check_eq('a named postcode picks its zone',
    app.pos_delivery_zone_for(v_outlet, '58200'), v_z1);
  perform pg_temp.check_eq('an unnamed one falls to the catch-all',
    app.pos_delivery_zone_for(v_outlet, '43300'), v_z2);
  perform pg_temp.check_eq('and so does no postcode at all',
    app.pos_delivery_zone_for(v_outlet, null), v_z2);

  -- ------------------------------------------------------------------
  -- Taking the address
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 2, 12.00);

  select * into v_r from public.set_pos_delivery(
    v_sale, '12 Jalan Sri 3', '012-3456789',
    'Taman Sri Indah', 'Kuala Lumpur', 'Wilayah Persekutuan', '58200',
    'Puan Aminah', 'Guardhouse will not let bikes through — call at the gate');

  perform pg_temp.check_eq('the address lands in the zone that names it',
    v_r.zone_name, 'Taman Sri');
  perform pg_temp.check_eq('and is charged what that zone charges',
    v_r.fee, 5.00);
  perform pg_temp.check_true('with nothing standing in the way of it',
    v_r.blocked_reason is null);
  perform pg_temp.check_eq('taking an address puts the bill on delivery',
    (select s.order_channel::text from public.pos_sales s where s.id = v_sale),
    'delivery');
  perform pg_temp.check_eq('the fee is on the bill',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale), 5.00);

  -- The assertion this file is built around, part one: the ride is
  -- added to the food rather than taken out of it.
  perform pg_temp.check_eq('and the total is the food plus the ride',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 29.00);

  -- ------------------------------------------------------------------
  -- Both halves of an address are required
  -- ------------------------------------------------------------------
  begin
    perform public.set_pos_delivery(v_sale, '   ', '012-3456789');
    raise exception 'FAIL took a delivery with no address';
  exception when check_violation then
    raise notice 'ok   a delivery needs somewhere to go';
  end;
  begin
    perform public.set_pos_delivery(v_sale, '12 Jalan Sri 3', '  ');
    raise exception 'FAIL took a delivery with no phone number';
  exception when check_violation then
    raise notice 'ok   and a number the driver can ring';
  end;

  -- ------------------------------------------------------------------
  -- Free above a threshold, the moment it is crossed
  -- ------------------------------------------------------------------
  --
  -- Derived on every recalculation rather than fixed at the door. A fee
  -- stored once would still be charging five ringgit on the order that
  -- just qualified for free delivery.
  perform public.add_pos_sale_line(v_sale, v_item, 3, 12.00);
  perform pg_temp.check_eq('crossing the free-delivery line drops the fee',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale), 0.00);
  perform pg_temp.check_eq('and the bill is the food alone',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 60.00);

  delete from public.pos_sale_lines l
   where l.sale_id = v_sale and l.line_no = 2;
  perform app.recalc_pos_sale(v_sale);
  perform pg_temp.check_eq('dropping back below it brings the fee back',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale), 5.00);

  -- ------------------------------------------------------------------
  -- A discount on the food is not a discount on the ride
  -- ------------------------------------------------------------------
  --
  -- The whole bill given away and the courier still has to be paid.
  perform public.discount_pos_sale(v_sale, 100, null, 'Complaint — whole bill');
  perform pg_temp.check_eq('a bill given away still owes the rider',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 5.00);
  perform public.discount_pos_sale(v_sale, 0, null, 'Put it back');
  perform pg_temp.check_eq('and putting the price back restores the total',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 29.00);

  -- ------------------------------------------------------------------
  -- Charging something else
  -- ------------------------------------------------------------------
  select * into v_r from public.set_pos_delivery(
    v_sale, '12 Jalan Sri 3', '012-3456789', null, null, null, '58200',
    null, null, null, 8.00);
  perform pg_temp.check_eq('a longer ride can be charged more',
    v_r.fee, 8.00);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 12.00);
  perform pg_temp.check_eq('and a typed fee is left where it was put',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale), 8.00);

  -- ------------------------------------------------------------------
  -- Charging less is a discount, whatever it is called on the screen
  -- ------------------------------------------------------------------
  insert into public.access_types (org_id, name)
  values (v_org, 'Till, no discounts') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write'), (v_type, 'inventory', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_junior;

  perform pg_temp.sign_in_as(v_junior);
  perform pg_temp.check_true('a cashier granted the till may work it',
    app.can_write_module(v_org, 'pos'));
  perform pg_temp.check_true('but may not discount',
    not app.can_discount_pos(v_org));
  begin
    perform public.set_pos_delivery(
      v_sale, '12 Jalan Sri 3', '012-3456789', null, null, null, '58200',
      null, null, null, 1.00);
    raise exception 'FAIL undercharged the zone without permission';
  exception when insufficient_privilege then
    raise notice 'ok   charging under the zone needs permission to discount';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- Back to the zone's own price for the rest of the file.
  select * into v_r from public.set_pos_delivery(
    v_sale, '12 Jalan Sri 3', '012-3456789', null, null, null, '58200');
  perform pg_temp.check_eq('and the zone price comes back',
    v_r.fee, 5.00);

  -- ------------------------------------------------------------------
  -- A minimum is checked when the money is taken
  -- ------------------------------------------------------------------
  v_sale2 := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale2, v_item, 1, 12.00);
  select * into v_r from public.set_pos_delivery(
    v_sale2, '9 Jalan Sri 1', '012-9999999', null, null, null, '58000');
  perform pg_temp.check_true('a short order says so, and by how much',
    v_r.blocked_reason like '%another 8.00%');
  begin
    perform public.complete_pos_sale(v_sale2, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 20.00)));
    raise exception 'FAIL rang up an order under the zone minimum';
  exception when check_violation then
    raise notice 'ok   and the till refuses it at the one moment it is final';
  end;
  perform public.add_pos_sale_line(v_sale2, v_item, 1, 12.00);
  perform pg_temp.check_true('adding the food clears the shortfall',
    app.pos_delivery_blocked(v_sale2) is null);

  -- ------------------------------------------------------------------
  -- Somebody to carry it
  -- ------------------------------------------------------------------
  v_drv := public.upsert_pos_driver(
    null, v_org, 'Hafiz', '013-1112222', 'Honda EX5', 'WXY 1234');
  v_drv2 := public.upsert_pos_driver(
    null, v_org, 'Branch rider', null, null, null, v_out2);

  select d.id into v_del from public.pos_deliveries d where d.sale_id = v_sale;

  begin
    perform public.set_pos_delivery_status(v_del, 'collected');
    raise exception 'FAIL sent food out with nobody carrying it';
  exception when check_violation then
    raise notice 'ok   nothing leaves the shop without a driver on it';
  end;

  begin
    perform public.assign_pos_delivery(v_del, v_drv2);
    raise exception 'FAIL gave a run to another outlet''s driver';
  exception when check_violation then
    raise notice 'ok   a driver kept to one outlet stays there';
  end;

  perform public.assign_pos_delivery(v_del, v_drv);
  perform pg_temp.check_eq('giving it to a driver moves it along',
    (select d.status::text from public.pos_deliveries d where d.id = v_del),
    'assigned');

  begin
    perform public.clear_pos_delivery(v_sale);
    raise exception 'FAIL deleted a run that was already out';
  exception when check_violation then
    raise notice 'ok   a run that happened is not undone by deleting it';
  end;

  -- ------------------------------------------------------------------
  -- The money, and where it lands in the ledger
  -- ------------------------------------------------------------------
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 41.00)));

  select s.invoice_id into v_inv from public.pos_sales s where s.id = v_sale;
  perform pg_temp.check_eq('the ride is shipping on the invoice, not food',
    (select d.shipping_amount from public.sales_documents d where d.id = v_inv),
    5.00);
  perform pg_temp.check_eq('and the invoice is the food plus the ride',
    (select d.total_amount from public.sales_documents d where d.id = v_inv),
    41.00);
  -- The lines are the food alone. A fee rung up as an item would be in
  -- here, in the item ranking, and in every promotion naming "all
  -- items".
  perform pg_temp.check_eq('the lines carry the food and nothing else',
    (select coalesce(sum(l.line_subtotal), 0)
       from public.sales_document_lines l where l.document_id = v_inv),
    36.00);
  -- `complete_pos_sale` returning at all is the ledger assertion:
  -- `post_sales_document_internal` refuses a journal that does not
  -- balance, and the receivable it debits is the header total.
  perform pg_temp.check_true('and the journal it posted balances',
    (select d.gl_entry_id from public.sales_documents d where d.id = v_inv)
      is not null);

  perform pg_temp.check_eq('a settled bill cannot change where it went',
    (select count(*) from public.pos_sales s
      where s.id = v_sale and s.status = 'completed'), 1);
  begin
    perform public.set_pos_delivery(v_sale, '1 Jalan Lain', '012-0000000');
    raise exception 'FAIL moved the address on a settled bill';
  exception when check_violation then
    raise notice 'ok   an issued invoice does not move house';
  end;

  -- ------------------------------------------------------------------
  -- The run, to the door
  -- ------------------------------------------------------------------
  perform public.set_pos_delivery_status(v_del, 'collected');
  perform public.set_pos_delivery_status(v_del, 'delivered');
  perform pg_temp.check_true('a delivered run has the moment it landed',
    (select d.delivered_at from public.pos_deliveries d where d.id = v_del)
      is not null);
  begin
    perform public.set_pos_delivery_status(v_del, 'failed', 'Changed my mind');
    raise exception 'FAIL moved a finished run';
  exception when check_violation then
    raise notice 'ok   and finished is finished';
  end;

  -- A failure has to say why. "Failed" on its own tells a shop nothing
  -- it can act on.
  select d.id into v_del from public.pos_deliveries d where d.sale_id = v_sale2;
  perform public.assign_pos_delivery(v_del, v_drv);
  begin
    perform public.set_pos_delivery_status(v_del, 'failed');
    raise exception 'FAIL recorded a failure with no reason';
  exception when check_violation then
    raise notice 'ok   a failed run says why';
  end;

  begin
    perform public.retire_pos_driver(v_drv);
    raise exception 'FAIL stood down a driver with food on the bike';
  exception when check_violation then
    raise notice 'ok   a driver with orders out cannot be stood down';
  end;

  perform public.set_pos_delivery_status(v_del, 'failed', 'Nobody home');
  perform pg_temp.check_eq('a failure keeps the reason as it was given',
    (select d.failure_reason from public.pos_deliveries d where d.id = v_del),
    'Nobody home');

  -- ------------------------------------------------------------------
  -- Folding one bill into another
  -- ------------------------------------------------------------------
  v_sale2 := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale2, v_item, 2, 12.00);
  perform public.set_pos_delivery(
    v_sale2, '4 Jalan Satu', '012-1111111', null, null, null, '58000');

  v_sale3 := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale3, v_item, 2, 12.00);
  perform public.set_pos_delivery(
    v_sale3, '7 Jalan Dua', '012-2222222', null, null, null, '58000');
  begin
    perform public.merge_pos_sales(v_sale2, v_sale3);
    raise exception 'FAIL merged two bills going to two houses';
  exception when check_violation then
    raise notice 'ok   two addresses on one bill is nobody''s decision';
  end;

  perform public.clear_pos_delivery(v_sale3);
  perform pg_temp.check_eq('clearing an address takes the fee with it',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale3), 0.00);
  perform public.merge_pos_sales(v_sale3, v_sale2);
  perform pg_temp.check_eq('and a merge carries the address across',
    (select d.address_line1 from public.pos_deliveries d
      where d.sale_id = v_sale3), '4 Jalan Satu');
  perform pg_temp.check_eq('with the fee on the bill it landed on',
    (select s.delivery_fee from public.pos_sales s where s.id = v_sale3), 5.00);

  -- ------------------------------------------------------------------
  -- What the pass and the office read
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the run still out is on the board',
    (select count(*) from public.pos_delivery_board(v_outlet) b
      where b.sale_id = v_sale3), 1);
  perform pg_temp.check_eq('and a run that landed is not',
    (select count(*) from public.pos_delivery_board(v_outlet) b
      where b.status = 'delivered'), 0);

  select * into v_b from public.pos_driver_runs(
    v_org, (now() at time zone 'Asia/Kuala_Lumpur')::date) r
   where r.driver_id = v_drv;
  perform pg_temp.check_eq('the driver''s day counts what landed',
    v_b.delivered, 1);
  perform pg_temp.check_eq('and what did not, separately',
    v_b.failed, 1);

  select * into v_b from public.pos_delivery_day(
    v_org, (now() at time zone 'Asia/Kuala_Lumpur')::date) d
   where d.outlet_id = v_outlet;
  perform pg_temp.check_eq('the outlet''s day counts every run',
    v_b.runs, 3);
  perform pg_temp.check_true('and adds up what the rides earned',
    v_b.fees > 0);

  -- ------------------------------------------------------------------
  -- A shop that does not deliver cannot record one
  -- ------------------------------------------------------------------
  perform public.set_outlet_channel(v_out2, 'delivery', false);
  v_shift := public.open_pos_shift(v_reg2, 50.00);
  v_sale3 := public.open_pos_sale(v_reg2);
  perform public.add_pos_sale_line(v_sale3, v_item, 1, 12.00);
  begin
    perform public.set_pos_delivery(v_sale3, '1 Jalan Jauh', '012-3333333');
    raise exception 'FAIL delivered from an outlet that does not';
  exception when check_violation then
    raise notice 'ok   an outlet only records what it accepts';
  end;
end $$;

rollback;

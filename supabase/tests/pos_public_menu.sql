-- =====================================================================
-- Point of sale :: the menu a phone can order from
--
-- The assertion this file is built around is the one that decides
-- whether a public endpoint is safe to have: the price is the shop's.
-- `place_public_pos_order` takes an item and a quantity and nothing
-- else, and a browser that sends a price is ignored — because a price
-- arriving from a browser is a price somebody typed.
--
-- The second is that a token is the whole credential and reaches
-- exactly one outlet's menu: no organization id crosses the boundary,
-- an expired link is refused, and a single-use one closes behind the
-- order it carried.
--
-- The third is that the phone and the till agree about what is on. 0258
-- decides, at the moment of ordering rather than at the moment the page
-- was loaded, so nobody orders breakfast at four.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_drink  uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_area   uuid;
  v_t7     uuid;
  v_grp    uuid;
  v_mod    uuid;
  v_link   record;
  v_dead   record;
  v_once   record;
  v_tbl    record;
  v_order  record;
  v_n      integer;
  v_sched  uuid;
  v_txt    text;
begin
  v_org := pg_temp.test_org('Kedai QR Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00, 5.00)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TEH', 'Teh tarik', 'service', false, 'C62', 3.00, 1.00)
  returning id into v_drink;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);

  insert into public.pos_floor_areas (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'MAIN', 'Dining room') returning id into v_area;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_outlet, v_area, 'T7', 4) returning id into v_t7;

  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'PEDAS', 'How spicy?', 0, 1) returning id into v_grp;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta)
  values (v_org, v_grp, 'EXTRA', 'Extra sambal', 1.50) returning id into v_mod;
  insert into public.item_modifier_groups (org_id, item_id, group_id)
  values (v_org, v_item, v_grp);

  -- ------------------------------------------------------------------
  -- A sticker on a table
  -- ------------------------------------------------------------------
  begin
    perform public.upsert_pos_menu_link(v_outlet, 'table', null);
    raise exception 'FAIL published a table QR that names no table';
  exception when check_violation then
    raise notice 'ok   a table QR has to say which table';
  end;

  select * into v_link from public.upsert_pos_menu_link(
    v_outlet, 'table', v_t7, null, 'Table 7 sticker');
  perform pg_temp.check_true('a published link has a token to reach it by',
    length(v_link.token) > 16);

  -- ------------------------------------------------------------------
  -- What the phone sees
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the menu comes back for the token alone',
    (select count(*) from public.public_pos_menu(v_link.token)), 2);
  perform pg_temp.check_eq('and knows which table it is stuck to',
    (select distinct m.table_code from public.public_pos_menu(v_link.token) m),
    'T7');
  perform pg_temp.check_eq('with the shop''s own price',
    (select m.unit_price from public.public_pos_menu(v_link.token) m
      where m.item_id = v_item), 12.00);
  perform pg_temp.check_eq('and the questions the plate comes with',
    (select count(*) from public.public_pos_menu_modifiers(v_link.token, v_item)), 1);

  begin
    perform * from public.public_pos_menu('not-a-real-token');
    raise exception 'FAIL served a menu to a token nobody issued';
  exception when no_data_found then
    raise notice 'ok   a token nobody issued reaches nothing';
  end;

  -- ------------------------------------------------------------------
  -- A shop that has not opened
  -- ------------------------------------------------------------------
  begin
    perform * from public.place_public_pos_order(
      v_link.token, jsonb_build_array(jsonb_build_object('item', v_item)));
    raise exception 'FAIL took an order into a till with no shift';
  exception when check_violation then
    raise notice 'ok   a shop with no shift open is closed';
  end;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- The order
  -- ------------------------------------------------------------------
  select * into v_order from public.place_public_pos_order(
    v_link.token,
    jsonb_build_array(
      jsonb_build_object('item', v_item, 'quantity', 2,
        'modifiers', jsonb_build_array(jsonb_build_object('modifier', v_mod))),
      jsonb_build_object('item', v_drink, 'quantity', 1, 'note', 'kurang manis')),
    'Aminah', '012-3456789', 'Please hurry');

  perform pg_temp.check_true('an order comes back with a number to quote',
    v_order.sale_no is not null);
  -- 2 x 12.00 + 2 x 1.50 sambal + 3.00 teh
  perform pg_temp.check_eq('and the shop''s arithmetic, not the phone''s',
    v_order.total, 30.00);
  perform pg_temp.check_eq('it lands as a parked bill on the till',
    (select s.status::text from public.pos_sales s where s.id = v_order.sale_id),
    'parked');
  perform pg_temp.check_eq('on the table the sticker is on',
    (select s.table_id from public.pos_sales s where s.id = v_order.sale_id), v_t7);
  perform pg_temp.check_eq('with the name to call out',
    (select s.guest_name from public.pos_sales s where s.id = v_order.sale_id),
    'Aminah');
  perform pg_temp.check_eq('and the note the customer typed',
    (select s.note from public.pos_sales s where s.id = v_order.sale_id),
    'Please hurry');

  -- The assertion this file exists for.
  select * into v_order from public.place_public_pos_order(
    v_link.token,
    jsonb_build_array(jsonb_build_object(
      'item', v_drink, 'quantity', 1, 'unit_price', 0.01, 'price', 0.01)));
  perform pg_temp.check_eq('a price sent by a phone is ignored',
    (select l.unit_price from public.pos_sale_lines l
      where l.sale_id = v_order.sale_id order by l.line_no desc limit 1), 3.00);

  -- A second scan of the same sticker joins the bill already on the
  -- table rather than opening a second one.
  perform pg_temp.check_eq('and a second scan joins the bill already there',
    (select count(*) from public.pos_sales s
      where s.table_id = v_t7 and s.status = 'parked'), 1);

  -- ------------------------------------------------------------------
  -- What the kitchen took off
  -- ------------------------------------------------------------------
  perform public.stop_pos_item(v_outlet, v_drink, 'Habis');
  begin
    perform * from public.place_public_pos_order(
      v_link.token, jsonb_build_array(jsonb_build_object('item', v_drink)));
    raise exception 'FAIL sold something the kitchen had taken off';
  exception when check_violation then
    raise notice 'ok   a sold-out dish cannot be ordered from a phone';
  end;
  perform pg_temp.check_true('and the phone is told why on the menu',
    (select m.off_reason from public.public_pos_menu(v_link.token) m
      where m.item_id = v_drink) is not null);
  perform public.resume_pos_item(v_outlet, v_drink);

  -- ------------------------------------------------------------------
  -- Breakfast stops at eleven, on a phone too
  -- ------------------------------------------------------------------
  -- A window that is definitely not now, so the dish is off whatever
  -- time this test runs.
  v_sched := public.upsert_pos_menu_schedule(
    v_org, 'Impossible hour',
    array[extract(isodow from
      (now() at time zone 'Asia/Kuala_Lumpur') + interval '1 day')::smallint],
    time '00:00', time '00:01',
    null, null,
    array[v_drink]::uuid[]);
  begin
    perform * from public.place_public_pos_order(
      v_link.token, jsonb_build_array(jsonb_build_object('item', v_drink)));
    raise exception 'FAIL sold something outside the hours it is offered';
  exception when check_violation then
    raise notice 'ok   the scheduler decides for the phone as well';
  end;
  perform public.retire_pos_menu_schedule(v_sched);

  -- ------------------------------------------------------------------
  -- A link that stops working
  -- ------------------------------------------------------------------
  select * into v_dead from public.upsert_pos_menu_link(
    v_outlet, 'takeaway', null, null, 'Expired poster',
    now() - interval '1 hour');
  begin
    perform * from public.public_pos_menu(v_dead.token);
    raise exception 'FAIL served a menu from an expired link';
  exception when check_violation then
    raise notice 'ok   an expired link is refused, in a sentence';
  end;

  select * into v_once from public.upsert_pos_menu_link(
    v_outlet, 'takeaway', null, null, 'One-time link', null, true);
  perform * from public.place_public_pos_order(
    v_once.token, jsonb_build_array(jsonb_build_object('item', v_item)));
  perform pg_temp.check_true('a single-use link records that it was used',
    (select l.used_at from public.pos_menu_links l where l.id = v_once.id)
      is not null);
  begin
    perform * from public.place_public_pos_order(
      v_once.token, jsonb_build_array(jsonb_build_object('item', v_item)));
    raise exception 'FAIL used a single-use link twice';
  exception when check_violation then
    raise notice 'ok   and closes behind the order it carried';
  end;

  perform public.retire_pos_menu_link(v_link.id);
  begin
    perform * from public.public_pos_menu(v_link.token);
    raise exception 'FAIL a retired sticker still worked';
  exception when no_data_found then
    raise notice 'ok   a sticker switched off stops working at once';
  end;

  -- ------------------------------------------------------------------
  -- A link that needs an address
  -- ------------------------------------------------------------------
  perform public.set_outlet_channel(v_outlet, 'delivery', true);
  select * into v_tbl from public.upsert_pos_menu_link(
    v_outlet, 'delivery', null, null, 'Delivery link');
  begin
    perform * from public.place_public_pos_order(
      v_tbl.token, jsonb_build_array(jsonb_build_object('item', v_item)));
    raise exception 'FAIL took a delivery order with nowhere to send it';
  exception when check_violation then
    raise notice 'ok   a delivery order needs an address';
  end;

  perform public.upsert_pos_delivery_zone(
    null, v_outlet, 'Taman Sri', array['58200'], 5.00, 0, null, 30, 1, true);
  select * into v_order from public.place_public_pos_order(
    v_tbl.token,
    jsonb_build_array(jsonb_build_object('item', v_item, 'quantity', 2)),
    'Siti', '012-9999999', null,
    '12 Jalan Sri 3', null, 'Kuala Lumpur', null, '58200');
  perform pg_temp.check_eq('a delivery order is charged for the ride',
    v_order.fee, 5.00);
  perform pg_temp.check_eq('and the total carries it',
    v_order.total, 29.00);
  perform pg_temp.check_eq('and it is on the delivery board',
    (select count(*) from public.pos_delivery_board(v_outlet) b
      where b.sale_id = v_order.sale_id), 1);

  -- ------------------------------------------------------------------
  -- And it is an ordinary bill from here on
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the receipt renders for an order from a phone',
    length(public.pos_receipt_text(v_order.sale_id)) > 50);
  perform pg_temp.check_eq('and the till sees it among the open orders',
    (select count(*) from public.pos_open_orders(v_outlet) o
      where o.sale_id = v_order.sale_id), 1);

  -- ------------------------------------------------------------------
  -- The links a shop can see
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.pos_menu_links_admin(v_org);
  perform pg_temp.check_eq('every link this shop published is listed', v_n, 4);
  -- One, not two: both scans of the table sticker joined the bill
  -- already on table seven, which is the row above asserted from the
  -- other end.
  perform pg_temp.check_eq('with the bills that came in through it',
    (select l.orders from public.pos_menu_links_admin(v_org) l
      where l.id = v_link.id), 1);
end $$;

rollback;

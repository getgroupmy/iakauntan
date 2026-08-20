-- =====================================================================
-- Point of sale :: the customer works the till
--
-- A kiosk order is an ordinary sale posting an ordinary invoice. Three
-- rules make it a kiosk, and each is asserted here because each is the
-- kind of thing that would otherwise be enforced only by a screen:
--
--   * no cash. A machine in a lobby cannot give change, and a shift
--     that counted a drawer the kiosk could add to would be counting
--     money nobody put in it.
--
--   * a number, and never the same one twice. It is the only thing
--     connecting a customer who has walked away from the machine to
--     their food.
--
--   * paid, then cooked. The kitchen is told when the money arrives,
--     not when somebody taps a button, because at a kiosk there is
--     nobody to tap it.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_item   uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_till   uuid;
  v_kiosk  uuid;
  v_cash   uuid;
  v_card   uuid;
  v_grill  uuid;
  v_shift  uuid;
  v_s1     uuid;
  v_s2     uuid;
  v_no1    integer;
  v_no2    integer;
  v_tk     uuid;
begin
  v_org := pg_temp.test_org('Ayam Segera Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'BURGER', 'Burger ayam', 'stock', true, 'C62', 12.00, 5.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'QSR', 'The shop', 'kiosk', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Front counter') returning id into v_till;
  insert into public.pos_registers (org_id, outlet_id, code, name, is_kiosk)
  values (v_org, v_outlet, 'K1', 'Kiosk one', true) returning id into v_kiosk;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true) returning id into v_cash;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CARD', 'Card', 'card', '04', false, false) returning id into v_card;
  insert into public.pos_kitchen_stations (org_id, outlet_id, code, name, is_default)
  values (v_org, v_outlet, 'HOT', 'Grill', true) returning id into v_grill;

  -- A kiosk still needs a shift. One selling into a day nobody opened
  -- is a day whose takings belong to no count at all.
  v_shift := public.open_pos_shift(v_kiosk, 0);

  begin
    perform public.start_kiosk_order(v_till);
    raise exception 'FAIL started a kiosk order on a staff till';
  exception when check_violation then
    raise notice 'ok   a staff till will not take a kiosk order';
  end;

  v_s1 := public.start_kiosk_order(v_kiosk);
  perform public.add_pos_sale_line(v_s1, v_item, 1, 12.00);
  perform pg_temp.check_true('a kiosk order knows it is one',
    (select s.is_kiosk from public.pos_sales s where s.id = v_s1));

  begin
    perform * from public.complete_kiosk_order(v_s1, v_cash);
    raise exception 'FAIL took cash at a machine with no drawer';
  exception when check_violation then
    raise notice 'ok   a kiosk will not take cash';
  end;

  select r.order_no into v_no1
    from public.complete_kiosk_order(v_s1, v_card, 12.00, 'AUTH123') r;
  perform pg_temp.check_eq('the first order of the day is number one', v_no1, 1);
  perform pg_temp.check_true('and it posted an invoice like any other',
    (select d.status from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_s1) = 'completed');
  perform pg_temp.check_true('with the card authorisation on the tender',
    (select t.reference from public.pos_tenders t where t.sale_id = v_s1) = 'AUTH123');
  -- Paid, then cooked. Nobody tapped anything.
  perform pg_temp.check_eq('and the kitchen was told without anybody tapping',
    (select count(*) from public.pos_kitchen_tickets k where k.sale_id = v_s1), 1);

  v_s2 := public.start_kiosk_order(v_kiosk);
  perform public.add_pos_sale_line(v_s2, v_item, 2, 12.00);
  select r.order_no into v_no2 from public.complete_kiosk_order(v_s2, v_card) r;
  perform pg_temp.check_eq('the next order is two', v_no2, 2);
  -- The one that puts two customers at the counter for one bag.
  perform pg_temp.check_eq('and nobody is given a number somebody else has',
    (select count(distinct s.order_no) from public.pos_sales s
      where s.outlet_id = v_outlet and s.order_no is not null), 2);

  -- ------------------------------------------------------------------
  -- The board the customer watches
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('both orders are up', 
    (select count(*) from public.kiosk_order_board(v_outlet)), 2);
  perform pg_temp.check_eq('and both are being made',
    (select count(*) from public.kiosk_order_board(v_outlet) b where b.state = 'making'), 2);

  select k.id into v_tk from public.pos_kitchen_tickets k where k.sale_id = v_s1;
  perform public.bump_kitchen_ticket(v_tk, 'ready');
  perform pg_temp.check_true('one is ready',
    (select b.state from public.kiosk_order_board(v_outlet) b where b.order_no = v_no1) = 'ready');
  perform public.bump_kitchen_ticket(v_tk, 'served');
  perform pg_temp.check_eq('and a collected order leaves the board',
    (select count(*) from public.kiosk_order_board(v_outlet) b where b.order_no = v_no1), 0);
  perform pg_temp.check_eq('while the other is still waiting',
    (select count(*) from public.kiosk_order_board(v_outlet)), 1);

  raise notice 'point of sale kiosk: all assertions passed';
end;
$$;

rollback;

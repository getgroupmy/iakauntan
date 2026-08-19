-- =====================================================================
-- Point of sale :: the dining room
--
-- The assertion this file is built around is the one that costs money
-- when it fails: tapping a table that already has a bill on it returns
-- THAT bill. A waiter adding a round of drinks to table seven means
-- "the bill on table seven". Opening a second one would leave the first
-- parked and invisible, and the party would be charged twice or not at
-- all depending on which bill somebody happened to settle.
--
-- The rest follows from table state being derived rather than stored:
-- a table is occupied exactly when a parked sale points at it, so
-- moving a party frees the table they left in the same statement that
-- occupies the one they went to, and there is no second copy to fall
-- out of step.
-- =====================================================================
\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_item   uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_out2   uuid;
  v_reg    uuid;
  v_reg2   uuid;
  v_area   uuid;
  v_t7     uuid;
  v_t8     uuid;
  v_bar    uuid;
  v_far    uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_cash   uuid;
begin
  v_org := pg_temp.test_org('Warung Sedap Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak', 'stock', true, 'C62', 12.00, 5.00)
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
  values (v_org, v_outlet, 'T1', 'Waiter tablet') returning id into v_reg;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out2, 'T2', 'Branch till') returning id into v_reg2;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);

  -- ------------------------------------------------------------------
  -- The room
  -- ------------------------------------------------------------------
  insert into public.pos_floor_areas (org_id, outlet_id, code, name, sort_order)
  values (v_org, v_outlet, 'MAIN', 'Dining room', 1) returning id into v_area;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats, pos_x, pos_y)
  values (v_org, v_outlet, v_area, 'T7', 4, 10, 20) returning id into v_t7;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_outlet, v_area, 'T8', 2) returning id into v_t8;
  insert into public.pos_tables (org_id, outlet_id, code, seats, shape)
  values (v_org, v_outlet, 'BAR1', 1, 'bar') returning id into v_bar;
  insert into public.pos_tables (org_id, outlet_id, code, seats)
  values (v_org, v_out2, 'F1', 4) returning id into v_far;

  -- A plan is drawn per outlet, so a table cannot be filed under a room
  -- in a different building.
  begin
    insert into public.pos_tables (org_id, outlet_id, area_id, code)
    values (v_org, v_out2, v_area, 'X1');
    raise exception 'FAIL put a table in another outlet''s area';
  exception when check_violation then
    raise notice 'ok   a table cannot sit in another outlet''s area';
  end;

  -- ------------------------------------------------------------------
  -- Sitting somebody down
  -- ------------------------------------------------------------------
  v_shift := public.open_pos_shift(v_reg, 100.00);

  perform pg_temp.check_eq('an empty room shows every table free',
    (select count(*) from public.pos_floor_plan(v_outlet) f where f.sale_id is null), 3);

  v_sale := public.seat_table(v_reg, v_t7, 3);
  perform pg_temp.check_true('seating opens a bill on the table',
    (select s.table_id from public.pos_sales s where s.id = v_sale) = v_t7);
  perform pg_temp.check_eq('with the covers the waiter counted',
    (select s.covers from public.pos_sales s where s.id = v_sale), 3);

  -- The assertion the whole function exists for.
  perform pg_temp.check_true('tapping the table again returns the same bill',
    public.seat_table(v_reg, v_t7) = v_sale);
  perform pg_temp.check_eq('and does not open a second one',
    (select count(*) from public.pos_sales s
      where s.table_id = v_t7 and s.status = 'parked'), 1);

  -- A two-top that became a five-top is the normal case, not an error.
  perform public.seat_table(v_reg, v_t7, 5);
  perform pg_temp.check_eq('covers can be corrected on the way past',
    (select s.covers from public.pos_sales s where s.id = v_sale), 5);

  perform pg_temp.check_eq('an uncounted table assumes it is full',
    (select s.covers from public.pos_sales s
      where s.id = public.seat_table(v_reg, v_t8)), 2);

  -- A waiter cannot seat a table they are not standing in.
  begin
    perform public.seat_table(v_reg2, v_t7);
    raise exception 'FAIL seated a table from another outlet''s till';
  exception when check_violation then
    raise notice 'ok   a waiter cannot seat a table in another outlet';
  end;

  -- ------------------------------------------------------------------
  -- The plan a waiter looks at
  -- ------------------------------------------------------------------
  perform public.add_pos_sale_line(v_sale, v_item, 2, 12.00);
  perform pg_temp.check_eq('the plan shows what is on the table',
    (select f.total_amount from public.pos_floor_plan(v_outlet) f
      where f.sale_id = v_sale), 24.00);
  perform pg_temp.check_eq('and how many lines are on the bill',
    (select f.line_count from public.pos_floor_plan(v_outlet) f
      where f.sale_id = v_sale), 1);
  perform pg_temp.check_eq('and how long they have been sitting there',
    (select f.minutes_seated from public.pos_floor_plan(v_outlet) f
      where f.sale_id = v_sale), 0);
  perform pg_temp.check_eq('two tables are taken and one is free',
    (select count(*) from public.pos_floor_plan(v_outlet) f where f.sale_id is null), 1);
  perform pg_temp.check_eq('the branch is a different room entirely',
    (select count(*) from public.pos_floor_plan(v_out2)), 1);

  -- ------------------------------------------------------------------
  -- Moving a party
  -- ------------------------------------------------------------------
  perform public.move_pos_sale(v_sale, v_bar);
  perform pg_temp.check_true('the bill went with them',
    (select s.table_id from public.pos_sales s where s.id = v_sale) = v_bar);
  perform pg_temp.check_eq('what they ordered came too',
    (select f.total_amount from public.pos_floor_plan(v_outlet) f
      where f.sale_id = v_sale), 24.00);
  -- Occupancy is derived, so freeing the old table is not a second
  -- thing somebody has to remember to do.
  perform pg_temp.check_eq('and the table they left is free in the same breath',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_t7 and f.sale_id is null), 1);

  begin
    perform public.move_pos_sale(v_sale, v_far);
    raise exception 'FAIL moved a bill to another outlet';
  exception when check_violation then
    raise notice 'ok   a bill cannot move to a table in another outlet';
  end;
  perform pg_temp.check_true('and it stayed where it was',
    (select s.table_id from public.pos_sales s where s.id = v_sale) = v_bar);

  -- A bill can leave the room and still be a bill: that is takeaway.
  perform public.move_pos_sale(v_sale, null);
  perform pg_temp.check_true('a takeaway bill sits at no table',
    (select s.table_id from public.pos_sales s where s.id = v_sale) is null);
  perform pg_temp.check_eq('so the bar is free again',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_bar and f.sale_id is null), 1);

  -- ------------------------------------------------------------------
  -- And it is still an ordinary sale
  -- ------------------------------------------------------------------
  -- Nothing about a dining room changes the money. The bill posts the
  -- same invoice and receipt a counter sale does, and the table is
  -- released because the sale is no longer parked.
  perform public.move_pos_sale(v_sale, v_t7);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true) returning id into v_cash;
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 24.00)));
  perform pg_temp.check_true('a table bill posts an invoice like any other',
    (select d.status::text from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale) = 'completed');
  perform pg_temp.check_eq('and settling it clears the table',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_t7 and f.sale_id is not null), 0);

  raise notice 'point of sale dining room: all assertions passed';
end;
$$;

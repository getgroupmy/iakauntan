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
  v_reg3   uuid;
  v_shift3 uuid;
  v_claim  uuid;
  v_st3    uuid;
  v_area   uuid;
  v_t7     uuid;
  v_t8     uuid;
  v_bar    uuid;
  v_far    uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_sale2  uuid;
  v_cash   uuid;
  v_spice  uuid;
  v_extra  uuid;
  v_mild   uuid;
  v_hot    uuid;
  v_egg    uuid;
  v_nocuc  uuid;
  v_line   uuid;
  v_lm     uuid;
  v_cat    uuid;
  v_teh    uuid;
  v_hotst  uuid;
  v_barst  uuid;
  v_tk     uuid;
  v_split  uuid;
  v_void   uuid;
  v_vline  uuid;
  v_msg    text;
  v_l1     uuid;
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
  -- The counter in the same room as the waiter's tablet. A restaurant
  -- has both, and the whole point of `claim_pos_sale` is what happens
  -- when a bill has to move between them.
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Front counter') returning id into v_reg3;
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

  -- Called once into a variable, not inlined into the subquery's WHERE.
  -- `seat_table` is volatile, so a planner free to evaluate it per row
  -- opens a bill per row and matches none of them -- which is exactly
  -- what an earlier version of this line did.
  v_sale2 := public.seat_table(v_reg, v_t8);
  perform pg_temp.check_eq('an uncounted table assumes it is full',
    (select s.covers from public.pos_sales s where s.id = v_sale2), 2);

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

  -- ------------------------------------------------------------------
  -- What is on the plate
  -- ------------------------------------------------------------------
  -- A modifier belongs to a line, not to the bill. One plate is one
  -- line at one price -- which is both what the kitchen needs on a
  -- docket and what the customer expects to read.
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'SPICE', 'Pedas', 1, 1) returning id into v_spice;
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'EXTRA', 'Tambah', 0, 2) returning id into v_extra;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta)
  values (v_org, v_spice, 'MILD', 'Kurang pedas', 0) returning id into v_mild;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta)
  values (v_org, v_spice, 'HOT', 'Extra pedas', 0) returning id into v_hot;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta)
  values (v_org, v_extra, 'EGG', 'Telur mata', 1.50) returning id into v_egg;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta)
  values (v_org, v_extra, 'NOCUC', 'Tiada timun', 0) returning id into v_nocuc;
  insert into public.item_modifier_groups (org_id, item_id, group_id)
  values (v_org, v_item, v_spice), (v_org, v_item, v_extra);

  v_sale := public.seat_table(v_reg, v_t8, 2);
  v_line := public.add_pos_sale_line(v_sale, v_item, 2, 12.00);
  perform pg_temp.check_eq('two plates at the menu price',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 24.00);
  perform pg_temp.check_true('and no base price is kept while there is nothing to keep',
    (select l.base_unit_price from public.pos_sale_lines l where l.id = v_line) is null);

  v_lm := public.add_line_modifier(v_line, v_egg);
  perform pg_temp.check_eq('the menu price is remembered once a modifier lands',
    (select l.base_unit_price from public.pos_sale_lines l where l.id = v_line), 12.0000);
  perform pg_temp.check_eq('the plate costs the menu price plus the egg',
    (select l.unit_price from public.pos_sale_lines l where l.id = v_line), 13.5000);
  perform pg_temp.check_eq('and the bill is two of those', 
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 27.00);
  -- The whole reason a modifier is not a second line.
  perform pg_temp.check_eq('it is still one line, not two',
    (select count(*) from public.pos_sale_lines l where l.sale_id = v_sale), 1);

  perform public.add_line_modifier(v_line, v_egg);
  perform pg_temp.check_eq('asked for twice is two eggs',
    (select m.quantity from public.pos_sale_line_modifiers m where m.id = v_lm), 2);
  perform pg_temp.check_eq('at another one fifty a plate',
    (select l.unit_price from public.pos_sale_lines l where l.id = v_line), 15.0000);

  -- Two eggs already fills a group that takes two.
  begin
    perform public.add_line_modifier(v_line, v_nocuc);
    raise exception 'FAIL exceeded the group maximum';
  exception when check_violation then
    raise notice 'ok   the group maximum is a hard stop';
  end;

  perform public.remove_line_modifier(v_lm);
  perform pg_temp.check_eq('taking the eggs off restores the menu price',
    (select l.unit_price from public.pos_sale_lines l where l.id = v_line), 12.0000);
  perform pg_temp.check_eq('and the bill with it',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 24.00);

  -- A question a cook cannot guess the answer to.
  perform pg_temp.check_eq('one required choice is still open',
    (select count(*) from public.pos_line_modifier_gaps(v_sale)), 1);
  perform pg_temp.check_true('and it is the one that has to be answered',
    (select g.group_name from public.pos_line_modifier_gaps(v_sale) g) = 'Pedas');
  perform public.add_line_modifier(v_line, v_mild);
  perform pg_temp.check_eq('answering it closes the gap',
    (select count(*) from public.pos_line_modifier_gaps(v_sale)), 0);
  perform pg_temp.check_eq('and a choice worth nothing changes no price',
    (select l.unit_price from public.pos_sale_lines l where l.id = v_line), 12.0000);

  begin
    perform public.add_line_modifier(v_line, v_hot);
    raise exception 'FAIL took two answers to a choose-one question';
  exception when check_violation then
    raise notice 'ok   it cannot be both mild and hot';
  end;

  -- The snapshot. A menu edit tonight must not re-price a plate that
  -- was ordered an hour ago.
  perform public.add_line_modifier(v_line, v_egg);
  update public.pos_modifiers set price_delta = 99.00 where id = v_egg;
  -- Re-priced deliberately, so this asserts the snapshot rather than
  -- the absence of anything having recalculated.
  perform app.reprice_pos_line(v_line);
  perform pg_temp.check_eq('what was ordered was priced when it was ordered',
    (select l.unit_price from public.pos_sale_lines l where l.id = v_line), 13.5000);

  -- And the plate owns its modifiers.
  delete from public.pos_sale_lines where id = v_line;
  perform pg_temp.check_eq('taking the plate off takes the egg with it',
    (select count(*) from public.pos_sale_line_modifiers m where m.line_id = v_line), 0);

  -- ------------------------------------------------------------------
  -- The kitchen gets told once
  -- ------------------------------------------------------------------
  insert into public.item_categories (org_id, code, name)
  values (v_org, 'DRINK', 'Minuman') returning id into v_cat;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, category_id)
  values (v_org, 'TEH', 'Teh tarik', 'stock', true, 'C62', 3.00, 1.00, v_cat)
  returning id into v_teh;

  insert into public.pos_kitchen_stations
    (org_id, outlet_id, code, name, is_default, sort_order)
  values (v_org, v_outlet, 'HOT', 'Dapur', true, 1) returning id into v_hotst;
  insert into public.pos_kitchen_stations (org_id, outlet_id, code, name, sort_order)
  values (v_org, v_outlet, 'BAR', 'Bar', 2) returning id into v_barst;
  insert into public.category_kitchen_stations (org_id, category_id, station_id)
  values (v_org, v_cat, v_barst);

  perform pg_temp.check_true('a dish with no rule goes to the default station',
    app.pos_route_item(v_outlet, v_item) = v_hotst);
  perform pg_temp.check_true('drinks go to the bar by category',
    app.pos_route_item(v_outlet, v_teh) = v_barst);
  insert into public.item_kitchen_stations (org_id, item_id, station_id)
  values (v_org, v_teh, v_hotst);
  perform pg_temp.check_true('and a rule on the dish itself beats its category',
    app.pos_route_item(v_outlet, v_teh) = v_hotst);
  delete from public.item_kitchen_stations where item_id = v_teh;

  v_sale := public.seat_table(v_reg, v_bar, 2);
  v_line := public.add_pos_sale_line(v_sale, v_item, 2, 12.00);
  perform public.add_pos_sale_line(v_sale, v_teh, 2, 3.00);

  -- A cook cannot guess "choose one".
  begin
    perform * from public.send_order_to_kitchen(v_sale);
    raise exception 'FAIL sent an order with a choice still to make';
  exception when check_violation then
    raise notice 'ok   an unanswered required choice does not reach the kitchen';
  end;
  perform public.add_line_modifier(v_line, v_mild);

  perform pg_temp.check_eq('one send makes one docket per station',
    (select count(*) from public.send_order_to_kitchen(v_sale)), 2);
  perform pg_temp.check_true('with the choice written on the food docket',
    (select kl.modifiers from public.pos_kitchen_ticket_lines kl
      join public.pos_kitchen_tickets k on k.id = kl.ticket_id
     where k.station_id = v_hotst and k.sale_id = v_sale) = 'Kurang pedas');

  -- The assertion this whole stage is built around. A send that
  -- reissued the bill would have the first course cooked twice, and the
  -- second plate is a cost nothing downstream ever accounts for.
  perform pg_temp.check_eq('sending again sends nothing, because nothing is new',
    (select count(*) from public.send_order_to_kitchen(v_sale)), 0);
  perform pg_temp.check_eq('the kitchen still has two dockets, not four',
    (select count(*) from public.pos_kitchen_tickets k where k.sale_id = v_sale), 2);
  perform pg_temp.check_eq('and four plates in total, not eight',
    (select sum(kl.quantity) from public.pos_kitchen_ticket_lines kl
      join public.pos_kitchen_tickets k on k.id = kl.ticket_id
     where k.sale_id = v_sale), 4);

  -- A later round is its own docket, not an addition to one that may
  -- already be cooking.
  perform public.add_pos_sale_line(v_sale, v_teh, 1, 3.00);
  perform pg_temp.check_eq('a second round is one new docket',
    (select count(*) from public.send_order_to_kitchen(v_sale)), 1);
  perform pg_temp.check_eq('at the bar, alongside the first',
    (select count(*) from public.pos_kitchen_tickets k
      where k.sale_id = v_sale and k.station_id = v_barst), 2);
  perform pg_temp.check_eq('and the bar screen shows both',
    (select count(*) from public.kitchen_display(v_barst)), 2);

  select k.id into v_tk from public.pos_kitchen_tickets k
   where k.sale_id = v_sale and k.station_id = v_hotst;
  perform public.bump_kitchen_ticket(v_tk, 'cooking');
  perform pg_temp.check_true('the clock starts when somebody picks it up',
    (select k.started_at is not null from public.pos_kitchen_tickets k where k.id = v_tk));
  perform public.bump_kitchen_ticket(v_tk, 'ready');
  begin
    perform public.bump_kitchen_ticket(v_tk, 'new');
    raise exception 'FAIL sent a ticket backwards';
  exception when check_violation then
    raise notice 'ok   a ticket goes forward, or not at all';
  end;
  perform public.bump_kitchen_ticket(v_tk, 'served');
  perform pg_temp.check_eq('a served ticket leaves the screen',
    (select count(*) from public.kitchen_display(v_hotst) d where d.ticket_id = v_tk), 0);

  -- ------------------------------------------------------------------
  -- Splitting the bill
  -- ------------------------------------------------------------------
  -- Evenly first, because it moves nothing: one meal is one supply and
  -- one invoice, settled by several tenders.
  perform pg_temp.check_eq('the bill so far',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 33.00);
  perform pg_temp.check_eq('three ways is three shares',
    (select count(*) from public.pos_even_split(v_sale, 3)), 3);
  -- The property that matters. The shares are only how it is reached.
  perform pg_temp.check_eq('and they add up to the bill exactly',
    (select sum(e.amount) from public.pos_even_split(v_sale, 3) e), 33.00);

  -- A bill that does not divide. 33.00 does; 10.00 three ways does not.
  perform public.add_pos_sale_line(v_sale, v_teh, 1, 1.00);
  perform pg_temp.check_eq('an awkward total still adds up exactly',
    (select sum(e.amount) from public.pos_even_split(v_sale, 3) e),
    (select s.total_amount from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_true('with the odd sen on the first share',
    (select e.amount from public.pos_even_split(v_sale, 3) e where e.share_no = 1)
      >= (select e.amount from public.pos_even_split(v_sale, 3) e where e.share_no = 3));

  -- By item, which does move things.
  select l.id into v_l1 from public.pos_sale_lines l
   where l.sale_id = v_sale and l.item_id = v_item;
  v_split := public.split_pos_sale(v_sale, array[v_l1]);
  perform pg_temp.check_true('the second bill is on the same table',
    (select s.table_id from public.pos_sales s where s.id = v_split)
      = (select s.table_id from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_eq('the fish went with the person who ate it',
    (select s.total_amount from public.pos_sales s where s.id = v_split), 24.00);
  perform pg_temp.check_eq('and the two bills still add to what was ordered',
    (select sum(s.total_amount) from public.pos_sales s
      where s.id in (v_sale, v_split)), 34.00);
  -- A moved line keeps its id, so everything pointing at it still does.
  perform pg_temp.check_eq('its modifiers moved with it',
    (select count(*) from public.pos_sale_line_modifiers m where m.line_id = v_l1), 1);
  perform pg_temp.check_eq('and the kitchen docket still knows it was cooked',
    (select count(*) from public.pos_kitchen_ticket_lines kl where kl.sale_line_id = v_l1), 1);
  perform pg_temp.check_eq('the table now shows two bills',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_bar and f.sale_id is not null), 2);

  begin
    perform public.split_pos_sale(v_split, array[v_l1]);
    raise exception 'FAIL split every line off a bill';
  exception when check_violation then
    raise notice 'ok   splitting the whole bill is a move, not a split';
  end;

  -- And back together.
  perform pg_temp.check_eq('merging brings the line back', 
    public.merge_pos_sales(v_sale, v_split), 1);
  perform pg_temp.check_eq('the bill is whole again',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 34.00);
  perform pg_temp.check_eq('and the emptied bill is gone, not left on the floor plan',
    (select count(*) from public.pos_sales s where s.id = v_split), 0);
  perform pg_temp.check_eq('and no docket was lost along the way',
    (select count(*) from public.pos_kitchen_tickets k where k.sale_id = v_sale), 3);

  -- ------------------------------------------------------------------
  -- Taking something off, before and after the kitchen was told
  -- ------------------------------------------------------------------
  --
  -- The rule 0225 exists for: `sent_to_kitchen_at` is the whole test.
  -- Before it, a line is a keystroke and comes off free. After it,
  -- food exists, and a till that let it vanish silently could not tell
  -- a mistake from a theft.
  v_split := public.open_pos_sale(v_reg);
  v_vline := public.add_pos_sale_line(v_split, v_teh, 1, 3.00);
  perform pg_temp.check_eq('a line is on the bill',
    (select s.total_amount from public.pos_sales s where s.id = v_split), 3.00);

  perform public.remove_pos_sale_line(v_vline);
  perform pg_temp.check_eq('an unsent line comes off, and the bill follows',
    (select s.total_amount from public.pos_sales s where s.id = v_split), 0.00);
  perform pg_temp.check_eq('leaving nothing behind to explain',
    (select count(*) from public.pos_sale_line_voids v where v.sale_id = v_split), 0);

  -- Now one the kitchen has been told about.
  v_vline := public.add_pos_sale_line(v_split, v_teh, 2, 3.00);
  perform public.send_order_to_kitchen(v_split);

  begin
    perform public.remove_pos_sale_line(v_vline);
    raise exception 'FAIL removed a line the kitchen was already making';
  exception when check_violation then
    raise notice 'ok   a sent line cannot simply be removed';
  end;

  begin
    perform public.void_pos_sale_line(v_vline, 'other', null);
    raise exception 'FAIL voided as "other" with nothing said';
  exception when check_violation then
    raise notice 'ok   "other" has to say what happened';
  end;

  v_void := public.void_pos_sale_line(v_vline, 'not_received', 'never came out');
  perform pg_temp.check_eq('voiding takes it off the bill',
    (select s.total_amount from public.pos_sales s where s.id = v_split), 0.00);
  perform pg_temp.check_eq('and leaves exactly one thing to explain',
    (select count(*) from public.pos_sale_line_voids v where v.sale_id = v_split), 1);
  perform pg_temp.check_true('which says what went, and what it was worth',
    (select v.description = 'Teh tarik' and v.quantity = 2 and v.line_total = 6.00
       from public.pos_sale_line_voids v where v.id = v_void));
  perform pg_temp.check_true('and that the kitchen had already been told',
    (select v.was_sent_at is not null
       from public.pos_sale_line_voids v where v.id = v_void));

  -- The assertion 0215 built the `on delete set null` for. The docket
  -- keeps its own words: the food was cooked, whatever the bill says.
  perform pg_temp.check_true('the kitchen docket keeps what it made',
    exists (select 1 from public.pos_kitchen_ticket_lines kl
              join public.pos_kitchen_tickets k on k.id = kl.ticket_id
             where k.sale_id = v_split
               and kl.description = 'Teh tarik'
               and kl.sale_line_id is null));

  perform pg_temp.check_eq('and the day has a figure somebody can question',
    (select sum(x.value) from public.pos_void_summary(v_org) x
      where x.reason = 'not_received'), 6.00);

  -- ------------------------------------------------------------------
  -- Every open bill in the shop, and moving one between drawers
  -- ------------------------------------------------------------------
  --
  -- `parkedPosSales` answers "what is on this till". That is the wrong
  -- question at a counter: the customer walks up holding a bill a
  -- waiter opened on a tablet, and a till that can only see itself
  -- cannot find it at all.
  perform pg_temp.check_true('the shop-wide list finds a bill on another till',
    exists (select 1 from public.pos_open_orders(v_outlet) o
             where o.sale_id = v_split and o.register_id = v_reg));

  -- The count as well as the presence: a list that happened to be
  -- empty would satisfy an existence check that only looked for
  -- absences, and a positive control is what stops that passing
  -- vacuously.
  perform pg_temp.check_eq('and lists every parked bill, not just one',
    (select count(*) from public.pos_open_orders(v_outlet)),
    (select count(*) from public.pos_sales s
      where s.outlet_id = v_outlet and s.status = 'parked'));

  perform pg_temp.check_eq('with the room it is in on the row',
    (select o.table_name from public.pos_open_orders(v_outlet) o
      where o.sale_id = v_sale2), 'T8');

  -- A drawer that is not open cannot take a bill, for the same reason
  -- it cannot take a sale: takings that belong to no count belong to
  -- nobody.
  begin
    perform public.claim_pos_sale(v_split, v_reg3);
    raise exception 'FAIL took a bill onto a till with no shift open';
  exception when check_violation then
    raise notice 'ok   a closed drawer cannot take a bill';
  end;

  v_shift3 := public.open_pos_shift(v_reg3, 50.00);
  v_claim  := public.claim_pos_sale(v_split, v_reg3);

  perform pg_temp.check_true('claiming moves the bill to the counter',
    v_claim = v_split
      and (select s.register_id = v_reg3 from public.pos_sales s where s.id = v_split));

  -- The assertion this whole function exists for. `app.pos_expected_cash`
  -- counts by shift, so a bill settled at the counter while its shift
  -- still pointed at the tablet would put the counter's cash into the
  -- tablet's expected figure and fail both counts, in opposite
  -- directions, for a reason neither cashier could see.
  perform pg_temp.check_true('and the shift with it, which is the point',
    (select s.shift_id = v_shift3 from public.pos_sales s where s.id = v_split));

  perform pg_temp.check_true('while the row still says where it started',
    (select s.opened_on_register_id = v_reg
       from public.pos_sales s where s.id = v_split));

  -- Twice is a no-op. A cashier who taps a bill already on their till
  -- wants to open it, not to be told off -- and the second call must
  -- not rewrite where it started.
  perform public.claim_pos_sale(v_split, v_reg3);
  perform pg_temp.check_true('claiming again changes nothing',
    (select s.register_id = v_reg3 and s.opened_on_register_id = v_reg
       from public.pos_sales s where s.id = v_split));

  -- A bill cannot walk to another shop: the stock it will move comes
  -- out of this outlet's warehouse and the receipt carries this
  -- outlet's header.
  begin
    perform public.claim_pos_sale(v_split, v_reg2);
    raise exception 'FAIL took a bill onto a till in another outlet';
  exception when check_violation then
    raise notice 'ok   a bill cannot be taken to another outlet';
  end;

  -- ------------------------------------------------------------------
  -- Setting up a counter, and saying what goes to it
  -- ------------------------------------------------------------------
  --
  -- 0215 built the routing and left it reachable only by writing SQL.
  -- 0228's functions are what a screen calls, and each exists because
  -- doing the same thing directly goes wrong.

  -- One default, cleared in the same transaction. Two client calls
  -- would leave a moment with no default at all, which is exactly the
  -- moment `send_order_to_kitchen` refuses an unrouted dish.
  v_st3 := public.upsert_kitchen_station(
    v_outlet, 'PASTRY', 'Pastry', null, 3, true);
  perform pg_temp.check_eq('exactly one counter takes anything unrouted',
    (select count(*) from public.pos_kitchen_stations st
      where st.outlet_id = v_outlet and st.is_default), 1);
  perform pg_temp.check_true('and it is the one just made the default',
    (select st.is_default from public.pos_kitchen_stations st
      where st.id = v_st3));

  -- A dish beats its category. The drink already has a category rule
  -- pointing at the bar, so this is the override rather than the first
  -- rule it has ever had.
  perform public.route_item_to_station(v_teh, v_outlet, v_st3);
  perform pg_temp.check_eq('the dish goes where it was told',
    (select r.station from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'Pastry');
  perform pg_temp.check_eq('and the screen can say a person decided that',
    (select r.decided_by from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'item');

  -- Routing it again replaces rather than adds. Two rows for one dish
  -- in one outlet would make `app.pos_route_item` take `limit 1` from a
  -- set of two, and the bar and the kitchen would take turns receiving
  -- the drink with nobody able to say why.
  perform public.route_item_to_station(v_teh, v_outlet, v_hotst);
  perform pg_temp.check_eq('routing again replaces the rule, not adds to it',
    (select count(*) from public.item_kitchen_stations iks
       join public.pos_kitchen_stations st on st.id = iks.station_id
      where iks.item_id = v_teh and st.outlet_id = v_outlet), 1);
  perform pg_temp.check_eq('and it goes to the new one',
    (select r.station from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'Dapur');

  -- Clearing hands the dish back to the level below, which for this one
  -- is the category rule set up earlier.
  perform public.route_item_to_station(v_teh, v_outlet, null);
  perform pg_temp.check_eq('cleared, the dish falls back to its category',
    (select r.decided_by from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'category');
  perform pg_temp.check_eq('which is the bar',
    (select r.station from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'Bar');

  -- And clearing that one hands it to the outlet default, which is the
  -- bottom of the three rules.
  perform public.route_category_to_station(
    (select i.category_id from public.items i where i.id = v_teh),
    v_outlet, null);
  perform pg_temp.check_eq('with no category rule either, the default takes it',
    (select r.decided_by from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'default');
  perform pg_temp.check_eq('and the default is the new counter',
    (select r.station from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'Pastry');

  -- Put the category rule back, because the rest of the room depends
  -- on drinks going to the bar.
  perform public.route_category_to_station(
    (select i.category_id from public.items i where i.id = v_teh),
    v_outlet, v_barst);
  perform pg_temp.check_eq('and it can be put back',
    (select r.station from public.pos_station_routing(v_outlet) r
      where r.item_id = v_teh), 'Bar');

  -- A counter in another outlet is not this outlet's to route to.
  begin
    perform public.route_item_to_station(v_teh, v_outlet, v_reg2);
    raise exception 'FAIL routed a dish to something that is not a counter here';
  exception when check_violation then
    raise notice 'ok   a dish cannot be routed outside its outlet';
  end;

  -- Retiring, and the two refusals that make it safe.
  begin
    perform public.retire_kitchen_station(v_st3);
    raise exception 'FAIL retired the counter unrouted dishes fall back to';
  exception when check_violation then
    raise notice 'ok   the default counter cannot simply be retired';
  end;

  perform public.upsert_kitchen_station(v_outlet, 'HOT', 'Dapur', v_hotst, 1, true);
  perform public.retire_kitchen_station(v_st3);
  perform pg_temp.check_true('a retired counter stops receiving',
    (select not st.is_active from public.pos_kitchen_stations st
      where st.id = v_st3));

  -- Retired, not deleted. `pos_kitchen_tickets.station_id` cascades, so
  -- a delete would take every docket the counter ever received with it.
  perform pg_temp.check_eq('and it is still there to hang history off',
    (select count(*) from public.pos_kitchen_stations st
      where st.id = v_st3), 1);

  raise notice 'point of sale dining room: all assertions passed';
end;
$$;

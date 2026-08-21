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
  v_t9     uuid;
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
  v_long   uuid;
  v_pa     uuid;
  v_pb     uuid;
  v_lsale  uuid;
  v_bsale  uuid;
  v_smsg   text;
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

  -- ------------------------------------------------------------------
  -- The card on the table
  -- ------------------------------------------------------------------
  -- A cashier at the counter has the bill in front of them and no
  -- reason to walk to the floor plan. What the shop puts on the table
  -- is a card, and every reader in this market types its code and
  -- presses enter — so the whole feature is turning that string into
  -- this table. What must not live in the client is which strings
  -- count, because a shop that changes its sticker printer would then
  -- need a release.
  perform pg_temp.check_true('a printed code finds the table',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'T7') t) = v_t7);
  perform pg_temp.check_true('so does it typed by somebody who lost the card',
    (select t.table_id from public.pos_table_by_code(v_outlet, 't7') t) = v_t7);
  -- A QR sticker a customer might also point a phone at has to be a
  -- link, so the link and the code are the same table.
  perform pg_temp.check_true('and a QR sticker that is a link',
    (select t.table_id
       from public.pos_table_by_code(v_outlet, 'https://iakauntan.com/t/T7') t)
    = v_t7);
  perform pg_temp.check_true('and one with a tracking query on it',
    (select t.table_id
       from public.pos_table_by_code(v_outlet, 'https://iakauntan.com/t/T7?utm=qr') t)
    = v_t7);
  -- What a tag writer defaults to when it is handed a bare code.
  perform pg_temp.check_true('and the token an NFC tag is written with',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'table:T7') t) = v_t7);

  -- ------------------------------------------------------------------
  -- And a code is asked for as it was scanned, first
  -- ------------------------------------------------------------------
  --
  -- `pos_tables.code` is free text a shop chooses, and "row A, table 1"
  -- gets written `A/1` by somebody who has never thought about URLs.
  -- 0243 stripped everything before the last slash unconditionally, so
  -- that card resolved to a table called `1` — a *different* table,
  -- with a party already at it. Finding nothing would have been bad;
  -- seating them somewhere else is the expensive kind of wrong.
  --
  -- The decoy is the assertion. Without a table called `1` in the room
  -- the old rule merely returned nothing and this would have passed.
  insert into public.pos_tables (org_id, outlet_id, area_id, code, name, seats)
  values (v_org, v_outlet, v_area, 'A/1', 'Row A, 1', 4) returning id into v_t9;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, name, seats)
  values (v_org, v_outlet, v_area, '1', 'Table one', 2);

  perform pg_temp.check_true('a code with a slash in it finds its own table',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'A/1') t) = v_t9);
  -- And the wrapper shapes still fall through to the stripping, which
  -- is the half that must not regress while fixing the other half.
  perform pg_temp.check_true('while a link is still unwrapped',
    (select t.table_id
       from public.pos_table_by_code(v_outlet, 'https://iakauntan.com/t/T7') t)
    = v_t7);
  perform pg_temp.check_true('and a token still is',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'table:T7') t) = v_t7);

  -- What it says about the table, so the till does not have to ask
  -- twice to tell the cashier what they just scanned.
  perform pg_temp.check_eq('it says which area the table is in',
    (select t.area from public.pos_table_by_code(v_outlet, 'T7') t), 'Dining room');
  perform pg_temp.check_eq('a free table reports no bill on it',
    (select t.open_bills from public.pos_table_by_code(v_outlet, 'T7') t), 0);
  -- Two bills on one table is legitimate — a split leaves exactly that
  -- — so this is a fact to show the cashier, not a reason to refuse.
  perform pg_temp.check_eq('and an occupied one says how many',
    (select t.open_bills from public.pos_table_by_code(v_outlet, 'BAR1') t), 1);

  -- The refusals. A lookup that fell through to another outlet would
  -- put a bill in a room the cashier cannot see.
  perform pg_temp.check_eq('a table in the branch is not this shop''s',
    (select count(*) from public.pos_table_by_code(v_outlet, 'X1')), 0);
  perform pg_temp.check_eq('a code nobody printed finds nothing',
    (select count(*) from public.pos_table_by_code(v_outlet, 'T99')), 0);
  -- The one that would be worst: an empty scan matching everything and
  -- the till seating the party at whichever table sorted first.
  perform pg_temp.check_eq('and an empty scan finds nothing at all',
    (select count(*) from public.pos_table_by_code(v_outlet, '   ')), 0);
  perform pg_temp.check_eq('nor does a sticker worn down to its slashes',
    (select count(*) from public.pos_table_by_code(v_outlet, '///')), 0);

  -- A table taken out of service is off the floor plan, so it must be
  -- off the scan too — otherwise the one route that skips the plan is
  -- the one that can still seat somebody at it.
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_outlet, v_area, 'T9', 2) returning id into v_t9;
  perform pg_temp.check_true('a table in service is found',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'T9') t) = v_t9);
  update public.pos_tables set is_active = false where id = v_t9;
  perform pg_temp.check_eq('one taken out of service is not',
    (select count(*) from public.pos_table_by_code(v_outlet, 'T9')), 0);

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

  -- ------------------------------------------------------------------
  -- How the order arrived
  -- ------------------------------------------------------------------
  --
  -- `business_type` says what shape of shop this is. It has never said
  -- how an order reached it, and one warung takes a bill at a table, a
  -- bag over the counter, a phone call and a delivery app.

  -- Seeded by 0229 from the shape of the shop, which is what makes the
  -- feature usable on the day it ships rather than after somebody
  -- configures every outlet by hand.
  perform pg_temp.check_eq('a dining room is set up to take dine-in',
    (select c.channel::text from public.pos_outlet_channels c
      where c.outlet_id = v_outlet and c.is_default), 'dine_in');
  perform pg_temp.check_true('and more than one way in',
    (select count(*) from public.pos_outlet_channels c
      where c.outlet_id = v_outlet and c.is_active) > 1);

  -- The trigger, resolved in the order a shop actually sets it up.
  v_sale2 := public.open_pos_sale(v_reg);
  perform pg_temp.check_eq('a sale takes the outlet default',
    (select s.order_channel::text from public.pos_sales s where s.id = v_sale2),
    'dine_in');

  update public.pos_registers set default_channel = 'takeaway' where id = v_reg;
  v_split := public.open_pos_sale(v_reg);
  perform pg_temp.check_eq('but the till beats the outlet',
    (select s.order_channel::text from public.pos_sales s where s.id = v_split),
    'takeaway');
  update public.pos_registers set default_channel = null where id = v_reg;

  -- Saying this one was something else.
  perform public.set_pos_sale_channel(v_split, 'delivery');
  perform pg_temp.check_eq('a bill can say it arrived another way',
    (select s.order_channel::text from public.pos_sales s where s.id = v_split),
    'delivery');

  -- A shop that does not do a thing cannot record it. A report split
  -- by a channel nobody sells has a row that can only be a mistake.
  perform public.set_outlet_channel(v_outlet, 'mobile_app', false);
  begin
    perform public.set_pos_sale_channel(v_split, 'mobile_app');
    raise exception 'FAIL recorded a channel the outlet does not take';
  exception when check_violation then
    raise notice 'ok   an outlet only records what it accepts';
  end;

  -- Moving the default clears the old one in the same statement, which
  -- is what the unique partial index requires.
  perform public.set_outlet_channel(v_outlet, 'takeaway', true, true);
  perform pg_temp.check_eq('the default moves rather than duplicating',
    (select count(*) from public.pos_outlet_channels c
      where c.outlet_id = v_outlet and c.is_default), 1);
  perform pg_temp.check_eq('and it is the one just named',
    (select c.channel::text from public.pos_outlet_channels c
      where c.outlet_id = v_outlet and c.is_default), 'takeaway');

  -- A default nobody can order through is not a default.
  begin
    perform public.set_outlet_channel(v_outlet, 'delivery', false, true);
    raise exception 'FAIL made a switched-off channel the default';
  exception when check_violation then
    raise notice 'ok   a channel cannot be off and be the default';
  end;

  -- Switching one off clears its own default flag, so a shop is never
  -- left defaulting to something it does not sell.
  perform public.set_outlet_channel(v_outlet, 'takeaway', false);
  perform pg_temp.check_eq('switching the default off gives it up',
    (select count(*) from public.pos_outlet_channels c
      where c.outlet_id = v_outlet and c.is_default), 0);
  perform public.set_outlet_channel(v_outlet, 'dine_in', true, true);

  -- Completed sales are what the day was, so the channel stops moving.
  perform public.add_pos_sale_line(v_split, v_teh, 1, 3.00);
  perform public.complete_pos_sale(v_split, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 3.00)));
  begin
    perform public.set_pos_sale_channel(v_split, 'dine_in');
    raise exception 'FAIL re-categorised a sale that had already been reported';
  exception when check_violation then
    raise notice 'ok   an issued invoice keeps how the order arrived';
  end;

  perform pg_temp.check_true('and the day can be split by it',
    exists (select 1 from public.pos_sales_by_channel(v_org) x
             where x.channel = 'delivery' and x.sales > 0));

  -- ------------------------------------------------------------------
  -- A long table is two tables
  -- ------------------------------------------------------------------
  --
  -- Two unrelated parties down one twelve-seater is the ordinary case
  -- in a warung, and until 0245 the room had one place for them: one
  -- bill between strangers, or two bills on a table `seat_table`
  -- refuses to disambiguate.
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_outlet, v_area, 'LONG', 7) returning id into v_long;

  -- A party is already sitting there when somebody thinks to split it,
  -- which is exactly when anybody would.
  v_lsale := public.seat_table(v_reg, v_long, 3);

  perform pg_temp.check_eq('a long table splits, and hands back its parts',
    (select count(*)::integer from public.split_pos_table(v_long, 2)), 2);

  select t.id into v_pa from public.pos_tables t
   where t.outlet_id = v_outlet and t.code = 'LONG-A';
  select t.id into v_pb from public.pos_tables t
   where t.outlet_id = v_outlet and t.code = 'LONG-B';
  perform pg_temp.check_true('both halves exist', v_pa is not null and v_pb is not null);

  -- Seven seats is a four and a three, not two threes and a lost chair.
  perform pg_temp.check_eq('the seats are divided, remainder first',
    (select t.seats from public.pos_tables t where t.id = v_pa), 4);
  perform pg_temp.check_eq('and the rest go to the other half',
    (select t.seats from public.pos_tables t where t.id = v_pb), 3);
  perform pg_temp.check_eq('a half knows which table it is half of',
    (select t.parent_table_id from public.pos_tables t where t.id = v_pa), v_long);

  -- The party that was already there keeps their bill, their number and
  -- everything the kitchen has. They were the only party on it, so
  -- there was nothing to guess.
  perform pg_temp.check_eq('the party sitting there kept their bill',
    (select s.table_id from public.pos_sales s where s.id = v_lsale), v_pa);

  -- The room now has two places where it had one.
  perform pg_temp.check_eq('the whole table is off the floor',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_long), 0);
  perform pg_temp.check_eq('and both halves are on it',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id in (v_pa, v_pb)), 2);
  perform pg_temp.check_eq('the plan says which whole a half belongs to',
    (select f.parent_table_id from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_pb), v_long);

  -- A card printed for a half resolves the day it is printed, because
  -- a half is an ordinary table as far as everything else is concerned.
  perform pg_temp.check_eq('a card that says LONG-A finds the half',
    (select t.table_id from public.pos_table_by_code(v_outlet, 'long-a') t), v_pa);
  -- And the old card stops resolving, which is the truth: there is no
  -- whole table to seat anybody at while two parties are in its halves.
  perform pg_temp.check_true('and the card for the whole stops answering',
    (select count(*) from public.pos_table_by_code(v_outlet, 'LONG')) = 0);

  -- A half does not split again.
  begin
    perform public.split_pos_table(v_pa, 2);
    raise exception 'FAIL split a half table';
  exception when check_violation then
    raise notice 'ok   a half table does not split again';
  end;

  -- Nor does a table that is already in halves.
  begin
    perform public.split_pos_table(v_long, 2);
    raise exception 'FAIL split a table that was already split';
  exception when check_violation then
    raise notice 'ok   a split table is not split twice';
  end;

  -- And a number nobody means. On a table that is *in service*: T9 was
  -- taken out of service earlier in this file and never put back, so
  -- asking it this question would be answered by the not-in-service
  -- guard instead and leave the range check unasserted. That is what
  -- this assertion did until somebody read it.
  begin
    perform public.split_pos_table(v_t8, 1);
    raise exception 'FAIL split a table into one part';
  exception when check_violation then
    get stacked diagnostics v_smsg = message_text;
    raise notice 'ok   a table does not split into one';
  end;
  perform pg_temp.check_true('and it is the range that refused it',
    v_smsg like '%between two and eight%');

  -- The other guard, on its own table, so neither hides the other.
  begin
    perform public.split_pos_table(v_t9, 2);
    raise exception 'FAIL split a table that is out of service';
  exception when check_violation then
    get stacked diagnostics v_smsg = message_text;
    raise notice 'ok   a table out of service is not split';
  end;
  perform pg_temp.check_true('and says so',
    v_smsg like '%not in service%');

  -- ------------------------------------------------------------------
  -- Putting it back together
  -- ------------------------------------------------------------------
  --
  -- Two parties cannot be merged onto one table, for the same reason
  -- they had to be split apart: the next tap on it would be ambiguous.
  v_bsale := public.seat_table(v_reg, v_pb, 2);
  begin
    perform public.merge_pos_table(v_pa);
    raise exception 'FAIL merged two parties onto one table';
  exception when check_violation then
    get stacked diagnostics v_smsg = message_text;
    raise notice 'ok   two parties are not merged onto one table';
  end;
  perform pg_temp.check_true('and the refusal names the halves still sat at',
    v_smsg like '%LONG-A, LONG-B%');

  -- One party gets up.
  perform public.move_pos_sale(v_bsale, null);
  perform public.merge_pos_table(v_pb);

  perform pg_temp.check_eq('the whole table is back on the floor',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id = v_long), 1);
  perform pg_temp.check_eq('the halves are not',
    (select count(*) from public.pos_floor_plan(v_outlet) f
      where f.table_id in (v_pa, v_pb)), 0);
  -- Symmetric with the split: the one party left comes back to the
  -- whole table with the bill they have been eating off all evening.
  perform pg_temp.check_eq('and the party that stayed came with it',
    (select s.table_id from public.pos_sales s where s.id = v_lsale), v_long);

  -- Deactivated, not deleted: `pos_sales.table_id` is `on delete set
  -- null`, so deleting a half would erase which table last week's bills
  -- were served at.
  perform pg_temp.check_eq('the halves still exist, out of service',
    (select count(*) from public.pos_tables t
      where t.parent_table_id = v_long and not t.is_active), 2);

  -- Which is also why splitting again is the same two halves, so a shop
  -- that splits its long table every Friday accumulates one history per
  -- half rather than a new pair of tables every week.
  perform public.split_pos_table(v_long, 2);
  perform pg_temp.check_eq('splitting again is the same LONG-A',
    (select t.id from public.pos_tables t
      where t.outlet_id = v_outlet and t.code = 'LONG-A'), v_pa);
  perform public.merge_pos_table(v_long);

  -- A table nobody merged is not a table to merge.
  begin
    perform public.merge_pos_table(v_t9);
    raise exception 'FAIL merged a table that was never split';
  exception when check_violation then
    raise notice 'ok   an unsplit table has nothing to put back';
  end;

  raise notice 'point of sale dining room: all assertions passed';
end;
$$;

rollback;

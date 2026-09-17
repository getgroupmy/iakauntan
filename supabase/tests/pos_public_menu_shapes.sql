-- =====================================================================
-- Point of sale :: the shapes behind the menu a phone orders from
--
-- `pos_public_menu.sql` is the behaviour file for this surface and it is
-- a good one: it proves the assertion the endpoint exists to make, that
-- a price arriving from a browser is ignored. What stands behind it is
-- ONE company, ONE outlet, ONE till, TWO items and ONE question. So
-- almost every filter in the four functions had nothing to exclude.
--
-- A sweep of 71 one-line mutants killed 21. This file is for the rest,
-- and the reason it matters more than the count suggests is WHERE these
-- four functions sit: `public_pos_menu`, `public_pos_menu_modifiers` and
-- `place_public_pos_order` are granted to `anon`. A token typed into a
-- phone is the whole credential. Every filter in them is a boundary
-- between one shop and the next, and none of them was asserted.
--
-- So this file stands a second company next door with its own outlet,
-- its own till and its own menu, and gives the shop under test four
-- tills it must not land an order on, three items that are not on the
-- menu, a question nobody asks any more and a table with somebody
-- else's bill on it.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_next    uuid;
  v_wh      uuid;
  v_walkin  uuid;
  v_out     uuid;
  v_out2    uuid;
  -- the shop's own tills
  v_c0a     uuid;   -- retired, with a shift open
  v_c0b     uuid;   -- deleted, with a shift open
  v_c0c     uuid;   -- open for business, no shift
  v_c0d     uuid;   -- the one an order should land on
  v_c1      uuid;   -- the one a link may name
  v_b1      uuid;   -- next door's till
  -- what is on the menu, and what is not
  v_cat_f   uuid;
  v_cat_d   uuid;
  v_nasi    uuid;
  v_teh     uuid;
  v_plain   uuid;
  v_gone    uuid;
  v_off     uuid;
  v_raw     uuid;
  v_theirs  uuid;
  -- the questions a plate comes with
  v_g_size  uuid;
  v_g_spice uuid;
  v_g_dead  uuid;
  v_g_empty uuid;
  v_g_teh   uuid;
  v_m_large uuid;
  v_m_extra uuid;
  v_m_none  uuid;
  v_m_old   uuid;
  v_area    uuid;
  v_t7      uuid;
  v_t8      uuid;
  v_link    record;
  v_named   record;
  v_take    record;
  v_deliv   record;
  v_once    record;
  v_spare   record;
  v_order   record;
  v_first   uuid;
  v_second  uuid;
  v_eight   uuid;
  v_line    uuid;
  v_promo   uuid;
begin
  -- ------------------------------------------------------------------
  -- The shop under test
  -- ------------------------------------------------------------------
  v_org := pg_temp.test_org('Kedai Terbuka Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  -- Two categories whose names sort AGAINST the item names inside them,
  -- so a menu grouped by category cannot be told apart from one sorted
  -- by name alone unless the grouping is what decides.
  insert into public.item_categories (org_id, code, name)
  values (v_org, 'FOOD', 'Aaa food') returning id into v_cat_f;
  insert into public.item_categories (org_id, code, name)
  values (v_org, 'DRINK', 'Zzz drinks') returning id into v_cat_d;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, category_id)
  values (v_org, 'NASI', 'Zzz nasi lemak', 'service', false, 'C62',
          12.00, 5.00, v_cat_f)
  returning id into v_nasi;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, category_id)
  values (v_org, 'TEH', 'Aaa teh tarik', 'service', false, 'C62',
          3.00, 1.00, v_cat_d)
  returning id into v_teh;
  -- Nobody filed this one under anything.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'PLAIN', 'Mmm nasi putih', 'service', false, 'C62', 2.00, 0.50)
  returning id into v_plain;

  -- Three that are not on the menu, all named so they would sort FIRST
  -- if any of them ever came back.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, deleted_at)
  values (v_org, 'GONE', 'Aaa deleted dish', 'service', false, 'C62',
          9.00, 1.00, now())
  returning id into v_gone;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, is_active)
  values (v_org, 'OFF', 'Aaa retired dish', 'service', false, 'C62',
          9.00, 1.00, false)
  returning id into v_off;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, is_sold)
  values (v_org, 'RAW', 'Aaa raw ingredient', 'service', false, 'C62',
          9.00, 1.00, false)
  returning id into v_raw;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_out;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);

  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out, 'C0A', 'Retired counter') returning id into v_c0a;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out, 'C0B', 'Deleted counter') returning id into v_c0b;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out, 'C0C', 'Counter that has not opened')
  returning id into v_c0c;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out, 'C0D', 'The open counter') returning id into v_c0d;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out, 'C1', 'The counter a link may name')
  returning id into v_c1;

  insert into public.pos_floor_areas (org_id, outlet_id, code, name)
  values (v_org, v_out, 'MAIN', 'Dining room') returning id into v_area;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_out, v_area, 'T7', 4) returning id into v_t7;
  insert into public.pos_tables (org_id, outlet_id, area_id, code, seats)
  values (v_org, v_out, v_area, 'T8', 2) returning id into v_t8;

  -- ------------------------------------------------------------------
  -- The questions the nasi comes with
  --
  -- Four groups on one plate: the size first because the shop said so,
  -- then how spicy, then one with nothing in it yet, and one the shop
  -- stopped asking. Their NAMES sort the other way round from their
  -- order, so a list ordered by name is a different list.
  -- ------------------------------------------------------------------
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'SAIZ', 'What size?', 1, 1) returning id into v_g_size;
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'PEDAS', 'How spicy?', 0, 3) returning id into v_g_spice;
  insert into public.pos_modifier_groups
    (org_id, code, name, min_select, max_select, is_active)
  values (v_org, 'LAMA', 'A question nobody asks now', 0, 1, false)
  returning id into v_g_dead;
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'KOSONG', 'Zzz a question with no answers yet', 0, 1)
  returning id into v_g_empty;
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'MANIS', 'How sweet?', 0, 1) returning id into v_g_teh;

  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta, sort_order)
  values (v_org, v_g_size, 'BESAR', 'Large', 2.00, 1) returning id into v_m_large;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta, sort_order)
  values (v_org, v_g_spice, 'EXTRA', 'Extra sambal', 1.50, 1)
  returning id into v_m_extra;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta, sort_order)
  values (v_org, v_g_spice, 'TAK', 'No sambal', 0, 2) returning id into v_m_none;
  insert into public.pos_modifiers
    (org_id, group_id, code, name, price_delta, sort_order, is_active)
  values (v_org, v_g_spice, 'HABIS', 'A sambal we stopped making', 1.00, 3, false)
  returning id into v_m_old;
  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta, sort_order)
  values (v_org, v_g_teh, 'KURANG', 'Less sweet', 0, 1);

  insert into public.item_modifier_groups (org_id, item_id, group_id, sort_order)
  values (v_org, v_nasi, v_g_size, 1),
         (v_org, v_nasi, v_g_spice, 2),
         (v_org, v_nasi, v_g_empty, 3),
         (v_org, v_nasi, v_g_dead, 4),
         (v_org, v_teh, v_g_teh, 1);

  -- ------------------------------------------------------------------
  -- The shop next door: its own company, outlet, till and menu
  -- ------------------------------------------------------------------
  v_next := pg_temp.test_org('Kedai Sebelah Sdn Bhd');
  perform public.create_fiscal_year(v_next, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_next, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_next, 'MAIN', 'Their store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_next, 'WALK-IN', 'Their counter sales', 'customer')
  returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_next, 'THEIRS', 'Aaa their own dish', 'service', false, 'C62',
          40.00, 10.00)
  returning id into v_theirs;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_next, 'SEBELAH', 'Next door', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_out2;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_next, true);
  -- Coded so it sorts BEFORE every till in the shop under test: if the
  -- outlet filter on the till search ever goes, this is where the
  -- order lands.
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_next, v_out2, 'B1', 'Their counter') returning id into v_b1;
  perform public.open_pos_shift(v_b1, 50.00);
  -- Next door takes dine-in orders. The shop under test does not, and
  -- the sweep's question is whether that distinction is read from the
  -- right outlet's list.
  perform public.set_outlet_channel(v_out2, 'dine_in', true);

  -- What the shop under test says it takes: deliveries yes, dine-in
  -- switched off rather than absent. A new bill opens as a takeaway,
  -- so 'dine_in' is the value that has to be earned.
  perform public.set_outlet_channel(v_out, 'delivery', true);
  perform public.set_outlet_channel(v_out, 'dine_in', false);

  -- ------------------------------------------------------------------
  -- What the phone sees
  -- ------------------------------------------------------------------
  select * into v_link from public.upsert_pos_menu_link(
    v_out, 'table', v_t7, null, 'Table 7 sticker');

  perform pg_temp.check_eq('the menu is this shop''s own three dishes',
    (select count(*) from public.public_pos_menu(v_link.token)), 3);
  perform pg_temp.check_eq('a dish somebody deleted is not on it',
    (select count(*) from public.public_pos_menu(v_link.token) m
      where m.item_id = v_gone), 0);
  perform pg_temp.check_eq('nor one the shop retired',
    (select count(*) from public.public_pos_menu(v_link.token) m
      where m.item_id = v_off), 0);
  perform pg_temp.check_eq('nor a raw ingredient nobody sells',
    (select count(*) from public.public_pos_menu(v_link.token) m
      where m.item_id = v_raw), 0);
  perform pg_temp.check_eq('nor anything belonging to the shop next door',
    (select count(*) from public.public_pos_menu(v_link.token) m
      where m.item_id = v_theirs), 0);
  perform pg_temp.check_eq('the menu is grouped, not merely sorted',
    (select m.item_id from public.public_pos_menu(v_link.token) m limit 1),
    v_nasi);
  perform pg_temp.check_eq('and a dish filed under nothing gets a heading',
    (select m.category from public.public_pos_menu(v_link.token) m
      where m.item_id = v_plain), 'Uncategorised');

  -- ------------------------------------------------------------------
  -- The questions, in the order the shop put them in
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the shop''s own order decides, not the wording',
    (select g.group_id from public.public_pos_menu_modifiers(v_link.token, v_nasi) g
      limit 1),
    v_g_size);
  perform pg_temp.check_eq('a question the shop stopped asking is not asked',
    (select count(*) from public.public_pos_menu_modifiers(v_link.token, v_nasi) g
      where g.group_id = v_g_dead), 0);
  perform pg_temp.check_eq('an answer it stopped offering is not offered',
    (select count(*) from public.public_pos_menu_modifiers(v_link.token, v_nasi) g
      where g.group_id = v_g_spice and g.modifier_id is not null), 2);
  perform pg_temp.check_eq('a question with no answers yet still shows',
    (select count(*) from public.public_pos_menu_modifiers(v_link.token, v_nasi) g
      where g.group_id = v_g_empty), 1);
  perform pg_temp.check_eq('and the questions are this plate''s',
    (select count(*) from public.public_pos_menu_modifiers(v_link.token, v_nasi) g
      where g.group_id = v_g_teh), 0);

  -- ------------------------------------------------------------------
  -- Which till the order lands on
  --
  -- Four tills the order must not reach, each excluded by a different
  -- condition, and all four coded to sort before the one it should.
  -- ------------------------------------------------------------------
  perform public.open_pos_shift(v_c0a, 10.00);
  perform public.open_pos_shift(v_c0b, 10.00);
  perform public.open_pos_shift(v_c0d, 10.00);
  perform public.open_pos_shift(v_c1, 10.00);
  update public.pos_registers set is_active = false where id = v_c0a;
  update public.pos_registers set deleted_at = now() where id = v_c0b;

  select * into v_order from public.place_public_pos_order(
    v_link.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  v_first := v_order.sale_id;
  perform pg_temp.check_eq('the order lands on an open till of this shop''s',
    (select s.register_id from public.pos_sales s where s.id = v_first), v_c0d);

  select * into v_named from public.upsert_pos_menu_link(
    v_out, 'takeaway', null, v_c1, 'The counter''s own poster');
  select * into v_order from public.place_public_pos_order(
    v_named.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  perform pg_temp.check_eq('and on the one the link names when it names one',
    (select s.register_id from public.pos_sales s where s.id = v_order.sale_id),
    v_c1);

  -- ------------------------------------------------------------------
  -- How the order arrived, and whose list decides
  --
  -- A bill opens as a walk-in. A table sticker asks for dine-in, and
  -- this outlet has dine-in switched OFF while it has delivery on and
  -- the shop next door has dine-in on. So the one line below fails if
  -- the list is read from the wrong outlet, if any active channel
  -- counts as this one, or if a switched-off row counts as on.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a channel this outlet has switched off is not used',
    (select s.order_channel::text from public.pos_sales s where s.id = v_first),
    'walk_in');

  perform public.set_outlet_channel(v_out, 'dine_in', true);
  perform * from public.place_public_pos_order(
    v_link.token, jsonb_build_array(jsonb_build_object('item', v_teh)));
  perform pg_temp.check_eq('and one it has switched on is',
    (select s.order_channel::text from public.pos_sales s where s.id = v_first),
    'dine_in');

  perform public.set_outlet_channel(v_out, 'takeaway', true);
  select * into v_take from public.upsert_pos_menu_link(
    v_out, 'takeaway', null, null, 'Takeaway poster');
  select * into v_order from public.place_public_pos_order(
    v_take.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  perform pg_temp.check_eq('a poster with no table on it is a takeaway',
    (select s.order_channel::text from public.pos_sales s
      where s.id = v_order.sale_id), 'takeaway');

  -- ------------------------------------------------------------------
  -- The table sticker, and the bill it joins
  -- ------------------------------------------------------------------
  -- Somebody else's party, parked on the next table along.
  select * into v_spare from public.upsert_pos_menu_link(
    v_out, 'table', v_t8, null, 'Table 8 sticker');
  select * into v_order from public.place_public_pos_order(
    v_spare.token, jsonb_build_array(jsonb_build_object('item', v_teh)));
  v_eight := v_order.sale_id;
  perform pg_temp.check_eq('the next table along gets its own bill',
    (select s.table_id from public.pos_sales s where s.id = v_eight), v_t8);

  -- Table seven's bill is settled and gone, so the next scan of that
  -- sticker is a new party.
  update public.pos_sales set status = 'voided', voided_at = now()
   where id = v_first;
  select * into v_order from public.place_public_pos_order(
    v_link.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  v_second := v_order.sale_id;
  perform pg_temp.check_true('a scan does not join a bill already settled',
    v_second <> v_first);
  perform pg_temp.check_true('nor the bill on the next table along',
    v_second <> v_eight);
  perform pg_temp.check_eq('and the new bill is put on the right table',
    (select s.table_id from public.pos_sales s where s.id = v_second), v_t7);

  -- ------------------------------------------------------------------
  -- What may be ordered
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a dish belonging to the shop next door',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, jsonb_build_array(jsonb_build_object('item', v_theirs))),
    'That is not on the menu.%', 'P0002');
  perform pg_temp.check_refused('a dish somebody deleted',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, jsonb_build_array(jsonb_build_object('item', v_gone))),
    'That is not on the menu.%', 'P0002');
  perform pg_temp.check_refused('a dish the shop retired',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, jsonb_build_array(jsonb_build_object('item', v_off))),
    'That is not on the menu.%', 'P0002');
  perform pg_temp.check_refused('a raw ingredient nobody sells',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, jsonb_build_array(jsonb_build_object('item', v_raw))),
    'That is not on the menu.%', 'P0002');
  perform pg_temp.check_refused('an item id that is nobody''s',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token,
           jsonb_build_array(jsonb_build_object(
             'item', '00000000-0000-0000-0000-000000000001'::uuid))),
    'That is not on the menu.%', 'P0002');
  perform pg_temp.check_refused('an empty basket',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, '[]'::jsonb),
    'There is nothing in this order.%', '23514');

  -- The company the order is checked against is the OUTLET's. Whichever
  -- company a mutant reads instead, one of these two lines fails.
  select * into v_order from public.place_public_pos_order(
    v_take.token, jsonb_build_array(jsonb_build_object(
      'item', v_nasi, 'quantity', 3, 'note', 'bungkus',
      'modifiers', jsonb_build_array(
        jsonb_build_object('modifier', v_m_extra, 'quantity', 2)))));
  select l.id into v_line from public.pos_sale_lines l
   where l.sale_id = v_order.sale_id order by l.line_no desc limit 1;
  perform pg_temp.check_eq('the quantity the phone asked for',
    (select l.quantity from public.pos_sale_lines l where l.id = v_line), 3);
  perform pg_temp.check_eq('the note the phone typed on the line',
    (select l.note from public.pos_sale_lines l where l.id = v_line), 'bungkus');
  perform pg_temp.check_eq('and two of an extra is charged as two',
    (select lm.quantity from public.pos_sale_line_modifiers lm
      where lm.line_id = v_line and lm.modifier_id = v_m_extra), 2);

  -- ------------------------------------------------------------------
  -- What the kitchen has taken off
  --
  -- The phone is told twice: on the menu, where the dish reads as not
  -- available, and at the moment of ordering. The two refusals along
  -- that path are worded differently on purpose — this one is the
  -- reason alone, and the till's own is the dish's name and then the
  -- reason — so an assertion can tell which of them fired.
  -- ------------------------------------------------------------------
  perform public.stop_pos_item(v_out, v_teh, 'Habis');
  perform pg_temp.check_true('a dish the kitchen stopped reads as unavailable',
    not (select m.available from public.public_pos_menu(v_link.token) m
          where m.item_id = v_teh));
  perform pg_temp.check_refused('and ordering it is refused in the kitchen''s words',
    format('select * from public.place_public_pos_order(%L, %L::jsonb)',
           v_link.token, jsonb_build_array(jsonb_build_object('item', v_teh))),
    'Habis', '23514');
  perform public.resume_pos_item(v_out, v_teh);
  perform pg_temp.check_true('and it is back on the menu once the kitchen says so',
    (select m.available from public.public_pos_menu(v_link.token) m
      where m.item_id = v_teh));

  -- ------------------------------------------------------------------
  -- What a second scan must not erase
  -- ------------------------------------------------------------------
  select * into v_order from public.place_public_pos_order(
    v_link.token, jsonb_build_array(jsonb_build_object('item', v_teh)),
    'Aminah', '012-3456789', 'No ice please');
  select * into v_order from public.place_public_pos_order(
    v_link.token, jsonb_build_array(jsonb_build_object('item', v_teh)));
  perform pg_temp.check_eq('a second scan does not erase the name given',
    (select s.guest_name from public.pos_sales s where s.id = v_second), 'Aminah');
  perform pg_temp.check_eq('nor the number to call',
    (select s.guest_phone from public.pos_sales s where s.id = v_second),
    '012-3456789');
  perform pg_temp.check_eq('nor what the customer asked for',
    (select s.note from public.pos_sales s where s.id = v_second),
    'No ice please');

  -- ------------------------------------------------------------------
  -- A delivery, and the address it goes to
  -- ------------------------------------------------------------------
  perform public.upsert_pos_delivery_zone(
    null, v_out, 'Taman Sri', array['58200'], 5.00, 100.00, null, 30, 1, true);
  select * into v_deliv from public.upsert_pos_menu_link(
    v_out, 'delivery', null, null, 'Delivery poster');
  select * into v_order from public.place_public_pos_order(
    v_deliv.token,
    jsonb_build_array(jsonb_build_object('item', v_teh)),
    'Siti', '012-9999999', null,
    '12 Jalan Sri 3', 'Level 2', 'Kuala Lumpur', 'Selangor', '58200');

  perform pg_temp.check_eq('a delivery is booked as one',
    (select s.order_channel::text from public.pos_sales s
      where s.id = v_order.sale_id), 'delivery');
  perform pg_temp.check_eq('the town is the town, not the second line',
    (select d.city from public.pos_deliveries d where d.sale_id = v_order.sale_id),
    'Kuala Lumpur');
  perform pg_temp.check_eq('and the second line is the second line',
    (select d.address_line2 from public.pos_deliveries d
      where d.sale_id = v_order.sale_id), 'Level 2');
  perform pg_temp.check_eq('the driver is given the number the phone left',
    (select d.phone from public.pos_deliveries d where d.sale_id = v_order.sale_id),
    '012-9999999');
  -- A three ringgit teh against a hundred ringgit minimum: the zone
  -- takes the order and the phone is told, in a sentence, that it will
  -- not go out.
  perform pg_temp.check_true('and the phone is told the ride will not happen',
    v_order.blocked_reason is not null);

  -- ------------------------------------------------------------------
  -- The shop's own rules, applied to a basket a phone filled
  -- ------------------------------------------------------------------
  v_promo := public.upsert_pos_promotion(
    v_org, 'Ten per cent off everything', 'percent_off', null, 10.00);
  select * into v_order from public.place_public_pos_order(
    v_take.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  perform pg_temp.check_eq('the shop''s promotion reaches an order from a phone',
    (select s.promo_discount from public.pos_sales s
      where s.id = v_order.sale_id), 1.20);

  -- ------------------------------------------------------------------
  -- A link that closes behind one order closes only itself
  -- ------------------------------------------------------------------
  select * into v_once from public.upsert_pos_menu_link(
    v_out, 'takeaway', null, null, 'One-time link', null, true);
  perform * from public.place_public_pos_order(
    v_once.token, jsonb_build_array(jsonb_build_object('item', v_nasi)));
  perform pg_temp.check_true('a single-use link closes behind its order',
    (select l.used_at from public.pos_menu_links l where l.id = v_once.id)
      is not null);
  perform pg_temp.check_true('and every other poster the shop printed stays up',
    (select l.used_at from public.pos_menu_links l where l.id = v_take.id)
      is null);

  -- ------------------------------------------------------------------
  -- The rules the equivalent mutants lean on
  --
  -- `public_pos_menu_modifiers` filters `img.org_id = v_org` beside
  -- `img.item_id = p_item`, and the filter cannot be observed: the row
  -- is held to its own item's company by a composite key, so naming the
  -- item has already named the company. The constraint is the rule.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'a plate''s questions are held to the plate''s own company',
    (select count(*) from pg_constraint
      where conrelid = 'public.item_modifier_groups'::regclass
        and conname = 'item_modifier_groups_item_same_org'), 1);
  -- And a link is reached by a token that is always there to be typed
  -- wrong, never one that is absent: 0534 holds the column to it, so a
  -- caller sending no token at all cannot match a row that has none.
  perform pg_temp.check_eq('every menu link has a token',
    (select count(*) from information_schema.columns
      where table_name = 'pos_menu_links' and column_name = 'token'
        and is_nullable = 'NO'), 1);
end $$;

rollback;

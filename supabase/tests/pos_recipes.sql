-- =====================================================================
-- Point of sale :: what the plate takes out of the store
--
-- Four things have to be true, and everything else in this file exists
-- to hold them up.
--
--   1. The units convert, or they refuse. 180 grams out of stock kept
--      in kilograms is 0.18, not 180, and a system that is out by a
--      thousand on rice is out by a thousand on every reorder it
--      suggests for the rest of the year.
--
--   2. The ingredients actually leave, once, when the bill is settled,
--      and the cost of them lands in the ledger against the sale that
--      caused it. Not at parking. Not twice.
--
--   3. A sub-recipe explodes and a counted one does not. The sambal
--      nobody counts resolves to chilli; the sambal in the fridge comes
--      out of the fridge.
--
--   4. The countdown tells the truth about what is left, including what
--      the open tables have already promised, and the till refuses when
--      the shop has asked it to.
--
-- Nothing is written; the file rolls back.
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
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;

  v_rice   uuid;   -- stocked in kilograms
  v_egg    uuid;   -- stocked in units
  v_milk   uuid;   -- stocked in litres
  v_chilli uuid;   -- stocked in kilograms
  v_sambal uuid;   -- made, never counted: a sub-recipe
  v_paste  uuid;   -- made and counted: a leaf
  v_nasi   uuid;   -- the dish
  v_special uuid;  -- a dish built on the counted paste
  v_tin    uuid;   -- a packaging conversion

  v_sale   uuid;
  v_sale2  uuid;
  v_line   uuid;
  v_rec    uuid;
  v_r      record;
  v_msg    text;
  v_qty    numeric;
  v_cogs   numeric;
  v_inv    numeric;
  v_mods   uuid;
  v_extra  uuid;
begin
  v_org := pg_temp.test_org('Warung Resipi Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Kitchen store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  -- The ingredients, each stocked in the unit a shop actually buys it in.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'BERAS', 'Beras', 'stock', true, 'KGM', 4.00)
  returning id into v_rice;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'TELUR', 'Telur', 'stock', true, 'C62', 0.50)
  returning id into v_egg;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SANTAN', 'Santan', 'stock', true, 'LTR', 6.00)
  returning id into v_milk;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'CILI', 'Cili kering', 'stock', true, 'KGM', 20.00)
  returning id into v_chilli;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'SUSU', 'Susu pekat', 'stock', true, 'C62', 3.00)
  returning id into v_tin;

  -- Made in the kitchen and never counted: it exists only as a recipe.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'SAMBAL', 'Sambal', 'non_stock', false, 'GRM')
  returning id into v_sambal;

  -- Made in the central kitchen and counted in the fridge.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'PES', 'Pes kari', 'stock', true, 'KGM', 30.00)
  returning id into v_paste;

  -- The dishes.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00)
  returning id into v_nasi;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KARI', 'Nasi kari', 'service', false, 'C62', 15.00)
  returning id into v_special;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'WARUNG', 'The warung', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- 1. The units
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a kilogram is a thousand grams',
    app.uom_qty(v_rice, 180, 'GRM'), 0.18::numeric);
  perform pg_temp.check_eq('a litre is a thousand millilitres',
    app.uom_qty(v_milk, 40, 'MLT'), 0.04::numeric);
  perform pg_temp.check_eq('its own unit is itself',
    app.uom_qty(v_egg, 2, 'C62'), 2::numeric);
  perform pg_temp.check_eq('and so is no unit at all',
    app.uom_qty(v_egg, 2, null), 2::numeric);
  perform pg_temp.check_eq('a dozen is twelve',
    app.uom_qty(v_egg, 2, 'DZN'), 24::numeric);
  perform pg_temp.check_eq('a kilogram written in kilograms is untouched',
    app.uom_qty(v_rice, 3, 'KGM'), 3::numeric);

  -- Across dimensions, never.
  begin
    perform app.uom_qty(v_rice, 1, 'LTR');
    perform pg_temp.check_true('grams do not become litres', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'grams do not become litres, and it says which item: ' || v_msg,
      v_msg like '%Beras%');
  end;

  -- A carton is whatever the shop says it is.
  begin
    perform app.uom_qty(v_tin, 1, 'CT');
    perform pg_temp.check_true('a carton means nothing on its own', false);
  exception when others then
    perform pg_temp.check_true('a carton means nothing on its own', true);
  end;
  perform public.upsert_item_uom_pack(v_tin, 'CT', 48);
  perform pg_temp.check_eq('until the shop says how many are in one',
    app.uom_qty(v_tin, 2, 'CT'), 96::numeric);
  perform pg_temp.check_true('and the options list offers it',
    exists (select 1 from public.item_uom_options(v_tin) o
             where o.uom_code = 'CT' and o.is_pack));
  perform public.upsert_item_uom_pack(v_tin, 'CT', 24);
  perform pg_temp.check_eq('a pack size can be corrected',
    app.uom_qty(v_tin, 2, 'CT'), 48::numeric);

  -- A pack beats the reference table, because the shop is more specific.
  perform public.upsert_item_uom_pack(v_rice, 'BG', 10);
  perform pg_temp.check_eq('a bag of rice is what this shop buys',
    app.uom_qty(v_rice, 1, 'BG'), 10::numeric);

  begin
    perform public.upsert_item_uom_pack(v_rice, 'KGM', 2);
    perform pg_temp.check_true('a unit cannot be redefined as itself', false);
  exception when others then
    perform pg_temp.check_true('a unit cannot be redefined as itself', true);
  end;

  -- ------------------------------------------------------------------
  -- 2. The recipes
  -- ------------------------------------------------------------------
  -- Sambal: a batch of 500g takes 200g of chilli. Never counted, so
  -- selling something that uses it has to reach the chilli.
  perform public.upsert_pos_recipe(v_org, v_sambal, 500, jsonb_build_array(
    jsonb_build_object('item', v_chilli, 'quantity', 200, 'uom', 'GRM')));

  -- Nasi lemak: 180g rice, 40ml santan, one egg, 30g sambal, and a
  -- garnish that never stops a sale.
  v_rec := public.upsert_pos_recipe(v_org, v_nasi, 1, jsonb_build_array(
    jsonb_build_object('item', v_rice,   'quantity', 180, 'uom', 'GRM'),
    jsonb_build_object('item', v_milk,   'quantity', 40,  'uom', 'MLT'),
    jsonb_build_object('item', v_egg,    'quantity', 1,   'uom', 'C62'),
    jsonb_build_object('item', v_sambal, 'quantity', 30,  'uom', 'GRM'),
    jsonb_build_object('item', v_tin,    'quantity', 1,   'uom', 'C62',
                       'optional', true)));

  perform pg_temp.check_eq('a recipe keeps its lines',
    (select count(*)::integer from public.pos_recipe_lines l
      where l.recipe_id = v_rec), 5);

  -- A dish that keeps its own stock is refused one.
  begin
    perform public.upsert_pos_recipe(v_org, v_paste, 1, jsonb_build_array(
      jsonb_build_object('item', v_chilli, 'quantity', 1, 'uom', 'KGM')));
    perform pg_temp.check_true('a counted dish may not have a recipe', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a counted dish may not have a recipe, and it says why',
      v_msg like '%keeps its own stock%');
  end;

  -- Nor may a recipe contain itself, however far round.
  begin
    perform public.upsert_pos_recipe(v_org, v_sambal, 500, jsonb_build_array(
      jsonb_build_object('item', v_nasi, 'quantity', 1, 'uom', 'C62')));
    perform pg_temp.check_true('a recipe may not contain itself', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a recipe may not contain itself through its sub-recipes',
      v_msg like '%ingredient of itself%');
  end;
  perform pg_temp.check_eq('and the refusal left the sambal alone',
    (select count(*)::integer from public.pos_recipe_lines l
      join public.pos_recipes r on r.id = l.recipe_id
     where r.item_id = v_sambal), 1);

  -- ------------------------------------------------------------------
  -- 3. What one plate actually draws
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('180g of rice out of a kilogram store is 0.18',
    (select round(c.quantity, 4) from app.pos_recipe_components(v_nasi, 1) c
      where c.item_id = v_rice), 0.18::numeric);
  perform pg_temp.check_eq('40ml of santan out of a litre store is 0.04',
    (select round(c.quantity, 4) from app.pos_recipe_components(v_nasi, 1) c
      where c.item_id = v_milk), 0.04::numeric);
  perform pg_temp.check_eq('one egg is one egg',
    (select round(c.quantity, 4) from app.pos_recipe_components(v_nasi, 1) c
      where c.item_id = v_egg), 1::numeric);

  -- The sub-recipe. 30g of a 500g batch that takes 200g of chilli is
  -- 12g of chilli, which out of a kilogram store is 0.012.
  perform pg_temp.check_eq('a sub-recipe nobody counts explodes to its own',
    (select round(c.quantity, 6) from app.pos_recipe_components(v_nasi, 1) c
      where c.item_id = v_chilli), 0.012::numeric);
  perform pg_temp.check_true('and the sambal itself is not a component',
    not exists (select 1 from app.pos_recipe_components(v_nasi, 1) c
                 where c.item_id = v_sambal));

  -- Scaling is linear and the optional line is still consumed.
  perform pg_temp.check_eq('three plates take three times the rice',
    (select round(c.quantity, 4) from app.pos_recipe_components(v_nasi, 3) c
      where c.item_id = v_rice), 0.54::numeric);
  perform pg_temp.check_true('a garnish is still an ingredient',
    exists (select 1 from app.pos_recipe_components(v_nasi, 1) c
             where c.item_id = v_tin and c.is_optional));

  -- A component that keeps its own stock stops the descent.
  perform public.upsert_pos_recipe(v_org, v_special, 1, jsonb_build_array(
    jsonb_build_object('item', v_rice,  'quantity', 200, 'uom', 'GRM'),
    jsonb_build_object('item', v_paste, 'quantity', 50,  'uom', 'GRM')));
  perform pg_temp.check_eq('a counted sub-assembly is taken as itself',
    (select round(c.quantity, 4) from app.pos_recipe_components(v_special, 1) c
      where c.item_id = v_paste), 0.05::numeric);

  -- Wastage grosses up rather than marking up.
  perform public.upsert_pos_recipe(v_org, v_sambal, 500, jsonb_build_array(
    jsonb_build_object('item', v_chilli, 'quantity', 200, 'uom', 'GRM',
                       'wastage', 10)));
  perform pg_temp.check_eq(
    'ten per cent waste needs 1/0.9 of the weight, not 1.1 of it',
    (select round(c.quantity, 6) from app.pos_recipe_components(v_sambal, 500) c
      where c.item_id = v_chilli), 0.222222::numeric);
  -- Put it back for the arithmetic that follows.
  perform public.upsert_pos_recipe(v_org, v_sambal, 500, jsonb_build_array(
    jsonb_build_object('item', v_chilli, 'quantity', 200, 'uom', 'GRM')));

  -- ------------------------------------------------------------------
  -- 4. The countdown, before anything has been bought
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('with an empty store nothing can be made',
    (select p.portions from public.pos_item_portions(v_outlet) p
      where p.item_id = v_nasi) = 0);

  -- Buy the ingredients in.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values
    (v_org, 'OB-1', current_date, 'opening_balance', v_rice,   v_wh, 10,   4.00),
    (v_org, 'OB-2', current_date, 'opening_balance', v_milk,   v_wh, 2,    6.00),
    (v_org, 'OB-3', current_date, 'opening_balance', v_egg,    v_wh, 30,   0.50),
    (v_org, 'OB-4', current_date, 'opening_balance', v_chilli, v_wh, 1,   20.00),
    (v_org, 'OB-5', current_date, 'opening_balance', v_tin,    v_wh, 100,  3.00),
    (v_org, 'OB-6', current_date, 'opening_balance', v_paste,  v_wh, 1,   30.00);

  -- 10kg of rice at 0.18 is 55 plates; 2L of santan at 0.04 is 50;
  -- 30 eggs is 30; 1kg of chilli at 0.012 is 83. The eggs are the wall.
  select * into v_r from public.pos_item_portions(v_outlet) p
   where p.item_id = v_nasi;
  perform pg_temp.check_eq('the countdown is the scarcest ingredient',
    v_r.portions, 30::numeric);
  perform pg_temp.check_eq('and it names the one that ran out first',
    v_r.limiting_item_name, 'Telur');
  perform pg_temp.check_true('an optional line never limits it',
    v_r.limiting_item_id <> v_tin);

  -- ------------------------------------------------------------------
  -- 5. Settling the bill moves the store
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_nasi, 2, 12.00);

  perform pg_temp.check_eq('a parked bill has moved nothing',
    (select i.quantity_on_hand from public.items i where i.id = v_rice),
    10::numeric);
  perform pg_temp.check_eq('but the countdown knows it is promised',
    (select p.portions from public.pos_item_portions(v_outlet) p
      where p.item_id = v_nasi), 28::numeric);
  perform pg_temp.check_eq('while the shelf itself is unchanged',
    (select p.on_hand_portions from public.pos_item_portions(v_outlet) p
      where p.item_id = v_nasi), 30::numeric);

  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 24.00)));

  perform pg_temp.check_eq('two plates take 360g of rice',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_rice),
    9.64::numeric);
  perform pg_temp.check_eq('and 80ml of santan',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_milk),
    1.92::numeric);
  perform pg_temp.check_eq('and two eggs',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_egg),
    28::numeric);
  perform pg_temp.check_eq('and 24g of chilli, through the sambal',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_chilli),
    0.976::numeric);
  perform pg_temp.check_eq('and the optional garnish too',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tin),
    98::numeric);

  perform pg_temp.check_eq('the dish itself never moves, having no stock',
    (select count(*)::integer from public.stock_movements sm
      where sm.item_id = v_nasi), 0);
  perform pg_temp.check_eq('one movement per ingredient, not one per plate',
    (select count(*)::integer from public.stock_movements sm
      where sm.source_table = 'pos_sales' and sm.source_id = v_sale), 5);

  -- And what it cost. 0.36kg of rice at 4.00 is 1.44; 0.08L of santan
  -- at 6.00 is 0.48; two eggs at 0.50 is 1.00; 0.024kg of chilli at
  -- 20.00 is 0.48; two tins at 3.00 is 6.00. Nine ringgit forty.
  select round(sum(-sm.total_cost), 2) into v_cogs
    from public.stock_movements sm
   where sm.source_table = 'pos_sales' and sm.source_id = v_sale;
  perform pg_temp.check_eq('the food cost is the weighted average of it',
    v_cogs, 9.40::numeric);

  select round(sum(gl.debit), 2) into v_cogs
    from public.gl_lines gl
    join public.gl_entries e on e.id = gl.entry_id
    join public.accounts a on a.id = gl.account_id
   where e.source_table = 'pos_sales' and e.source_id = v_sale
     and a.code = '5200';
  perform pg_temp.check_eq('and it is debited to cost of goods sold',
    v_cogs, 9.40::numeric);

  select round(sum(gl.credit), 2) into v_inv
    from public.gl_lines gl
    join public.gl_entries e on e.id = gl.entry_id
    join public.accounts a on a.id = gl.account_id
   where e.source_table = 'pos_sales' and e.source_id = v_sale
     and a.code = '1310';
  perform pg_temp.check_eq('and credited out of inventory',
    v_inv, 9.40::numeric);

  perform pg_temp.check_true('every movement carries the journal that priced it',
    not exists (select 1 from public.stock_movements sm
                 where sm.source_table = 'pos_sales' and sm.source_id = v_sale
                   and sm.gl_entry_id is null));

  -- ------------------------------------------------------------------
  -- 6. A settled bill is not voided, and this is where that is said
  -- ------------------------------------------------------------------
  -- `void_pos_sale` refuses a completed bill outright, so the
  -- ingredients never come back that way. Asserted rather than assumed,
  -- because the depletion trigger would otherwise be one status change
  -- away from running backwards.
  begin
    perform public.void_pos_sale(v_sale, 'other', 'Kitchen dropped the tray');
    perform pg_temp.check_true('a settled bill cannot be voided', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a settled bill is reversed by a credit note, not a void',
      v_msg like '%credit note%');
  end;
  perform pg_temp.check_eq('so the rice stays where the sale left it',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_rice),
    9.64::numeric);
  perform pg_temp.check_eq('and consuming at the average left it unmoved',
    (select round(i.average_cost, 4) from public.items i where i.id = v_rice),
    4.00::numeric);

  -- ------------------------------------------------------------------
  -- 7. What a modifier takes
  -- ------------------------------------------------------------------
  insert into public.pos_modifier_groups (org_id, code, name, min_select, max_select)
  values (v_org, 'TAMBAH', 'Tambahan', 0, 2) returning id into v_mods;
  insert into public.pos_modifiers
    (org_id, group_id, code, name, price_delta, recipe_item_id,
     recipe_quantity, recipe_uom_code)
  values (v_org, v_mods, 'TELUR2', 'Telur tambahan', 2.00, v_egg, 1, 'C62')
  returning id into v_extra;
  insert into public.item_modifier_groups (org_id, item_id, group_id)
  values (v_org, v_nasi, v_mods);

  v_sale2 := public.open_pos_sale(v_reg);
  v_line := public.add_pos_sale_line(v_sale2, v_nasi, 1, 12.00);
  perform public.add_line_modifier(v_line, v_extra);
  perform public.complete_pos_sale(
    v_sale2, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 14.00)));

  -- 28 on the shelf, one for the plate and one for the modifier.
  perform pg_temp.check_eq('an extra egg is an egg off the shelf',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_egg),
    26::numeric);

  -- ------------------------------------------------------------------
  -- 8. The till refusing
  -- ------------------------------------------------------------------
  -- Off by hand, whatever the switch says. 0258 built the stop list and
  -- the counter has never consulted it.
  perform public.stop_pos_item(v_outlet, v_nasi, 'Beras habis');
  v_sale2 := public.open_pos_sale(v_reg);
  begin
    perform public.add_pos_sale_line(v_sale2, v_nasi, 1, 12.00);
    perform pg_temp.check_true('a stopped dish cannot be rung up', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a stopped dish cannot be rung up, and it repeats the reason',
      v_msg like '%Beras habis%');
  end;
  perform public.resume_pos_item(v_outlet, v_nasi);
  perform pg_temp.check_true('and can be again once it is back',
    public.add_pos_sale_line(v_sale2, v_nasi, 1, 12.00) is not null);
  perform public.void_pos_sale(v_sale2, 'customer_cancelled', 'Clearing the bench');

  -- The count. Off by default, because most shops never weigh the rice.
  update public.items set quantity_on_hand = quantity_on_hand where id = v_egg;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'ADJ-1', current_date, 'adjustment_out', v_egg, v_wh, -24, 0);

  perform pg_temp.check_eq('two eggs left is two plates',
    (select p.portions from public.pos_item_portions(v_outlet) p
      where p.item_id = v_nasi), 2::numeric);

  v_sale2 := public.open_pos_sale(v_reg);
  perform pg_temp.check_true('with the switch off the till sells anyway',
    public.add_pos_sale_line(v_sale2, v_nasi, 5, 12.00) is not null);
  perform public.void_pos_sale(v_sale2, 'customer_cancelled', 'Clearing the bench');

  update public.pos_settings set block_out_of_stock = true where org_id = v_org;

  v_sale2 := public.open_pos_sale(v_reg);
  begin
    perform public.add_pos_sale_line(v_sale2, v_nasi, 5, 12.00);
    perform pg_temp.check_true('with it on the till refuses', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'with it on the till refuses, and says how many are left',
      v_msg like '%only enough left for 2%');
  end;
  perform pg_temp.check_true('but sells what it can',
    public.add_pos_sale_line(v_sale2, v_nasi, 2, 12.00) is not null);
  begin
    perform public.add_pos_sale_line(v_sale2, v_nasi, 1, 12.00);
    perform pg_temp.check_true('and not one more, the bill being counted', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and not one more, the parked bill being counted against it',
      v_msg like '%run out%');
  end;
  perform public.void_pos_sale(v_sale2, 'customer_cancelled', 'Clearing the bench');

  -- A dish with no recipe is never blocked by a count nobody keeps.
  perform pg_temp.check_true('a dish with no recipe has no countdown',
    not exists (select 1 from public.pos_item_portions(v_outlet) p
                 where p.item_id = v_tin));

  -- ------------------------------------------------------------------
  -- 9. What the screens read
  -- ------------------------------------------------------------------
  select * into v_r from public.pos_item_availability(v_outlet) a
   where a.item_id = v_nasi;
  perform pg_temp.check_true('the till is told what is available',
    v_r.available);
  perform pg_temp.check_eq('and how many',
    v_r.portions, 2::numeric);

  perform public.stop_pos_item(v_outlet, v_nasi, 'Habis');
  select * into v_r from public.pos_item_availability(v_outlet) a
   where a.item_id = v_nasi;
  perform pg_temp.check_true('a stop shows up as unavailable', not v_r.available);
  perform pg_temp.check_eq('with the reason a manager typed',
    v_r.off_reason, 'Habis');
  perform public.resume_pos_item(v_outlet, v_nasi);

  perform pg_temp.check_eq('the list costs each recipe at what it holds',
    (select round(l.cost_per_unit, 2) from public.pos_recipes_list(v_org) l
      where l.item_id = v_nasi), 4.70::numeric);
  perform pg_temp.check_eq('and counts its lines',
    (select l.line_count from public.pos_recipes_list(v_org) l
      where l.item_id = v_nasi), 5);
  perform pg_temp.check_eq('the editor reads them back in order',
    (select count(*)::integer from public.pos_recipe_lines_for(v_rec)), 5);
  perform pg_temp.check_eq('and the requirement is the exploded one',
    (select count(*)::integer from public.pos_recipe_requirement(v_nasi, 1)), 5);

  -- The till's own menu carries the same two answers, so the tile and
  -- the guard behind it can never disagree.
  select * into v_r from public.pos_menu(v_outlet) m where m.item_id = v_nasi;
  perform pg_temp.check_eq('the menu carries the countdown',
    v_r.portions, 2::numeric);
  perform pg_temp.check_true('and is still on with the switch on and stock left',
    v_r.available);

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'ADJ-2', current_date, 'adjustment_out', v_egg, v_wh, -2, 0);

  select * into v_r from public.pos_menu(v_outlet) m where m.item_id = v_nasi;
  perform pg_temp.check_true('and greys out when the kitchen runs out',
    not v_r.available);
  perform pg_temp.check_eq('naming what ran out',
    v_r.off_reason, 'Out of telur');

  update public.pos_settings set block_out_of_stock = false where org_id = v_org;
  select * into v_r from public.pos_menu(v_outlet) m where m.item_id = v_nasi;
  perform pg_temp.check_true('but with the switch off the tile stays live',
    v_r.available);
  perform pg_temp.check_eq('while the number is still advice',
    v_r.portions, 0::numeric);

  perform pg_temp.check_true('deleting a recipe takes its lines with it',
    public.delete_pos_recipe(v_rec));
  perform pg_temp.check_eq('and leaves nothing behind',
    (select count(*)::integer from public.pos_recipe_lines l
      where l.recipe_id = v_rec), 0);
  perform pg_temp.check_true('after which nothing is drawn for it',
    not exists (select 1 from app.pos_recipe_components(v_nasi, 1)));

  raise notice 'ok   pos_recipes';
end $$;

rollback;

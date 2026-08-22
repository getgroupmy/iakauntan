-- =====================================================================
-- The van, and the chicken that becomes eight pieces
--
-- Two arithmetics, and they are the reason this file exists.
--
--   1. A transfer conserves value. What leaves the kitchen at its
--      weighted average arrives at the shop at the same unit cost, and
--      1320 Goods in Transit is empty again at the end. A transfer that
--      re-values stock on the way is a company moving profit between
--      its own warehouses.
--
--   2. A conversion conserves value. A chicken that cost twelve ringgit
--      is twelve ringgit of inventory after somebody has cut it into
--      four pieces. A cost share that does not total a hundred invents
--      or destroys stock value with a knife, and is refused when it is
--      saved rather than discovered at the year end.
--
-- The rest is the state machine: nothing arrives that was not sent,
-- nothing is sent twice, and a shortfall is named rather than absorbed.
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
  v_kitchen uuid;
  v_shop   uuid;

  v_rice   uuid;
  v_chicken uuid;
  v_breast uuid;
  v_thigh  uuid;
  v_wing   uuid;

  v_t      uuid;
  v_conv   uuid;
  v_l      record;
  v_nosy   uuid;
  v_lines  jsonb;
  v_r      record;
  v_msg    text;
  v_n      numeric;
  v_line   uuid;
  v_value  numeric;
begin
  v_org := pg_temp.test_org('Dapur Pusat Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','pos']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Central kitchen', true) returning id into v_kitchen;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'KEDAI', 'The shop') returning id into v_shop;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'BERAS', 'Beras', 'stock', true, 'KGM', 4.00)
  returning id into v_rice;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'AYAM', 'Ayam sebiji', 'stock', true, 'C62', 12.00)
  returning id into v_chicken;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'DADA', 'Dada ayam', 'stock', true, 'C62')
  returning id into v_breast;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'PEHA', 'Peha ayam', 'stock', true, 'C62')
  returning id into v_thigh;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'KEPAK', 'Kepak ayam', 'stock', true, 'C62')
  returning id into v_wing;

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values
    (v_org, 'OB-1', current_date, 'opening_balance', v_rice,    v_kitchen, 100, 4.00),
    (v_org, 'OB-2', current_date, 'opening_balance', v_chicken, v_kitchen,  10, 12.00);

  -- ------------------------------------------------------------------
  -- 1. Writing a transfer down
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_rice, 'quantity', 20, 'uom', 'KGM')),
    'Monday delivery');

  perform pg_temp.check_true('a transfer gets a number of its own',
    (select t.transfer_no from public.stock_transfers t where t.id = v_t)
      like 'STN-%');
  perform pg_temp.check_eq('and starts as a draft',
    (select t.status::text from public.stock_transfers t where t.id = v_t),
    'draft');

  -- Two places, and they have to be two.
  begin
    perform public.upsert_stock_transfer(
      null, v_org, v_kitchen, v_kitchen, current_date, '[]'::jsonb);
    perform pg_temp.check_true('a store cannot send to itself', false);
  exception when others then
    perform pg_temp.check_true('a store cannot send to itself', true);
  end;

  -- Only stocked items. Moving a service between warehouses is moving
  -- nothing.
  begin
    perform public.upsert_stock_transfer(
      null, v_org, v_kitchen, v_shop, current_date,
      jsonb_build_array(
        jsonb_build_object('item', v_breast, 'quantity', 1, 'uom', 'LTR')));
    perform pg_temp.check_true('a unit that does not convert is refused', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a unit that does not convert is refused when it is typed',
      v_msg like '%no way to turn%');
  end;

  -- And a kitchen cannot send what it has not got.
  perform public.upsert_stock_transfer(
    v_t, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_rice, 'quantity', 500, 'uom', 'KGM')));
  begin
    perform public.send_stock_transfer(v_t);
    perform pg_temp.check_true('nothing leaves that is not there', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'nothing leaves that is not there, and it names what',
      v_msg like '%Beras%');
  end;

  -- ------------------------------------------------------------------
  -- 2. Loading the van
  -- ------------------------------------------------------------------
  -- Written in bags, which this shop has said hold ten kilograms each.
  perform public.upsert_item_uom_pack(v_rice, 'BG', 10);
  perform public.upsert_stock_transfer(
    v_t, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_rice, 'quantity', 2, 'uom', 'BG')));

  perform public.send_stock_transfer(v_t);

  perform pg_temp.check_eq('sending resolves the unit it was written in',
    (select l.sent_quantity from public.stock_transfer_lines l
      where l.transfer_id = v_t), 20::numeric);
  perform pg_temp.check_eq('at the store''s own weighted average',
    (select l.sent_unit_cost from public.stock_transfer_lines l
      where l.transfer_id = v_t), 4::numeric);

  perform pg_temp.check_eq('the kitchen is twenty kilograms lighter',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_kitchen),
    80::numeric);
  perform pg_temp.check_true('and the shop has nothing yet',
    coalesce((select sl.quantity from public.stock_levels sl
               where sl.item_id = v_rice and sl.warehouse_id = v_shop), 0) = 0);

  -- Which is the whole reason 1320 exists.
  perform pg_temp.check_eq('the value is in goods in transit, not nowhere',
    (select round(sum(gl.debit - gl.credit), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = (select t.send_entry_id from public.stock_transfers t
                            where t.id = v_t)
        and a.code = '1320'), 80::numeric);
  perform pg_temp.check_eq('taken out of inventory to get there',
    (select round(sum(gl.credit - gl.debit), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = (select t.send_entry_id from public.stock_transfers t
                            where t.id = v_t)
        and a.code = '1310'), 80::numeric);

  -- A sent transfer is a record, not a draft.
  begin
    perform public.upsert_stock_transfer(
      v_t, v_org, v_kitchen, v_shop, current_date, '[]'::jsonb);
    perform pg_temp.check_true('a sent transfer cannot be re-typed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a sent transfer cannot be re-typed, and it says what to do instead',
      v_msg like '%Receive it%');
  end;
  begin
    perform public.send_stock_transfer(v_t);
    perform pg_temp.check_true('nor sent a second time', false);
  exception when others then
    perform pg_temp.check_true('nor sent a second time', true);
  end;
  begin
    perform public.cancel_stock_transfer(v_t);
    perform pg_temp.check_true('nor cancelled once the stock has moved', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'nor cancelled once the stock has moved',
      v_msg like '%other way%');
  end;

  -- ------------------------------------------------------------------
  -- 3. Counting it in
  -- ------------------------------------------------------------------
  select l.id into v_line from public.stock_transfer_lines l
   where l.transfer_id = v_t;

  begin
    perform public.receive_stock_transfer(v_t,
      jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 25)));
    perform pg_temp.check_true('more cannot arrive than was sent', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'more cannot arrive than was sent',
      v_msg like '%cannot have arrived%');
  end;

  perform public.receive_stock_transfer(v_t);

  perform pg_temp.check_eq('an uncounted line is taken as having all arrived',
    (select l.received_quantity from public.stock_transfer_lines l
      where l.id = v_line), 20::numeric);
  perform pg_temp.check_eq('the shop has its twenty kilograms',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_shop),
    20::numeric);
  perform pg_temp.check_eq('at the price they left at, not a new one',
    (select round(sl.average_cost, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_shop),
    4::numeric);
  perform pg_temp.check_eq('and the company still has a hundred of them',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_rice),
    100::numeric);

  -- The assertion the whole design is for.
  perform pg_temp.check_eq('goods in transit is empty again',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '1320'), 0::numeric);
  perform pg_temp.check_eq('and inventory is back where it started',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_table = 'stock_transfers' and a.code = '1310'),
    0::numeric);

  -- ------------------------------------------------------------------
  -- 4. A van that loses a bag
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, current_date,
    jsonb_build_array(
      jsonb_build_object('item', v_rice, 'quantity', 10, 'uom', 'KGM')));
  perform public.send_stock_transfer(v_t);
  select l.id into v_line from public.stock_transfer_lines l
   where l.transfer_id = v_t;
  perform public.receive_stock_transfer(v_t,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 9)));

  perform pg_temp.check_eq('nine arriving of ten sent puts nine on the shelf',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_rice and sl.warehouse_id = v_shop),
    29::numeric);
  perform pg_temp.check_eq('and the missing one is a loss with a name',
    (select round(sum(gl.debit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.source_id = v_t and a.code = '5900'), 4::numeric);
  perform pg_temp.check_eq('transit is cleared whether or not it arrived',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '1320'), 0::numeric);
  perform pg_temp.check_eq('and the list says what it was short by',
    (select l.shortfall from public.stock_transfers_list(v_org) l
      where l.id = v_t), 4::numeric);
  perform pg_temp.check_eq('the company is one bag lighter than it was',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_rice),
    99::numeric);

  -- ------------------------------------------------------------------
  -- What the receiving branch reads off the note
  --
  -- `stock_transfer_lines_for` is how the screen draws that van's
  -- contents, and it was called by nothing. Two of its columns are the
  -- whole point of the screen: what was sent against what arrived, which
  -- is the discrepancy somebody has to explain, and the unit the item is
  -- actually stocked in beside the unit it was sent in.
  -- ------------------------------------------------------------------
  select * into v_l from public.stock_transfer_lines_for(v_t)
   where item_id = v_rice;
  perform pg_temp.check_eq('the line names the item',
    v_l.item_name, 'Beras');
  perform pg_temp.check_eq('what was asked for', v_l.quantity, 10::numeric);
  perform pg_temp.check_eq('what left the kitchen', v_l.sent_quantity, 10::numeric);
  perform pg_temp.check_eq('and what arrived at the shop',
    v_l.received_quantity, 9::numeric);
  perform pg_temp.check_eq('at what it was carried out at',
    v_l.sent_unit_cost, 4::numeric);
  -- `base_uom` is deliberately not asserted here. Everything in this
  -- fixture is sent in the unit it is stocked in, so the item's unit and
  -- the line's are the same string and an assertion on either would hold
  -- with the two columns swapped. The distinction belongs with a
  -- multi-unit transfer, and there is not one in this file.
  perform pg_temp.check_eq('one line, not every line in the company',
    (select count(*) from public.stock_transfer_lines_for(v_t)), 1);

  begin
    perform * from public.stock_transfer_lines_for(gen_random_uuid());
    perform pg_temp.check_true('a transfer that does not exist is refused', false);
  exception when sqlstate 'P0002' then
    perform pg_temp.check_true('a transfer that does not exist is refused', true);
  end;

  -- ------------------------------------------------------------------
  -- 5. The chicken
  -- ------------------------------------------------------------------
  -- Shares that do not add up are refused when they are written.
  begin
    perform public.upsert_item_conversion(
      null, v_org, 'AYAM4', 'Potong ayam', v_chicken, 1, 'C62',
      jsonb_build_array(
        jsonb_build_object('item', v_breast, 'quantity', 2, 'share', 40),
        jsonb_build_object('item', v_thigh,  'quantity', 2, 'share', 35)));
    perform pg_temp.check_true('a split has to add up to a hundred', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a split has to add up to a hundred, and it says what it came to',
      v_msg like '%75%');
  end;

  -- Nor may a conversion produce what it consumes.
  begin
    perform public.upsert_item_conversion(
      null, v_org, 'SILLY', 'Silly', v_chicken, 1, 'C62',
      jsonb_build_array(
        jsonb_build_object('item', v_chicken, 'quantity', 1, 'share', 100)));
    perform pg_temp.check_true('a conversion into itself is not one', false);
  exception when others then
    perform pg_temp.check_true('a conversion into itself is not one', true);
  end;

  v_conv := public.upsert_item_conversion(
    null, v_org, 'AYAM4', 'Potong ayam', v_chicken, 1, 'C62',
    jsonb_build_array(
      jsonb_build_object('item', v_breast, 'quantity', 2, 'share', 40),
      jsonb_build_object('item', v_thigh,  'quantity', 2, 'share', 35),
      jsonb_build_object('item', v_wing,   'quantity', 2, 'share', 25)));

  perform pg_temp.check_eq('a conversion keeps its outputs',
    (select c.output_count from public.item_conversions_list(v_org) c
      where c.id = v_conv), 3);

  v_value := public.run_item_conversion(v_conv, 2, v_kitchen);

  perform pg_temp.check_eq('two chickens at twelve is twenty-four of value',
    v_value, 24::numeric);

  -- ------------------------------------------------------------------
  -- What the recipe screen shows
  --
  -- `item_conversion_outputs_for` was called by nothing, and `cost_share`
  -- is the only figure on it that is a decision rather than a fact: it
  -- is how a twelve ringgit bird is split between the breast, the thigh
  -- and the wing, and it is what every one of those three is then
  -- costed at. The shares have to come back as they were set and in the
  -- order they were set, because the screen edits them in place.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the outputs come back in the order they were set',
    -- Aggregated in the order the function returned them. Ordering by
    -- line_no here would be the test doing the sorting and asserting
    -- nothing about the function.
    (select string_agg(o.item_name, ',')
       from public.item_conversion_outputs_for(v_conv) o),
    'Dada ayam,Peha ayam,Kepak ayam');
  perform pg_temp.check_eq('with the share the breast was given',
    (select o.cost_share from public.item_conversion_outputs_for(v_conv) o
      where o.item_id = v_breast), 40::numeric);
  perform pg_temp.check_eq('and the wing',
    (select o.cost_share from public.item_conversion_outputs_for(v_conv) o
      where o.item_id = v_wing), 25::numeric);
  perform pg_temp.check_eq('which come to the whole bird and no more',
    (select sum(o.cost_share) from public.item_conversion_outputs_for(v_conv) o),
    100::numeric);
  perform pg_temp.check_eq('and how many of each one bird makes',
    (select o.quantity from public.item_conversion_outputs_for(v_conv) o
      where o.item_id = v_thigh), 2::numeric);

  begin
    perform * from public.item_conversion_outputs_for(gen_random_uuid());
    perform pg_temp.check_true('a conversion that does not exist is refused', false);
  exception when sqlstate 'P0002' then
    perform pg_temp.check_true('a conversion that does not exist is refused', true);
  end;

  -- A recipe is what this kitchen has worked out its yields to be, and
  -- how it costs them. Both listers resolve the company from the parent
  -- row, so the module check is all there is between a stranger and it.
  --
  -- Signed in again after each block on purpose: a caught exception
  -- rolls back to a savepoint and takes `set_config(..., true)` with it,
  -- so without this the second assertion would be made by the owner and
  -- would fail against a function behaving correctly.
  v_nosy := pg_temp.another_user('nosy@ayam.test');
  perform pg_temp.sign_in_as(v_nosy);
  begin
    perform * from public.item_conversion_outputs_for(v_conv);
    perform pg_temp.check_true('another kitchen''s recipe is refused', false);
  exception when sqlstate '42501' then
    perform pg_temp.check_true('another kitchen''s recipe is refused', true);
  end;
  perform pg_temp.sign_in_as(v_nosy);
  begin
    perform * from public.stock_transfer_lines_for(v_t);
    perform pg_temp.check_true('and so is another shop''s van', false);
  exception when sqlstate '42501' then
    perform pg_temp.check_true('and so is another shop''s van', true);
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('two chickens leave the store',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_chicken and sl.warehouse_id = v_kitchen),
    8::numeric);
  perform pg_temp.check_eq('four breasts arrive',
    (select round(sl.quantity, 4) from public.stock_levels sl
      where sl.item_id = v_breast and sl.warehouse_id = v_kitchen),
    4::numeric);

  -- 40% of 24 is 9.60 across four breasts: 2.40 each.
  perform pg_temp.check_eq('carrying two-fifths of what a chicken cost',
    (select round(sl.average_cost, 4) from public.stock_levels sl
      where sl.item_id = v_breast and sl.warehouse_id = v_kitchen),
    2.4::numeric);
  perform pg_temp.check_eq('a thigh a little less',
    (select round(sl.average_cost, 4) from public.stock_levels sl
      where sl.item_id = v_thigh and sl.warehouse_id = v_kitchen),
    2.1::numeric);
  perform pg_temp.check_eq('and a wing least of all',
    (select round(sl.average_cost, 4) from public.stock_levels sl
      where sl.item_id = v_wing and sl.warehouse_id = v_kitchen),
    1.5::numeric);

  -- The assertion this is all for.
  select round(sum(sl.value), 2) into v_n
    from public.stock_levels sl
   where sl.item_id in (v_breast, v_thigh, v_wing);
  perform pg_temp.check_eq(
    'what came out is worth exactly what went in', v_n, 24::numeric);

  perform pg_temp.check_eq('and no journal was posted, nothing having left 1310',
    (select count(*)::integer from public.gl_entries e
      where e.source_table = 'item_conversions'), 0);

  -- A kitchen cannot cut up chickens it does not have.
  begin
    perform public.run_item_conversion(v_conv, 100, v_kitchen);
    perform pg_temp.check_true('nor cut up what is not there', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nor cut up what is not there',
      v_msg like '%not that much%');
  end;

  -- Switched off is switched off.
  perform public.upsert_item_conversion(
    v_conv, v_org, 'AYAM4', 'Potong ayam', v_chicken, 1, 'C62',
    jsonb_build_array(
      jsonb_build_object('item', v_breast, 'quantity', 2, 'share', 40),
      jsonb_build_object('item', v_thigh,  'quantity', 2, 'share', 35),
      jsonb_build_object('item', v_wing,   'quantity', 2, 'share', 25)),
    false);
  begin
    perform public.run_item_conversion(v_conv, 1, v_kitchen);
    perform pg_temp.check_true('a retired conversion does not run', false);
  exception when others then
    perform pg_temp.check_true('a retired conversion does not run', true);
  end;

  perform pg_temp.check_true('and it can be deleted',
    public.delete_item_conversion(v_conv));
  perform pg_temp.check_eq('taking its outputs with it',
    (select count(*)::integer from public.item_conversion_outputs o
      where o.conversion_id = v_conv), 0);

  raise notice 'ok   stock_transfers';
end $$;

rollback;

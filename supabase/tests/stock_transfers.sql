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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
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
    (v_org, 'OB-1', pg_temp.today(), 'opening_balance', v_rice,    v_kitchen, 100, 4.00),
    (v_org, 'OB-2', pg_temp.today(), 'opening_balance', v_chicken, v_kitchen,  10, 12.00);

  -- ------------------------------------------------------------------
  -- 1. Writing a transfer down
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_kitchen, v_shop, pg_temp.today(),
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
      null, v_org, v_kitchen, v_kitchen, pg_temp.today(), '[]'::jsonb);
    perform pg_temp.check_true('a store cannot send to itself', false);
  exception when others then
    perform pg_temp.check_true('a store cannot send to itself', true);
  end;

  -- Only stocked items. Moving a service between warehouses is moving
  -- nothing.
  begin
    perform public.upsert_stock_transfer(
      null, v_org, v_kitchen, v_shop, pg_temp.today(),
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
    v_t, v_org, v_kitchen, v_shop, pg_temp.today(),
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
    v_t, v_org, v_kitchen, v_shop, pg_temp.today(),
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
      v_t, v_org, v_kitchen, v_shop, pg_temp.today(), '[]'::jsonb);
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
    null, v_org, v_kitchen, v_shop, pg_temp.today(),
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

-- ---------------------------------------------------------------------
-- What sending a van refuses
-- ---------------------------------------------------------------------
-- The block above asserts the two arithmetics — value conserved on the
-- road, value conserved under the knife — and the shortfall. It does
-- not assert the state machine around them, and a sweep of
-- `send_stock_transfer` found every refusal open: sending twice,
-- sending nothing, sending as somebody outside the company, and the
-- setting that lets a company go short on purpose.
--
-- The permission case uses a stranger rather than a viewer, because a
-- member with no access type assigned has module write whatever their
-- role (`0501`). A viewer is not refused here and asserting that they
-- are would be asserting something untrue.
do $$
declare
  v_org   uuid;
  v_a     uuid;
  v_b     uuid;
  v_item  uuid;
  v_t     uuid;
  v_empty uuid;
  v_short uuid;
  v_tracked uuid;
  v_batch uuid;
  v_lot   uuid;
  v_mv    uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Van Kedua Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','pos']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'SATU', 'Store one', true) returning id into v_a;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'DUA', 'Store two') returning id into v_b;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'KOTAK', 'Kotak', 'stock', true, 'C62', 5.00)
  returning id into v_item;

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'VK-0001', pg_temp.today(), 'opening_balance', v_item, v_a, 20, 5);

  -- ------------------------------------------------------------------
  -- Nothing on it
  -- ------------------------------------------------------------------
  v_empty := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(), '[]'::jsonb, 'Empty van');
  begin
    perform public.send_stock_transfer(v_empty);
    raise exception 'FAIL sent a transfer with nothing on it';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an empty van is not a transfer',
      v_msg like '%nothing on this transfer%');
  end;

  -- ------------------------------------------------------------------
  -- Who may send it
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_item, 'quantity', 5, 'uom', 'C62')),
    'Five boxes');

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-van@example.test'));
  begin
    perform public.send_stock_transfer(v_t);
    raise exception 'FAIL a stranger sent a transfer';
  exception when insufficient_privilege then
    raise notice 'ok   somebody outside the company cannot send its stock';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- Once
  -- ------------------------------------------------------------------
  perform public.send_stock_transfer(v_t);
  perform pg_temp.check_eq('five boxes leave the first store',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_a), 15);

  begin
    perform public.send_stock_transfer(v_t);
    raise exception 'FAIL sent the same transfer twice';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a van already gone cannot go again',
      v_msg like '%already sent%');
  end;
  perform pg_temp.check_eq('so the store is down five, not ten',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_a), 15);

  -- ------------------------------------------------------------------
  -- Going short on purpose
  -- ------------------------------------------------------------------
  -- Fifteen left and twenty asked for. A company that has not said it
  -- allows negative stock is refused; one that has is not. Both halves
  -- are asserted, because the setting is only a setting if turning it
  -- on changes something.
  v_short := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_item, 'quantity', 20, 'uom', 'C62')),
    'More than there is');
  begin
    perform public.send_stock_transfer(v_short);
    raise exception 'FAIL sent more than the store held';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a store cannot send what it does not have',
      v_msg like '%not that much%');
  end;

  insert into public.pos_settings (org_id, allow_negative_stock)
  values (v_org, true)
  on conflict (org_id) do update set allow_negative_stock = true;

  perform public.send_stock_transfer(v_short);
  perform pg_temp.check_eq(
    'unless the company has said it may, and then the store goes negative',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_a), -5);

  -- ------------------------------------------------------------------
  -- A batch nobody has
  -- ------------------------------------------------------------------
  -- Allowing negative stock is a decision about the COUNT. It is not a
  -- decision about batches: a batch-tracked item can only move if the
  -- batches are there to move, because a van cannot carry a lot number
  -- that does not exist. The setting is left on here deliberately, so
  -- the refusal can only be coming from the lot check.
  -- Brought in untracked and then declared batch-tracked, which is how
  -- the other lot fixtures do it: a movement of a tracked item has to
  -- name its lots as it posts, so the stock arrives first and the
  -- batches are attached to it afterwards.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'UBAT', 'Ubat', 'stock', true, 'C62', 9.00)
  returning id into v_tracked;

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'VK-0002', pg_temp.today(), 'opening_balance', v_tracked, v_a, 6, 9)
  returning id into v_mv;

  update public.items set tracking = 'batch' where id = v_tracked;
  insert into public.stock_lots (org_id, item_id, lot_ref, kind, expiry_date)
  values (v_org, v_tracked, 'LOT-A', 'batch', pg_temp.today() + 365)
  returning id into v_lot;
  insert into public.stock_movement_lots (org_id, movement_id, lot_id, quantity)
  values (v_org, v_mv, v_lot, 6);

  perform pg_temp.check_eq('six in the batch, and six on the shelf',
    app.lot_available(v_tracked, v_a), 6);

  v_batch := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_tracked, 'quantity', 10, 'uom', 'C62')),
    'Ten of six');
  begin
    perform public.send_stock_transfer(v_batch);
    raise exception 'FAIL sent more batches than exist';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a van cannot carry a batch nobody has, negative stock or not',
      v_msg like '%batches of%');
  end;
end $$;

-- ---------------------------------------------------------------------
-- What receiving a van refuses
-- ---------------------------------------------------------------------
-- The same shape again. Everything about what receiving DOES to the
-- ledger is asserted — the price it arrives at, the shortfall charged
-- to 5900, transit cleared of both what came and what was lost — and
-- everything about when it may happen was open.
do $$
declare
  v_org   uuid;
  v_a     uuid;
  v_b     uuid;
  v_item  uuid;
  v_t     uuid;
  v_line  uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Van Ketiga Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','pos']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'SATU', 'Store one', true) returning id into v_a;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'DUA', 'Store two') returning id into v_b;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'TIN', 'Tin', 'stock', true, 'C62', 3.00)
  returning id into v_item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'VT-0001', pg_temp.today(), 'opening_balance', v_item, v_a, 20, 3);

  v_t := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_item, 'quantity', 8, 'uom', 'C62')),
    'Eight tins');

  -- ------------------------------------------------------------------
  -- Nothing is on its way yet
  -- ------------------------------------------------------------------
  begin
    perform public.receive_stock_transfer(v_t);
    raise exception 'FAIL received a transfer that was never sent';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a van still in the yard has not arrived',
      v_msg like '%nothing on its way%');
  end;

  perform public.send_stock_transfer(v_t);
  select l.id into v_line from public.stock_transfer_lines l
   where l.transfer_id = v_t;

  -- ------------------------------------------------------------------
  -- Who may sign for it
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-terima@example.test'));
  begin
    perform public.receive_stock_transfer(v_t);
    raise exception 'FAIL a stranger signed for a delivery';
  exception when insufficient_privilege then
    raise notice 'ok   somebody outside the company cannot sign for its stock';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- A count that is not a count
  -- ------------------------------------------------------------------
  begin
    perform public.receive_stock_transfer(v_t, jsonb_build_array(
      jsonb_build_object('line', v_line, 'quantity', -2)));
    raise exception 'FAIL accepted a negative count';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('minus two tins is not a count',
      v_msg like '%cannot be negative%');
  end;

  -- ------------------------------------------------------------------
  -- Signed for once
  -- ------------------------------------------------------------------
  perform public.receive_stock_transfer(v_t, jsonb_build_array(
    jsonb_build_object('line', v_line, 'quantity', 8)));
  perform pg_temp.check_true('the transfer says it has arrived',
    (select t.status::text = 'received' from public.stock_transfers t
      where t.id = v_t));
  perform pg_temp.check_eq('and the eight tins are in the second store',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_b), 8);

  begin
    perform public.receive_stock_transfer(v_t);
    raise exception 'FAIL signed for the same delivery twice';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a van already unloaded cannot arrive again',
      v_msg like '%nothing on its way%');
  end;
  perform pg_temp.check_eq('so the second store has eight, not sixteen',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_b), 8);
end $$;

-- ---------------------------------------------------------------------
-- Van Keempat Sdn Bhd: calling off a transfer that has not left
--
-- Cancelling is three lines of code and had one assertion behind it —
-- that a van already on the road cannot be called back.  Sweeping
-- cancel_stock_transfer left the other three open: a transfer id that
-- is not a transfer reported as cancelled, a stranger calling off
-- another company's transfer, and the transfer left sitting in draft
-- after the call was made.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_a     uuid;
  v_b     uuid;
  v_item  uuid;
  v_t     uuid;
  v_t2    uuid;
  v_owner uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Van Keempat Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','pos']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'SATU', 'Store one', true) returning id into v_a;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'DUA', 'Store two') returning id into v_b;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'BEG', 'Bag', 'stock', true, 'C62', 4.00)
  returning id into v_item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'VK-0001', pg_temp.today(), 'opening_balance', v_item, v_a, 12, 4);

  v_t := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_item, 'quantity', 5, 'uom', 'C62')),
    'Five bags');

  -- ------------------------------------------------------------------
  -- A transfer that is not a transfer
  -- ------------------------------------------------------------------
  perform pg_temp.check_true(
    'an id that names no transfer cannot be called off',
    public.cancel_stock_transfer(gen_random_uuid()) = false);

  -- ------------------------------------------------------------------
  -- Who may call it off
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-batal@example.test'));
  begin
    perform public.cancel_stock_transfer(v_t);
    raise exception 'FAIL a stranger called off another company''s transfer';
  exception when insufficient_privilege then
    raise notice 'ok   somebody outside the company cannot call off its transfer';
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and the transfer is still standing in draft',
    (select t.status::text = 'draft' from public.stock_transfers t
      where t.id = v_t));

  -- ------------------------------------------------------------------
  -- Called off before it left
  -- ------------------------------------------------------------------
  -- A second draft beside it, so "this transfer" and "every draft the
  -- company has" are not the same rows (`mutants/cancel_stock_transfer.py`
  -- found them indistinguishable with one).
  v_t2 := public.upsert_stock_transfer(
    null, v_org, v_a, v_b, pg_temp.today(),
    jsonb_build_array(jsonb_build_object(
      'item', v_item, 'quantity', 2, 'uom', 'C62')),
    'Two bags, still going');
  perform pg_temp.check_true('a transfer still in the yard is called off',
    public.cancel_stock_transfer(v_t) = true);
  perform pg_temp.check_true('and the one beside it is still going',
    (select t.status::text = 'draft' from public.stock_transfers t
      where t.id = v_t2));
  perform pg_temp.check_true('and the transfer says it was cancelled',
    (select t.status::text = 'cancelled' from public.stock_transfers t
      where t.id = v_t));
  perform pg_temp.check_eq('with no stock moved out of the first store',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_a), 12);
end $$;

-- ---------------------------------------------------------------------
-- The three a mutation run found no file could see
-- ---------------------------------------------------------------------
--
-- `public.send_stock_transfer` was mutated 23 ways on 5 October.
-- Nineteen died against the assertions above and four survived; running
-- the other two files that reach it -- `lot_allocation_shapes.sql` and
-- `lots_across_the_new_sources.sql` -- killed one more, because both
-- transfer BATCH-TRACKED items and so reach the `app.lot_available`
-- check this file's items skip entirely.
--
--     python3 scripts/mutate_sql.py \
--       supabase/migrations/0267_the_batch_that_went_in_the_van.sql \
--       supabase/tests/stock_transfers.sql \
--       supabase/tests/mutants/send_stock_transfer.py
--
-- Four survivors in one file against three in the union, which is the
-- same arithmetic as every other function in this sweep: a per-file
-- score understates what the suite as a whole asserts.
--
-- The three that survived everywhere:
--
--   * `< v_qty` on the stock check, mutated to `<=`. Sending a store's
--     ENTIRE holding is the ordinary last transfer of a line, and no
--     fixture above empties a store completely -- every one leaves a
--     remainder, so "not enough" and "exactly enough" were never
--     distinguished.
--   * the 1310 guard, which no company in the suite is without.
--   * the movement-to-journal link, which nothing asserted at all.
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_poor  uuid;
  v_from  uuid;
  v_to    uuid;
  v_item  uuid;
  v_t     uuid;
  v_entry uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();

  -- ------------------------------------------------------------------
  -- Emptying a store is allowed; a gram more is not
  -- ------------------------------------------------------------------
  v_org := pg_temp.test_org('Pindah Habis Sdn Bhd');
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'A', 'Store A', true) returning id into v_from;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'B', 'Store B') returning id into v_to;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'TIN', 'Tin susu', 'stock', true, 'C62', 5.00)
  returning id into v_item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'OPEN-TIN', pg_temp.today(), 'opening_balance', v_item,
          v_from, 30, 5.00);
  perform pg_temp.check_eq('store A holds thirty',
    (select sl.quantity from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_from), 30);

  -- One more than it holds: refused.
  insert into public.stock_transfers
    (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id,
     status)
  values (v_org, 'TR-31', pg_temp.today(), v_from, v_to, 'draft')
  returning id into v_t;
  insert into public.stock_transfer_lines
    (org_id, transfer_id, line_no, item_id, quantity, uom_code)
  values (v_org, v_t, 1, v_item, 31, 'C62');
  perform pg_temp.check_refused(
    'thirty-one out of thirty is refused',
    format('select public.send_stock_transfer(%L)', v_t),
    '%not that much%', '23514');

  -- Exactly what it holds: allowed. This is the assertion the mutation
  -- run was missing -- every fixture above leaves a remainder behind,
  -- so `< v_qty` and `<= v_qty` gave the same answer throughout.
  insert into public.stock_transfers
    (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id,
     status)
  values (v_org, 'TR-30', pg_temp.today(), v_from, v_to, 'draft')
  returning id into v_t;
  insert into public.stock_transfer_lines
    (org_id, transfer_id, line_no, item_id, quantity, uom_code)
  values (v_org, v_t, 1, v_item, 30, 'C62');
  v_entry := public.send_stock_transfer(v_t);
  perform pg_temp.check_true('but exactly thirty goes, emptying the store',
    v_entry is not null);
  perform pg_temp.check_eq('and store A is empty',
    (select coalesce(sl.quantity, 0) from public.stock_levels sl
      where sl.item_id = v_item and sl.warehouse_id = v_from), 0);

  -- ------------------------------------------------------------------
  -- The movements name the journal they went with
  -- ------------------------------------------------------------------
  -- Nothing asserted this at all, so the mutant that writes a null
  -- there survived every file. Without the link a stock movement and
  -- the journal that priced it cannot be reconciled to one another.
  select count(*)::integer into v_n from public.stock_movements
   where source_table = 'stock_transfers' and source_id = v_t;
  perform pg_temp.check_eq('the send wrote one movement', v_n, 1);
  perform pg_temp.check_eq('and it names the journal it was priced in',
    (select sm.gl_entry_id from public.stock_movements sm
      where sm.source_table = 'stock_transfers' and sm.source_id = v_t),
    v_entry);
  perform pg_temp.check_eq('which the transfer remembers too',
    (select t.send_entry_id from public.stock_transfers t where t.id = v_t),
    v_entry);

  -- ------------------------------------------------------------------
  -- A company with no 1310 cannot send stock into transit
  -- ------------------------------------------------------------------
  v_poor := pg_temp.test_org('Tiada 1310 Pindah Sdn Bhd');
  perform public.create_fiscal_year(v_poor,
    date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_poor, m, true from unnest(array['inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_poor, 'A', 'Store A', true) returning id into v_from;
  insert into public.warehouses (org_id, code, name)
  values (v_poor, 'B', 'Store B') returning id into v_to;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_poor, 'TIN', 'Tin susu', 'stock', true, 'C62', 5.00)
  returning id into v_item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_poor, 'OPEN-TIN', pg_temp.today(), 'opening_balance', v_item,
          v_from, 10, 5.00);
  update public.accounts set code = '1311'
   where org_id = v_poor and code = '1310';
  insert into public.stock_transfers
    (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id,
     status)
  values (v_poor, 'TR-NO1310', pg_temp.today(), v_from, v_to, 'draft')
  returning id into v_t;
  insert into public.stock_transfer_lines
    (org_id, transfer_id, line_no, item_id, quantity, uom_code)
  values (v_poor, v_t, 1, v_item, 4, 'C62');
  perform pg_temp.check_refused(
    'with no 1310 in the chart the send is refused',
    format('select public.send_stock_transfer(%L)', v_t),
    '%inventory account (1310)%', 'P0002');
  perform pg_temp.check_eq('and the transfer is still a draft',
    (select t.status::text from public.stock_transfers t where t.id = v_t),
    'draft');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- receive_stock_transfer: the fourteen the sender's sweep did not cover
--
-- `send_stock_transfer` scored 19 of 23 on this file and 23 of 23
-- across its three. Its PAIR scored 20 of 35, and the difference is
-- the one `revalue_foreign_balances` had an hour earlier: the two
-- halves of a symmetric thing do not get symmetric coverage.
--
-- Receiving has one rule sending does not: a SHORTFALL. Sending is one
-- quantity per line; receiving is two -- what was sent and what turned
-- up -- so the journal has three shapes (all arrived, some arrived,
-- none arrived) and each puts a different set of legs on it. All three
-- balance, so the only thing that tells them apart is which accounts
-- appear and how many lines there are.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_from   uuid; v_to uuid;
  v_a      uuid; v_b uuid;
  v_t      uuid; v_la uuid; v_lb uuid;
  v_entry  uuid; v_send uuid;
  v_1310   uuid; v_5900 uuid; v_1320 uuid;
  v_other  uuid; v_ot uuid; v_ol uuid; v_oi uuid; v_ow uuid; v_ow2 uuid;
  v_free   uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Pindah Celah Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'GUD1', 'Store one', true) returning id into v_from;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'GUD2', 'Store two') returning id into v_to;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'ITEM-A', 'Barang A', 'stock', true, 'C62', 10.00)
  returning id into v_a;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'ITEM-B', 'Barang B', 'stock', true, 'C62', 7.00)
  returning id into v_b;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'OPEN-A', pg_temp.today(), 'opening_balance', v_a, v_from, 100, 10.00),
         (v_org, 'OPEN-B', pg_temp.today(), 'opening_balance', v_b, v_from, 100, 7.00);

  select id into v_1310 from public.accounts where org_id = v_org and code = '1310';
  select id into v_5900 from public.accounts where org_id = v_org and code = '5900';
  v_1320 := app.goods_in_transit_account(v_org);

  -- ------------------------------------------------------------------
  -- 1. TWO LINES, TWO DIFFERENT COUNTS
  -- ------------------------------------------------------------------
  -- The count is matched to its line by id. With one line, or with two
  -- lines counted the same, "the count for THIS line" and "a count"
  -- are the same number.
  v_t := public.upsert_stock_transfer(
    null, v_org, v_from, v_to, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('item', v_a, 'quantity', 10, 'uom', 'C62'),
      jsonb_build_object('item', v_b, 'quantity', 20, 'uom', 'C62')),
    'two lines, two counts');
  perform public.send_stock_transfer(v_t);
  select id into v_la from public.stock_transfer_lines
   where transfer_id = v_t and item_id = v_a;
  select id into v_lb from public.stock_transfer_lines
   where transfer_id = v_t and item_id = v_b;
  select gl_entry_id into v_send from public.stock_movements
   where source_id = v_t and movement_type = 'transfer_out' limit 1;

  v_entry := public.receive_stock_transfer(v_t, jsonb_build_array(
    jsonb_build_object('line', v_la, 'quantity', 8),
    jsonb_build_object('line', v_lb, 'quantity', 15)));

  perform pg_temp.check_eq('line A is received at ITS count',
    (select received_quantity from public.stock_transfer_lines where id = v_la),
    8);
  perform pg_temp.check_eq('and line B at ITS OWN, which is a different number',
    (select received_quantity from public.stock_transfer_lines where id = v_lb),
    15);
  perform pg_temp.check_eq('the shop holds eight of A',
    (select sum(quantity) from public.stock_movements
      where source_id = v_t and item_id = v_a
        and movement_type = 'transfer_in'), 8);
  perform pg_temp.check_eq('and fifteen of B',
    (select sum(quantity) from public.stock_movements
      where source_id = v_t and item_id = v_b
        and movement_type = 'transfer_in'), 15);

  -- The journal: 8 at 10 plus 15 at 7 arrived = 185; 2 at 10 plus 5 at
  -- 7 short = 55; transit out = 240, which is what was sent.
  perform pg_temp.check_eq('inventory takes what arrived',
    (select debit from public.gl_lines
      where entry_id = v_entry and account_id = v_1310), 185);
  perform pg_temp.check_eq('5900 takes what did not',
    (select debit from public.gl_lines
      where entry_id = v_entry and account_id = v_5900), 55);
  perform pg_temp.check_eq('and transit is emptied of everything that left',
    (select credit from public.gl_lines
      where entry_id = v_entry and account_id = v_1320), 240);

  -- THE MOVEMENT LINKS, in both directions. The receipt journal values
  -- the INBOUND movements; the outbound ones belong to the send
  -- journal and must not be relinked, or the send's own valuation
  -- points at the wrong entry and `report_stock_valuation` double-reads
  -- it.
  perform pg_temp.check_eq('every inbound movement is valued by this journal',
    (select count(*) from public.stock_movements
      where source_id = v_t and movement_type = 'transfer_in'
        and gl_entry_id = v_entry), 2);
  perform pg_temp.check_eq('and no inbound movement is left unvalued',
    (select count(*) from public.stock_movements
      where source_id = v_t and movement_type = 'transfer_in'
        and gl_entry_id is null), 0);
  perform pg_temp.check_true('while the OUTBOUND ones keep the send journal',
    v_send is not null and (select bool_and(gl_entry_id = v_send)
       from public.stock_movements
      where source_id = v_t and movement_type = 'transfer_out'));

  -- AND THE THREE STAMPS, none of which anything read back.
  perform pg_temp.check_true('the transfer records when it arrived',
    (select received_at is not null from public.stock_transfers where id = v_t));
  perform pg_temp.check_true('and who signed for it',
    (select received_by from public.stock_transfers where id = v_t) = v_owner);
  perform pg_temp.check_eq('and the journal that received it',
    (select receipt_entry_id from public.stock_transfers where id = v_t),
    v_entry);

  -- ------------------------------------------------------------------
  -- 2. RECEIVED IN FULL: no shortfall leg at all
  -- ------------------------------------------------------------------
  v_t := public.upsert_stock_transfer(
    null, v_org, v_from, v_to, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('item', v_a, 'quantity', 5, 'uom', 'C62')),
    'all of it arrives');
  perform public.send_stock_transfer(v_t);
  v_entry := public.receive_stock_transfer(v_t);
  perform pg_temp.check_eq('a transfer that arrives in full is two lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
  perform pg_temp.check_eq('and writes NOTHING off to 5900',
    (select count(*) from public.gl_lines
      where entry_id = v_entry and account_id = v_5900), 0);

  -- ------------------------------------------------------------------
  -- 3. NOTHING ARRIVED: a shortfall-only receipt
  -- ------------------------------------------------------------------
  -- A van that never got there. Every quantity counted as ZERO, which
  -- is also the boundary of `if v_got < 0` -- nothing in the suite had
  -- ever counted a line in at nought, so widening that guard to
  -- `<= 0` refused a real and ordinary count.
  v_t := public.upsert_stock_transfer(
    null, v_org, v_from, v_to, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('item', v_a, 'quantity', 6, 'uom', 'C62')),
    'none of it arrives');
  perform public.send_stock_transfer(v_t);
  select id into v_la from public.stock_transfer_lines where transfer_id = v_t;
  v_entry := public.receive_stock_transfer(v_t, jsonb_build_array(
    jsonb_build_object('line', v_la, 'quantity', 0)));

  perform pg_temp.check_true('a count of NOUGHT is a count', v_entry is not null);
  perform pg_temp.check_eq('it makes no stock movement at all',
    (select count(*) from public.stock_movements
      where source_id = v_t and movement_type = 'transfer_in'), 0);
  perform pg_temp.check_eq('the whole load is written off',
    (select debit from public.gl_lines
      where entry_id = v_entry and account_id = v_5900), 60);
  perform pg_temp.check_eq('and NOTHING is debited to inventory',
    (select count(*) from public.gl_lines
      where entry_id = v_entry and account_id = v_1310), 0);
  perform pg_temp.check_eq('so the journal is the loss and the transit, and no more',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
  perform pg_temp.check_eq('with transit emptied of what left',
    (select credit from public.gl_lines
      where entry_id = v_entry and account_id = v_1320), 60);

  -- ------------------------------------------------------------------
  -- 4. A CHART WITH NO 5900
  -- ------------------------------------------------------------------
  -- Refused in words. Without the guard the shortfall leg has a null
  -- account and `gl_lines` refuses it with a not-null violation, which
  -- is a database error where a sentence belongs -- and a company that
  -- renamed its chart meets it on an ordinary short delivery.
  v_other := pg_temp.test_org('Carta Tanpa 5900 Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_other, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_other, m, true from unnest(array['inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_other, 'W1', 'One', true) returning id into v_ow;
  insert into public.warehouses (org_id, code, name)
  values (v_other, 'W2', 'Two') returning id into v_ow2;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_other, 'X', 'Barang X', 'stock', true, 'C62', 3.00)
  returning id into v_oi;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_other, 'OPEN-X', pg_temp.today(), 'opening_balance', v_oi, v_ow, 50, 3.00);

  v_ot := public.upsert_stock_transfer(
    null, v_other, v_ow, v_ow2, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('item', v_oi, 'quantity', 10, 'uom', 'C62')),
    'short, with no account to lose it to');
  perform public.send_stock_transfer(v_ot);
  select id into v_ol from public.stock_transfer_lines where transfer_id = v_ot;
  delete from public.accounts where org_id = v_other and code = '5900';
  perform pg_temp.check_refused(
    'a shortfall with no 5900 in the chart is refused in words',
    format($q$select public.receive_stock_transfer(%L,
              jsonb_build_array(jsonb_build_object('line', %L, 'quantity', 4)))$q$,
           v_ot, v_ol),
    'No inventory adjustment account (5900) in the chart.', 'P0002');
  perform pg_temp.check_eq('and the transfer is still on its way',
    (select status::text from public.stock_transfers where id = v_ot), 'sent');

  -- ------------------------------------------------------------------
  -- 5. STOCK THAT IS WORTH NOTHING
  -- ------------------------------------------------------------------
  -- `if round(v_arrived, 2) <> 0 or round(v_short, 2) <> 0` is what
  -- keeps a journal of nothing off the ledger, and every item in this
  -- suite has a cost, so the test was always true. A promotional case
  -- taken into stock at nought -- a supplier's free sample, a
  -- competition prize -- moves between warehouses like anything else,
  -- and the movement is real while the VALUE is not. The quantity has
  -- to arrive; the journal must not exist.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'ITEM-FREE', 'Sampel percuma', 'stock', true, 'C62', 0)
  returning id into v_free;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'OPEN-FREE', pg_temp.today(), 'opening_balance',
          v_free, v_from, 30, 0);

  v_t := public.upsert_stock_transfer(
    null, v_org, v_from, v_to, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('item', v_free, 'quantity', 12, 'uom', 'C62')),
    'twelve of something worth nothing');
  perform public.send_stock_transfer(v_t);
  v_entry := public.receive_stock_transfer(v_t);

  perform pg_temp.check_true(
    'a transfer of stock worth nothing posts NO journal at all',
    v_entry is null);
  perform pg_temp.check_eq('and none exists for it',
    (select count(*) from public.gl_entries
      where org_id = v_org and source_table = 'stock_transfers'
        and source_id = v_t), 0);
  -- The quantity still moved, which is the half that matters to a
  -- stocktake. A journal of two zeroes would balance and tell nobody
  -- anything; the movement is the record.
  perform pg_temp.check_eq('while the twelve really arrived',
    (select sum(quantity) from public.stock_movements
      where source_id = v_t and movement_type = 'transfer_in'), 12);
  perform pg_temp.check_eq('and the transfer is received',
    (select status::text from public.stock_transfers where id = v_t),
    'received');

  -- What this block does NOT prove, said here so the next sweep does
  -- not re-chase it.
  --
  -- The receipt's `and sm.movement_type = 'transfer_in'` is an
  -- EQUIVALENT mutation target, proven by the SENDER's own update:
  -- `send_stock_transfer` links every unvalued movement of the transfer
  -- with no type filter at all, so by the time a receipt runs the
  -- outbound movements already carry the send journal and
  -- `and sm.gl_entry_id is null` excludes them on its own. The only
  -- state where they are unvalued is a transfer worth nothing -- the
  -- case just above -- and there the receipt posts no journal either,
  -- so the update does not run. Right to keep: it says what the
  -- statement means, and it is the only thing standing between the two
  -- journals if the sender's filter is ever tightened.
  --
  -- And putting an `order by a.is_group desc` on the 1310
  -- lookup is an EQUIVALENT mutation. The chart holds ONE account per
  -- code -- `accounts` is unique on (org_id, code), which is why
  -- `app.cheque_account` revives a retired row rather than inserting a
  -- second -- so that select returns at most one row and no ordering
  -- can change which. The 1310 heading trap that `0727`/`0728` closed
  -- was a FALLBACK to the parent, not an ordering, and there is no
  -- fallback here.
  raise notice 'ok   receiving: two counts, all of it, none of it, and no account to lose it to';
end $$;


-- ---------------------------------------------------------------------
-- `run_item_conversion`, rule by rule
--
-- A mutation sweep (`mutants/run_item_conversion.py`) left eight of its
-- sixteen with nothing in any of the four files that call it to tell
-- them from their absence: the conversion that does not exist, who may
-- run one, running it no times, which store is the default and the
-- company with none, the exact amount the store holds, a company that
-- allows negative stock, and more than the batches hold. The default
-- store needed a second store made FIRST: with the default the only
-- one, "the default" and "any store" were the same row.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid; v_bare uuid; v_shop uuid; v_kitchen uuid;
  v_chicken uuid; v_breast uuid; v_lotted uuid; v_piece uuid;
  v_conv uuid; v_lconv uuid; v_bconv uuid; v_bchicken uuid; v_bbreast uuid;
begin
  v_org := pg_temp.test_org('Potong Satu Persatu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','pos']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);

  -- The shop first, so it is the store a careless "any store" finds.
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'KEDAI', 'The shop') returning id into v_shop;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'DAPUR', 'Central kitchen', true) returning id into v_kitchen;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'AYAM', 'Ayam sebiji', 'stock', true, 'C62', 12.00)
  returning id into v_chicken;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'DADA', 'Dada ayam', 'stock', true, 'C62')
  returning id into v_breast;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'RC-1', pg_temp.today(), 'opening_balance', v_chicken, v_kitchen, 3, 12.00);
  v_conv := public.upsert_item_conversion(
    null, v_org, 'AYAM2', 'Potong dua', v_chicken, 1, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_breast, 'quantity', 2, 'share', 100)));

  perform pg_temp.check_refused('a conversion that does not exist is said so',
    format('select public.run_item_conversion(%L, 1, null)', gen_random_uuid()),
    'No such conversion.', 'P0002');
  perform pg_temp.check_refused('nor is one run no times',
    format('select public.run_item_conversion(%L, 0, null)', v_conv),
    'How many times?', '23514');
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-potong@example.test'));
  perform pg_temp.check_refused('somebody outside the company runs none of it',
    format('select public.run_item_conversion(%L, 1, null)', v_conv),
    'not permitted to write for this organization', '42501');
  perform pg_temp.sign_in_as(v_owner);

  -- No store named: the default one, which is where the chickens are.
  perform public.run_item_conversion(v_conv, 1, null);
  perform pg_temp.check_true('with no store named, the default one is used',
    (select sm.warehouse_id = v_kitchen from public.stock_movements sm
      where sm.source_table = 'item_conversions' and sm.source_id = v_conv
        and sm.item_id = v_chicken));
  -- Exactly what is left is enough.
  perform pg_temp.check_eq('exactly what the store holds is enough',
    public.run_item_conversion(v_conv, 2, v_kitchen), 24::numeric);

  -- A company that allows negative stock cuts up what it has not got.
  insert into public.pos_settings (org_id, allow_negative_stock)
  values (v_org, true)
  on conflict (org_id) do update set allow_negative_stock = true;
  perform pg_temp.check_true('and one that allows negative stock may go below none',
    public.run_item_conversion(v_conv, 1, v_kitchen) is not null);

  -- A bird whose stock arrived before anybody tracked it by batch: the
  -- store holds four, the batches hold none, and it is the batches that
  -- are cut. (Batch-tracked stock cannot arrive without a batch, so the
  -- tracking is switched on after.)
  update public.pos_settings set allow_negative_stock = false where org_id = v_org;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'AYAM-B', 'Ayam berkelompok', 'stock', true, 'C62', 12.00)
  returning id into v_bchicken;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'DADA-B', 'Dada berkelompok', 'stock', true, 'C62')
  returning id into v_bbreast;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'RC-2', pg_temp.today(), 'opening_balance', v_bchicken, v_kitchen, 4, 12.00);
  update public.items set tracking = 'batch' where id = v_bchicken;
  v_bconv := public.upsert_item_conversion(
    null, v_org, 'AYAMB2', 'Potong berkelompok', v_bchicken, 1, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_bbreast, 'quantity', 2, 'share', 100)));
  perform pg_temp.check_refused('more than its batches hold is not cut up',
    format('select public.run_item_conversion(%L, 1, %L)', v_bconv, v_kitchen),
    'The batches of it in that store come to %', '23514');

  -- And a company with no store at all is told so.
  v_bare := pg_temp.test_org('Tiada Stor Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_bare, 'inventory', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_bare, 'X', 'Whole', 'stock', true, 'C62') returning id into v_lotted;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_bare, 'Y', 'Piece', 'stock', true, 'C62') returning id into v_piece;
  v_lconv := public.upsert_item_conversion(
    null, v_bare, 'XY', 'Cut', v_lotted, 1, 'C62',
    jsonb_build_array(jsonb_build_object('item', v_piece, 'quantity', 2, 'share', 100)));
  perform pg_temp.check_refused('a company with no store is told so',
    format('select public.run_item_conversion(%L, 1, null)', v_lconv),
    'This company has no store to do it in.', 'P0002');
  perform pg_temp.sign_out();
end $$;

rollback;

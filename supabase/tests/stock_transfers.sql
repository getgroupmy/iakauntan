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

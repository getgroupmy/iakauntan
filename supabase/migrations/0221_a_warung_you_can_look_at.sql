-- A café somebody can open and look at.
--
-- ## Why a fourth tenant rather than more furniture on Sinar
--
-- Sinar is a computer wholesaler with a trade counter, and 0207 gave it
-- one — which is the right demo for retail. A floor plan, a kitchen
-- screen and a self-service kiosk on a company that sells rack servers
-- would be a demo that teaches the wrong thing about who this is for.
--
-- So the dining room gets its own tenant: a warung with tables inside
-- and out, two kitchen stations, a menu that asks questions, a card
-- kiosk by the door and a loyalty scheme. Everything the food and
-- beverage stages built, in one place, with service already under way.
--
-- ## Service already under way
--
-- The tables are not empty. A demo whose floor plan shows eight free
-- tables demonstrates a floor plan; one with two parties seated, an
-- order in the kitchen and a bill already settled demonstrates a
-- restaurant. The screens this module added are all screens about
-- things in progress, and a snapshot of an empty room shows none of
-- them working.
--
-- ## What it does not track
--
-- Stock. A warung counts ingredients, not plates of nasi lemak, so the
-- menu items are `track_inventory = false`. That is not a shortcut
-- around opening balances -- it is what the business actually does, and
-- a demo showing a negative stock figure against "Teh tarik" would be
-- teaching a habit rather than a feature.

create or replace function app.demo_warung(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wh      uuid;
  v_walkin  uuid;
  v_member  uuid;
  v_outlet  uuid;
  v_dalam   uuid;
  v_luar    uuid;
  v_dapur   uuid;
  v_bar     uuid;
  v_minum   uuid;
  v_counter uuid;
  v_waiter  uuid;
  v_kiosk   uuid;
  v_tunai   uuid;
  v_kad     uuid;
  v_nasi    uuid;
  v_mee     uuid;
  v_roti    uuid;
  v_teh     uuid;
  v_kopi    uuid;
  v_pedas   uuid;
  v_tambah  uuid;
  v_kurang  uuid;
  v_telur   uuid;
  v_prog    uuid;
  v_shift   uuid;
  v_wshift  uuid;
  v_kshift  uuid;
  v_t3      uuid;
  v_t5      uuid;
  v_bill    uuid;
  v_line    uuid;
  v_seated  integer := 0;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos', 'inventory', 'einvoice']);

  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 2.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh from public.warehouses w
   where w.org_id = p_org and w.is_active order by w.code limit 1;

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Pelanggan kaunter', 'customer', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_walkin from public.contacts c
   where c.org_id = p_org and c.code = 'WALK-IN';

  -- Somebody on the loyalty card, so the scheme has a member rather
  -- than a definition.
  insert into public.contacts (org_id, code, name, contact_type, is_active, phone)
  values (p_org, 'AHLI-001', 'Puan Aminah binti Yusof', 'customer', true,
          '012-3456789')
  on conflict (org_id, code) do nothing;
  select c.id into v_member from public.contacts c
   where c.org_id = p_org and c.code = 'AHLI-001';

  -- ------------------------------------------------------------------
  -- The menu
  -- ------------------------------------------------------------------
  insert into public.item_categories (org_id, code, name)
  values (p_org, 'MINUM', 'Minuman')
  on conflict (org_id, code) do nothing;
  select c.id into v_minum from public.item_categories c
   where c.org_id = p_org and c.code = 'MINUM';

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, category_id)
  values
    (p_org, 'NASI-LEMAK', 'Nasi lemak ayam',  'service', false, 'C62',  8.50, 3.20, null),
    (p_org, 'MEE-GORENG', 'Mee goreng mamak', 'service', false, 'C62',  9.00, 3.60, null),
    (p_org, 'ROTI-CANAI', 'Roti canai',       'service', false, 'C62',  2.00, 0.60, null),
    (p_org, 'TEH-TARIK',  'Teh tarik',        'service', false, 'C62',  3.00, 0.90, v_minum),
    (p_org, 'KOPI-O',     'Kopi O',           'service', false, 'C62',  2.50, 0.70, v_minum),
    (p_org, 'SIRAP',      'Air sirap',        'service', false, 'C62',  2.00, 0.50, v_minum)
  on conflict (org_id, code) do nothing;

  select id into v_nasi from public.items where org_id = p_org and code = 'NASI-LEMAK';
  select id into v_mee  from public.items where org_id = p_org and code = 'MEE-GORENG';
  select id into v_roti from public.items where org_id = p_org and code = 'ROTI-CANAI';
  select id into v_teh  from public.items where org_id = p_org and code = 'TEH-TARIK';
  select id into v_kopi from public.items where org_id = p_org and code = 'KOPI-O';

  -- ------------------------------------------------------------------
  -- The room
  -- ------------------------------------------------------------------
  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'WARUNG', 'Warung Sedap', 'food_beverage', v_wh, v_walkin,
    'Warung Sedap — Jalan Kebun',
    'Terima kasih. Datang lagi!',
    -- Below the SST threshold, so the menu price is the price and
    -- there is no tax to be inside or outside of.
    false)
  on conflict (org_id, code) do update
     set warehouse_id = excluded.warehouse_id,
         walk_in_contact_id = excluded.walk_in_contact_id
  returning id into v_outlet;
  if v_outlet is null then
    select o.id into v_outlet from public.pos_outlets o
     where o.org_id = p_org and o.code = 'WARUNG';
  end if;

  insert into public.pos_floor_areas (org_id, outlet_id, code, name, sort_order)
  values (p_org, v_outlet, 'DALAM', 'Dalam', 1),
         (p_org, v_outlet, 'LUAR',  'Luar (bawah pokok)', 2)
  on conflict (outlet_id, code) do nothing;
  select id into v_dalam from public.pos_floor_areas
   where outlet_id = v_outlet and code = 'DALAM';
  select id into v_luar from public.pos_floor_areas
   where outlet_id = v_outlet and code = 'LUAR';

  insert into public.pos_tables
    (org_id, outlet_id, area_id, code, seats, pos_x, pos_y, shape)
  values
    (p_org, v_outlet, v_dalam, 'T1', 2,  40,  40, 'square'),
    (p_org, v_outlet, v_dalam, 'T2', 2, 140,  40, 'square'),
    (p_org, v_outlet, v_dalam, 'T3', 4,  40, 140, 'round'),
    (p_org, v_outlet, v_dalam, 'T4', 4, 140, 140, 'round'),
    (p_org, v_outlet, v_dalam, 'T5', 6,  40, 250, 'rectangle'),
    (p_org, v_outlet, v_luar,  'L1', 4,  40,  40, 'round'),
    (p_org, v_outlet, v_luar,  'L2', 4, 150,  40, 'round')
  on conflict (outlet_id, code) do nothing;
  select id into v_t3 from public.pos_tables where outlet_id = v_outlet and code = 'T3';
  select id into v_t5 from public.pos_tables where outlet_id = v_outlet and code = 'T5';

  insert into public.pos_registers (org_id, outlet_id, code, name, device_note, is_kiosk)
  values
    (p_org, v_outlet, 'T1', 'Kaunter',
     'Counter terminal by the till, cash drawer underneath', false),
    (p_org, v_outlet, 'W1', 'Tablet pelayan',
     'Waiter tablet carried around the tables', false),
    (p_org, v_outlet, 'K1', 'Kiosk pintu masuk',
     'Self-service screen by the door, card and e-wallet only', true)
  on conflict (org_id, code) do nothing;
  select id into v_counter from public.pos_registers
   where org_id = p_org and code = 'T1';
  select id into v_waiter from public.pos_registers
   where org_id = p_org and code = 'W1';
  select id into v_kiosk from public.pos_registers
   where org_id = p_org and code = 'K1';

  -- ------------------------------------------------------------------
  -- The kitchen
  -- ------------------------------------------------------------------
  insert into public.pos_kitchen_stations
    (org_id, outlet_id, code, name, is_default, sort_order)
  values (p_org, v_outlet, 'DAPUR', 'Dapur', true, 1),
         (p_org, v_outlet, 'BAR',   'Bar minuman', false, 2)
  on conflict (outlet_id, code) do nothing;
  select id into v_dapur from public.pos_kitchen_stations
   where outlet_id = v_outlet and code = 'DAPUR';
  select id into v_bar from public.pos_kitchen_stations
   where outlet_id = v_outlet and code = 'BAR';

  -- One rule, not six: drinks go to the bar because of what they are.
  insert into public.category_kitchen_stations (org_id, category_id, station_id)
  values (p_org, v_minum, v_bar)
  on conflict (category_id, station_id) do nothing;

  -- ------------------------------------------------------------------
  -- The questions the menu asks
  -- ------------------------------------------------------------------
  insert into public.pos_modifier_groups
    (org_id, code, name, min_select, max_select, sort_order)
  values (p_org, 'PEDAS',  'Pedas',  1, 1, 1),
         (p_org, 'TAMBAH', 'Tambah', 0, 2, 2)
  on conflict (org_id, code) do nothing;
  select id into v_pedas from public.pos_modifier_groups
   where org_id = p_org and code = 'PEDAS';
  select id into v_tambah from public.pos_modifier_groups
   where org_id = p_org and code = 'TAMBAH';

  insert into public.pos_modifiers (org_id, group_id, code, name, price_delta, sort_order)
  values
    (p_org, v_pedas,  'KURANG', 'Kurang pedas', 0,    1),
    (p_org, v_pedas,  'BIASA',  'Biasa',        0,    2),
    (p_org, v_pedas,  'EXTRA',  'Extra pedas',  0,    3),
    (p_org, v_tambah, 'TELUR',  'Telur mata',   1.50, 1),
    (p_org, v_tambah, 'AYAM',   'Ayam tambah',  4.00, 2),
    (p_org, v_tambah, 'NOTIMUN','Tanpa timun',  0,    3)
  on conflict (group_id, code) do nothing;
  select id into v_kurang from public.pos_modifiers
   where group_id = v_pedas and code = 'KURANG';
  select id into v_telur from public.pos_modifiers
   where group_id = v_tambah and code = 'TELUR';

  insert into public.item_modifier_groups (org_id, item_id, group_id, sort_order)
  values (p_org, v_nasi, v_pedas, 1),
         (p_org, v_nasi, v_tambah, 2),
         (p_org, v_mee,  v_pedas, 1)
  on conflict (item_id, group_id) do nothing;

  -- ------------------------------------------------------------------
  -- Ways to pay, and a card worth carrying
  -- ------------------------------------------------------------------
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values
    (p_org, 'TUNAI',   'Tunai',   'cash',    '01', true,  true,  true),
    (p_org, 'KAD',     'Kad',     'card',    '04', false, false, false),
    (p_org, 'EWALLET', 'E-dompet','ewallet', '06', false, false, false)
  on conflict (org_id, code) do nothing;
  select id into v_tunai from public.pos_tender_types
   where org_id = p_org and code = 'TUNAI';
  select id into v_kad from public.pos_tender_types
   where org_id = p_org and code = 'KAD';

  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, dormancy_expiry_months)
  values (p_org, 'MESRA', 'Kad Mesra', 1, 0.01, 100, 12)
  on conflict (org_id, code) do nothing;
  select id into v_prog from public.loyalty_programs
   where org_id = p_org and code = 'MESRA';

  insert into public.loyalty_accounts (org_id, program_id, contact_id, card_no)
  values (p_org, v_prog, v_member, 'MESRA-0001')
  on conflict (program_id, contact_id) do nothing;

  -- ------------------------------------------------------------------
  -- Service, already under way
  -- ------------------------------------------------------------------
  -- A shift is per register, because a shift is a drawer. The counter
  -- has one and opens on two hundred; the waiter's tablet and the kiosk
  -- have none at all and open on nothing -- their shift exists to give
  -- the sales rung on them a count to belong to, and its expected cash
  -- is zero because no coins ever pass through either device.
  --
  -- This is not a demo detail. Seating a table from a tablet whose own
  -- drawer was never opened is refused, which is how writing this seed
  -- found it.
  --
  -- Guarded, so a rebuild that runs twice in a day does not open a
  -- second drawer on the same till.
  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_counter and s.status <> 'closed') then
    v_shift := public.open_pos_shift(v_counter, 200.00,
      'Demo service — opened for the lunch rush');
  end if;
  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_waiter and s.status <> 'closed') then
    v_wshift := public.open_pos_shift(v_waiter, 0,
      'Waiter tablet — takes orders, takes no money');
  end if;
  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_kiosk and s.status <> 'closed') then
    v_kshift := public.open_pos_shift(v_kiosk, 0,
      'Kiosk — card and e-wallet only, no drawer');
  end if;

  if v_shift is not null then
    -- Table 3: two people, food and drinks, sent to the kitchen.
    v_bill := public.seat_table(v_waiter, v_t3, 2);
    v_line := public.add_pos_sale_line(v_bill, v_nasi, 2, 8.50);
    perform public.add_line_modifier(v_line, v_kurang);
    perform public.add_line_modifier(v_line, v_telur);
    perform public.add_pos_sale_line(v_bill, v_teh, 2, 3.00);
    perform public.send_order_to_kitchen(v_bill);

    -- Table 5: a bigger party, ordered later, still being made.
    v_bill := public.seat_table(v_waiter, v_t5, 5);
    v_line := public.add_pos_sale_line(v_bill, v_mee, 3, 9.00);
    perform public.add_line_modifier(v_line, v_kurang);
    perform public.add_pos_sale_line(v_bill, v_roti, 4, 2.00);
    perform public.add_pos_sale_line(v_bill, v_kopi, 3, 2.50);
    perform public.send_order_to_kitchen(v_bill);

    -- And one that has already paid and gone, so the day's takings are
    -- not zero and the drawer has something in it to count.
    v_bill := public.open_pos_sale(v_counter, v_member);
    perform public.add_pos_sale_line(v_bill, v_roti, 2, 2.00);
    perform public.add_pos_sale_line(v_bill, v_kopi, 1, 2.50);
    perform public.complete_pos_sale(v_bill, jsonb_build_array(
      jsonb_build_object('type', v_tunai, 'amount', 10.00)));

    -- And somebody who used the machine by the door: paid by card,
    -- given a number, and watching the board for it. Without this the
    -- kiosk is a register nobody has ever touched.
    v_bill := public.start_kiosk_order(v_kiosk);
    perform public.add_pos_sale_line(v_bill, v_roti, 3, 2.00);
    perform public.add_pos_sale_line(v_bill, v_teh, 1, 3.00);
    perform public.complete_kiosk_order(v_bill, v_kad, null, 'DEMO-AUTH-0001');
  end if;

  select count(*) into v_seated from public.pos_sales s
   where s.outlet_id = v_outlet and s.status = 'parked' and s.table_id is not null;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Warung Sedap: %s tables in 2 areas, %s stations, a kiosk, %s parties '
    'seated with orders in the kitchen, and one bill already settled.',
    (select count(*) from public.pos_tables t where t.outlet_id = v_outlet),
    (select count(*) from public.pos_kitchen_stations k where k.outlet_id = v_outlet),
    v_seated);
end;
$$;

revoke all on function app.demo_warung(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Into the rebuild
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched, for the reason 0201 and 0207
-- both give: a `create or replace` that only somebody's memory says
-- matches the previous body is how a rebuild quietly loses a tenant.
-- The only additions are the warung, its cook, and their place in the
-- summary.
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid; v_warung uuid;
  v_books text; v_books_a text; v_books_h text;
  v_cash text; v_assets text; v_pay text; v_desk text; v_fc text; v_pos text;
  v_cook uuid; v_warung_txt text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.com',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.com',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.com',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.com', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.com',  'Tan Chee Keong');
  v_cook      := app.demo_user('warung@iakauntan.com',    'Faridah Ismail');

  v_sinar := app.demo_company(
    v_demo, 'Sinar Teknologi Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201901004567', 'C20194567890', '46510',
    'Wholesale of computers and peripherals',
    '10', 'Petaling Jaya', '46200',
    'Level 8, Menara Sinar, Jalan Utara', '03-7955 1200',
    'accounts@sinartek.demo', 12::smallint);
  perform public.set_sst_registration(
    v_sinar, true, date_trunc('year', current_date)::date - 365,
    'W10-1808-31000123', 'ST8');
  perform app.demo_member(v_sinar, v_clerk,   'accounts_clerk');
  perform app.demo_member(v_sinar, v_auditor, 'auditor');
  perform app.demo_modules(v_sinar, array[
    'einvoice', 'purchases', 'inventory', 'crm', 'hr', 'payroll',
    'fixed_assets', 'approvals', 'manufacturing', 'branches',
    'timesheets', 'chat', 'mbrs']);
  v_books  := app.demo_books_sinar(v_sinar, v_demo);
  v_cash   := app.demo_sinar_bank(v_sinar, v_demo);
  v_assets := app.demo_sinar_assets(v_sinar, v_demo);
  v_pay    := app.demo_sinar_payroll(v_sinar, v_demo);
  v_desk   := app.demo_tickets_sinar(v_sinar, v_demo);
  -- After the books and the bills, because it reads both.
  v_fc     := app.demo_forecast_sinar(v_sinar, v_demo);
  -- After forecasting, because the counter sells out of the same
  -- warehouse the forecast is about.
  v_pos    := app.demo_pos_sinar(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);

  v_harta := app.demo_company(
    v_property, 'Harta Prima Management Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202101007890', 'C20217890123', '68201',
    'Property management on a fee or contract basis',
    '10', 'Shah Alam', '40150',
    'Ground Floor, Blok A, Pusat Perniagaan Harta', '03-5511 4400',
    'admin@hartaprima.demo', 12::smallint);
  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'approvals', 'chat']);
  v_books_h := app.demo_books_harta(v_harta, v_property);

  -- The dining room gets its own tenant rather than more furniture on
  -- the wholesaler. A floor plan and a kitchen screen on a company that
  -- sells rack servers would demo the wrong thing about who this is for.
  v_warung := app.demo_company(
    v_cook, 'Warung Sedap Enterprise', 'sole_proprietor'::app.entity_type,
    'SA0123456-X', 'IG20191234560', '56103',
    'Restaurants and mobile food service activities',
    '10', 'Puchong', '47100',
    'Lot 12, Jalan Kebun Baru', '03-8070 2233',
    'warung@warungsedap.demo', 12::smallint);
  v_warung_txt := app.demo_warung(v_warung, v_cook);

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 4 tenants, 6 logins. %s %s %s %s %s %s %s %s %s %s',
                v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
                v_pos, v_books_a, v_books_h, v_warung_txt);
end;
$$;

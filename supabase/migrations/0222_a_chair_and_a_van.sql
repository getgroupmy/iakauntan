-- The two kinds of shop with nowhere to look at them.
--
-- ## Counting what is actually covered
--
-- `app.pos_business_type` has five values, and until now the demo data
-- covered three of them:
--
--   retail         Sinar's trade counter          (0207)
--   food_beverage  Warung Sedap                   (0221)
--   kiosk          the warung's screen by the door (0221)
--   service        nothing
--   mobile         nothing
--
-- A module sold on running five kinds of shop that can only be *shown*
-- running three is a module whose demo argues against its own pitch.
-- Worse, the two missing ones are where most of the interesting SQL
-- lives: the exclusion constraint that stops a slot being sold twice,
-- the membership that covers a line to nothing, and the offline batch
-- that has to land exactly once. All three had assertions and no
-- tenant, so nobody could ever see them work.
--
-- ## Why two more tenants and not two more outlets on the warung
--
-- The same argument 0221 made against putting a dining room on a
-- computer wholesaler. A salon is not a café with different items on
-- the menu -- it sells a person's time in bookable slots, has no
-- kitchen, has no tables, and its repeat customers pay monthly for
-- sessions rather than carrying a points card. A stall is not a café
-- either: it is one phone, no premises, and a signal that comes and
-- goes.
--
-- Modelling them as outlets of the warung would produce a demo where
-- every screen is switched on for every business, which is precisely
-- the impression this module should not give.
--
-- ## What each is for
--
-- **Seri Ayu** is the diary. Two chairs with different hours, four
-- services of different lengths, a day with slots already sold -- one
-- checked in and being charged, one still to come, one that did not
-- turn up -- and a facial package somebody has already used twice.
--
-- **Roti Warisan** is the offline path. A van, one phone, no premises,
-- and a lunchtime pitch under a flyover where the signal does not
-- reach. Its sales are seeded through `ingest_offline_sales` rather
-- than rung up directly, because landing a batch is the thing worth
-- looking at, and a stall whose sales were entered online would be
-- demonstrating an ordinary till in a van.

-- ---------------------------------------------------------------------
-- A chair, and the hours somebody sits in it
-- ---------------------------------------------------------------------
create or replace function app.demo_salon(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wh       uuid;
  v_walkin   uuid;
  v_siti     uuid;
  v_outlet   uuid;
  v_desk     uuid;
  v_aida     uuid;
  v_faiz     uuid;
  v_gunting  uuid;
  v_warna    uuid;
  v_rawatan  uuid;
  v_urut     uuid;
  v_tunai    uuid;
  v_pakej    uuid;
  v_shift    uuid;
  v_book     uuid;
  v_sale     uuid;
  v_today    date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_kl       text := 'Asia/Kuala_Lumpur';
  v_bookings integer := 0;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos', 'crm', 'chat']);

  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 5.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh from public.warehouses w
   where w.org_id = p_org and w.is_active order by w.code limit 1;

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Pelanggan kaunter', 'customer', true),
         -- A named regular, because a membership and a booking both
         -- need somebody who is not the walk-in. A salon knows who its
         -- customers are; that is most of what makes it a salon.
         (p_org, 'AHLI-001', 'Siti Nurhaliza binti Hamid', 'customer', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_walkin from public.contacts c
   where c.org_id = p_org and c.code = 'WALK-IN';
  select c.id into v_siti from public.contacts c
   where c.org_id = p_org and c.code = 'AHLI-001';

  -- ------------------------------------------------------------------
  -- What is sold, and how long each takes
  -- ------------------------------------------------------------------
  --
  -- Services rather than goods: nothing here comes off a shelf, so
  -- `track_inventory` is false and there is no opening stock to book.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values
    (p_org, 'GUNTING', 'Gunting rambut',        'service', false, 'C62',  45.00, 0),
    (p_org, 'WARNA',   'Warna rambut',          'service', false, 'C62', 180.00, 0),
    (p_org, 'RAWATAN', 'Rawatan muka',          'service', false, 'C62', 120.00, 0),
    (p_org, 'URUT',    'Urut kepala dan bahu',  'service', false, 'C62',  60.00, 0),
    (p_org, 'PAKEJ-MUKA', 'Pakej rawatan muka bulanan',
                                                'service', false, 'C62', 200.00, 0)
  on conflict (org_id, code) do nothing;
  select id into v_gunting from public.items where org_id = p_org and code = 'GUNTING';
  select id into v_warna   from public.items where org_id = p_org and code = 'WARNA';
  select id into v_rawatan from public.items where org_id = p_org and code = 'RAWATAN';
  select id into v_urut    from public.items where org_id = p_org and code = 'URUT';
  select id into v_pakej   from public.items where org_id = p_org and code = 'PAKEJ-MUKA';

  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'SALON', 'Seri Ayu', 'service', v_wh, v_walkin,
    'Seri Ayu Salon & Spa — Bangi',
    'Sila tempah awal untuk hujung minggu. Terima kasih!',
    false)
  on conflict (org_id, code) do update
     set warehouse_id = excluded.warehouse_id,
         walk_in_contact_id = excluded.walk_in_contact_id
  returning id into v_outlet;
  if v_outlet is null then
    select o.id into v_outlet from public.pos_outlets o
     where o.org_id = p_org and o.code = 'SALON';
  end if;

  insert into public.pos_registers (org_id, outlet_id, code, name, device_note)
  values (p_org, v_outlet, 'D1', 'Kaunter depan',
          'Front desk tablet — takes bookings and payment')
  on conflict (org_id, code) do nothing;
  select id into v_desk from public.pos_registers
   where org_id = p_org and code = 'D1';

  -- ------------------------------------------------------------------
  -- Two chairs, and they do not keep the same hours
  -- ------------------------------------------------------------------
  --
  -- Deliberately different. One provider is a schedule; two providers
  -- with the same schedule is still one schedule drawn twice. Aida
  -- works Tuesday to Sunday, Faiz weekday evenings and Saturday —
  -- which is what makes "who is free at three" a real question.
  insert into public.pos_service_providers
    (org_id, outlet_id, code, name, colour)
  values (p_org, v_outlet, 'AIDA', 'Aida', '#C2185B'),
         (p_org, v_outlet, 'FAIZ', 'Faiz', '#00796B')
  on conflict (outlet_id, code) do nothing;
  select id into v_aida from public.pos_service_providers
   where outlet_id = v_outlet and code = 'AIDA';
  select id into v_faiz from public.pos_service_providers
   where outlet_id = v_outlet and code = 'FAIZ';

  insert into public.pos_provider_hours
    (org_id, provider_id, weekday, starts_at, ends_at)
  select p_org, v_aida, d, time '10:00', time '19:00'
    from generate_series(2, 7) d
  on conflict (provider_id, weekday, starts_at) do nothing;

  insert into public.pos_provider_hours
    (org_id, provider_id, weekday, starts_at, ends_at)
  select p_org, v_faiz, d, time '14:00', time '21:00'
    from generate_series(1, 5) d
  on conflict (provider_id, weekday, starts_at) do nothing;
  insert into public.pos_provider_hours
    (org_id, provider_id, weekday, starts_at, ends_at)
  values (p_org, v_faiz, 6, time '10:00', time '18:00')
  on conflict (provider_id, weekday, starts_at) do nothing;

  -- A colour costs the chair longer than it costs the customer: the
  -- buffer is the sweeping and the wash-down afterwards, and 0217 put
  -- it in the slot rather than in somebody's head.
  insert into public.pos_services
    (org_id, item_id, duration_minutes, buffer_minutes)
  values (p_org, v_gunting, 45, 10),
         (p_org, v_warna,   90, 20),
         (p_org, v_rawatan, 60, 10),
         (p_org, v_urut,    30,  5)
  on conflict (item_id) do nothing;

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values
    (p_org, 'TUNAI',   'Tunai',    'cash',    '01', true,  true,  true),
    (p_org, 'KAD',     'Kad',      'card',    '04', false, false, false),
    (p_org, 'EWALLET', 'E-dompet', 'ewallet', '06', false, false, false)
  on conflict (org_id, code) do nothing;
  select id into v_tunai from public.pos_tender_types
   where org_id = p_org and code = 'TUNAI';

  -- ------------------------------------------------------------------
  -- Paying monthly for something you have not had yet
  -- ------------------------------------------------------------------
  insert into public.pos_memberships
    (org_id, code, name, item_id, period, sessions_included)
  values (p_org, 'PAKEJ-MUKA', 'Pakej rawatan muka (2 sesi sebulan)',
          v_pakej, 'monthly', 2)
  on conflict (org_id, code) do nothing;

  insert into public.membership_items (org_id, membership_id, item_id)
  select p_org, m.id, v_rawatan from public.pos_memberships m
   where m.org_id = p_org and m.code = 'PAKEJ-MUKA'
  on conflict (membership_id, item_id) do nothing;

  -- ------------------------------------------------------------------
  -- A day with something in it
  -- ------------------------------------------------------------------
  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_desk and s.status <> 'closed') then
    v_shift := public.open_pos_shift(v_desk, 150.00,
      'Demo — front desk, opened this morning');
  end if;

  if v_shift is not null then
    -- The day is built to show all four states a slot can be in, in
    -- the order they happen. Writing this seed is what established
    -- that `arrived` is a state you pass through rather than one you
    -- rest in: `app.pos_booking_follows_sale` moves the booking to
    -- `completed` the moment its sale completes. A demo that checked
    -- somebody in and then took their money would therefore show
    -- nobody in the chair, which is the opposite of what a salon looks
    -- like at eleven in the morning.
    --
    -- Done and paid for. This is also the day's takings, so the
    -- drawer has something in it to count.
    v_book := public.book_appointment(
      v_aida, v_urut,
      ((v_today + time '10:00') at time zone v_kl),
      null, 'First of the day');
    v_sale := public.check_in_booking(v_book, v_desk);
    perform public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_tunai, 'amount', 60.00)));

    -- In the chair right now: checked in, so the bill is open and
    -- unpaid. `check_in_booking` opened it, which is the whole
    -- argument of 0217 — arrival is a claim about money rather than a
    -- status somebody types. Deliberately not settled, so the diary
    -- has somebody in it and the front desk has a bill to take.
    v_book := public.book_appointment(
      v_aida, v_gunting,
      ((v_today + time '11:00') at time zone v_kl),
      v_siti, 'Regular — short at the back');
    perform public.check_in_booking(v_book, v_desk);

    -- Still to come this afternoon, on the other chair, so the diary
    -- has a future in it as well as a past.
    perform public.book_appointment(
      v_faiz, v_warna,
      ((v_today + time '15:00') at time zone v_kl),
      null, 'Walk-in enquiry, paying on the day');
    perform public.book_appointment(
      v_aida, v_rawatan,
      ((v_today + time '16:30') at time zone v_kl),
      v_siti, 'On the monthly package');

    -- And one that did not turn up. The hour is free again — the
    -- exclusion constraint ignores this status — but the day still has
    -- to show it was sold once, which is why the diary strikes it
    -- through rather than removing it.
    v_book := public.book_appointment(
      v_faiz, v_urut,
      ((v_today + time '17:30') at time zone v_kl),
      null, null);
    perform public.set_booking_status(v_book, 'no_show', 'Tidak hadir');
  end if;

  select count(*) into v_bookings from public.pos_bookings b
    join public.pos_service_providers p on p.id = b.provider_id
   where p.outlet_id = v_outlet;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Seri Ayu: 2 chairs on different hours, %s services, %s bookings '
    'today — one done and paid, one in the chair with the bill still '
    'open, two still to come and one no-show — and a monthly facial '
    'package.',
    (select count(*) from public.pos_services s where s.org_id = p_org),
    v_bookings);
end;
$$;

revoke all on function app.demo_salon(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- A van, a phone, and no signal under the flyover
-- ---------------------------------------------------------------------
--
-- The sales are landed through `ingest_offline_sales` rather than rung
-- up, because that is the thing worth seeing. A stall whose takings
-- were entered online would be demonstrating an ordinary till that
-- happens to be in a van.
--
-- Note the deliberate second call with the same batch further down: it
-- lands nothing and reports `already`, which is the property the whole
-- offline design exists for and the one nobody believes until they
-- watch it.
create or replace function app.demo_stall(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wh      uuid;
  v_walkin  uuid;
  v_outlet  uuid;
  v_phone   uuid;
  v_tunai   uuid;
  v_ewallet uuid;
  v_john    uuid;
  v_kebab   uuid;
  v_air     uuid;
  v_shift   uuid;
  v_batch   jsonb;
  v_landed  integer := 0;
  v_again   integer := 0;
  v_sale    uuid;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos']);

  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 2.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh from public.warehouses w
   where w.org_id = p_org and w.is_active order by w.code limit 1;

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Pelanggan tepi jalan', 'customer', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_walkin from public.contacts c
   where c.org_id = p_org and c.code = 'WALK-IN';

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values
    (p_org, 'ROTI-JOHN', 'Roti john daging', 'service', false, 'C62', 8.00, 3.10),
    (p_org, 'KEBAB',     'Kebab ayam',       'service', false, 'C62', 9.50, 3.80),
    (p_org, 'AIR-TIN',   'Air tin',          'service', false, 'C62', 2.50, 1.20)
  on conflict (org_id, code) do nothing;
  select id into v_john  from public.items where org_id = p_org and code = 'ROTI-JOHN';
  select id into v_kebab from public.items where org_id = p_org and code = 'KEBAB';
  select id into v_air   from public.items where org_id = p_org and code = 'AIR-TIN';

  -- No floor plan, no kitchen station, no table. A stall is a counter
  -- somebody walks up to, and modelling it with a dining room would be
  -- teaching the wrong shape.
  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'VAN', 'Roti Warisan (gerai bergerak)', 'mobile', v_wh, v_walkin,
    'Roti Warisan — gerai bergerak',
    'Ikuti kami di media sosial untuk lokasi harian.',
    false)
  on conflict (org_id, code) do update
     set warehouse_id = excluded.warehouse_id,
         walk_in_contact_id = excluded.walk_in_contact_id
  returning id into v_outlet;
  if v_outlet is null then
    select o.id into v_outlet from public.pos_outlets o
     where o.org_id = p_org and o.code = 'VAN';
  end if;

  insert into public.pos_registers (org_id, outlet_id, code, name, device_note)
  values (p_org, v_outlet, 'HP1', 'Telefon gerai',
          'The owner''s phone. Card reader over Bluetooth, and no signal '
          'at the lunchtime pitch under the flyover.')
  on conflict (org_id, code) do nothing;
  select id into v_phone from public.pos_registers
   where org_id = p_org and code = 'HP1';

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values
    (p_org, 'TUNAI',   'Tunai',    'cash',    '01', true,  true,  false),
    (p_org, 'EWALLET', 'E-dompet', 'ewallet', '06', false, false, false)
  on conflict (org_id, code) do nothing;
  select id into v_tunai from public.pos_tender_types
   where org_id = p_org and code = 'TUNAI';
  select id into v_ewallet from public.pos_tender_types
   where org_id = p_org and code = 'EWALLET';

  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_phone and s.status <> 'closed') then
    v_shift := public.open_pos_shift(v_phone, 50.00,
      'Demo — float counted into the cash tin before setting off');
  end if;

  if v_shift is not null then
    -- One sale rung up with a signal, so the day is not entirely a
    -- reconstruction.
    v_sale := public.open_pos_sale(v_phone);
    perform public.add_pos_sale_line(v_sale, v_kebab, 1, 9.50);
    perform public.add_pos_sale_line(v_sale, v_air, 1, 2.50);
    perform public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_tunai, 'amount', 12.00)));

    -- And the lunchtime rush, which happened with no bars on the
    -- phone. Each carries the till's own id and the till's own clock:
    -- `offline_sold_at` is when it was actually sold, kept alongside
    -- the server's time rather than instead of it.
    v_batch := jsonb_build_array(
      jsonb_build_object(
        'client_uuid', gen_random_uuid(),
        'sold_at', now() - interval '3 hours',
        'lines', jsonb_build_array(
          jsonb_build_object('item_id', v_john, 'quantity', 2, 'unit_price', 8.00),
          jsonb_build_object('item_id', v_air,  'quantity', 2, 'unit_price', 2.50)),
        'tenders', jsonb_build_array(
          jsonb_build_object('type', v_tunai, 'amount', 21.00))),
      jsonb_build_object(
        'client_uuid', gen_random_uuid(),
        'sold_at', now() - interval '2 hours 40 minutes',
        'lines', jsonb_build_array(
          jsonb_build_object('item_id', v_kebab, 'quantity', 3, 'unit_price', 9.50)),
        'tenders', jsonb_build_array(
          jsonb_build_object('type', v_ewallet, 'amount', 28.50))),
      jsonb_build_object(
        'client_uuid', gen_random_uuid(),
        'sold_at', now() - interval '2 hours 10 minutes',
        'lines', jsonb_build_array(
          jsonb_build_object('item_id', v_john, 'quantity', 1, 'unit_price', 8.00)),
        'tenders', jsonb_build_array(
          jsonb_build_object('type', v_tunai, 'amount', 10.00))));

    select count(*) into v_landed
      from public.ingest_offline_sales(v_phone, v_batch) r
     where r.outcome = 'landed';

    -- Sent twice, because a van coming back into signal retries the
    -- batch it is not sure went. Nothing lands the second time. This
    -- is the assertion `pos_offline.sql` makes; seeding it here means
    -- the demo tenant carries the evidence rather than the claim.
    select count(*) into v_again
      from public.ingest_offline_sales(v_phone, v_batch) r
     where r.outcome = 'already';
  end if;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Roti Warisan: a phone in a van, %s sales landed from the offline '
    'queue and %s rejected as already-landed when the batch was sent '
    'twice.', v_landed, v_again);
end;
$$;

revoke all on function app.demo_stall(uuid, uuid) from public, anon, authenticated;

comment on function app.demo_salon(uuid, uuid) is
  'Seeds the service business type: two providers on different hours, '
  'four services with their own durations and turnaround, a day with '
  'bookings already sold, and a monthly membership.';

comment on function app.demo_stall(uuid, uuid) is
  'Seeds the mobile business type, and the offline path with it: the '
  'lunchtime takings are landed through ingest_offline_sales and the '
  'batch is deliberately sent twice, so the tenant carries the evidence '
  'that it lands once rather than only the claim.';

-- ---------------------------------------------------------------------
-- Into the rebuild
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched, for the reason 0201, 0207 and
-- 0221 all give: a `create or replace` that only somebody's memory says
-- matches the previous body is how a rebuild quietly loses a tenant.
-- The only additions are the salon, the stall, their two owners, and
-- their place in the summary.
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
  v_stylist uuid; v_hawker uuid;
  v_salon uuid; v_stall uuid;
  v_salon_txt text; v_stall_txt text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.com',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.com',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.com',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.com', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.com',  'Tan Chee Keong');
  v_cook      := app.demo_user('warung@iakauntan.com',    'Faridah Ismail');
  v_stylist   := app.demo_user('salon@iakauntan.com',     'Aida Zulkifli');
  v_hawker    := app.demo_user('stall@iakauntan.com',     'Hafiz Rahman');

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

  -- And the two business types that had assertions but nowhere to look
  -- at them. See this migration's header for why they are tenants
  -- rather than extra outlets on the warung.
  v_salon := app.demo_company(
    v_stylist, 'Seri Ayu Salon & Spa Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201801003344', 'C20183344556', '96021',
    'Hairdressing and other beauty treatment',
    '10', 'Bandar Baru Bangi', '43650',
    'No 7-1, Jalan Medan Pusat Bandar 8', '03-8922 7788',
    'tempahan@seriayu.demo', 12::smallint);
  v_salon_txt := app.demo_salon(v_salon, v_stylist);

  v_stall := app.demo_company(
    v_hawker, 'Roti Warisan Enterprise', 'sole_proprietor'::app.entity_type,
    'JM0456789-K', 'IG20205678901', '56103',
    'Restaurants and mobile food service activities',
    '01', 'Johor Bahru', '80100',
    'Gerai bergerak — tiada premis tetap', '07-221 4455',
    'hafiz@rotiwarisan.demo', 12::smallint);
  v_stall_txt := app.demo_stall(v_stall, v_hawker);

  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
    v_pos, v_books_a, v_books_h, v_warung_txt, v_salon_txt, v_stall_txt);
end;
$$;

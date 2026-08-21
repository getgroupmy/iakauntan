-- =====================================================================
-- The demo that could only be rebuilt on a Tuesday
--
-- 0222 gave the salon two chairs with deliberately different diaries:
-- Aida Tuesday to Sunday, Faiz weekday evenings plus a short Saturday.
-- The same function then writes *today's* diary — four bookings at
-- fixed times — and `book_appointment` refuses a slot outside the
-- provider's hours, as it should.
--
-- Those two decisions do not fit together, and the seed therefore
-- failed outright on three days in every seven:
--
--   * Monday   — Aida has no hours, so the ten o'clock refused.
--   * Saturday — Faiz stops at six, so the half past five booking
--                (thirty minutes and a five minute buffer) needed six
--                oh five and refused.
--   * Sunday   — Faiz has no hours at all, so the three o'clock
--                refused.
--
-- `supabase/tests/demo_rebuild.sql` runs that seed, so CI was red on
-- those days for reasons that had nothing to do with the commit under
-- test — which is the worst kind of red, because it teaches people to
-- re-run the build instead of reading it.
--
-- The fix keeps the point of the original — two chairs that are not
-- interchangeable — and moves it from *days* to *hours*: Aida ten to
-- seven, Faiz two to nine, both every day. "Who is free at eight"
-- still has one answer, and the seed now works whatever day it is run.
-- =====================================================================

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
  -- Deliberately different hours. One provider is a schedule; two
  -- providers with the same schedule is still one schedule drawn
  -- twice. Aida opens the salon at ten, Faiz takes the evenings to
  -- nine -- which is what makes "who is free at eight" a real question.
  --
  -- Different *hours*, not different *days*, and that is this
  -- migration's whole point. Both chairs now work all seven, because
  -- the seed below writes today's diary and the days a chair did not
  -- work were days the demo could not be rebuilt at all.
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
    from generate_series(1, 7) d
  on conflict (provider_id, weekday, starts_at) do nothing;

  insert into public.pos_provider_hours
    (org_id, provider_id, weekday, starts_at, ends_at)
  select p_org, v_faiz, d, time '14:00', time '21:00'
    from generate_series(1, 7) d
  on conflict (provider_id, weekday, starts_at) do nothing;

  -- Saturday's shorter shift, deleted rather than left. The row said
  -- ten to six, and the half past five booking below needs six oh
  -- five: on a Saturday the seed refused itself.
  delete from public.pos_provider_hours h
   where h.provider_id = v_faiz and h.weekday = 6
     and h.starts_at = time '10:00' and h.ends_at = time '18:00';

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

-- =====================================================================
-- An address, a fee and a driver
--
-- 0229 taught the module that an order can arrive by delivery. It did
-- not teach it anything about the delivery itself, so a shop that took
-- one had a bill marked `delivery` and no way to say where it was
-- going, what the ride cost, or who took it. The address lived in the
-- note field, the fee was rung up as an item called "DELIVERY", and the
-- driver was a name somebody shouted at the door.
--
-- ---------------------------------------------------------------------
-- The fee is a shipping charge, not a plate of food
--
-- A delivery fee rung up as a line item lands in food revenue, is
-- counted in the item ranking, is discounted by every promotion that
-- names "all items", and earns loyalty points. None of that is what a
-- courier charge is. `sales_documents.shipping_amount` has existed
-- since 0005 and 0013 already posts it to 4900 on its own, so the fee
-- goes there: the ledger separates the ride from the food without a
-- single new account, and the journal balances because the receivable
-- was always the header total.
--
-- Points follow the same reasoning. `complete_pos_sale` now settles
-- loyalty against the total less the fee, because a shop that pays
-- points on a courier charge is paying points on money it hands
-- straight to a rider.
--
-- ---------------------------------------------------------------------
-- A zone is a postcode list, and the fee is derived from it
--
-- Malaysian addresses are reliably identified by a five-digit postcode
-- and unreliably by anything else, so a zone is a name and a list of
-- postcodes. A zone with an empty list is the catch-all — "anywhere
-- else we will go" — and is only reached when no zone names the
-- postcode.
--
-- The fee is recomputed by `recalc_pos_sale` on every change to the
-- basket, exactly like a promotion, because `free_above` is a promise
-- that has to come true the moment the customer adds the plate that
-- crosses it. A fee stored once at the door would still be sitting
-- there charging RM 6 on an order that just qualified for free
-- delivery. A fee typed by hand is marked `fee_is_manual` and is left
-- alone; typing one *below* what the zone says needs `pos_discount`,
-- because a fee a cashier can quietly set to zero is a discount wearing
-- a different hat.
--
-- ---------------------------------------------------------------------
-- A minimum is checked when the money is taken, not when the address is
--
-- Every shop with a minimum order takes the address first and the order
-- second, so refusing at the door refuses the wrong thing. The shortfall
-- is a sentence the till can show — the same shape as a blocked
-- promotion — and it becomes an error only in `complete_pos_sale`,
-- which is the one moment the basket is final.
--
-- ---------------------------------------------------------------------
-- Five states, and the driver is required for three of them
--
-- pending -> assigned -> collected -> delivered is the run. `failed` is
-- nobody home, a refused order, an address that does not exist; it
-- carries a reason because "failed" on its own tells a shop nothing it
-- can act on. Assigned, collected and delivered all require a driver,
-- enforced by a constraint rather than by the function that sets them:
-- a delivered order with nobody who delivered it is a row that can only
-- have come from a bug.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where the run has got to
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_delivery_status') then
    create type app.pos_delivery_status as enum (
      'pending',    -- address taken, nobody carrying it yet
      'assigned',   -- a driver has it on their list
      'collected',  -- the food is in the bag and out of the door
      'delivered',  -- handed over
      'failed'      -- nobody home, refused, or an address that is not one
    );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- How far, and what that costs
-- ---------------------------------------------------------------------
create table if not exists public.pos_delivery_zones (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,

  name       text not null check (btrim(name) <> ''),

  -- Five digits each, normalised on the way in. Empty means "anywhere
  -- we have not named", which is the catch-all and is matched last.
  postcodes  text[] not null default '{}',

  fee        numeric(18, 2) not null default 0 check (fee >= 0),

  -- What the food has to come to before this zone is worth the ride.
  -- Checked when the sale completes, not when the address is taken.
  min_order  numeric(18, 2) not null default 0 check (min_order >= 0),

  -- Spend this much and the ride is free. Null means it never is.
  free_above numeric(18, 2) check (free_above is null or free_above > 0),

  -- Roughly how long the ride takes, for what the customer is told.
  eta_minutes integer check (eta_minutes is null or eta_minutes > 0),

  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists pos_delivery_zones_name_uq
  on public.pos_delivery_zones (outlet_id, lower(btrim(name)));
create index if not exists pos_delivery_zones_outlet_idx
  on public.pos_delivery_zones (outlet_id, sort_order) where is_active;

comment on table public.pos_delivery_zones is
  'How far this outlet will go and what it charges to get there. A zone is a name and a list of five-digit postcodes; a zone with no postcodes is the catch-all and is only reached when no other zone names the address.';
comment on column public.pos_delivery_zones.free_above is
  'Spend this much on food and the ride is free. Re-tested by recalc_pos_sale on every change to the basket, so the fee falls away the moment the plate that qualifies is added.';
comment on column public.pos_delivery_zones.min_order is
  'What the food must come to before this zone is worth the ride. Shown as a shortfall while the bill is open and refused only at completion, because the address is taken before the order is.';

-- ---------------------------------------------------------------------
-- Who takes it
-- ---------------------------------------------------------------------
create table if not exists public.pos_drivers (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,

  -- Null means every outlet. A rider on one motorbike serving three
  -- shops in the same row is the normal case, not the exception.
  outlet_id  uuid references public.pos_outlets (id) on delete cascade,

  name       text not null check (btrim(name) <> ''),
  phone      text,
  vehicle    text,
  plate_no   text,

  -- When the rider has a login of their own. Optional: most do not.
  user_id    uuid references auth.users (id) on delete set null,

  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists pos_drivers_org_idx
  on public.pos_drivers (org_id, name) where is_active;

comment on table public.pos_drivers is
  'The people who carry the orders. Retired, never deleted: last month''s runs name the driver who made them and a deleted row would take that answer with it.';

-- ---------------------------------------------------------------------
-- The delivery itself
-- ---------------------------------------------------------------------
create table if not exists public.pos_deliveries (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,

  -- One per sale. A bill goes to one address; two would be two bills.
  sale_id    uuid not null unique references public.pos_sales (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,

  -- Both required. A house with no phone number is a house the driver
  -- cannot ask for directions to, and every shop that has tried it has
  -- the same story about the roundabout.
  address_line1 text not null check (btrim(address_line1) <> ''),
  phone         text not null check (btrim(phone) <> ''),

  address_line2 text,
  city          text,
  state_name    text,
  postcode      text,
  recipient     text,

  -- Gate codes, "leave it with the guard", which lift. The half of an
  -- address that is not on the envelope.
  notes         text,

  zone_id       uuid references public.pos_delivery_zones (id) on delete set null,
  fee           numeric(18, 2) not null default 0 check (fee >= 0),

  -- A fee somebody typed. Left alone by recalculation; a derived fee is
  -- rebuilt from the zone on every change to the basket.
  fee_is_manual boolean not null default false,

  driver_id     uuid references public.pos_drivers (id) on delete set null,
  status        app.pos_delivery_status not null default 'pending',

  -- What the customer was told, kept as it was said.
  promised_at   timestamptz,

  assigned_at   timestamptz,
  collected_at  timestamptz,
  delivered_at  timestamptz,
  failed_at     timestamptz,
  failure_reason text,

  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- A run that has left needs somebody carrying it. A delivered order
  -- with nobody who delivered it is a row that can only be a bug.
  constraint pos_deliveries_driver_ck check (
    status = 'pending' or status = 'failed' or driver_id is not null),

  -- Each stamp belongs to its state.
  constraint pos_deliveries_delivered_ck check (
    (status = 'delivered') = (delivered_at is not null)),
  constraint pos_deliveries_failed_ck check (
    (status = 'failed') = (failed_at is not null)),

  -- And a failure says why. "Failed" on its own tells a shop nothing
  -- it can act on.
  constraint pos_deliveries_reason_ck check (
    status <> 'failed' or btrim(coalesce(failure_reason, '')) <> '')
);

create index if not exists pos_deliveries_open_idx
  on public.pos_deliveries (outlet_id, created_at)
  where status in ('pending', 'assigned', 'collected');
create index if not exists pos_deliveries_driver_idx
  on public.pos_deliveries (driver_id, created_at desc);
create index if not exists pos_deliveries_org_idx
  on public.pos_deliveries (org_id, created_at desc);

comment on table public.pos_deliveries is
  'Where one bill is going, what the ride costs and who is carrying it. One row per sale, because a bill goes to one address.';
comment on column public.pos_deliveries.fee_is_manual is
  'True when somebody typed the fee. A derived fee is rebuilt from the zone on every recalculation so free_above can come true mid-basket; a typed one is left where it was put.';

-- ---------------------------------------------------------------------
-- And on the bill
-- ---------------------------------------------------------------------
alter table public.pos_sales
  add column if not exists delivery_fee numeric(18, 2) not null default 0
    check (delivery_fee >= 0);

comment on column public.pos_sales.delivery_fee is
  'The courier charge on this bill, derived by recalc_pos_sale from the delivery row. Added to the total after every discount, because a fee that discounts away is a shop paying a rider out of its own pocket.';

-- ---------------------------------------------------------------------
-- Five digits, whatever was typed
-- ---------------------------------------------------------------------
--
-- Postcodes arrive as "58200", "58 200" and "Kuala Lumpur 58200". Only
-- the digits mean anything, and only the first five of those.
create or replace function app.pos_postcode(p_text text)
returns text
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select nullif(left(regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g'), 5), '');
$$;

comment on function app.pos_postcode(text) is
  'The five digits of a Malaysian postcode, whatever was typed around them. Immutable, so a zone''s list can be normalised on the way in and matched with =.';

-- ---------------------------------------------------------------------
-- Which zone this address falls in
-- ---------------------------------------------------------------------
--
-- A zone that names the postcode wins. The catch-all — a zone with no
-- postcodes at all — is only reached when none does, which is what
-- makes "anywhere else, RM 12" expressible without listing the country.
create or replace function app.pos_delivery_zone_for(
  p_outlet   uuid,
  p_postcode text)
returns uuid
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_pc   text := app.pos_postcode(p_postcode);
  v_zone uuid;
begin
  if v_pc is not null then
    select z.id into v_zone
      from public.pos_delivery_zones z
     where z.outlet_id = p_outlet and z.is_active
       and v_pc = any (z.postcodes)
     order by z.sort_order, z.name
     limit 1;
  end if;

  if v_zone is null then
    select z.id into v_zone
      from public.pos_delivery_zones z
     where z.outlet_id = p_outlet and z.is_active
       and cardinality(z.postcodes) = 0
     order by z.sort_order, z.name
     limit 1;
  end if;

  return v_zone;
end;
$$;

revoke all on function app.pos_delivery_zone_for(uuid, text) from public, anon;
grant execute on function app.pos_delivery_zone_for(uuid, text) to authenticated;

comment on function app.pos_delivery_zone_for(uuid, text) is
  'The zone this postcode falls in at this outlet. A zone naming the postcode beats the catch-all, so "anywhere else" is expressible without listing the country.';

-- ---------------------------------------------------------------------
-- What that zone charges for this basket
-- ---------------------------------------------------------------------
create or replace function app.pos_delivery_fee(
  p_zone  uuid,
  p_goods numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_z public.pos_delivery_zones;
begin
  if p_zone is null then
    return 0;
  end if;
  select * into v_z from public.pos_delivery_zones where id = p_zone;
  if v_z.id is null or not v_z.is_active then
    return 0;
  end if;
  -- The promise on the poster, kept the moment it comes true.
  if v_z.free_above is not null and coalesce(p_goods, 0) >= v_z.free_above then
    return 0;
  end if;
  return round(v_z.fee, 2);
end;
$$;

revoke all on function app.pos_delivery_fee(uuid, numeric) from public, anon;
grant execute on function app.pos_delivery_fee(uuid, numeric) to authenticated;

comment on function app.pos_delivery_fee(uuid, numeric) is
  'What this zone charges to carry a basket worth this much. Zero once free_above is reached — the poster''s promise, kept the moment it comes true.';

-- ---------------------------------------------------------------------
-- Why this order is not ready to go yet
-- ---------------------------------------------------------------------
--
-- A sentence, or null. The same shape as a blocked promotion, and for
-- the same reason: the till has to be able to say what is wrong while
-- the customer is still on the phone.
create or replace function app.pos_delivery_blocked(p_sale uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_min   numeric;
  v_name  text;
  v_goods numeric;
begin
  select z.min_order, z.name
    into v_min, v_name
    from public.pos_deliveries d
    join public.pos_delivery_zones z on z.id = d.zone_id
   where d.sale_id = p_sale;

  if coalesce(v_min, 0) <= 0 then
    return null;
  end if;

  -- Summed from the lines. `pos_sales.subtotal` is only right once
  -- recalculation has run, and a rule that depends on the caller having
  -- remembered to run something is a rule that fails on a Friday.
  select coalesce(sum(l.line_subtotal + l.tax_amount), 0) into v_goods
    from public.pos_sale_lines l where l.sale_id = p_sale;

  if v_goods >= v_min then
    return null;
  end if;

  return v_name || ' needs ' || to_char(v_min, 'FM999999990.00')
    || ' of food before we deliver — another '
    || to_char(v_min - v_goods, 'FM999999990.00') || ' to go.';
end;
$$;

revoke all on function app.pos_delivery_blocked(uuid) from public, anon;
grant execute on function app.pos_delivery_blocked(uuid) to authenticated;

comment on function app.pos_delivery_blocked(uuid) is
  'Why this delivery is not ready to be rung up — the zone minimum and the shortfall — or null. Shown while the bill is open; raised by complete_pos_sale, which is the one moment the basket is final.';

-- ---------------------------------------------------------------------
-- Recalculating a basket that now has a ride on it
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0256, for one term and its ordering. The fee is
-- rebuilt from the zone first — so free_above comes true the moment the
-- qualifying plate is added — and then added *after* every discount has
-- been taken and floored. A delivery fee that a bill discount can eat
-- is a shop paying the rider out of its own margin.
create or replace function app.recalc_pos_sale(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sub numeric; v_tax numeric; v_disc numeric;
  v_loy numeric; v_pct numeric; v_bill numeric;
  v_promo numeric; v_gross numeric; v_fee numeric;
begin
  select coalesce(sum(l.line_subtotal), 0),
         coalesce(sum(l.tax_amount), 0),
         coalesce(sum(l.discount_amount), 0)
    into v_sub, v_tax, v_disc
    from public.pos_sale_lines l where l.sale_id = p_sale;

  select coalesce(s.loyalty_discount, 0),
         coalesce(s.bill_discount_percent, 0),
         coalesce(s.bill_discount, 0)
    into v_loy, v_pct, v_bill
    from public.pos_sales s where s.id = p_sale;

  -- Derived, never stored twice: the rows are the promotions.
  select coalesce(sum(sp.amount), 0) into v_promo
    from public.pos_sale_promotions sp where sp.sale_id = p_sale;

  v_gross := round(v_sub + v_tax, 2);

  -- The ride, rebuilt from the zone against the food. Measured on the
  -- goods before any discount, because "spend RM 50 and delivery is
  -- free" is a promise about what was ordered, not about what was
  -- charged after the manager knocked something off.
  update public.pos_deliveries d
     set fee = app.pos_delivery_fee(d.zone_id, v_gross),
         updated_at = now()
   where d.sale_id = p_sale
     and not d.fee_is_manual
     and d.fee <> app.pos_delivery_fee(d.zone_id, v_gross);

  select coalesce(d.fee, 0) into v_fee
    from public.pos_deliveries d where d.sale_id = p_sale;
  v_fee := coalesce(v_fee, 0);

  if v_pct > 0 then
    v_bill := round(v_gross * v_pct / 100.0, 2);
  end if;
  v_bill := least(greatest(v_bill, 0), v_gross);
  -- Whatever is left after the manual discount, so the two together can
  -- never hand money back across the counter.
  v_promo := least(greatest(v_promo, 0), v_gross - v_bill);

  update public.pos_sales s
     set subtotal = v_sub,
         tax_amount = v_tax,
         discount_amount = v_disc,
         bill_discount = v_bill,
         promo_discount = v_promo,
         delivery_fee = v_fee,
         -- The food, floored at nothing, and then the ride on top.
         total_amount = round(
           greatest(round(v_gross - v_bill - v_promo - v_loy, 2), 0) + v_fee, 2)
   where s.id = p_sale;
end;
$$;

-- ---------------------------------------------------------------------
-- Taking the address
-- ---------------------------------------------------------------------
--
-- One function for both the first time and every correction after it,
-- because "the customer just read the unit number back differently" is
-- the normal case and a second function for it would be a second place
-- for the zone to be resolved.
--
-- Setting an address puts the bill on the delivery channel, which goes
-- through 0229's own function so an outlet that does not deliver still
-- cannot record a delivery.
create or replace function public.set_pos_delivery(
  p_sale      uuid,
  p_line1     text,
  p_phone     text,
  p_line2     text default null,
  p_city      text default null,
  p_state     text default null,
  p_postcode  text default null,
  p_recipient text default null,
  p_notes     text default null,
  p_promised  timestamptz default null,
  p_fee       numeric default null)
returns table (
  delivery_id    uuid,
  zone_name      text,
  fee            numeric,
  eta_minutes    integer,
  blocked_reason text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_zone   uuid;
  v_goods  numeric;
  v_auto   numeric;
  v_fee    numeric;
  v_manual boolean := false;
  v_id     uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception
      'That sale is already %. Where it went is part of what was '
      'reported for the day.', v_sale.status
      using errcode = '23514';
  end if;
  if btrim(coalesce(p_line1, '')) = '' then
    raise exception 'Where is it going?' using errcode = '23514';
  end if;
  if btrim(coalesce(p_phone, '')) = '' then
    raise exception
      'A delivery needs a phone number. The driver will need it before '
      'the roundabout.'
      using errcode = '23514';
  end if;

  v_zone := app.pos_delivery_zone_for(v_sale.outlet_id, p_postcode);

  select coalesce(sum(l.line_subtotal + l.tax_amount), 0) into v_goods
    from public.pos_sale_lines l where l.sale_id = p_sale;

  v_auto := app.pos_delivery_fee(v_zone, v_goods);
  v_fee  := v_auto;

  if p_fee is not null then
    if p_fee < 0 then
      raise exception 'A delivery fee cannot be negative.' using errcode = '23514';
    end if;
    -- Charging more for a house up a hill is the shop's business.
    -- Charging less is money off the bill, and money off the bill is a
    -- permission, whatever it is called on the screen.
    if p_fee < v_auto and not app.can_discount_pos(v_sale.org_id) then
      raise exception
        'Charging less than the zone says needs permission to discount. '
        'Ask a manager.'
        using errcode = '42501';
    end if;
    v_fee    := round(p_fee, 2);
    v_manual := true;
  end if;

  insert into public.pos_deliveries as d (
    org_id, sale_id, outlet_id, address_line1, phone, address_line2,
    city, state_name, postcode, recipient, notes, zone_id, fee,
    fee_is_manual, promised_at, created_by)
  values (
    v_sale.org_id, p_sale, v_sale.outlet_id, btrim(p_line1), btrim(p_phone),
    nullif(btrim(coalesce(p_line2, '')), ''),
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(btrim(coalesce(p_state, '')), ''),
    app.pos_postcode(p_postcode),
    nullif(btrim(coalesce(p_recipient, '')), ''),
    nullif(btrim(coalesce(p_notes, '')), ''),
    v_zone, v_fee, v_manual, p_promised, auth.uid())
  on conflict (sale_id) do update
     set address_line1 = excluded.address_line1,
         phone         = excluded.phone,
         address_line2 = excluded.address_line2,
         city          = excluded.city,
         state_name    = excluded.state_name,
         postcode      = excluded.postcode,
         recipient     = excluded.recipient,
         notes         = excluded.notes,
         zone_id       = excluded.zone_id,
         fee           = excluded.fee,
         fee_is_manual = excluded.fee_is_manual,
         promised_at   = coalesce(excluded.promised_at, d.promised_at),
         updated_at    = now()
  returning id into v_id;

  -- 0229 owns the channel and the rule that an outlet accepts what it
  -- says it accepts. Calling it rather than restating it means a stall
  -- that does not deliver cannot get here by another door.
  if v_sale.order_channel is distinct from 'delivery'::app.pos_order_channel then
    perform public.set_pos_sale_channel(p_sale, 'delivery');
  end if;

  perform app.recalc_pos_sale(p_sale);

  delivery_id := v_id;
  select z.name, z.eta_minutes into zone_name, eta_minutes
    from public.pos_delivery_zones z where z.id = v_zone;
  select d.fee into fee from public.pos_deliveries d where d.id = v_id;
  blocked_reason := app.pos_delivery_blocked(p_sale);
  return next;
end;
$$;

revoke all on function public.set_pos_delivery(
  uuid, text, text, text, text, text, text, text, text, timestamptz, numeric)
  from public, anon;
grant execute on function public.set_pos_delivery(
  uuid, text, text, text, text, text, text, text, text, timestamptz, numeric)
  to authenticated;

comment on function public.set_pos_delivery(
  uuid, text, text, text, text, text, text, text, text, timestamptz, numeric) is
  'Takes or corrects the address on a parked bill, resolves the zone, derives the fee and puts the sale on the delivery channel. A fee below the zone''s needs pos_discount.';

-- ---------------------------------------------------------------------
-- It is being collected after all
-- ---------------------------------------------------------------------
create or replace function public.clear_pos_delivery(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_del  public.pos_deliveries;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception
      'That sale is already %. Where it went is part of what was '
      'reported for the day.', v_sale.status
      using errcode = '23514';
  end if;

  select * into v_del from public.pos_deliveries where sale_id = p_sale;
  if v_del.id is null then
    return;
  end if;
  -- Once a driver has it, the run happened. Whatever the shop wants to
  -- record instead, it is not "there was never a delivery".
  if v_del.status <> 'pending' then
    raise exception
      'That order is already with %. Mark the run failed instead.',
      coalesce((select dr.name from public.pos_drivers dr where dr.id = v_del.driver_id),
               'a driver')
      using errcode = '23514';
  end if;

  delete from public.pos_deliveries where id = v_del.id;
  perform app.recalc_pos_sale(p_sale);
end;
$$;

revoke all on function public.clear_pos_delivery(uuid) from public, anon;
grant execute on function public.clear_pos_delivery(uuid) to authenticated;

comment on function public.clear_pos_delivery(uuid) is
  'Takes the address and the fee back off a parked bill. Refused once a driver has the order: a run that happened is not undone by deleting the row that says so.';

-- ---------------------------------------------------------------------
-- Giving it to somebody
-- ---------------------------------------------------------------------
--
-- Assigning and re-assigning are the same call: a driver whose bike
-- will not start hands the bag to the next one, and that is a Tuesday,
-- not an exception.
create or replace function public.assign_pos_delivery(
  p_delivery uuid,
  p_driver   uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_del public.pos_deliveries;
  v_drv public.pos_drivers;
begin
  select * into v_del from public.pos_deliveries where id = p_delivery;
  if v_del.id is null then
    raise exception 'No such delivery.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_del.org_id, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;
  if v_del.status in ('delivered', 'failed') then
    raise exception 'That run is already %.', v_del.status
      using errcode = '23514';
  end if;

  select * into v_drv from public.pos_drivers where id = p_driver;
  if v_drv.id is null or v_drv.org_id <> v_del.org_id then
    raise exception 'No such driver.' using errcode = 'P0002';
  end if;
  if not v_drv.is_active then
    raise exception '% is not driving any more.', v_drv.name
      using errcode = '23514';
  end if;
  -- A driver kept for one outlet stays at that outlet. A driver with no
  -- outlet works all of them, which is how most shops actually run.
  if v_drv.outlet_id is not null and v_drv.outlet_id <> v_del.outlet_id then
    raise exception '% does not drive for this outlet.', v_drv.name
      using errcode = '23514';
  end if;

  update public.pos_deliveries d
     set driver_id = p_driver,
         status = case when d.status = 'pending' then 'assigned' else d.status end,
         assigned_at = coalesce(d.assigned_at, now()),
         updated_at = now()
   where d.id = p_delivery;

  return p_delivery;
end;
$$;

revoke all on function public.assign_pos_delivery(uuid, uuid) from public, anon;
grant execute on function public.assign_pos_delivery(uuid, uuid) to authenticated;

comment on function public.assign_pos_delivery(uuid, uuid) is
  'Puts a run on a driver''s list, or moves it to another one. Refused once the run is finished, and refused for a driver kept to a different outlet.';

-- ---------------------------------------------------------------------
-- Where the run got to
-- ---------------------------------------------------------------------
create or replace function public.set_pos_delivery_status(
  p_delivery uuid,
  p_status   app.pos_delivery_status,
  p_reason   text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_del public.pos_deliveries;
begin
  select * into v_del from public.pos_deliveries where id = p_delivery;
  if v_del.id is null then
    raise exception 'No such delivery.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_del.org_id, 'pos') then
    raise exception 'not permitted to work this shop' using errcode = '42501';
  end if;

  -- Finished is finished. An order that was handed over cannot become
  -- one that was never collected because somebody tapped the wrong row.
  if v_del.status in ('delivered', 'failed') then
    raise exception
      'That run is already %. It cannot be moved again.', v_del.status
      using errcode = '23514';
  end if;
  if p_status = 'pending' then
    raise exception
      'A run does not go back to waiting. Give it to another driver instead.'
      using errcode = '23514';
  end if;
  if p_status in ('assigned', 'collected', 'delivered')
     and v_del.driver_id is null then
    raise exception 'Give it to a driver first.' using errcode = '23514';
  end if;
  if p_status = 'failed' and btrim(coalesce(p_reason, '')) = '' then
    raise exception
      'Why did it fail? "Failed" on its own tells nobody anything they '
      'can act on.'
      using errcode = '23514';
  end if;

  update public.pos_deliveries d
     set status = p_status,
         collected_at = case when p_status in ('collected', 'delivered')
                             then coalesce(d.collected_at, now())
                             else d.collected_at end,
         delivered_at = case when p_status = 'delivered' then now() end,
         failed_at    = case when p_status = 'failed' then now() end,
         failure_reason = case when p_status = 'failed'
                               then btrim(p_reason) else d.failure_reason end,
         updated_at = now()
   where d.id = p_delivery;

  return p_delivery;
end;
$$;

revoke all on function public.set_pos_delivery_status(
  uuid, app.pos_delivery_status, text) from public, anon;
grant execute on function public.set_pos_delivery_status(
  uuid, app.pos_delivery_status, text) to authenticated;

comment on function public.set_pos_delivery_status(uuid, app.pos_delivery_status, text) is
  'Moves a run along. Delivered and failed are terminal, a failure has to say why, and nothing leaves the shop without a driver on it.';

-- ---------------------------------------------------------------------
-- Keeping the zones
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_delivery_zone(
  p_id         uuid,
  p_outlet     uuid,
  p_name       text,
  p_postcodes  text[] default '{}',
  p_fee        numeric default 0,
  p_min_order  numeric default 0,
  p_free_above numeric default null,
  p_eta        integer default null,
  p_sort       integer default 0,
  p_active     boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_pcs text[];
  v_id  uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A zone needs a name people recognise.' using errcode = '23514';
  end if;

  -- Normalised on the way in so matching is an equality test rather
  -- than a function nobody remembers to call.
  select coalesce(array_agg(distinct pc order by pc), '{}')
    into v_pcs
    from unnest(coalesce(p_postcodes, '{}')) u
    cross join lateral (select app.pos_postcode(u) as pc) n
   where n.pc is not null;

  if p_id is null then
    insert into public.pos_delivery_zones
      (org_id, outlet_id, name, postcodes, fee, min_order, free_above,
       eta_minutes, sort_order, is_active)
    values
      (v_org, p_outlet, btrim(p_name), v_pcs, coalesce(p_fee, 0),
       coalesce(p_min_order, 0), p_free_above, p_eta,
       coalesce(p_sort, 0), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.pos_delivery_zones z
       set name = btrim(p_name),
           postcodes = v_pcs,
           fee = coalesce(p_fee, 0),
           min_order = coalesce(p_min_order, 0),
           free_above = p_free_above,
           eta_minutes = p_eta,
           sort_order = coalesce(p_sort, 0),
           is_active = coalesce(p_active, true),
           updated_at = now()
     where z.id = p_id and z.org_id = v_org
    returning z.id into v_id;
    if v_id is null then
      raise exception 'No such zone.' using errcode = 'P0002';
    end if;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_delivery_zone(
  uuid, uuid, text, text[], numeric, numeric, numeric, integer, integer, boolean)
  from public, anon;
grant execute on function public.upsert_pos_delivery_zone(
  uuid, uuid, text, text[], numeric, numeric, numeric, integer, integer, boolean)
  to authenticated;

create or replace function public.retire_pos_delivery_zone(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select org_id into v_org from public.pos_delivery_zones where id = p_id;
  if v_org is null then
    raise exception 'No such zone.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  -- Retired, never deleted: every delivery already taken names the zone
  -- it was charged under.
  update public.pos_delivery_zones
     set is_active = false, updated_at = now()
   where id = p_id;
end;
$$;

revoke all on function public.retire_pos_delivery_zone(uuid) from public, anon;
grant execute on function public.retire_pos_delivery_zone(uuid) to authenticated;

create or replace function public.pos_delivery_zones_admin(p_org uuid)
returns table (
  id          uuid,
  outlet_id   uuid,
  outlet_name text,
  name        text,
  postcodes   text[],
  fee         numeric,
  min_order   numeric,
  free_above  numeric,
  eta_minutes integer,
  sort_order  integer,
  is_active   boolean,
  runs        integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select z.id, z.outlet_id, o.name, z.name, z.postcodes, z.fee,
         z.min_order, z.free_above, z.eta_minutes, z.sort_order, z.is_active,
         (select count(*)::integer from public.pos_deliveries d
           where d.zone_id = z.id)
    from public.pos_delivery_zones z
    join public.pos_outlets o on o.id = z.outlet_id
   where z.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by o.name, z.sort_order, z.name;
$$;

grant execute on function public.pos_delivery_zones_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Keeping the drivers
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_driver(
  p_id      uuid,
  p_org     uuid,
  p_name    text,
  p_phone   text default null,
  p_vehicle text default null,
  p_plate   text default null,
  p_outlet  uuid default null,
  p_user    uuid default null,
  p_active  boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A driver needs a name.' using errcode = '23514';
  end if;
  if p_outlet is not null
     and not exists (select 1 from public.pos_outlets o
                      where o.id = p_outlet and o.org_id = p_org) then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;

  if p_id is null then
    insert into public.pos_drivers
      (org_id, outlet_id, name, phone, vehicle, plate_no, user_id, is_active)
    values
      (p_org, p_outlet, btrim(p_name),
       nullif(btrim(coalesce(p_phone, '')), ''),
       nullif(btrim(coalesce(p_vehicle, '')), ''),
       nullif(btrim(coalesce(p_plate, '')), ''),
       p_user, coalesce(p_active, true))
    returning id into v_id;
  else
    update public.pos_drivers d
       set outlet_id = p_outlet,
           name = btrim(p_name),
           phone = nullif(btrim(coalesce(p_phone, '')), ''),
           vehicle = nullif(btrim(coalesce(p_vehicle, '')), ''),
           plate_no = nullif(btrim(coalesce(p_plate, '')), ''),
           user_id = p_user,
           is_active = coalesce(p_active, true),
           updated_at = now()
     where d.id = p_id and d.org_id = p_org
    returning d.id into v_id;
    if v_id is null then
      raise exception 'No such driver.' using errcode = 'P0002';
    end if;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_driver(
  uuid, uuid, text, text, text, text, uuid, uuid, boolean) from public, anon;
grant execute on function public.upsert_pos_driver(
  uuid, uuid, text, text, text, text, uuid, uuid, boolean) to authenticated;

create or replace function public.retire_pos_driver(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_open integer;
begin
  select org_id into v_org from public.pos_drivers where id = p_id;
  if v_org is null then
    raise exception 'No such driver.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;

  select count(*)::integer into v_open
    from public.pos_deliveries d
   where d.driver_id = p_id and d.status in ('assigned', 'collected');
  if v_open > 0 then
    raise exception
      'That driver still has % order(s) out. Land them first.', v_open
      using errcode = '23514';
  end if;

  update public.pos_drivers
     set is_active = false, updated_at = now()
   where id = p_id;
end;
$$;

revoke all on function public.retire_pos_driver(uuid) from public, anon;
grant execute on function public.retire_pos_driver(uuid) to authenticated;

comment on function public.retire_pos_driver(uuid) is
  'Stands a driver down. Refused while they still have orders out, because the shop would lose the only name attached to food that is on a motorbike right now.';

create or replace function public.pos_drivers_admin(p_org uuid)
returns table (
  id          uuid,
  outlet_id   uuid,
  outlet_name text,
  name        text,
  phone       text,
  vehicle     text,
  plate_no    text,
  is_active   boolean,
  out_now     integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select dr.id, dr.outlet_id, o.name, dr.name, dr.phone, dr.vehicle,
         dr.plate_no, dr.is_active,
         (select count(*)::integer from public.pos_deliveries d
           where d.driver_id = dr.id
             and d.status in ('assigned', 'collected'))
    from public.pos_drivers dr
    left join public.pos_outlets o on o.id = dr.outlet_id
   where dr.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by dr.is_active desc, dr.name;
$$;

grant execute on function public.pos_drivers_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Completing a sale that has a ride on it
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0256 for three changes, all of them about the fee
-- being a courier charge rather than a plate of food.
--
-- The zone minimum is raised here because this is the one moment the
-- basket is final. The fee goes onto the invoice header's
-- `shipping_amount`, which 0013 already posts to 4900 by itself — so
-- the ride lands in its own revenue account without a new account, a
-- new line type, or a change to the posting function. And loyalty
-- settles against the total less the fee, because points paid on a
-- courier charge are points paid on money the shop never keeps.
create or replace function public.complete_pos_sale(
  p_sale    uuid,
  p_tenders jsonb,
  p_contact uuid default null)
returns table (
  sale_id     uuid,
  invoice_no  text,
  total       numeric,
  cash_due    numeric,
  change_due  numeric,
  rounding    numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
  v_block    text;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  -- Worked out again here, not trusted from the screen. A bill parked
  -- at ten to eleven and settled at five past is settled outside the
  -- happy hour, and the customer is charged what the shop's own rule
  -- says at the moment the money changes hands. Re-read afterwards,
  -- because this is what moves the total.
  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  select * into v_sale from public.pos_sales where id = p_sale;

  -- The zone minimum, checked at the one moment the basket is final.
  -- Refusing at the door would refuse the wrong thing: every shop with
  -- a minimum takes the address first and the order second.
  v_block := app.pos_delivery_blocked(p_sale);
  if v_block is not null then
    raise exception '%', v_block using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, current_date, current_date, v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id);
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         -- The redemption AND the bill discount, on the header rather
         -- than spread across the lines. `sales_documents.discount_amount`
         -- is exactly the field for a discount that belongs to the
         -- document, and `prepare_einvoice` already maps it to the
         -- MyInvois total discount, so what LHDN is told matches what
         -- was charged. Both are added because both came off the same
         -- header: reporting only one of them would understate the
         -- discount on every bill a manager touched.
         discount_amount = coalesce(v_sale.loyalty_discount, 0)
                         + coalesce(v_sale.bill_discount, 0)
                         + coalesce(v_sale.promo_discount, 0),
         -- The ride, on the field the ledger already knows what to do
         -- with. 0013 posts shipping_amount to 4900 on its own, so the
         -- courier charge lands in its own revenue account instead of
         -- in food sales, and the journal still balances because the
         -- receivable was always the header total.
         shipping_amount = coalesce(v_sale.delivery_fee, 0),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- Banked against the first tender's account. A shop splitting one
  -- sale across two accounts is real and is not this migration's
  -- problem; what matters here is that the money lands somewhere named
  -- rather than in the current account by default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from public.pos_tender_types tt
   where tt.id = ((p_tenders -> 0) ->> 'type')::uuid;

  v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

  insert into public.receipts (
    org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
    bank_account_id, currency, exchange_rate, amount, base_amount,
    status, notes, created_by)
  values (
    v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
    'MYR', 1,
    round(v_sale.total_amount + v_adj, 2),
    round(v_sale.total_amount + v_adj, 2),
    'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_rcp;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if round(v_sale.total_amount + v_adj, 2) > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, round(v_sale.total_amount + v_adj, 2),
       v_sale.sold_by);
  end if;

  perform app.post_receipt_internal(v_rcp);

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  -- On the food, not on the ride. A shop that pays points on a courier
  -- charge is paying points on money it hands straight to a rider.
  perform app.pos_settle_loyalty(
    p_sale,
    greatest(round(v_sale.total_amount + v_adj
                   - coalesce(v_sale.delivery_fee, 0), 2), 0));

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$$;

-- ---------------------------------------------------------------------
-- What the till shows while the bill is open
-- ---------------------------------------------------------------------
create or replace function public.pos_delivery_for(p_sale uuid)
returns table (
  id             uuid,
  address_line1  text,
  address_line2  text,
  city           text,
  state_name     text,
  postcode       text,
  recipient      text,
  phone          text,
  notes          text,
  zone_id        uuid,
  zone_name      text,
  eta_minutes    integer,
  fee            numeric,
  fee_is_manual  boolean,
  status         app.pos_delivery_status,
  driver_id      uuid,
  driver_name    text,
  driver_phone   text,
  promised_at    timestamptz,
  blocked_reason text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select d.id, d.address_line1, d.address_line2, d.city, d.state_name,
         d.postcode, d.recipient, d.phone, d.notes,
         d.zone_id, z.name, z.eta_minutes, d.fee, d.fee_is_manual,
         d.status, d.driver_id, dr.name, dr.phone, d.promised_at,
         app.pos_delivery_blocked(d.sale_id)
    from public.pos_deliveries d
    left join public.pos_delivery_zones z on z.id = d.zone_id
    left join public.pos_drivers dr on dr.id = d.driver_id
   where d.sale_id = p_sale
     and app.can_read_module(d.org_id, 'pos');
$$;

grant execute on function public.pos_delivery_for(uuid) to authenticated;

comment on function public.pos_delivery_for(uuid) is
  'Where this bill is going, what the ride costs and who has it — with the shortfall sentence, so the till can say what is wrong while the customer is still on the phone.';

-- ---------------------------------------------------------------------
-- The runs still out
-- ---------------------------------------------------------------------
--
-- What somebody standing at the pass needs: every order that has not
-- landed, oldest first, with the minutes it has been waiting computed
-- on the server. Two devices with two clocks would otherwise show two
-- different boards, and the argument that follows is with a customer.
create or replace function public.pos_delivery_board(p_outlet uuid)
returns table (
  id            uuid,
  sale_id       uuid,
  sale_no       text,
  status        app.pos_delivery_status,
  recipient     text,
  phone         text,
  address_line1 text,
  address_line2 text,
  city          text,
  postcode      text,
  notes         text,
  zone_name     text,
  fee           numeric,
  total_amount  numeric,
  paid          boolean,
  driver_id     uuid,
  driver_name   text,
  promised_at   timestamptz,
  waiting_minutes integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select d.id, d.sale_id, s.sale_no, d.status, d.recipient, d.phone,
         d.address_line1, d.address_line2, d.city, d.postcode, d.notes,
         z.name, d.fee, s.total_amount,
         s.status = 'completed',
         d.driver_id, dr.name, d.promised_at,
         floor(extract(epoch from (now() - d.created_at)) / 60.0)::integer
    from public.pos_deliveries d
    join public.pos_sales s on s.id = d.sale_id
    left join public.pos_delivery_zones z on z.id = d.zone_id
    left join public.pos_drivers dr on dr.id = d.driver_id
   where d.outlet_id = p_outlet
     and d.status in ('pending', 'assigned', 'collected')
     and s.status <> 'voided'
     and app.can_read_module(d.org_id, 'pos')
   order by d.created_at;
$$;

grant execute on function public.pos_delivery_board(uuid) to authenticated;

comment on function public.pos_delivery_board(uuid) is
  'Every run at this outlet that has not landed, oldest first, with minutes waiting computed on the server so two devices cannot show two different boards.';

-- ---------------------------------------------------------------------
-- What the day's driving looked like
-- ---------------------------------------------------------------------
--
-- Per driver, per trading day, in the shop's own time. Failed runs are
-- their own column rather than missing from the count: a driver with
-- twelve runs and four failures is a different conversation from one
-- with eight and none, and the second is what an average would show.
create or replace function public.pos_driver_runs(
  p_org  uuid,
  p_date date)
returns table (
  driver_id   uuid,
  driver_name text,
  outlet_name text,
  runs        integer,
  delivered   integer,
  failed      integer,
  still_out   integer,
  fees        numeric,
  goods       numeric,
  median_minutes integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select dr.id, dr.name, o.name,
         count(d.id)::integer,
         count(*) filter (where d.status = 'delivered')::integer,
         count(*) filter (where d.status = 'failed')::integer,
         count(*) filter (where d.status in ('assigned', 'collected'))::integer,
         coalesce(sum(d.fee), 0),
         coalesce(sum(s.total_amount - d.fee), 0),
         ceil(percentile_cont(0.5) within group (
           order by case when d.status = 'delivered'
                    then extract(epoch from (d.delivered_at - d.created_at)) / 60.0
                    end))::integer
    from public.pos_drivers dr
    left join public.pos_deliveries d
           on d.driver_id = dr.id
          and (d.created_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
    left join public.pos_sales s on s.id = d.sale_id
    left join public.pos_outlets o on o.id = dr.outlet_id
   where dr.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   group by dr.id, dr.name, o.name
   order by dr.name;
$$;

grant execute on function public.pos_driver_runs(uuid, date) to authenticated;

comment on function public.pos_driver_runs(uuid, date) is
  'What each driver carried on one trading day, in Asia/Kuala_Lumpur. Failures are their own column: twelve runs with four failures is a different conversation from eight with none.';

-- ---------------------------------------------------------------------
-- And the same day, per outlet
-- ---------------------------------------------------------------------
create or replace function public.pos_delivery_day(
  p_org  uuid,
  p_date date)
returns table (
  outlet_id     uuid,
  outlet_name   text,
  runs          integer,
  delivered     integer,
  failed        integer,
  still_out     integer,
  fees          numeric,
  free_rides    integer,
  median_minutes integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select o.id, o.name,
         count(d.id)::integer,
         count(*) filter (where d.status = 'delivered')::integer,
         count(*) filter (where d.status = 'failed')::integer,
         count(*) filter (where d.status in ('pending', 'assigned', 'collected'))::integer,
         coalesce(sum(d.fee), 0),
         -- What the free-delivery promise cost in rides given away.
         count(*) filter (where d.fee = 0)::integer,
         ceil(percentile_cont(0.5) within group (
           order by case when d.status = 'delivered'
                    then extract(epoch from (d.delivered_at - d.created_at)) / 60.0
                    end))::integer
    from public.pos_outlets o
    -- Left, so an outlet that delivered nothing is a row of noughts
    -- rather than missing. Its absence would read as "no problem".
    left join public.pos_deliveries d
           on d.outlet_id = o.id
          and (d.created_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
   where o.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   group by o.id, o.name
   order by o.name;
$$;

grant execute on function public.pos_delivery_day(uuid, date) to authenticated;

comment on function public.pos_delivery_day(uuid, date) is
  'One day of delivering, per outlet: what went out, what came back, what the rides earned and how many were given away free.';

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_delivery_zones enable row level security;
alter table public.pos_drivers        enable row level security;
alter table public.pos_deliveries     enable row level security;

create policy pos_delivery_zones_read on public.pos_delivery_zones for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy pos_drivers_read on public.pos_drivers for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy pos_deliveries_read on public.pos_deliveries for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policies. The fee is derived, the state machine is the point
-- of the feature, and a client that could update these rows directly
-- could set its own delivery charge to nothing.
grant select on public.pos_delivery_zones to authenticated;
grant select on public.pos_drivers        to authenticated;
grant select on public.pos_deliveries     to authenticated;

-- ---------------------------------------------------------------------
-- Folding one bill into another, when one of them is going somewhere
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0255 for one block. The bill being absorbed is
-- deleted at the end of this function, and `pos_deliveries.sale_id`
-- cascades — so without this, merging a delivery into a dine-in bill
-- silently threw away the address and the fee, and the first anybody
-- knew was a driver with a bag and no idea where to take it.
create or replace function public.merge_pos_sales(
  p_into uuid,
  p_from uuid)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_into public.pos_sales;
  v_from public.pos_sales;
  v_no   integer;
  v_line record;
  v_n    integer := 0;
begin
  if p_into = p_from then
    raise exception 'A bill cannot be merged into itself.' using errcode = '23514';
  end if;

  select * into v_into from public.pos_sales where id = p_into;
  select * into v_from from public.pos_sales where id = p_from;
  if v_into.id is null or v_from.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_into.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_into.status <> 'parked' or v_from.status <> 'parked' then
    raise exception
      'Both bills have to still be open. One of these is already settled.'
      using errcode = '23514';
  end if;
  if v_into.outlet_id <> v_from.outlet_id then
    raise exception 'Those bills are in different outlets.' using errcode = '23514';
  end if;

  select coalesce(max(l.line_no), 0) into v_no
    from public.pos_sale_lines l where l.sale_id = p_into;

  for v_line in
    select l.id from public.pos_sale_lines l where l.sale_id = p_from order by l.line_no
  loop
    v_no := v_no + 1;
    v_n  := v_n + 1;
    update public.pos_sale_lines l set sale_id = p_into, line_no = v_no
     where l.id = v_line.id;
  end loop;

  -- A redemption on the bill being absorbed would otherwise vanish with
  -- it. Carried across only when the bill it is joining has none of its
  -- own, because two redemptions on one basket is a decision nobody has
  -- made -- the till should re-apply it and let somebody look.
  if coalesce(v_from.loyalty_points_redeemed, 0) > 0
     and coalesce(v_into.loyalty_points_redeemed, 0) = 0 then
    update public.pos_sales s
       set loyalty_account_id = v_from.loyalty_account_id,
           loyalty_points_redeemed = v_from.loyalty_points_redeemed,
           loyalty_discount = v_from.loyalty_discount
     where s.id = p_into;
  end if;

  -- Same rule for a discount, and for the same reason: the bill it was
  -- given on is about to stop existing, and two discounts on one basket
  -- is nobody's decision. Note the asymmetry with a split -- here a
  -- flat amount does travel, because the food it was given against is
  -- travelling with it and the alternative is losing it silently.
  if (coalesce(v_from.bill_discount, 0) > 0
      or coalesce(v_from.bill_discount_percent, 0) > 0)
     and coalesce(v_into.bill_discount, 0) = 0
     and coalesce(v_into.bill_discount_percent, 0) = 0 then
    update public.pos_sales s
       set bill_discount_percent = v_from.bill_discount_percent,
           bill_discount         = v_from.bill_discount,
           bill_discount_reason  = v_from.bill_discount_reason,
           bill_discounted_by    = v_from.bill_discounted_by,
           bill_discounted_at    = v_from.bill_discounted_at
     where s.id = p_into;
  end if;

  -- And the address, on the same reasoning and with one difference:
  -- two addresses on one bill is not a decision the till can make for
  -- anybody, and quietly keeping one of them would send food to the
  -- wrong house. So this one refuses rather than picks.
  if exists (select 1 from public.pos_deliveries d where d.sale_id = p_from) then
    if exists (select 1 from public.pos_deliveries d where d.sale_id = p_into) then
      raise exception
        'Both of those bills are going somewhere. Merging them would '
        'lose one of the addresses.'
        using errcode = '23514';
    end if;
    if exists (select 1 from public.pos_deliveries d
                where d.sale_id = p_from and d.status <> 'pending') then
      raise exception
        'That bill is already out with a driver. It cannot be folded '
        'into another one.'
        using errcode = '23514';
    end if;
    update public.pos_deliveries d set sale_id = p_into, updated_at = now()
     where d.sale_id = p_from;
  end if;

  -- Dockets follow the food. The kitchen was told by a bill that is
  -- about to stop existing, and a ticket pointing at nothing is a
  -- ticket nobody can trace back to a table.
  update public.pos_kitchen_tickets k set sale_id = p_into where k.sale_id = p_from;

  -- The emptied bill goes. It has no lines, no tenders and no
  -- documents; leaving it parked would put a phantom on the floor plan.
  delete from public.pos_sales where id = p_from;

  perform app.recalc_pos_sale(p_into);
  return v_n;
end;
$$;

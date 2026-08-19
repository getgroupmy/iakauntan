-- Salons, spas and studios: selling an hour of somebody's time.
--
-- ## The one thing a booking system must not do
--
-- Sell the same hour twice. Every other defect here is an
-- inconvenience; this one puts two customers in the chair and sends one
-- of them home.
--
-- The obvious implementation is to look for a clash and then insert if
-- there isn't one. That is wrong in the only case that matters: two
-- receptionists tapping at the same moment both look, both see a free
-- slot, and both insert. The window between the look and the insert is
-- small, and it is widest exactly when the salon is busiest.
--
-- So the refusal is an EXCLUSION CONSTRAINT: the database itself will
-- not hold two overlapping bookings for one provider. There is no
-- window, because there is no gap between the check and the write --
-- they are the same operation. `book_appointment` still looks first, but
-- only so the error is a sentence rather than a constraint name.
--
-- ## The turnaround is part of the booking
--
-- A haircut takes forty minutes and the chair needs ten to be swept.
-- The booking runs fifty. Storing the buffer separately and expecting
-- every reader to add it is how a diary ends up with a ten-minute
-- overlap that no constraint can see, because as far as the constraint
-- is concerned the bookings do not touch.
--
-- ## A booking is not a sale
--
-- Nothing is owed until somebody turns up. The booking becomes a sale
-- at check-in, on a real register, in a real shift -- and from that
-- moment it is an ordinary POS sale that posts an ordinary invoice.
-- Money that appeared in the books because somebody wrote a name in a
-- diary would be revenue for a service nobody has had.

create type app.pos_booking_status as enum (
  'booked',     -- in the diary
  'confirmed',  -- the customer said yes to the reminder
  'arrived',    -- checked in; a sale exists
  'completed',  -- done and paid
  'no_show',    -- did not turn up; the slot is free again
  'cancelled'   -- called off; the slot is free again
);

-- ---------------------------------------------------------------------
-- Who does the work
-- ---------------------------------------------------------------------
create table if not exists public.pos_service_providers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets (id) on delete cascade,
  code        text not null,
  name        text not null,

  -- Optional on purpose. A chair may be rented by somebody who is not
  -- on the payroll, and a studio's Saturday cover may not have a login.
  employee_id uuid references public.employees (id) on delete set null,
  user_id     uuid references auth.users (id) on delete set null,

  colour      text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (outlet_id, code)
);

create index if not exists pos_service_providers_outlet_idx
  on public.pos_service_providers (outlet_id) where is_active;

-- ---------------------------------------------------------------------
-- How long a thing takes
-- ---------------------------------------------------------------------
--
-- A separate table rather than columns on `items`, because a duration
-- is meaningless for the ninety per cent of this database's items that
-- are things on a shelf, and a nullable column on a shared table is an
-- invitation to read it as zero.
create table if not exists public.pos_services (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations (id) on delete cascade,
  item_id          uuid not null references public.items (id) on delete cascade,
  duration_minutes integer not null check (duration_minutes > 0),

  -- Sweeping the chair, changing the bed, wiping the machine. Part of
  -- what the slot costs the shop, so part of what the slot occupies.
  buffer_minutes   integer not null default 0 check (buffer_minutes >= 0),

  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  unique (item_id)
);

-- ---------------------------------------------------------------------
-- When they work, and when they do not
-- ---------------------------------------------------------------------
create table if not exists public.pos_provider_hours (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  provider_id uuid not null references public.pos_service_providers (id) on delete cascade,

  -- ISO: 1 is Monday, 7 is Sunday, matching `extract(isodow)`. Stated
  -- rather than assumed, because half the world starts the week on
  -- Sunday and the other half does not.
  weekday     integer not null check (weekday between 1 and 7),
  starts_at   time not null,
  ends_at     time not null,
  constraint pos_provider_hours_order_ck check (ends_at > starts_at),
  unique (provider_id, weekday, starts_at)
);

create table if not exists public.pos_provider_time_off (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  provider_id uuid not null references public.pos_service_providers (id) on delete cascade,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  reason      text,
  created_at  timestamptz not null default now(),
  constraint pos_provider_time_off_order_ck check (ends_at > starts_at)
);

create index if not exists pos_provider_time_off_idx
  on public.pos_provider_time_off (provider_id, starts_at, ends_at);

-- ---------------------------------------------------------------------
-- The diary
-- ---------------------------------------------------------------------
create table if not exists public.pos_bookings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets (id) on delete cascade,
  provider_id uuid not null references public.pos_service_providers (id) on delete restrict,
  contact_id  uuid references public.contacts (id) on delete set null,
  item_id     uuid references public.items (id) on delete set null,

  -- Snapshots, so a diary printed for tomorrow still reads correctly
  -- after the price list changes tonight.
  description text not null default '',
  price       numeric(18, 4) not null default 0,

  starts_at   timestamptz not null,
  -- Duration AND turnaround. See the header: a buffer nobody adds is a
  -- buffer no constraint can enforce.
  ends_at     timestamptz not null,

  status      app.pos_booking_status not null default 'booked',
  sale_id     uuid references public.pos_sales (id) on delete set null,

  note        text,
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint pos_bookings_order_ck check (ends_at > starts_at)
);

create index if not exists pos_bookings_provider_idx
  on public.pos_bookings (provider_id, starts_at);
create index if not exists pos_bookings_outlet_day_idx
  on public.pos_bookings (outlet_id, starts_at);
create index if not exists pos_bookings_contact_idx
  on public.pos_bookings (contact_id, starts_at desc);

-- The refusal that has no race in it.
--
-- `btree_gist` is what lets a plain equality on `provider_id` sit in the
-- same exclusion constraint as an overlap on the time range; without it
-- GiST has no operator class for uuid equality.
--
-- Cancelled and no-show bookings are outside the constraint, because
-- the slot really is free again -- and a diary that would not re-let a
-- cancelled slot is a diary that loses the shop money every time
-- somebody rings to say they cannot make it.
create extension if not exists btree_gist;

alter table public.pos_bookings
  drop constraint if exists pos_bookings_no_double_booking;
alter table public.pos_bookings
  add constraint pos_bookings_no_double_booking
  exclude using gist (
    provider_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status not in ('cancelled', 'no_show'));

comment on constraint pos_bookings_no_double_booking on public.pos_bookings is
  'One provider, one customer at a time. An exclusion constraint rather than a check-then-insert, because two receptionists tapping at once both pass a check.';

-- ---------------------------------------------------------------------
-- Is that provider free
-- ---------------------------------------------------------------------
create or replace function app.pos_provider_is_open(
  p_provider uuid,
  p_from     timestamptz,
  p_to       timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select
    -- Inside a working block on that weekday. Compared in the company's
    -- own time, because a salon's Tuesday morning is Tuesday morning
    -- wherever the server happens to be.
    exists (
      select 1 from public.pos_provider_hours h
       where h.provider_id = p_provider
         and h.weekday = extract(isodow from (p_from at time zone 'Asia/Kuala_Lumpur'))::integer
         and h.starts_at <= (p_from at time zone 'Asia/Kuala_Lumpur')::time
         and h.ends_at   >= (p_to   at time zone 'Asia/Kuala_Lumpur')::time)
    and not exists (
      select 1 from public.pos_provider_time_off t
       where t.provider_id = p_provider
         and tstzrange(t.starts_at, t.ends_at, '[)')
             && tstzrange(p_from, p_to, '[)'));
$$;

revoke all on function app.pos_provider_is_open(uuid, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Writing a name in the diary
-- ---------------------------------------------------------------------
create or replace function public.book_appointment(
  p_provider  uuid,
  p_item      uuid,
  p_starts_at timestamptz,
  p_contact   uuid default null,
  p_note      text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_prov  public.pos_service_providers;
  v_svc   public.pos_services;
  v_item  record;
  v_ends  timestamptz;
  v_id    uuid;
  v_clash text;
begin
  select * into v_prov from public.pos_service_providers where id = p_provider;
  if v_prov.id is null then
    raise exception 'No such provider.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_prov.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if not v_prov.is_active then
    raise exception '% is not taking bookings.', v_prov.name using errcode = '23514';
  end if;

  select * into v_svc from public.pos_services s
   where s.item_id = p_item and s.org_id = v_prov.org_id and s.is_active;
  if v_svc.id is null then
    raise exception
      'That is not a bookable service. Give it a duration first.'
      using errcode = 'P0002';
  end if;
  select i.name, i.unit_price into v_item from public.items i where i.id = p_item;

  v_ends := p_starts_at
          + make_interval(mins => v_svc.duration_minutes + v_svc.buffer_minutes);

  if not app.pos_provider_is_open(p_provider, p_starts_at, v_ends) then
    raise exception
      '% does not work then, or is away.', v_prov.name using errcode = '23514';
  end if;

  -- Looked at first only so the message is a sentence. The constraint
  -- below is what actually decides, and it is the one with no window
  -- in it.
  select to_char(b.starts_at at time zone 'Asia/Kuala_Lumpur', 'HH24:MI')
    into v_clash
    from public.pos_bookings b
   where b.provider_id = p_provider
     and b.status not in ('cancelled', 'no_show')
     and tstzrange(b.starts_at, b.ends_at, '[)')
         && tstzrange(p_starts_at, v_ends, '[)')
   limit 1;
  if v_clash is not null then
    raise exception '% already has somebody at %.', v_prov.name, v_clash
      using errcode = '23505';
  end if;

  insert into public.pos_bookings (
    org_id, outlet_id, provider_id, contact_id, item_id,
    description, price, starts_at, ends_at, note, created_by)
  values (
    v_prov.org_id, v_prov.outlet_id, p_provider, p_contact, p_item,
    coalesce(v_item.name, 'Service'), coalesce(v_item.unit_price, 0),
    p_starts_at, v_ends, p_note, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.book_appointment(uuid, uuid, timestamptz, uuid, text)
  from public, anon;
grant execute on function public.book_appointment(uuid, uuid, timestamptz, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Moving and cancelling
-- ---------------------------------------------------------------------
create or replace function public.set_booking_status(
  p_booking uuid,
  p_status  app.pos_booking_status,
  p_note    text default null)
returns app.pos_booking_status
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b public.pos_bookings;
begin
  select * into v_b from public.pos_bookings where id = p_booking;
  if v_b.id is null then
    raise exception 'No such booking.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_b.status = 'completed' then
    raise exception
      'That appointment is done and paid for. Refund the sale instead.'
      using errcode = '23514';
  end if;
  -- 'arrived' and 'completed' are set by checking in and by settling the
  -- sale, not by hand: they are claims about money and stock that the
  -- functions below are the only things entitled to make.
  if p_status in ('arrived', 'completed') then
    raise exception
      'Check the customer in to mark them arrived.' using errcode = '23514';
  end if;

  update public.pos_bookings b
     set status = p_status,
         note = coalesce(p_note, b.note)
   where b.id = p_booking;
  return p_status;
end;
$$;

revoke all on function public.set_booking_status(uuid, app.pos_booking_status, text)
  from public, anon;
grant execute on function public.set_booking_status(uuid, app.pos_booking_status, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- The customer arrives
-- ---------------------------------------------------------------------
--
-- This is where a diary entry becomes money. It opens an ordinary sale
-- on an ordinary register in an open shift, puts the service on it, and
-- from that point nothing about this module is special -- the sale
-- completes, posts an invoice and a receipt, and takes its tenders like
-- any other.
create or replace function public.check_in_booking(
  p_booking  uuid,
  p_register uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b    public.pos_bookings;
  v_out  uuid;
  v_sale uuid;
begin
  select * into v_b from public.pos_bookings where id = p_booking;
  if v_b.id is null then
    raise exception 'No such booking.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_b.status in ('cancelled', 'no_show') then
    raise exception 'That appointment was %.', v_b.status using errcode = '23514';
  end if;

  -- Checked in twice is checked in once. A receptionist who taps again
  -- because the screen was slow should reach the same sale, not open a
  -- second one against the same appointment.
  if v_b.sale_id is not null then
    return v_b.sale_id;
  end if;

  select r.outlet_id into v_out from public.pos_registers r where r.id = p_register;
  if v_out is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if v_out <> v_b.outlet_id then
    raise exception 'That appointment is at another outlet.' using errcode = '23514';
  end if;

  v_sale := public.open_pos_sale(p_register, v_b.contact_id);
  if v_b.item_id is not null then
    perform public.add_pos_sale_line(v_sale, v_b.item_id, 1, v_b.price);
  end if;

  update public.pos_bookings b
     set status = 'arrived', sale_id = v_sale where b.id = p_booking;

  return v_sale;
end;
$$;

revoke all on function public.check_in_booking(uuid, uuid) from public, anon;
grant execute on function public.check_in_booking(uuid, uuid) to authenticated;

-- A settled sale closes the appointment behind it. Derived from the
-- sale rather than set by a second call, so the diary cannot disagree
-- with the till about whether somebody was seen.
create or replace function app.pos_booking_follows_sale()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    update public.pos_bookings b
       set status = 'completed' where b.sale_id = new.id and b.status = 'arrived';
  end if;
  return new;
end;
$$;

drop trigger if exists pos_booking_follows_sale on public.pos_sales;
create trigger pos_booking_follows_sale
  after update of status on public.pos_sales
  for each row execute function app.pos_booking_follows_sale();

-- ---------------------------------------------------------------------
-- The day, as a screen has to draw it
-- ---------------------------------------------------------------------
create or replace function public.pos_day_sheet(
  p_outlet uuid,
  p_date   date default current_date)
returns table (
  provider_id   uuid,
  provider      text,
  booking_id    uuid,
  starts_at     timestamptz,
  ends_at       timestamptz,
  minutes       integer,
  status        app.pos_booking_status,
  customer      text,
  description   text,
  price         numeric,
  sale_id       uuid)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select p.id, p.name, b.id, b.starts_at, b.ends_at,
         (extract(epoch from (b.ends_at - b.starts_at)) / 60)::integer,
         b.status, coalesce(c.name, 'Walk-in'), b.description, b.price, b.sale_id
    from public.pos_service_providers p
    left join public.pos_bookings b
      on b.provider_id = p.id
     and (b.starts_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
    left join public.contacts c on c.id = b.contact_id
   where p.outlet_id = p_outlet
     and p.is_active
     and app.can_read_module(p.org_id, 'pos')
   order by p.name, b.starts_at;
$$;

grant execute on function public.pos_day_sheet(uuid, date) to authenticated;

comment on function public.pos_day_sheet(uuid, date) is
  'One row per provider per booking for a day, and one row with nulls for a provider with an empty diary.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_service_providers enable row level security;
alter table public.pos_services          enable row level security;
alter table public.pos_provider_hours    enable row level security;
alter table public.pos_provider_time_off enable row level security;
alter table public.pos_bookings          enable row level security;

create policy pos_service_providers_read on public.pos_service_providers for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_service_providers_write on public.pos_service_providers for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_services_read on public.pos_services for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_services_write on public.pos_services for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_provider_hours_read on public.pos_provider_hours for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_provider_hours_write on public.pos_provider_hours for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_provider_time_off_read on public.pos_provider_time_off for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_provider_time_off_write on public.pos_provider_time_off for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Read only. A booking is written by the function that holds the
-- exclusion constraint's refusal in its hand; a client that could
-- insert one directly could still not double-book -- the constraint
-- sees to that -- but it could book outside working hours and around
-- the price snapshot, which is most of what the function is for.
create policy pos_bookings_read on public.pos_bookings for select
  using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_service_providers to authenticated;
grant select, insert, update, delete on public.pos_services to authenticated;
grant select, insert, update, delete on public.pos_provider_hours to authenticated;
grant select, insert, update, delete on public.pos_provider_time_off to authenticated;
grant select on public.pos_bookings to authenticated;

create trigger set_updated_at before update on public.pos_service_providers
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_bookings
  for each row execute function app.set_updated_at();

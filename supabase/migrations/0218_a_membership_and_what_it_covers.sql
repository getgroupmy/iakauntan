-- Memberships: paying once a month for things you take one at a time.
--
-- ## Two halves that must not be confused
--
-- A membership is a subscription (money arrives every month) AND an
-- entitlement (ten classes, four blow-dries, unlimited gym). Systems
-- that model only the first bill correctly and let the second drift
-- are how a customer gets charged for a class their membership covers,
-- or takes a twelfth class on a package of ten.
--
-- ## The billing is not reinvented
--
-- 0097 already raises invoices on a schedule, with a template snapshot,
-- a next-run date, auto-posting and auto-emailing, and a daily job that
-- drives it. A membership renewal is exactly that. So a subscription
-- points at a `recurring_documents` row rather than carrying its own
-- copy of a scheduler -- because a second scheduler is a second set of
-- bugs, and the one that is wrong is whichever nobody watches.
--
-- The link is made from the FIRST invoice, which is the one the
-- customer just paid at the counter. That is also the natural template:
-- it already has the right price, the right tax code and the right
-- payment terms on it.
--
-- Raising a recurring schedule needs `app.can_post`, and a cashier is
-- often not that. Rather than refuse the whole membership -- leaving
-- somebody who has paid with nothing -- the subscription is created
-- either way and the missing schedule is REPORTED, by
-- `membership_billing_gaps`. A gap somebody can see gets fixed; a
-- refusal at the counter gets worked around.
--
-- ## Sessions are a ledger, not a counter
--
-- `sessions_used` on the subscription would be a column that drifts the
-- first time a sale is voided or a line removed. Each use is a row
-- pointing at the sale line it covered, and the row goes when the line
-- goes -- so taking a class off a bill gives the session back without
-- anybody remembering to.

create type app.pos_membership_status as enum (
  'active', 'paused', 'cancelled', 'expired');

-- ---------------------------------------------------------------------
-- What is on offer
-- ---------------------------------------------------------------------
create table if not exists public.pos_memberships (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  code        text not null,
  name        text not null,

  -- What gets invoiced every period. An ordinary item, so the ledger,
  -- the tax code and the e-Invoice line all work without knowing this
  -- module exists.
  item_id     uuid not null references public.items (id) on delete restrict,

  period      text not null default 'monthly'
              check (period in ('weekly', 'monthly', 'quarterly', 'yearly')),

  -- Null means unlimited. Zero would mean a membership that entitles
  -- you to nothing, which is a different and probably mistaken thing,
  -- so it is not allowed.
  sessions_included integer check (sessions_included is null or sessions_included > 0),

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

-- Which services a membership covers. Empty means all of them, which is
-- what "unlimited gym" actually is.
create table if not exists public.membership_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  membership_id uuid not null references public.pos_memberships (id) on delete cascade,
  item_id       uuid not null references public.items (id) on delete cascade,
  unique (membership_id, item_id)
);

-- ---------------------------------------------------------------------
-- Somebody on it
-- ---------------------------------------------------------------------
create table if not exists public.pos_membership_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  membership_id uuid not null references public.pos_memberships (id) on delete restrict,
  contact_id    uuid not null references public.contacts (id) on delete cascade,

  started_on    date not null default current_date,
  ends_on       date,
  status        app.pos_membership_status not null default 'active',

  -- The schedule that bills it. Null is a real state, not an oversight:
  -- see the header. `membership_billing_gaps` is how it stops being one.
  recurring_document_id uuid references public.recurring_documents (id) on delete set null,

  -- The sale that started it, kept so the first period can be dated
  -- from what was actually paid rather than from when somebody typed.
  origin_sale_id uuid references public.pos_sales (id) on delete set null,

  note          text,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists pos_membership_subscriptions_contact_idx
  on public.pos_membership_subscriptions (contact_id) where status = 'active';

-- One live subscription per person per membership. Somebody who wants
-- two of the same package is buying sessions, not a second membership.
create unique index if not exists pos_membership_subscriptions_one_live
  on public.pos_membership_subscriptions (membership_id, contact_id)
  where status in ('active', 'paused');

-- The ledger. One row per session taken, pointing at the line it
-- covered, and gone when that line is.
create table if not exists public.pos_membership_sessions (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  subscription_id uuid not null references public.pos_membership_subscriptions (id) on delete cascade,
  sale_id         uuid references public.pos_sales (id) on delete set null,
  line_id         uuid not null references public.pos_sale_lines (id) on delete cascade,
  used_on         date not null default current_date,
  created_at      timestamptz not null default now(),
  -- A line is covered once. Twice would be one class paying for two.
  unique (line_id)
);

create index if not exists pos_membership_sessions_sub_idx
  on public.pos_membership_sessions (subscription_id, used_on);

-- ---------------------------------------------------------------------
-- Which period a date falls in
-- ---------------------------------------------------------------------
--
-- Counted from the day the membership started, not from the first of
-- the month. Somebody who joins on the 20th gets their ten classes
-- between the 20th and the 19th, which is what they were sold.
create or replace function app.membership_period(
  p_subscription uuid,
  p_on           date default current_date)
returns table (period_start date, period_end date)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_start date;
  v_period text;
  v_step  interval;
  v_from  date;
begin
  select s.started_on, m.period into v_start, v_period
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
   where s.id = p_subscription;
  if v_start is null then
    return;
  end if;

  v_step := case v_period
              when 'weekly'    then interval '7 days'
              when 'monthly'   then interval '1 month'
              when 'quarterly' then interval '3 months'
              else                  interval '1 year'
            end;

  -- Walked rather than computed, because months are not a fixed length
  -- and "add n months to the start" is the only arithmetic that keeps
  -- the 31st landing on the 30th in the way `date + interval` already
  -- decides. A membership has tens of periods, not millions.
  v_from := v_start;
  while v_from + v_step <= p_on loop
    v_from := (v_from + v_step)::date;
  end loop;

  period_start := v_from;
  period_end   := (v_from + v_step - interval '1 day')::date;
  return next;
end;
$$;

revoke all on function app.membership_period(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What is left this period
-- ---------------------------------------------------------------------
create or replace function public.membership_balance(p_subscription uuid)
returns table (
  membership   text,
  status       app.pos_membership_status,
  period_start date,
  period_end   date,
  included     integer,
  used         integer,
  remaining    integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select m.name, s.status, p.period_start, p.period_end,
         m.sessions_included,
         (select count(*)::integer from public.pos_membership_sessions x
           where x.subscription_id = s.id
             and x.used_on between p.period_start and p.period_end),
         case when m.sessions_included is null then null
              else greatest(m.sessions_included
                   - (select count(*)::integer from public.pos_membership_sessions x
                       where x.subscription_id = s.id
                         and x.used_on between p.period_start and p.period_end), 0)
         end
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
    cross join lateral app.membership_period(s.id, current_date) p
   where s.id = p_subscription
     and app.can_read_module(s.org_id, 'pos');
$$;

grant execute on function public.membership_balance(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Starting one, from the sale that paid for it
-- ---------------------------------------------------------------------
--
-- Called after the sale completes, like `request_einvoice_for_sale` is:
-- a membership that existed before the money did would be an
-- entitlement nobody paid for.
--
-- The recurring schedule is attempted, not required. See the header:
-- refusing the whole thing because a cashier cannot post would leave
-- somebody who has paid with nothing at all.
create or replace function public.start_membership(
  p_sale       uuid,
  p_membership uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_mem  public.pos_memberships;
  v_sub  uuid;
  v_rec  uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'completed' then
    raise exception
      'Take the money first. A membership that starts before the sale '
      'completes is an entitlement nobody paid for.'
      using errcode = '23514';
  end if;
  if v_sale.contact_id is null then
    raise exception 'A membership needs a member. Say who the customer is.'
      using errcode = '23502';
  end if;

  select * into v_mem from public.pos_memberships
   where id = p_membership and org_id = v_sale.org_id and is_active;
  if v_mem.id is null then
    raise exception 'That membership is not on offer.' using errcode = 'P0002';
  end if;

  -- The membership has to have been bought on this sale. Otherwise
  -- "start a membership" is a button that gives one away.
  if not exists (select 1 from public.pos_sale_lines l
                  where l.sale_id = p_sale and l.item_id = v_mem.item_id) then
    raise exception
      'This sale does not include %. Ring it up first.', v_mem.name
      using errcode = '23514';
  end if;

  insert into public.pos_membership_subscriptions
    (org_id, membership_id, contact_id, started_on, origin_sale_id, created_by)
  values (v_sale.org_id, p_membership, v_sale.contact_id,
          coalesce(v_sale.completed_at::date, current_date), p_sale, auth.uid())
  returning id into v_sub;

  -- The renewal schedule, from the invoice the customer just paid --
  -- which already carries the right price, tax code and terms.
  if v_sale.invoice_id is not null and app.can_post(v_sale.org_id) then
    begin
      v_rec := public.create_recurring_document(
        v_sale.invoice_id,
        v_mem.name || ' — ' || to_char(current_date, 'YYYY'),
        v_mem.period,
        (select (p.period_end + 1)::date from app.membership_period(v_sub, current_date) p),
        1, null, null, false, false);
      update public.pos_membership_subscriptions s
         set recurring_document_id = v_rec where s.id = v_sub;
    exception when others then
      -- Reported rather than fatal. The member has paid; the schedule
      -- is a thing somebody with the right role can add afterwards, and
      -- `membership_billing_gaps` is how they find out they need to.
      null;
    end;
  end if;

  return v_sub;
end;
$$;

revoke all on function public.start_membership(uuid, uuid) from public, anon;
grant execute on function public.start_membership(uuid, uuid) to authenticated;

-- The memberships nobody is billing. A list, because a silent gap in
-- recurring revenue is the kind of thing a shop discovers in March.
create or replace function public.membership_billing_gaps(p_org uuid)
returns table (
  subscription_id uuid,
  member          text,
  membership      text,
  started_on      date,
  next_period_starts date)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id, c.name, m.name, s.started_on, (p.period_end + 1)::date
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
    join public.contacts c on c.id = s.contact_id
    cross join lateral app.membership_period(s.id, current_date) p
   where s.org_id = p_org
     and s.status = 'active'
     and s.recurring_document_id is null
     and app.can_read_module(p_org, 'pos')
   order by s.started_on;
$$;

grant execute on function public.membership_billing_gaps(uuid) to authenticated;

comment on function public.membership_billing_gaps(uuid) is
  'Active memberships with no renewal schedule behind them. A gap somebody can see gets fixed; a refusal at the counter gets worked around.';

-- ---------------------------------------------------------------------
-- Taking a class on the membership
-- ---------------------------------------------------------------------
--
-- The line stays on the bill and goes to zero, rather than being taken
-- off it. What the member had is part of what happened, and a receipt
-- that shows "Yoga 45.00 — Membership -45.00" is a receipt they can
-- check; one that shows nothing is a receipt that looks like they were
-- never there.
create or replace function public.cover_line_with_membership(
  p_line         uuid,
  p_subscription uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_stat app.pos_sale_status;
  v_sub  public.pos_membership_subscriptions;
  v_mem  public.pos_memberships;
  v_left integer;
  v_cov  numeric;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  select s.status into v_stat from public.pos_sales s where s.id = v_line.sale_id;
  if v_stat <> 'parked' then
    raise exception 'That bill is % and cannot be changed.', v_stat
      using errcode = '23514';
  end if;

  select * into v_sub from public.pos_membership_subscriptions where id = p_subscription;
  if v_sub.id is null or v_sub.org_id <> v_line.org_id then
    raise exception 'No such membership.' using errcode = 'P0002';
  end if;
  if v_sub.status <> 'active' then
    raise exception 'That membership is %.', v_sub.status using errcode = '23514';
  end if;

  select * into v_mem from public.pos_memberships where id = v_sub.membership_id;

  -- An empty list means everything, which is what unlimited is.
  if exists (select 1 from public.membership_items mi
              where mi.membership_id = v_mem.id)
     and not exists (select 1 from public.membership_items mi
                      where mi.membership_id = v_mem.id and mi.item_id = v_line.item_id) then
    raise exception '% does not cover %.', v_mem.name, v_line.description
      using errcode = '23514';
  end if;

  if v_mem.sessions_included is not null then
    select b.remaining into v_left from public.membership_balance(p_subscription) b;
    if coalesce(v_left, 0) < 1 then
      raise exception
        'That membership has no sessions left this period.'
        using errcode = '23514';
    end if;
  end if;

  -- The whole line, discounted away. Computed from the line rather than
  -- passed in, because a caller that could name the amount could cover
  -- a fifty-ringgit treatment with a ten-ringgit membership.
  v_cov := round(v_line.unit_price * v_line.quantity, 2);

  update public.pos_sale_lines l set discount_amount = v_cov where l.id = p_line;
  perform app.reprice_pos_line(p_line);

  insert into public.pos_membership_sessions
    (org_id, subscription_id, sale_id, line_id, used_on)
  values (v_line.org_id, p_subscription, v_line.sale_id, p_line, current_date);

  return v_cov;
end;
$$;

revoke all on function public.cover_line_with_membership(uuid, uuid) from public, anon;
grant execute on function public.cover_line_with_membership(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Pausing, cancelling
-- ---------------------------------------------------------------------
create or replace function public.set_membership_status(
  p_subscription uuid,
  p_status       app.pos_membership_status)
returns app.pos_membership_status
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sub public.pos_membership_subscriptions;
begin
  select * into v_sub from public.pos_membership_subscriptions where id = p_subscription;
  if v_sub.id is null then
    raise exception 'No such membership.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sub.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  update public.pos_membership_subscriptions s
     set status = p_status,
         ends_on = case when p_status in ('cancelled', 'expired')
                        then coalesce(s.ends_on, current_date) else s.ends_on end
   where s.id = p_subscription;

  -- The billing stops with the membership. A cancelled member who keeps
  -- receiving invoices is the complaint that reaches the regulator.
  if p_status in ('cancelled', 'expired') and v_sub.recurring_document_id is not null then
    update public.recurring_documents r
       set is_active = false where r.id = v_sub.recurring_document_id;
  end if;

  return p_status;
end;
$$;

revoke all on function public.set_membership_status(uuid, app.pos_membership_status)
  from public, anon;
grant execute on function public.set_membership_status(uuid, app.pos_membership_status)
  to authenticated;

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_memberships                enable row level security;
alter table public.membership_items               enable row level security;
alter table public.pos_membership_subscriptions   enable row level security;
alter table public.pos_membership_sessions        enable row level security;

create policy pos_memberships_read on public.pos_memberships for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_memberships_write on public.pos_memberships for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy membership_items_read on public.membership_items for select
  using (app.can_read_module(org_id, 'pos'));
create policy membership_items_write on public.membership_items for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Read only, both of them. A subscription is a claim that somebody paid
-- and a session is a claim that they used what they paid for; the
-- functions above are the only things entitled to make either.
create policy pos_membership_subscriptions_read on public.pos_membership_subscriptions
  for select using (app.can_read_module(org_id, 'pos'));
create policy pos_membership_sessions_read on public.pos_membership_sessions
  for select using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_memberships to authenticated;
grant select, insert, update, delete on public.membership_items to authenticated;
grant select on public.pos_membership_subscriptions to authenticated;
grant select on public.pos_membership_sessions to authenticated;

create trigger set_updated_at before update on public.pos_memberships
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_membership_subscriptions
  for each row execute function app.set_updated_at();

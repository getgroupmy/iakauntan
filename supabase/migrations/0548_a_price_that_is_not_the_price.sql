-- ---------------------------------------------------------------------
-- 0548  A price that is not the price
-- ---------------------------------------------------------------------
-- `platform_modules.monthly_price` is the only number this product has
-- ever charged for an add-on. 0489 bills it, pro-rated by the days a
-- company held the module, and there is no way to say anything else:
-- no free month to get somebody started, no launch discount, no "this
-- one is on us" for a customer who is owed one. The console can change
-- the price, but the price is the same for everybody the moment it
-- changes -- so a thirty-day trial today means every existing customer
-- stops being billed too.
--
-- ### What a promotion is
--
-- A row in `module_promotions` says: for this module (or every add-on),
-- for this company (or every company), between these dates, the price
-- is not the list price. Four shapes, which is what an operator
-- actually asks for:
--
--   * **`trial`** -- free for the first N days after the company
--     switches it on, provided they switched it on while the promotion
--     was open. The trial is anchored to *their* start day, not to the
--     promotion's, so two companies joining a week apart each get their
--     full thirty days.
--   * **`free`** -- unlimited use. Every day inside the window costs
--     nothing. With no `ends_on` that is "free, indefinitely", which is
--     how a module is given away while it is still being finished, and
--     how one customer is thanked.
--   * **`percent_off`** -- the list price less a percentage.
--   * **`fixed_price`** -- a different monthly price outright.
--
-- ### Which one applies
--
-- The cheapest one the company qualifies for that day, and never more
-- than the list price. Two rules the alternative fails: an operator
-- running a launch promotion and separately granting one customer a
-- free year should not have to reason about which row wins, and a
-- `fixed_price` typed above the list price must not become a way to
-- charge somebody extra -- a promotion that raises a bill is not a
-- promotion, it is a pricing mistake with a friendly name on it.
--
-- Ties -- two promotions at the same price -- go to the older row, so
-- the answer does not move when a second one is added.
--
-- ### Where it lands
--
-- Per day, not per month. `app.module_days_in_month` already walks a
-- month and pro-rates by the days a module was held; this makes it walk
-- the days themselves and ask what each one cost. A promotion that
-- starts on the 15th therefore splits the month at the 15th without
-- anything having to special-case a month boundary, and a trial that
-- ends mid-month does the same. It is more work per invoice -- thirty
-- lookups instead of one -- for at most a few dozen add-ons a company,
-- once a month, which is not a number worth optimising against
-- correctness.
--
-- The invoice line names the promotion, because a bill that is lower
-- than the price list and does not say why is a support ticket.
--
-- ### What it does not do
--
-- No coupon codes -- nobody types anything; the operator decides who
-- qualifies. No stacking: promotions do not compose, the cheapest one
-- wins outright. No refunds of a month already invoiced; a promotion
-- created today does not rewrite yesterday's bill, and
-- `bill_org_modules` is still idempotent per month, so an invoice
-- already written stays written.
--
-- ### Mutants
--
-- Run against `supabase/tests/module_promotions.sql`, each named with
-- the assertion that kills it:
--   * the trial anchored to the promotion's start rather than the
--     company's -- "a company joining later still gets its own thirty
--     days";
--   * the trial's last day charged -- "the thirtieth day is still
--     free"; the day after it free -- "and the thirty-first is not";
--   * the sign-up window ignored -- "a company that switched it on
--     before the promotion opened pays list";
--   * `ends_on` exclusive -- "a promotion is on for the whole of its
--     last day";
--   * an inactive promotion applied -- "a promotion switched off is
--     not applied";
--   * another company's promotion applied -- "one company's promotion
--     is not another's";
--   * the dearest promotion chosen -- "the cheapest promotion the
--     company qualifies for is the one applied";
--   * a fixed price above list charged -- "a promotion never charges
--     more than the price list";
--   * the whole month priced at one day's rate -- "a promotion
--     starting on the 15th splits the month at the 15th";
--   * a promotion on a core module billing something -- "the product
--     itself is still not on the bill";
--   * the promotion name left off the invoice -- "the invoice line
--     names the promotion";
--   * a tenant admin allowed to write one -- "a company cannot give
--     itself a promotion".
-- ---------------------------------------------------------------------

create table if not exists public.module_promotions (
  id uuid primary key default gen_random_uuid(),

  -- What the customer is told it is. On the invoice line, so it is
  -- written for them rather than for the console.
  name text not null,

  -- Null is "every add-on", which is the launch promotion an operator
  -- means when they say "first month free".
  module_code text references public.platform_modules (code)
    on delete cascade,

  -- Null is "every company". Set, it is the one customer this was
  -- agreed with.
  org_id uuid references public.organizations (id) on delete cascade,

  kind text not null
    check (kind in ('trial', 'free', 'percent_off', 'fixed_price')),

  trial_days  integer,
  percent_off numeric(6, 3),
  fixed_price numeric(18, 2),

  starts_on date not null default app.today(),
  -- Null is open-ended: a module given away until somebody decides
  -- otherwise.
  ends_on   date,

  is_active boolean not null default true,
  notes     text,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),

  -- Each shape needs its own number and only its own. A `trial` row
  -- with a null `trial_days` is a promotion that silently does nothing,
  -- which is the worst of the three outcomes available here.
  constraint module_promotions_shape check (
    case kind
      when 'trial'       then trial_days is not null and trial_days > 0
      when 'percent_off' then percent_off is not null
                          and percent_off > 0 and percent_off <= 100
      when 'fixed_price' then fixed_price is not null and fixed_price >= 0
      else true
    end),
  constraint module_promotions_window check (ends_on is null or ends_on >= starts_on)
);

comment on table public.module_promotions is
  'A price that is not the list price: a trial, a giveaway, a discount '
  'or a fixed price, for one module or all of them, for one company or '
  'all of them. See 0548.';

create index if not exists module_promotions_lookup
  on public.module_promotions (module_code, org_id)
  where is_active;

alter table public.module_promotions enable row level security;

-- A company may read the promotions that could apply to it -- the ones
-- addressed to everybody, and its own. It is an offer; withholding it
-- would mean the settings screen could not say why the price on it is
-- lower than the price list. It may not read what another company was
-- given, which is a commercial fact about somebody else.
--
-- Deliberately not `is_active and ...`. That is the shape 0302 rejected
-- for `payment_gateways`, and for the same reason: realtime evaluates
-- the policy against the NEW row, so a promotion being switched off is
-- the one change that would not be delivered -- and it is the change
-- that matters most, because until it arrives the screen still offers
-- a price nobody is charging any more. An ended promotion is not a
-- secret; a promotion for another company is.
create policy module_promotions_read on public.module_promotions
  for select to authenticated
  using (org_id is null or app.is_org_member(org_id));

create policy module_promotions_platform on public.module_promotions
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

-- The privilege the read policy needs to run at all (0125). Select
-- only: every write goes through the console's SECURITY DEFINER
-- functions below, so nothing needs the table privilege to write, and
-- a promotion is not something a client should be able to POST.
grant select on table public.module_promotions to authenticated;

-- On the platform's own live channel (0302), so a promotion opened or
-- ended in the console reaches the settings screen of every company
-- that could take it up, without a reload. `live_changes` (below)
-- cannot do this one: a promotion addressed to everybody carries no
-- org_id, so it appends nothing there and would reach nobody.
do $do$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'module_promotions'
  ) then
    alter publication supabase_realtime add table public.module_promotions;
  end if;
end $do$;

-- The feed, on the same terms as every other org-scoped table (0547).
-- A promotion addressed to one company moves that company's screens;
-- `app.note_live_change` skips null org_ids, so a promotion addressed
-- to everybody appends nothing and reaches screens on their next load.
drop trigger if exists live_change_insert on public.module_promotions;
create trigger live_change_insert after insert on public.module_promotions
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
drop trigger if exists live_change_update on public.module_promotions;
create trigger live_change_update after update on public.module_promotions
  referencing new table as new_rows old table as old_rows
  for each statement execute function app.note_live_change();
drop trigger if exists live_change_delete on public.module_promotions;
create trigger live_change_delete after delete on public.module_promotions
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- What a module costs a company on one day
-- ---------------------------------------------------------------------
-- `p_started` is the day this company switched the module on, which is
-- what a trial counts from. Passed in rather than read here, because
-- the caller that bills already knows it and the caller that draws the
-- offer for a module nobody holds yet has to say "if they started
-- today".
create or replace function app.module_price_on(
  p_org_id uuid, p_code text, p_day date, p_started date)
returns table (price numeric, promotion text, kind text,
               trial_days integer, ends_on date)
language sql stable
set search_path = public, app, pg_temp as $$
  with list as (
    select m.monthly_price as price
      from public.platform_modules m
     where m.code = p_code
  ),
  applicable as (
    select p.name,
           p.kind,
           p.trial_days,
           p.ends_on,
           case p.kind
             when 'free'        then 0::numeric
             when 'trial'       then 0::numeric
             when 'percent_off' then round(l.price * (100 - p.percent_off) / 100, 2)
             else round(p.fixed_price, 2)
           end as price,
           p.created_at,
           p.id
      from public.module_promotions p
     cross join list l
     where p.is_active
       and (p.module_code is null or p.module_code = p_code)
       and (p.org_id is null or p.org_id = p_org_id)
       and case
             -- A trial is offered to companies that start while the
             -- offer is open, and then runs from their own start day.
             -- Both halves matter: the window alone would end somebody's
             -- trial early because the promotion closed, and the days
             -- alone would hand a trial to a customer who signed up two
             -- years before it was dreamt up.
             when p.kind = 'trial'
               then p_started >= p.starts_on
                and p_started <= coalesce(p.ends_on, p_started)
                and p_day < p_started + p.trial_days
             else p_day >= p.starts_on
              and p_day <= coalesce(p.ends_on, p_day)
           end
  )
  select least(l.price, coalesce(a.price, l.price)),
         case when a.price < l.price then a.name end,
         case when a.price < l.price then a.kind end,
         case when a.price < l.price then a.trial_days end,
         case when a.price < l.price then a.ends_on end
    from list l
    left join lateral (
      select * from applicable order by price, created_at, id limit 1
    ) a on true;
$$;

comment on function app.module_price_on(uuid, text, date, date) is
  'What one add-on costs one company on one day: the list price, or '
  'the cheapest promotion it qualifies for, whichever is lower. See 0548.';

revoke all on function app.module_price_on(uuid, text, date, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The month, day by day
-- ---------------------------------------------------------------------
-- Dropped and rebuilt rather than replaced: the row it returns gains
-- the list amount and the promotion's name, and `create or replace`
-- cannot change an OUT list.
drop function if exists app.module_days_in_month(uuid, date);

create or replace function app.module_days_in_month(
  p_org_id uuid, p_month date)
returns table (module_code text, name text, monthly_price numeric,
               days integer, days_in_month integer, amount numeric,
               list_amount numeric, promotion text)
language sql stable
set search_path = public, app, pg_temp as $$
  with bounds as (
    select date_trunc('month', p_month)::date as first_day,
           (date_trunc('month', p_month) + interval '1 month'
              - interval '1 day')::date as last_day
  ),
  held as (
    select om.module_code, m.name, m.monthly_price,
           -- The day it started counting for this month: the later of
           -- the month's first day and the day it was switched on.
           --
           -- `app.malaysian_day` and not `::date`, which reads the
           -- session's time zone -- UTC on this server. A module
           -- switched on at two in the morning in Kuala Lumpur is
           -- stamped the previous day in UTC, and the customer would be
           -- billed for a day before the one they agreed to.
           greatest(b.first_day,
                    coalesce(app.malaysian_day(om.enabled_at), b.first_day))
             as from_day,
           -- And the day it stopped: the earlier of the month's last
           -- day and the day before it lapsed. A module still on runs
           -- to the month end.
           least(b.last_day,
                 coalesce(app.malaysian_day(om.expires_at) - 1, b.last_day))
             as to_day,
           -- The day this company started, which is what a trial counts
           -- from -- not the first of the month, which would restart
           -- every trial on the first and never end one.
           coalesce(app.malaysian_day(om.enabled_at), b.first_day)
             as started_day
      from public.org_modules om
      join public.platform_modules m on m.code = om.module_code
     cross join bounds b
     where om.org_id = p_org_id
       -- Still on, or off with a date on when it went off. Not
       -- `om.is_enabled` alone: 0488 switches a module off by clearing
       -- the flag, and the row then says nothing about the days it was
       -- on before that.
       and (om.is_enabled or om.expires_at is not null)
       and m.is_active
       -- The product itself is not an add-on.
       and not m.is_core
       and m.monthly_price > 0
       -- Switched on after this month ended: not this month's bill.
       and coalesce(app.malaysian_day(om.enabled_at), b.first_day)
             <= b.last_day
  ),
  -- Every day the module was held, and what that day cost. A promotion
  -- that opens or closes inside the month lands here rather than in a
  -- special case.
  priced as (
    select h.module_code, h.name, h.monthly_price,
           d::date as day,
           p.price as day_price,
           p.promotion
      from held h
     cross join lateral generate_series(h.from_day, h.to_day,
                                        interval '1 day') d
     cross join lateral app.module_price_on(
                  p_org_id, h.module_code, d::date, h.started_day) p
     where h.to_day >= h.from_day
  )
  select p.module_code, p.name, p.monthly_price,
         count(*)::integer,
         (b.last_day - b.first_day + 1)::integer,
         -- The month's price is the sum of its days' prices over the
         -- days in the month, rounded once at the end. Rounding each
         -- day would lose up to half a sen thirty-one times.
         round(sum(p.day_price) / (b.last_day - b.first_day + 1), 2),
         round(p.monthly_price * count(*)
               / (b.last_day - b.first_day + 1), 2),
         -- Named once even if it only covered part of the month: the
         -- line exists to explain a number that is lower than the list.
         max(p.promotion)
    from priced p cross join bounds b
   group by p.module_code, p.name, p.monthly_price, b.first_day, b.last_day
   order by p.name;
$$;

comment on function app.module_days_in_month(uuid, date) is
  'What a company held in a month and what each add-on costs it, '
  'priced day by day so a promotion that opens or closes mid-month '
  'splits the month where it falls. See 0489, 0548.';

revoke all on function app.module_days_in_month(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The invoice line says why
-- ---------------------------------------------------------------------
-- Restated from 0490's definition -- not 0489's -- with one change: the
-- line names the promotion when there was one. A bill lower than the
-- published price list, with nothing on it to say why, is a support
-- ticket, and an operator reading it a year later has no way to tell a
-- discount from a bug.
--
-- The first draft of this restated 0489, which is the version this
-- file's comments quote, and silently dropped the block 0490 added at
-- the end: the mail that tells the company the invoice exists. Every
-- customer would have been billed in silence. `module_subscription.sql`
-- caught it -- "the company is told its bill exists" -- and the
-- self-check at the foot of this file now says so in the schema, the
-- way 0490's own does.
create or replace function app.bill_org_modules(
  p_org_id uuid, p_month date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org      public.organizations;
  v_issuer   jsonb;
  v_prefix   text;
  v_seq      integer;
  v_no       text;
  v_rate     numeric(6, 3) := 0;
  v_sub      numeric;
  v_tax      numeric(18, 2) := 0;
  v_lines    text;
  v_id       uuid;
  v_first    date := date_trunc('month', p_month)::date;
  v_note     text;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if v_org.id is null then
    return null;
  end if;
  -- A demo tenant exists to be looked at, not to be billed.
  if v_org.is_demo then
    return null;
  end if;

  -- Once per company per month. The note carries the period, which is
  -- what makes a second run find the first one rather than write
  -- another.
  v_note := 'modules:' || to_char(v_first, 'YYYY-MM');
  select id into v_id from public.platform_invoices
   where org_id = p_org_id and notes = v_note;
  if v_id is not null then
    return v_id;
  end if;

  select sum(d.amount),
         string_agg(d.name || ' -- ' || d.days || '/' || d.days_in_month
                    || ' days'
                    || case when d.promotion is null then ''
                            else ' (' || d.promotion || ')' end,
                    chr(10) order by d.name)
    into v_sub, v_lines
    from app.module_days_in_month(p_org_id, v_first) d;

  -- Nothing held is not a bill for nothing; it is no bill. A company
  -- whose add-ons were all free this month lands here too, which is
  -- the right answer: an invoice for RM 0.00 is a bill nobody can pay
  -- and a reminder nobody should be sent.
  if coalesce(v_sub, 0) <= 0 then
    return null;
  end if;

  -- Read the same way 0421 reads it, from the same row.
  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  v_issuer := coalesce(v_issuer, '{}'::jsonb);

  -- SST is charged when the issuer is registered for it, and not
  -- otherwise.
  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then
    v_rate := coalesce((v_issuer ->> 'sst_rate')::numeric, 0);
  end if;
  v_tax := round(v_sub * v_rate / 100, 2);

  -- One number at a time, as 0421 has it: the monthly run and an
  -- administrator's top-up can land in the same second.
  perform pg_advisory_xact_lock(hashtext('platform_invoice_no'));
  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');
  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1
    into v_seq
    from public.platform_invoices i
   where i.invoice_no like v_prefix || '-' || to_char(v_first, 'YYYY') || '-%';
  v_no := format('%s-%s-%s', v_prefix, to_char(v_first, 'YYYY'),
                 lpad(v_seq::text, 4, '0'));

  insert into public.platform_invoices (
    invoice_no, org_id, issue_date, currency,
    issuer_name, issuer_registration_no, issuer_old_registration_no,
    issuer_sst_no, issuer_address,
    bill_to_name, bill_to_registration_no, bill_to_tin, bill_to_address,
    description, subtotal, tax_rate, tax_amount, total_amount, notes)
  values (
    v_no, p_org_id, (v_first + interval '1 month')::date, 'MYR',
    coalesce(v_issuer ->> 'name', 'Kabeer Holdings Sdn Bhd'),
    v_issuer ->> 'registration_no',
    v_issuer ->> 'old_registration_no',
    nullif(v_issuer ->> 'sst_no', ''),
    nullif(v_issuer ->> 'address', ''),
    v_org.name, v_org.registration_no, v_org.tin, v_org.address_line1,
    -- FM, because `to_char(..., 'Month')` blank-pads the name to nine
    -- characters.
    'Modules for ' || to_char(v_first, 'FMMonth YYYY') || chr(10) || v_lines,
    v_sub, v_rate, v_tax, v_sub + v_tax, v_note)
  returning id into v_id;

  -- 0490. The company is told. Wrapped, because the invoice is the
  -- record and the mail is the courtesy: an outbox that refuses must
  -- not roll back the bill, and inside `bill_the_month` it would take
  -- every company after this one with it.
  begin
    perform app.queue_platform_invoice_email(v_id);
  exception when others then
    raise warning 'queue_platform_invoice_email failed for %: %',
      v_id, sqlerrm;
  end;

  return v_id;
end $$;

comment on function app.bill_org_modules(uuid, date) is
  'One invoice per company per month for the add-ons it held, '
  'pro-rated by days and priced against any promotion, which the line '
  'names, and the mail that tells them so. Idempotent per month. '
  'See 0489, 0490, 0548.';

revoke all on function app.bill_org_modules(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What the company sees of the month in progress
-- ---------------------------------------------------------------------
-- Restated from 0489 with the two new facts on each line: what the
-- list price would have come to, and the name of the promotion that
-- made it less.
create or replace function public.module_charges(
  p_org_id uuid, p_month date default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, app.today()))::date;
  v_rows  jsonb;
  v_sub   numeric;
  v_list  numeric;
begin
  -- What the company is being charged is an administrator's business,
  -- not every member's.
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator may see what the company is billed'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'module_code',   d.module_code,
           'name',          d.name,
           'monthly_price', d.monthly_price,
           'days',          d.days,
           'days_in_month', d.days_in_month,
           'amount',        d.amount,
           'list_amount',   d.list_amount,
           'promotion',     d.promotion)
           order by d.name), '[]'::jsonb),
         coalesce(sum(d.amount), 0),
         coalesce(sum(d.list_amount), 0)
    into v_rows, v_sub, v_list
    from app.module_days_in_month(p_org_id, v_month) d;

  return jsonb_build_object(
    'month', v_month, 'lines', v_rows, 'subtotal', v_sub,
    -- What it would have been, so the screen can show what a promotion
    -- saved rather than only a number that happens to be low.
    'list_subtotal', v_list, 'saved', v_list - v_sub);
end $$;

comment on function public.module_charges(uuid, date) is
  'What the add-ons a company holds have cost it so far this month, '
  'line by line, pro-rated by days and net of any promotion. See 0489, 0548.';

revoke all on function public.module_charges(uuid, date) from public, anon;
grant execute on function public.module_charges(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- The offer, on the screen where a company adds a module
-- ---------------------------------------------------------------------
-- Restated from 0234 with the promotion on it. Without this the
-- settings screen offers a module at RM 39 a month and then bills
-- nothing for thirty days, which is a pleasant surprise exactly once
-- and a reason not to trust the number after that.
--
-- The price shown for a module the company does not hold is what it
-- would pay if it started today; for one it holds, what it is paying
-- now -- which is the difference between "free for 30 days" and "free
-- for another 11 days".
drop function if exists public.org_module_surface(uuid);

create or replace function public.org_module_surface(p_org_id uuid)
returns table (
  module_code   text,
  name          text,
  description   text,
  is_core       boolean,
  monthly_price numeric,
  sort_order    integer,
  entitled      boolean,
  hidden        boolean,
  visible       boolean,
  promo_price   numeric,
  promotion     text,
  promo_kind    text,
  promo_days    integer,
  promo_until   date)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if p_org_id is null or not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  return query
    select pm.code,
           pm.name,
           pm.description,
           pm.is_core,
           pm.monthly_price,
           pm.sort_order,
           app.has_module(p_org_id, pm.code),
           coalesce(om.is_hidden, false),
           app.module_visible(p_org_id, pm.code),
           p.price,
           p.promotion,
           p.kind,
           p.trial_days,
           p.ends_on
      from public.platform_modules pm
      left join public.org_modules om
             on om.org_id = p_org_id
            and om.module_code = pm.code
     cross join lateral app.module_price_on(
                  p_org_id, pm.code, app.today(),
                  case when coalesce(om.is_enabled, false)
                       then coalesce(app.malaysian_day(om.enabled_at),
                                     app.today())
                       else app.today() end) p
     where pm.is_active
     order by pm.sort_order, pm.code;
end;
$$;

comment on function public.org_module_surface(uuid) is
  'Every module on offer, what this company is entitled to, and what '
  'each would cost it today net of any promotion. See 0234, 0548.';

grant execute on function public.org_module_surface(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The console
-- ---------------------------------------------------------------------
-- Every promotion, with the module and company it names resolved, so
-- the list does not read as two columns of identifiers.
create or replace function public.platform_promotions()
returns table (
  id          uuid,
  name        text,
  module_code text,
  module_name text,
  org_id      uuid,
  org_name    text,
  kind        text,
  trial_days  integer,
  percent_off numeric,
  fixed_price numeric,
  starts_on   date,
  ends_on     date,
  is_active   boolean,
  notes       text,
  created_at  timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator may see the promotions'
      using errcode = '42501';
  end if;

  return query
    select p.id, p.name, p.module_code, m.name, p.org_id, o.name,
           p.kind, p.trial_days, p.percent_off, p.fixed_price,
           p.starts_on, p.ends_on, p.is_active, p.notes, p.created_at
      from public.module_promotions p
      left join public.platform_modules m on m.code = p.module_code
      left join public.organizations o on o.id = p.org_id
     order by p.is_active desc, p.starts_on desc, p.created_at desc;
end $$;

grant execute on function public.platform_promotions() to authenticated;

-- Write one. `p_id` null creates, set updates -- the same shape as
-- `platform_save_module`, and for the same reason: the dialog does not
-- have to know which it is doing.
--
-- The numbers a kind does not use are cleared rather than carried, so
-- a promotion changed from `percent_off` to `trial` does not keep a
-- percentage that nothing reads and that the next person to look at
-- the row will believe.
create or replace function public.platform_save_promotion(
  p_id uuid default null,
  p_name text default null,
  p_module_code text default null,
  p_org_id uuid default null,
  p_kind text default null,
  p_trial_days integer default null,
  p_percent_off numeric default null,
  p_fixed_price numeric default null,
  p_starts_on date default null,
  p_ends_on date default null,
  p_is_active boolean default null,
  p_notes text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id   uuid;
  v_kind text := lower(btrim(coalesce(p_kind, '')));
begin
  -- A promotion is money off every invoice it touches. A company
  -- administrator may switch a module on and agree to its price; only
  -- the platform decides what that price is, or is not.
  if not app.is_platform_admin() then
    raise exception 'A promotion changes what companies are billed and may '
                    'only be set by a platform administrator'
      using errcode = '42501';
  end if;

  if p_id is null then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A promotion needs a name -- it goes on the invoice'
        using errcode = '23514';
    end if;
    if v_kind = '' then
      raise exception 'A promotion needs a kind' using errcode = '23514';
    end if;

    insert into public.module_promotions
      (name, module_code, org_id, kind, trial_days, percent_off,
       fixed_price, starts_on, ends_on, is_active, notes, created_by)
    values (btrim(p_name), nullif(btrim(p_module_code), ''), p_org_id,
            v_kind,
            case when v_kind = 'trial' then p_trial_days end,
            case when v_kind = 'percent_off' then p_percent_off end,
            case when v_kind = 'fixed_price' then p_fixed_price end,
            coalesce(p_starts_on, app.today()), p_ends_on,
            coalesce(p_is_active, true), nullif(btrim(p_notes), ''),
            auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.module_promotions p set
    name        = coalesce(nullif(btrim(p_name), ''), p.name),
    -- Blank is a real value here: the promotion moves from one module
    -- to every add-on, or from one company to all of them. `p_all`
    -- would be a second argument saying what a null already says, so
    -- the caller sends the column it means to change and omits the
    -- rest.
    module_code = nullif(btrim(coalesce(p_module_code, p.module_code, '')), ''),
    org_id      = coalesce(p_org_id, p.org_id),
    kind        = coalesce(nullif(v_kind, ''), p.kind),
    trial_days  = case when coalesce(nullif(v_kind, ''), p.kind) = 'trial'
                       then coalesce(p_trial_days, p.trial_days) end,
    percent_off = case when coalesce(nullif(v_kind, ''), p.kind) = 'percent_off'
                       then coalesce(p_percent_off, p.percent_off) end,
    fixed_price = case when coalesce(nullif(v_kind, ''), p.kind) = 'fixed_price'
                       then coalesce(p_fixed_price, p.fixed_price) end,
    starts_on   = coalesce(p_starts_on, p.starts_on),
    ends_on     = coalesce(p_ends_on, p.ends_on),
    is_active   = coalesce(p_is_active, p.is_active),
    notes       = coalesce(nullif(btrim(p_notes), ''), p.notes)
   where p.id = p_id
   returning p.id into v_id;

  if v_id is null then
    raise exception 'There is no such promotion' using errcode = 'P0002';
  end if;
  return v_id;
end $$;

comment on function public.platform_save_promotion is
  'Create or change a promotion. Platform administrators only. See 0548.';

grant execute on function public.platform_save_promotion(
  uuid, text, text, uuid, text, integer, numeric, numeric, date, date,
  boolean, text) to authenticated;

-- Take one back to every company at once. There is no delete: a
-- promotion that has priced an invoice is part of why that invoice
-- says what it says, and `is_active = false` stops it applying from
-- today without pretending it never did.
create or replace function public.platform_end_promotion(
  p_id uuid, p_on date default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator may end a promotion'
      using errcode = '42501';
  end if;
  update public.module_promotions
     set ends_on = coalesce(p_on, app.today()),
         is_active = false
   where id = p_id;
  if not found then
    raise exception 'There is no such promotion' using errcode = 'P0002';
  end if;
end $$;

grant execute on function public.platform_end_promotion(uuid, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
-- This migration restates a function three earlier ones wrote. The
-- rules they set are not this file's to lose, and a restatement that
-- drops one applies cleanly and says nothing.
do $do$
begin
  if position('queue_platform_invoice_email' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0 then
    raise exception '0548: the invoice tells nobody again (0490)';
  end if;
  if position('is_demo' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0
     or position('modules:' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0 then
    raise exception '0548: the billing rules 0489 set were dropped';
  end if;
  if position('module_visible' in pg_get_functiondef(
       'public.org_module_surface(uuid)'::regprocedure)) = 0 then
    raise exception '0548: the surface stopped saying what is visible (0234)';
  end if;
end $do$;

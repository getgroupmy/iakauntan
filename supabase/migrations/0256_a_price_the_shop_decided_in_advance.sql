-- =====================================================================
-- A price the shop decided in advance
--
-- 0255 gave the till a discount button: a person decides, types a
-- reason, and their name goes on it. That is the right control for
-- "the steak was burnt" and the wrong mechanism for "teh tarik is two
-- ringgit before eleven". A happy hour typed in by hand is a happy hour
-- that is wrong on the till nobody told, missing on the Tuesday the
-- manager was off, and unreportable afterwards because every
-- application looks like a cashier's judgement.
--
-- So the shop writes the rule down once and the till applies it.
--
-- ---------------------------------------------------------------------
-- A promotion never touches a line
--
-- The obvious implementation is to reprice the line, and it is a trap:
-- once the line has been rewritten there is no way back to what it cost
-- before, so removing a promotion means remembering the old price
-- somewhere, and that somewhere is a second copy of live state that can
-- disagree with the first.
--
-- Instead every application is a row in `pos_sale_promotions` carrying
-- what it took off, and `pos_sales.promo_discount` is the sum of those
-- rows. `line_id` on the row is provenance -- which plate the rule was
-- reasoned about -- not a mutation of it. Deleting the row is the whole
-- of removing the promotion, and `pos_sale_lines.discount_amount` stays
-- what 0255 made it: money a person decided to take off.
--
-- The cost of this choice is that a promotion comes off the header
-- rather than off the line, so it does not reduce that line's tax. That
-- is already true of the loyalty redemption (0212) and of the manual
-- bill discount (0255), and one rule applied three ways beats three
-- rules. A shop needing SST computed on the promotional price should
-- set the price on the item rather than discount it.
--
-- ---------------------------------------------------------------------
-- Re-evaluated, not remembered
--
-- `refresh_pos_promotions` throws away every automatic application and
-- works them out again from the basket as it now stands. Anything else
-- rots within one order: ten per cent off a basket that has shrunk is
-- no longer ten per cent, and "spend fifty, get five off" must stop
-- applying the moment somebody takes the fiftieth ringgit back off the
-- bill. It runs from the till after a change and again inside
-- `complete_pos_sale`, so a shop cannot miss a happy hour because
-- nobody refreshed the screen.
--
-- A coupon is different: somebody typed it, so it stays attached even
-- when it stops qualifying, with `blocked_reason` saying why. A voucher
-- that silently disappeared at forty-three ringgit would leave a
-- cashier explaining something they cannot see.
--
-- ---------------------------------------------------------------------
-- What counts as used
--
-- Usage caps are counted, not incremented. A counter column has to be
-- decided on: does parking a bill with a coupon on it burn a use? does
-- voiding give it back? Every answer is a bug waiting for the other
-- case. Counting completed, un-voided sales answers all of them at once
-- and cannot drift.
-- =====================================================================

do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_promo_kind') then
    create type app.pos_promo_kind as enum (
      'percent_off',  -- a share of what qualifies
      'amount_off',   -- a flat sum, capped at what qualifies
      'buy_x_get_y'   -- three for two, and its relatives
    );
  end if;
end;
$$;

create table if not exists public.pos_promotions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,

  -- Null for a promotion that applies itself. A code makes it a
  -- voucher: nothing happens until somebody types it.
  code        text,
  name        text not null,
  kind        app.pos_promo_kind not null,

  percent     numeric(9, 4) not null default 0
              check (percent >= 0 and percent <= 100),
  amount      numeric(18, 2) not null default 0 check (amount >= 0),

  -- Buy this many at full price, get this many at `percent` off.
  -- "Three for two" is buy 2, get 1, at a hundred per cent.
  buy_quantity integer not null default 0 check (buy_quantity >= 0),
  get_quantity integer not null default 0 check (get_quantity >= 0),

  -- When it runs. Every one of these is null-means-always, so a shop
  -- that wants a promotion with no conditions writes a name and a
  -- number and stops.
  starts_on   date,
  ends_on     date,
  -- ISO weekdays, 1 = Monday. Null is every day.
  weekdays    smallint[],
  -- The happy hour itself, in the shop's own time. Null is all day.
  -- `starts_at` after `ends_at` is a window that crosses midnight,
  -- which is what a late bar means by "ten till two".
  starts_at   time,
  ends_at     time,

  min_subtotal numeric(18, 2) not null default 0 check (min_subtotal >= 0),

  -- Null is no limit. Counted from completed sales, never incremented.
  max_uses     integer check (max_uses is null or max_uses > 0),
  max_per_customer integer
               check (max_per_customer is null or max_per_customer > 0),

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint pos_promotions_bxgy_ck check (
    kind <> 'buy_x_get_y' or (buy_quantity > 0 and get_quantity > 0)),
  constraint pos_promotions_window_ck check (
    (starts_at is null) = (ends_at is null))
);

-- One live code per company. Partial, because most promotions have none
-- and a unique index over nulls would be a unique index over nothing.
create unique index if not exists pos_promotions_code_idx
  on public.pos_promotions (org_id, upper(code)) where code is not null;
create index if not exists pos_promotions_org_idx
  on public.pos_promotions (org_id, is_active);

comment on table public.pos_promotions is
  'A price the shop decided in advance. Every window is null-means-always, so a promotion with no conditions is a name and a number.';
comment on column public.pos_promotions.code is
  'The voucher code. Null makes the promotion automatic — the till applies it without being asked.';
comment on column public.pos_promotions.starts_at is
  'The start of the happy hour in Asia/Kuala_Lumpur. Later than ends_at means the window crosses midnight, which is what a late bar means by "ten till two".';

-- ---------------------------------------------------------------------
-- What it applies to
-- ---------------------------------------------------------------------
--
-- Three lists, all of them empty-means-everything. That rule is worth
-- one sentence because it is the opposite of what a join table usually
-- means: no rows here is not "applies to nothing", it is "the shop did
-- not narrow it".
create table if not exists public.pos_promotion_items (
  promotion_id uuid not null references public.pos_promotions (id) on delete cascade,
  item_id      uuid not null references public.items (id) on delete cascade,
  primary key (promotion_id, item_id)
);

create table if not exists public.pos_promotion_outlets (
  promotion_id uuid not null references public.pos_promotions (id) on delete cascade,
  outlet_id    uuid not null references public.pos_outlets (id) on delete cascade,
  primary key (promotion_id, outlet_id)
);

create table if not exists public.pos_promotion_channels (
  promotion_id uuid not null references public.pos_promotions (id) on delete cascade,
  channel      app.pos_order_channel not null,
  primary key (promotion_id, channel)
);

comment on table public.pos_promotion_items is
  'Which dishes a promotion is about. No rows means every dish — the shop did not narrow it, rather than narrowed it to nothing.';

-- ---------------------------------------------------------------------
-- What was applied to a bill
-- ---------------------------------------------------------------------
create table if not exists public.pos_sale_promotions (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  sale_id      uuid not null references public.pos_sales (id) on delete cascade,
  promotion_id uuid not null references public.pos_promotions (id) on delete restrict,

  -- Provenance, not a mutation. Which line the rule was reasoned about,
  -- so a receipt can print the promotion under the plate it came off.
  -- Null for a promotion about the whole bill.
  line_id      uuid references public.pos_sale_lines (id) on delete cascade,

  amount       numeric(18, 2) not null default 0 check (amount >= 0),

  -- True when somebody typed a code. Those survive a refresh even when
  -- they stop qualifying; automatic ones are rebuilt from scratch.
  by_code      boolean not null default false,
  -- Why it is taking nothing off, when it is. Shown at the counter:
  -- "needs RM50, this bill is RM43" is an answer a cashier can give.
  blocked_reason text,

  applied_at   timestamptz not null default now(),
  applied_by   uuid references auth.users (id) on delete set null,

  -- One row per promotion per line, so a refresh can rebuild by key
  -- rather than by guessing which row was which.
  unique (sale_id, promotion_id, line_id)
);

create index if not exists pos_sale_promotions_sale_idx
  on public.pos_sale_promotions (sale_id);
create index if not exists pos_sale_promotions_promo_idx
  on public.pos_sale_promotions (promotion_id);

comment on table public.pos_sale_promotions is
  'What a promotion took off a bill. The row is the application: deleting it is the whole of removing the promotion, because no line was ever rewritten.';

alter table public.pos_sales
  add column if not exists promo_discount numeric(18, 2) not null default 0
    check (promo_discount >= 0);

comment on column public.pos_sales.promo_discount is
  'The sum of this bill''s pos_sale_promotions rows, derived by recalc_pos_sale. Kept apart from bill_discount because one is a rule the shop wrote down and the other is a person''s decision, and the reports read differently.';

-- ---------------------------------------------------------------------
-- Does this promotion run, for this bill, now
-- ---------------------------------------------------------------------
--
-- Returns the reason it does not, or null when it does. A boolean would
-- be cheaper and would throw away the only thing the counter needs: a
-- sentence to say out loud.
--
-- "Now" is Asia/Kuala_Lumpur throughout, the same clock every other POS
-- day calculation uses. A happy hour that ended at eleven has to end at
-- eleven in the shop, not at seven in the morning because the server
-- keeps UTC.
create or replace function app.pos_promo_blocked(
  p_promo uuid,
  p_sale  uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p     public.pos_promotions;
  v_sale  public.pos_sales;
  v_now   timestamp;
  v_date  date;
  v_time  time;
  v_dow   smallint;
  v_base  numeric;
  v_used  integer;
begin
  select * into v_p from public.pos_promotions where id = p_promo;
  if v_p.id is null then
    return 'That promotion does not exist.';
  end if;
  if not v_p.is_active then
    return v_p.name || ' has been switched off.';
  end if;

  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null or v_sale.org_id <> v_p.org_id then
    return 'That promotion belongs to another company.';
  end if;

  v_now  := (now() at time zone 'Asia/Kuala_Lumpur');
  v_date := v_now::date;
  v_time := v_now::time;
  -- ISO: Monday is 1, Sunday is 7. `extract(dow)` makes Sunday 0, which
  -- is the off-by-one every weekday filter is written around.
  v_dow  := extract(isodow from v_now)::smallint;

  if v_p.starts_on is not null and v_date < v_p.starts_on then
    return v_p.name || ' does not start until ' || v_p.starts_on || '.';
  end if;
  if v_p.ends_on is not null and v_date > v_p.ends_on then
    return v_p.name || ' ended on ' || v_p.ends_on || '.';
  end if;
  if v_p.weekdays is not null and not (v_dow = any (v_p.weekdays)) then
    return v_p.name || ' does not run today.';
  end if;

  if v_p.starts_at is not null then
    if v_p.starts_at <= v_p.ends_at then
      if v_time < v_p.starts_at or v_time > v_p.ends_at then
        return v_p.name || ' runs from ' || v_p.starts_at
             || ' to ' || v_p.ends_at || '.';
      end if;
    else
      -- Crosses midnight: inside means after the start OR before the
      -- end, which is the case a naive BETWEEN gets exactly backwards.
      if v_time < v_p.starts_at and v_time > v_p.ends_at then
        return v_p.name || ' runs from ' || v_p.starts_at
             || ' to ' || v_p.ends_at || '.';
      end if;
    end if;
  end if;

  if exists (select 1 from public.pos_promotion_outlets o
              where o.promotion_id = p_promo)
     and not exists (select 1 from public.pos_promotion_outlets o
                      where o.promotion_id = p_promo
                        and o.outlet_id = v_sale.outlet_id) then
    return v_p.name || ' is not running in this shop.';
  end if;

  if exists (select 1 from public.pos_promotion_channels c
              where c.promotion_id = p_promo)
     and not exists (select 1 from public.pos_promotion_channels c
                      where c.promotion_id = p_promo
                        and c.channel = v_sale.order_channel) then
    return v_p.name || ' does not apply to this kind of order.';
  end if;

  if v_p.min_subtotal > 0 then
    -- Summed from the lines, not read from `pos_sales.subtotal`.
    --
    -- That column is only correct once `recalc_pos_sale` has run, which
    -- makes every caller of this function responsible for recalculating
    -- first — and the one that forgets gets a voucher judged against
    -- the basket as it was one plate ago. Reading the lines is the same
    -- number with no ordering to get wrong, and it is the base
    -- `pos_promo_amount` already measures against, so "spend fifty"
    -- means the same fifty in both places.
    --
    -- Before anything came off, deliberately: a minimum spend that
    -- other discounts could push you under would switch itself off at
    -- the moment it was earned.
    select coalesce(sum(l.line_total), 0) into v_base
      from public.pos_sale_lines l where l.sale_id = p_sale;
    v_base := round(v_base, 2);
    if v_base < v_p.min_subtotal then
      return v_p.name || ' needs ' || v_p.min_subtotal
           || ' and this bill is ' || v_base || '.';
    end if;
  end if;

  -- Counted, never incremented. A parked bill holding the voucher has
  -- not used it; a written-off bill gives it back.
  if v_p.max_uses is not null then
    select count(*)::integer into v_used
      from public.pos_sale_promotions sp
      join public.pos_sales s on s.id = sp.sale_id
     where sp.promotion_id = p_promo
       and s.status = 'completed'
       and sp.amount > 0
       and s.id is distinct from p_sale;
    if v_used >= v_p.max_uses then
      return v_p.name || ' has been used up.';
    end if;
  end if;

  if v_p.max_per_customer is not null and v_sale.contact_id is not null then
    select count(distinct s.id)::integer into v_used
      from public.pos_sale_promotions sp
      join public.pos_sales s on s.id = sp.sale_id
     where sp.promotion_id = p_promo
       and s.status = 'completed'
       and sp.amount > 0
       and s.contact_id = v_sale.contact_id
       and s.id is distinct from p_sale;
    if v_used >= v_p.max_per_customer then
      return 'This customer has already had ' || v_p.name || '.';
    end if;
  end if;

  return null;
end;
$$;

revoke all on function app.pos_promo_blocked(uuid, uuid) from public, anon;
grant execute on function app.pos_promo_blocked(uuid, uuid) to authenticated;

comment on function app.pos_promo_blocked(uuid, uuid) is
  'Why this promotion does not apply to this bill right now, or null when it does. A sentence rather than a boolean, because the counter has to say it out loud.';

-- ---------------------------------------------------------------------
-- What it takes off
-- ---------------------------------------------------------------------
--
-- Assumes the promotion already qualifies; `pos_promo_blocked` is the
-- gate and this is the arithmetic, kept apart so the reason a voucher
-- was refused never depends on what it would have been worth.
--
-- The qualifying base is the promotion's items, or the whole basket
-- when it names none. Line totals are used rather than unit prices, so
-- a manual discount already taken off a plate is respected: a shop
-- cannot be made to give ten per cent off a price it already reduced.
create or replace function app.pos_promo_amount(
  p_promo uuid,
  p_sale  uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p    public.pos_promotions;
  v_base numeric := 0;
  v_out  numeric := 0;
  v_all  boolean;
begin
  select * into v_p from public.pos_promotions where id = p_promo;
  if v_p.id is null then
    return 0;
  end if;

  v_all := not exists (select 1 from public.pos_promotion_items i
                        where i.promotion_id = p_promo);

  select coalesce(sum(l.line_total), 0) into v_base
    from public.pos_sale_lines l
   where l.sale_id = p_sale
     and (v_all or exists (select 1 from public.pos_promotion_items i
                            where i.promotion_id = p_promo
                              and i.item_id = l.item_id));

  if v_base <= 0 then
    return 0;
  end if;

  if v_p.kind = 'percent_off' then
    v_out := round(v_base * v_p.percent / 100.0, 2);

  elsif v_p.kind = 'amount_off' then
    -- Capped, because a five-ringgit voucher against three ringgit of
    -- qualifying food is not two ringgit of change.
    v_out := least(v_p.amount, v_base);

  elsif v_p.kind = 'buy_x_get_y' then
    -- Three for two, done the way a supermarket does it: every unit at
    -- its own price, sorted dearest first, cut into blocks of
    -- (buy + get), and the cheapest `get` of each COMPLETE block
    -- discounted. Incomplete blocks pay full price, which is the whole
    -- point of the offer.
    --
    -- Whole units only. Half a plate cannot be the free one, and
    -- flooring is kinder than refusing.
    with units as (
      select l.line_total / nullif(l.quantity, 0) as unit
        from public.pos_sale_lines l
        cross join lateral generate_series(1, floor(l.quantity)::integer)
       where l.sale_id = p_sale
         and l.quantity >= 1
         and (v_all or exists (select 1 from public.pos_promotion_items i
                                where i.promotion_id = p_promo
                                  and i.item_id = l.item_id))
    ),
    ranked as (
      select u.unit,
             row_number() over (order by u.unit desc) as rn,
             count(*) over () as n
        from units u
    )
    select coalesce(sum(r.unit * v_p.percent / 100.0), 0) into v_out
      from ranked r
     where r.rn <= (r.n / (v_p.buy_quantity + v_p.get_quantity))
                   * (v_p.buy_quantity + v_p.get_quantity)
       and ((r.rn - 1) % (v_p.buy_quantity + v_p.get_quantity))
           >= v_p.buy_quantity;
    v_out := round(coalesce(v_out, 0), 2);
  end if;

  return least(greatest(coalesce(v_out, 0), 0), v_base);
end;
$$;

revoke all on function app.pos_promo_amount(uuid, uuid) from public, anon;
grant execute on function app.pos_promo_amount(uuid, uuid) to authenticated;

comment on function app.pos_promo_amount(uuid, uuid) is
  'What a qualifying promotion takes off this bill. Reads line totals, so a plate already discounted by hand is not discounted twice off the same money.';

-- ---------------------------------------------------------------------
-- Working them all out again
-- ---------------------------------------------------------------------
--
-- Automatic promotions are deleted and rebuilt; coupons keep their row
-- and have their amount recomputed. See the header for why: an
-- automatic rule that no longer applies should leave no trace, and a
-- voucher somebody typed should stay on the screen saying why it is
-- taking nothing off.
create or replace function app.refresh_pos_promotions(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_row  record;
  v_why  text;
  v_amt  numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null or v_sale.status <> 'parked' then
    -- A settled bill's promotions are history. Recomputing them would
    -- rewrite what a customer was charged last Tuesday.
    return;
  end if;

  delete from public.pos_sale_promotions sp
   where sp.sale_id = p_sale and not sp.by_code;

  for v_row in
    select p.id from public.pos_promotions p
     where p.org_id = v_sale.org_id and p.is_active and p.code is null
     order by p.created_at
  loop
    if app.pos_promo_blocked(v_row.id, p_sale) is null then
      v_amt := app.pos_promo_amount(v_row.id, p_sale);
      if v_amt > 0 then
        insert into public.pos_sale_promotions
          (org_id, sale_id, promotion_id, amount, by_code)
        values (v_sale.org_id, p_sale, v_row.id, v_amt, false)
        on conflict (sale_id, promotion_id, line_id) do update
          set amount = excluded.amount, blocked_reason = null;
      end if;
    end if;
  end loop;

  for v_row in
    select sp.id, sp.promotion_id from public.pos_sale_promotions sp
     where sp.sale_id = p_sale and sp.by_code
  loop
    v_why := app.pos_promo_blocked(v_row.promotion_id, p_sale);
    if v_why is null then
      v_amt := app.pos_promo_amount(v_row.promotion_id, p_sale);
      update public.pos_sale_promotions sp
         set amount = v_amt,
             blocked_reason = case when v_amt > 0 then null
                              else 'Nothing on this bill qualifies.' end
       where sp.id = v_row.id;
    else
      update public.pos_sale_promotions sp
         set amount = 0, blocked_reason = v_why
       where sp.id = v_row.id;
    end if;
  end loop;
end;
$$;

revoke all on function app.refresh_pos_promotions(uuid)
  from public, anon, authenticated;

comment on function app.refresh_pos_promotions(uuid) is
  'Recomputes every promotion on a parked bill from the basket as it now stands. Automatic ones are rebuilt; coupons keep their row and gain a blocked_reason when they stop qualifying.';

-- ---------------------------------------------------------------------
-- Recalculating a basket that now has three headers of discount
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0255, for one term. The order is the order that
-- favours the customer: the shop's own rules and the manager's decision
-- come off first, and points are spent against what is left.
create or replace function app.recalc_pos_sale(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sub numeric; v_tax numeric; v_disc numeric;
  v_loy numeric; v_pct numeric; v_bill numeric;
  v_promo numeric; v_gross numeric;
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
         total_amount = greatest(round(v_gross - v_bill - v_promo - v_loy, 2), 0)
   where s.id = p_sale;
end;
$$;

-- ---------------------------------------------------------------------
-- What the till can offer, and typing a code
-- ---------------------------------------------------------------------
create or replace function public.pos_sale_promotions_on(p_sale uuid)
returns table (
  id             uuid,
  promotion_id   uuid,
  name           text,
  code           text,
  kind           app.pos_promo_kind,
  amount         numeric,
  by_code        boolean,
  blocked_reason text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select sp.id, sp.promotion_id, p.name, p.code, p.kind,
         sp.amount, sp.by_code, sp.blocked_reason
    from public.pos_sale_promotions sp
    join public.pos_promotions p on p.id = sp.promotion_id
    join public.pos_sales s on s.id = sp.sale_id
   where sp.sale_id = p_sale
     and app.can_read_module(s.org_id, 'pos')
   order by sp.by_code desc, p.name;
$$;

grant execute on function public.pos_sale_promotions_on(uuid) to authenticated;

comment on function public.pos_sale_promotions_on(uuid) is
  'What is on this bill and what each took off, including coupons that currently qualify for nothing and the reason why.';

-- ---------------------------------------------------------------------
-- Typing a voucher
-- ---------------------------------------------------------------------
--
-- Not gated on `pos_discount`. That grant is about a cashier deciding
-- to reduce a price; honouring a code the shop published is the
-- opposite — the decision was made in advance by whoever wrote the
-- promotion, and a cashier who could not accept a voucher the shop
-- printed would be a till that cannot do its job.
create or replace function public.apply_pos_coupon(
  p_sale uuid,
  p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale  public.pos_sales;
  v_promo public.pos_promotions;
  v_why   text;
  v_id    uuid;
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
    raise exception 'That bill is % and cannot take a voucher.', v_sale.status
      using errcode = '23514';
  end if;

  select * into v_promo from public.pos_promotions p
   where p.org_id = v_sale.org_id
     and p.code is not null
     and upper(p.code) = upper(btrim(coalesce(p_code, '')));
  if v_promo.id is null then
    raise exception 'No voucher with that code.' using errcode = 'P0002';
  end if;

  -- Refused at the door rather than attached and inert, because a code
  -- that was never going to work is a typo and should read as one.
  v_why := app.pos_promo_blocked(v_promo.id, p_sale);
  if v_why is not null then
    raise exception '%', v_why using errcode = '23514';
  end if;

  insert into public.pos_sale_promotions
    (org_id, sale_id, promotion_id, amount, by_code, applied_by)
  values (v_sale.org_id, p_sale, v_promo.id,
          app.pos_promo_amount(v_promo.id, p_sale), true, auth.uid())
  on conflict (sale_id, promotion_id, line_id) do update
    set by_code = true,
        amount = excluded.amount,
        blocked_reason = null
  returning id into v_id;

  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  return v_id;
end;
$$;

revoke all on function public.apply_pos_coupon(uuid, text) from public, anon;
grant execute on function public.apply_pos_coupon(uuid, text) to authenticated;

comment on function public.apply_pos_coupon(uuid, text) is
  'Attaches a voucher to a parked bill, refusing a code that does not qualify rather than attaching it inert. Not gated on pos_discount: honouring a code the shop printed is not a cashier''s decision.';

create or replace function public.remove_pos_sale_promotion(p_row uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale uuid;
  v_org  uuid;
  v_status app.pos_sale_status;
begin
  select sp.sale_id, sp.org_id into v_sale, v_org
    from public.pos_sale_promotions sp where sp.id = p_row;
  if v_sale is null then
    raise exception 'No such promotion on this bill.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  select s.status into v_status from public.pos_sales s where s.id = v_sale;
  if v_status <> 'parked' then
    raise exception 'That bill is already %.', v_status using errcode = '23514';
  end if;

  -- Deleting the row is the whole of it. No line was ever rewritten, so
  -- there is no price to put back.
  delete from public.pos_sale_promotions where id = p_row;
  perform app.recalc_pos_sale(v_sale);
  return v_sale;
end;
$$;

revoke all on function public.remove_pos_sale_promotion(uuid) from public, anon;
grant execute on function public.remove_pos_sale_promotion(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Refreshing from the till
-- ---------------------------------------------------------------------
--
-- The public door onto `refresh`, so a screen can ask after adding a
-- plate. Returns what the bill now comes to, which is the only thing
-- the caller wanted.
create or replace function public.refresh_pos_sale_promotions(p_sale uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_total numeric;
begin
  select s.org_id into v_org from public.pos_sales s where s.id = p_sale;
  if v_org is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  select s.total_amount into v_total from public.pos_sales s where s.id = p_sale;
  return v_total;
end;
$$;

revoke all on function public.refresh_pos_sale_promotions(uuid) from public, anon;
grant execute on function public.refresh_pos_sale_promotions(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Writing the rule down
-- ---------------------------------------------------------------------
--
-- One function for both halves of the promotion — the rule and the
-- three lists it is narrowed by — because they are one decision. A
-- shop that saved "ten per cent off drinks" and then failed to save
-- which drinks would have published ten per cent off everything, and
-- would have found out from the takings.
--
-- Null for a list means "leave it alone"; an empty array means "clear
-- it", which is how a promotion narrowed to one outlet is widened back
-- to all of them.
create or replace function public.upsert_pos_promotion(
  p_org        uuid,
  p_name       text,
  p_kind       app.pos_promo_kind,
  p_code       text    default null,
  p_percent    numeric default 0,
  p_amount     numeric default 0,
  p_buy        integer default 0,
  p_get        integer default 0,
  p_starts_on  date    default null,
  p_ends_on    date    default null,
  p_weekdays   smallint[] default null,
  p_starts_at  time    default null,
  p_ends_at    time    default null,
  p_min_subtotal numeric default 0,
  p_max_uses   integer default null,
  p_max_per_customer integer default null,
  p_items      uuid[]  default null,
  p_outlets    uuid[]  default null,
  p_channels   text[]  default null,
  p_id         uuid    default null,
  p_is_active  boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A promotion needs a name. It goes on the receipt.'
      using errcode = '23514';
  end if;

  -- Each kind has one number that makes it mean anything, and a
  -- promotion saved without it is a promotion that takes nothing off
  -- and looks like it is working.
  if p_kind = 'percent_off' and coalesce(p_percent, 0) <= 0 then
    raise exception 'A percentage off has to be more than nought.'
      using errcode = '23514';
  end if;
  if p_kind = 'amount_off' and coalesce(p_amount, 0) <= 0 then
    raise exception 'An amount off has to be more than nought.'
      using errcode = '23514';
  end if;
  if p_kind = 'buy_x_get_y' then
    if coalesce(p_buy, 0) <= 0 or coalesce(p_get, 0) <= 0 then
      raise exception
        'Say how many are bought and how many come free. Three for two '
        'is buy 2, get 1.'
        using errcode = '23514';
    end if;
    if coalesce(p_percent, 0) <= 0 then
      raise exception
        'Say how much comes off the free ones. A hundred per cent is '
        'free; fifty is half price.'
        using errcode = '23514';
    end if;
  end if;
  if (p_starts_at is null) <> (p_ends_at is null) then
    raise exception 'An hours window needs both a start and an end.'
      using errcode = '23514';
  end if;
  if p_weekdays is not null
     and exists (select 1 from unnest(p_weekdays) d where d < 1 or d > 7) then
    raise exception 'Weekdays run from 1 (Monday) to 7 (Sunday).'
      using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.pos_promotions
      (org_id, code, name, kind, percent, amount, buy_quantity, get_quantity,
       starts_on, ends_on, weekdays, starts_at, ends_at, min_subtotal,
       max_uses, max_per_customer, is_active)
    values (p_org, nullif(btrim(coalesce(p_code, '')), ''), btrim(p_name),
            p_kind, coalesce(p_percent, 0), coalesce(p_amount, 0),
            coalesce(p_buy, 0), coalesce(p_get, 0),
            p_starts_on, p_ends_on, p_weekdays, p_starts_at, p_ends_at,
            coalesce(p_min_subtotal, 0), p_max_uses, p_max_per_customer,
            coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.pos_promotions p
       set code = nullif(btrim(coalesce(p_code, '')), ''),
           name = btrim(p_name),
           kind = p_kind,
           percent = coalesce(p_percent, 0),
           amount = coalesce(p_amount, 0),
           buy_quantity = coalesce(p_buy, 0),
           get_quantity = coalesce(p_get, 0),
           starts_on = p_starts_on,
           ends_on = p_ends_on,
           weekdays = p_weekdays,
           starts_at = p_starts_at,
           ends_at = p_ends_at,
           min_subtotal = coalesce(p_min_subtotal, 0),
           max_uses = p_max_uses,
           max_per_customer = p_max_per_customer,
           is_active = coalesce(p_is_active, true),
           updated_at = now()
     where p.id = p_id and p.org_id = p_org;
    if not found then
      raise exception 'No such promotion.' using errcode = 'P0002';
    end if;
    v_id := p_id;
  end if;

  if p_items is not null then
    delete from public.pos_promotion_items where promotion_id = v_id;
    insert into public.pos_promotion_items (promotion_id, item_id)
    select v_id, i from unnest(p_items) i
    on conflict do nothing;
  end if;
  if p_outlets is not null then
    delete from public.pos_promotion_outlets where promotion_id = v_id;
    insert into public.pos_promotion_outlets (promotion_id, outlet_id)
    select v_id, o from unnest(p_outlets) o
    on conflict do nothing;
  end if;
  if p_channels is not null then
    delete from public.pos_promotion_channels where promotion_id = v_id;
    insert into public.pos_promotion_channels (promotion_id, channel)
    select v_id, c::app.pos_order_channel from unnest(p_channels) c
    on conflict do nothing;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_promotion(
  uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer,
  date, date, smallint[], time, time, numeric, integer, integer,
  uuid[], uuid[], text[], uuid, boolean) from public, anon;
grant execute on function public.upsert_pos_promotion(
  uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer,
  date, date, smallint[], time, time, numeric, integer, integer,
  uuid[], uuid[], text[], uuid, boolean) to authenticated;

-- Retired, never deleted. `pos_sale_promotions.promotion_id` is
-- `on delete restrict` for the reason every other retirement in this
-- schema exists: last April's receipt has to keep saying which
-- promotion it was.
create or replace function public.retire_pos_promotion(p_promo uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select p.org_id into v_org from public.pos_promotions p where p.id = p_promo;
  if v_org is null then
    raise exception 'No such promotion.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  update public.pos_promotions p
     set is_active = false, updated_at = now() where p.id = p_promo;
  return p_promo;
end;
$$;

revoke all on function public.retire_pos_promotion(uuid) from public, anon;
grant execute on function public.retire_pos_promotion(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The list a shop administers, with what each one has cost
-- ---------------------------------------------------------------------
--
-- The money is on the row for the same reason the member count is on a
-- loyalty tier: a promotion nobody used and a promotion that gave away
-- four thousand ringgit look identical in a list of names.
create or replace function public.pos_promotions_admin(p_org uuid)
returns table (
  id           uuid,
  code         text,
  name         text,
  kind         app.pos_promo_kind,
  percent      numeric,
  amount       numeric,
  buy_quantity integer,
  get_quantity integer,
  starts_on    date,
  ends_on      date,
  weekdays     smallint[],
  starts_at    time,
  ends_at      time,
  min_subtotal numeric,
  max_uses     integer,
  max_per_customer integer,
  is_active    boolean,
  item_ids     uuid[],
  outlet_ids   uuid[],
  channels     text[],
  times_used   integer,
  given_away   numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select p.id, p.code, p.name, p.kind, p.percent, p.amount,
         p.buy_quantity, p.get_quantity,
         p.starts_on, p.ends_on, p.weekdays, p.starts_at, p.ends_at,
         p.min_subtotal, p.max_uses, p.max_per_customer, p.is_active,
         coalesce((select array_agg(i.item_id)
                     from public.pos_promotion_items i
                    where i.promotion_id = p.id), '{}'::uuid[]),
         coalesce((select array_agg(o.outlet_id)
                     from public.pos_promotion_outlets o
                    where o.promotion_id = p.id), '{}'::uuid[]),
         coalesce((select array_agg(c.channel::text)
                     from public.pos_promotion_channels c
                    where c.promotion_id = p.id), '{}'::text[]),
         -- Completed bills only, matching what the usage cap counts.
         coalesce((select count(*)::integer
                     from public.pos_sale_promotions sp
                     join public.pos_sales s on s.id = sp.sale_id
                    where sp.promotion_id = p.id
                      and s.status = 'completed' and sp.amount > 0), 0),
         coalesce((select sum(sp.amount)
                     from public.pos_sale_promotions sp
                     join public.pos_sales s on s.id = sp.sale_id
                    where sp.promotion_id = p.id
                      and s.status = 'completed'), 0)
    from public.pos_promotions p
   where p.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by p.is_active desc, p.name;
$$;

grant execute on function public.pos_promotions_admin(uuid) to authenticated;

comment on function public.pos_promotions_admin(uuid) is
  'Every promotion a company has written, retired ones included, with how many bills used it and what it gave away. The money is on the row because a list of names cannot tell those apart.';

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_promotions          enable row level security;
alter table public.pos_promotion_items     enable row level security;
alter table public.pos_promotion_outlets   enable row level security;
alter table public.pos_promotion_channels  enable row level security;
alter table public.pos_sale_promotions     enable row level security;

create policy pos_promotions_read on public.pos_promotions for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy pos_promotions_write on public.pos_promotions for all
  to authenticated using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- The three lists hang off the promotion and are guarded through it,
-- because they carry no org of their own and inventing one would be a
-- second answer to a question the parent already answers.
create policy pos_promotion_items_all on public.pos_promotion_items for all
  to authenticated
  using (exists (select 1 from public.pos_promotions p
                  where p.id = promotion_id
                    and app.can_write_module(p.org_id, 'pos')))
  with check (exists (select 1 from public.pos_promotions p
                       where p.id = promotion_id
                         and app.can_write_module(p.org_id, 'pos')));
create policy pos_promotion_outlets_all on public.pos_promotion_outlets for all
  to authenticated
  using (exists (select 1 from public.pos_promotions p
                  where p.id = promotion_id
                    and app.can_write_module(p.org_id, 'pos')))
  with check (exists (select 1 from public.pos_promotions p
                       where p.id = promotion_id
                         and app.can_write_module(p.org_id, 'pos')));
create policy pos_promotion_channels_all on public.pos_promotion_channels for all
  to authenticated
  using (exists (select 1 from public.pos_promotions p
                  where p.id = promotion_id
                    and app.can_write_module(p.org_id, 'pos')))
  with check (exists (select 1 from public.pos_promotions p
                       where p.id = promotion_id
                         and app.can_write_module(p.org_id, 'pos')));

-- Read only. There is no write policy on purpose: an application a
-- client could insert is a client that can give itself any discount it
-- likes. They are written through the functions above, which is the
-- same rule `loyalty_entries` has had since 0212.
create policy pos_sale_promotions_read on public.pos_sale_promotions for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_promotions to authenticated;
grant select, insert, update, delete on public.pos_promotion_items to authenticated;
grant select, insert, update, delete on public.pos_promotion_outlets to authenticated;
grant select, insert, update, delete on public.pos_promotion_channels to authenticated;
grant select on public.pos_sale_promotions to authenticated;

-- ---------------------------------------------------------------------
-- Completing a sale that a promotion is running on
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0255 for two changes, both of them about the
-- moment the money is decided.
--
-- The first is a refresh before anything is measured. A bill parked at
-- ten to eleven and settled at five past is settled outside the happy
-- hour; the till's screen may say otherwise and the till's screen is
-- not what charges the customer. It also closes the case where nothing
-- ever refreshed — a kiosk order, an offline sale landing hours later,
-- a bill a waiter never reopened.
--
-- The second is that the invoice header's discount now names all three
-- reductions rather than two, and this one is load-bearing rather than
-- descriptive. `post_sales_document_internal` derives the credit side
-- from the lines less the header discount and checks it against the
-- debit side, which is the invoice total. Leave the promotion out and
-- the two disagree by exactly what it took off: a bill for 60.00 of
-- food charged at 55.00 raises
--
--     Journal does not balance: debits 55.00, credits 60.00
--
-- and the sale fails at the counter. `prepare_einvoice` maps the same
-- field to the MyInvois total discount, so the same term is also what
-- keeps an e-Invoice's lines adding up to its total.
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
  perform app.pos_settle_loyalty(p_sale, round(v_sale.total_amount + v_adj, 2));

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

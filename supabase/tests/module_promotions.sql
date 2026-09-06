-- =====================================================================
-- iAkauntan :: a price that is not the price
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/module_promotions.sql
--
-- 0548 lets a platform operator say a module costs less than the price
-- list says, for a while, or for one customer, or for the first thirty
-- days after somebody switches it on. Everything here is money coming
-- off an invoice, so the arithmetic is asserted at the edges rather
-- than in the middle: the last day of a trial and the day after it,
-- the first and last day of a window, and the month a promotion opens
-- halfway through.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A fixed month with thirty-one days, so "twelve days of thirty-one"
-- is a number this file can name rather than one it has to compute
-- alongside the code it is checking.
create or replace function pg_temp.jan()
returns date language sql immutable as $$ select date '2026-01-01' $$;

create or replace function pg_temp.held(
  p_org uuid, p_code text, p_from timestamptz, p_until timestamptz default null)
returns void language sql as $$
  insert into public.org_modules
    (org_id, module_code, is_enabled, enabled_at, expires_at)
  values (p_org, p_code, true, p_from, p_until)
  on conflict (org_id, module_code) do update
     set is_enabled = true, enabled_at = excluded.enabled_at,
         expires_at = excluded.expires_at;
$$;

create or replace function pg_temp.promo(
  p_name text, p_kind text,
  p_module text default 'multi_company',
  p_org uuid default null,
  p_trial_days integer default null,
  p_percent numeric default null,
  p_fixed numeric default null,
  p_from date default date '2020-01-01',
  p_to date default null,
  p_active boolean default true)
returns uuid language sql as $$
  insert into public.module_promotions
    (name, kind, module_code, org_id, trial_days, percent_off, fixed_price,
     starts_on, ends_on, is_active)
  values (p_name, p_kind, p_module, p_org, p_trial_days, p_percent, p_fixed,
          p_from, p_to, p_active)
  returning id;
$$;

create or replace function pg_temp.amount_for(
  p_org uuid, p_code text, p_month date default null)
returns numeric language sql as $$
  select d.amount
    from app.module_days_in_month(p_org, coalesce(p_month, pg_temp.jan())) d
   where d.module_code = p_code;
$$;

create or replace function pg_temp.promo_on(
  p_org uuid, p_code text, p_month date default null)
returns text language sql as $$
  select d.promotion
    from app.module_days_in_month(p_org, coalesce(p_month, pg_temp.jan())) d
   where d.module_code = p_code;
$$;

-- What one day costs, which is where a trial's edges are.
create or replace function pg_temp.price_on(
  p_org uuid, p_day date, p_started date, p_code text default 'multi_company')
returns numeric language sql as $$
  select price from app.module_price_on(p_org, p_code, p_day, p_started);
$$;

do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_price  numeric;
  v_start  timestamptz := timestamptz '2026-01-01 09:00+08';
  v_id     uuid;
  v_inv    uuid;
  v_desc   text;
  v_sub    numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Promosi Sdn Bhd', array['crm']);
  perform pg_temp.allow_many_companies();
  v_other := pg_temp.test_org('Syarikat Lain Sdn Bhd', array['crm']);

  select monthly_price into v_price
    from public.platform_modules where code = 'multi_company';
  perform pg_temp.check_true('the add-on under test carries a price',
    v_price > 0);

  -- Held from the first, all month, in both companies.
  perform pg_temp.held(v_org, 'multi_company', v_start);
  perform pg_temp.held(v_other, 'multi_company', v_start);

  perform pg_temp.check_eq('with no promotion the month is the list price',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);
  perform pg_temp.check_true('and no promotion is named',
    pg_temp.promo_on(v_org, 'multi_company') is null);

  -- What is on the bill at all, before any promotion touches it. Both
  -- of these are 0489's rules; the day-by-day pricing below rewrote
  -- the query that holds them, so they are asserted here rather than
  -- taken on trust.
  perform pg_temp.held(v_org, 'chat', timestamptz '2025-11-04 09:00+08');
  perform pg_temp.check_true('a module that costs nothing is not on the bill',
    pg_temp.amount_for(v_org, 'chat') is null);

  -- Switched on on the last day of the month: one day, not none. The
  -- month's last day is an edge on both sides of the arithmetic --
  -- whether the module counts as held this month at all, and whether a
  -- single-day holding survives being grouped.
  perform pg_temp.held(v_org, 'multi_company',
                       timestamptz '2026-01-31 09:00+08');
  perform pg_temp.check_eq(
    'a module switched on on the last day is charged for that day',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 1 / 31, 2));
  perform pg_temp.held(v_org, 'multi_company', v_start);

  -- ------------------------------------------------------------------
  -- 1. The trial period
  -- ------------------------------------------------------------------
  -- Thirty days free from the day the company switched it on. The
  -- company above started on 1 January, so days 1..30 are free and the
  -- 31st is charged.
  v_id := pg_temp.promo('Thirty days on us', 'trial', p_trial_days => 30);

  perform pg_temp.check_eq('the first day of a trial is free',
    pg_temp.price_on(v_org, date '2026-01-01', date '2026-01-01'), 0);
  perform pg_temp.check_eq('the thirtieth day is still free',
    pg_temp.price_on(v_org, date '2026-01-30', date '2026-01-01'), 0);
  perform pg_temp.check_eq('and the thirty-first is not',
    pg_temp.price_on(v_org, date '2026-01-31', date '2026-01-01'), v_price);

  -- One day of thirty-one at the list price.
  perform pg_temp.check_eq(
    'a month covered by a thirty-day trial is billed for the day past it',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 1 / 31, 2));
  perform pg_temp.check_eq('and the line names the trial',
    pg_temp.promo_on(v_org, 'multi_company'), 'Thirty days on us');

  -- The trial counts from the company's own start day, not the
  -- promotion's. A company that switched it on on 20 January is inside
  -- its trial for the rest of the month.
  perform pg_temp.held(v_other, 'multi_company',
                       timestamptz '2026-01-20 09:00+08');
  perform pg_temp.check_true(
    'a company joining later still gets its own thirty days',
    pg_temp.amount_for(v_other, 'multi_company') is null
      or pg_temp.amount_for(v_other, 'multi_company') = 0);

  -- The sign-up window: a company already holding the module before the
  -- promotion opened is not handed a trial retrospectively.
  update public.module_promotions set starts_on = date '2026-01-10'
   where id = v_id;
  perform pg_temp.check_eq(
    'a company that switched it on before the promotion opened pays list',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);

  -- And the opening day itself is inside the offer. A company that
  -- signs up on the morning a promotion opens is exactly the company
  -- it was written for.
  perform pg_temp.check_eq(
    'a company that starts on the opening day is inside the offer',
    pg_temp.price_on(v_org, date '2026-01-10', date '2026-01-10'), 0);
  perform pg_temp.check_eq('and one that started the day before is not',
    pg_temp.price_on(v_org, date '2026-01-10', date '2026-01-09'), v_price);

  update public.module_promotions set starts_on = date '2020-01-01'
   where id = v_id;

  -- ------------------------------------------------------------------
  -- 2. Unlimited use
  -- ------------------------------------------------------------------
  update public.module_promotions set is_active = false where id = v_id;
  v_id := pg_temp.promo('On the house', 'free');

  perform pg_temp.check_eq('a module given away costs nothing all month',
    pg_temp.amount_for(v_org, 'multi_company'), 0);
  perform pg_temp.check_eq('and the line still names why',
    pg_temp.promo_on(v_org, 'multi_company'), 'On the house');

  -- The window's edges, both inclusive: a promotion is on for the whole
  -- of the day it starts and the whole of the day it ends.
  update public.module_promotions
     set starts_on = date '2026-01-10', ends_on = date '2026-01-20'
   where id = v_id;
  perform pg_temp.check_eq('a promotion is off the day before it opens',
    pg_temp.price_on(v_org, date '2026-01-09', date '2026-01-01'), v_price);
  perform pg_temp.check_eq('on for the whole of its first day',
    pg_temp.price_on(v_org, date '2026-01-10', date '2026-01-01'), 0);
  perform pg_temp.check_eq('on for the whole of its last day',
    pg_temp.price_on(v_org, date '2026-01-20', date '2026-01-01'), 0);
  perform pg_temp.check_eq('and off the day after',
    pg_temp.price_on(v_org, date '2026-01-21', date '2026-01-01'), v_price);

  -- Eleven free days of thirty-one, twenty charged.
  perform pg_temp.check_eq(
    'a promotion running the 10th to the 20th splits the month around it',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 20 / 31, 2));

  -- Switched off, it stops applying at once.
  update public.module_promotions
     set is_active = false, starts_on = date '2020-01-01', ends_on = null
   where id = v_id;
  perform pg_temp.check_eq('a promotion switched off is not applied',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);

  -- ------------------------------------------------------------------
  -- 3. One company's promotion is not another's
  -- ------------------------------------------------------------------
  v_id := pg_temp.promo('Agreed with them', 'free', p_org => v_other);
  perform pg_temp.check_eq('a promotion addressed to one company reaches it',
    pg_temp.amount_for(v_other, 'multi_company'), 0);
  perform pg_temp.check_eq('and not the company next to it',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);
  update public.module_promotions set is_active = false where id = v_id;

  -- ------------------------------------------------------------------
  -- 4. A percentage, a fixed price, and the cheapest of them
  -- ------------------------------------------------------------------
  v_id := pg_temp.promo('Quarter off', 'percent_off', p_percent => 25);
  perform pg_temp.check_eq('a quarter off is three quarters of the price',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 0.75, 2));

  -- A second promotion, dearer than the first, must not displace it.
  perform pg_temp.promo('Ten off', 'percent_off', p_percent => 10);
  perform pg_temp.check_eq(
    'the cheapest promotion the company qualifies for is the one applied',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 0.75, 2));
  perform pg_temp.check_eq('and it is the one named',
    pg_temp.promo_on(v_org, 'multi_company'), 'Quarter off');

  -- A fixed price above the list price is a pricing mistake, not a
  -- promotion. It never raises a bill.
  perform pg_temp.promo('Wrong way round', 'fixed_price',
                        p_fixed => v_price + 100);
  perform pg_temp.check_eq('a promotion never charges more than the price list',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 0.75, 2));

  -- A fixed price under it does apply, and beats the percentage.
  perform pg_temp.promo('Flat ten', 'fixed_price', p_fixed => 10);
  perform pg_temp.check_eq('a fixed price under the list price is charged',
    pg_temp.amount_for(v_org, 'multi_company'), 10);

  -- To the sen. A fixed price is a price, and a price rounded to the
  -- ringgit is fifty sen a month of somebody else's money.
  update public.module_promotions set fixed_price = 19.50
   where name = 'Flat ten';
  perform pg_temp.check_eq('a fixed price is charged to the sen',
    pg_temp.amount_for(v_org, 'multi_company'), 19.50);

  update public.module_promotions set is_active = false
   where org_id is null or org_id = v_org;

  -- ------------------------------------------------------------------
  -- 4b. A promotion that takes nothing off is not a promotion
  -- ------------------------------------------------------------------
  -- The price is the lower of the list and the promotion, so a
  -- promotion at the list price changes no invoice. It must not be
  -- NAMED either: a line that says "Quarter off" beside the ordinary
  -- price is a customer asking what the quarter was.
  -- Open through today as well as through the month under test: the
  -- offer on the settings screen is priced as at today, and a
  -- promotion whose window closed months ago would make the two
  -- assertions below pass by not applying at all.
  perform pg_temp.promo('Same as it ever was', 'fixed_price',
                        p_fixed => v_price, p_to => date '2099-12-31');
  perform pg_temp.check_eq('a promotion at the list price charges the list',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);
  perform pg_temp.check_true('and is not named on the line',
    pg_temp.promo_on(v_org, 'multi_company') is null);
  perform pg_temp.check_true('nor on the offer, with its kind or its end',
    not exists (
      select 1 from public.org_module_surface(v_org) s
       where s.module_code = 'multi_company'
         and (s.promotion is not null or s.promo_kind is not null
              or s.promo_until is not null)));

  -- The same rule where the list price is nothing at all. A trial on a
  -- module that was already free takes nothing off, so the offer must
  -- not say "free for 30 days" as though it were doing something.
  perform pg_temp.promo('Free thing, free trial', 'trial',
                        p_module => 'chat', p_trial_days => 30);
  perform pg_temp.check_true(
    'a trial on a module that costs nothing is not announced',
    not exists (
      select 1 from public.org_module_surface(v_org) s
       where s.module_code = 'chat'
         and (s.promotion is not null or s.promo_days is not null)));

  update public.module_promotions set is_active = false
   where org_id is null or org_id = v_org;

  -- ------------------------------------------------------------------
  -- 5. Every add-on at once
  -- ------------------------------------------------------------------
  -- A promotion with no module named is the launch offer: it applies to
  -- whatever the company holds.
  perform pg_temp.promo('Launch month', 'free', p_module => null);
  perform pg_temp.check_eq('a promotion naming no module reaches every add-on',
    pg_temp.amount_for(v_org, 'multi_company'), 0);

  -- And a core module is still not on the bill, promotion or not.
  perform pg_temp.check_true('the product itself is still not on the bill',
    not exists (
      select 1 from app.module_days_in_month(v_org, pg_temp.jan()) d
      join public.platform_modules m on m.code = d.module_code
     where m.is_core));

  update public.module_promotions set is_active = false;

  -- ------------------------------------------------------------------
  -- 6. What lands on the invoice
  -- ------------------------------------------------------------------
  perform pg_temp.promo('Quarter off', 'percent_off', p_percent => 25);
  v_inv := app.bill_org_modules(v_org, pg_temp.jan());
  perform pg_temp.check_true('a discounted month still raises an invoice',
    v_inv is not null);
  select description, subtotal into v_desc, v_sub
    from public.platform_invoices where id = v_inv;
  perform pg_temp.check_eq('the invoice is charged at the promotional price',
    v_sub, round(v_price * 0.75, 2));
  perform pg_temp.check_true('and the invoice line names the promotion',
    v_desc like '%(Quarter off)%');

  -- A month that came to nothing is no invoice at all, not one for
  -- RM 0.00 -- there is nothing to pay and nobody to chase.
  update public.module_promotions set kind = 'free', percent_off = null;
  perform pg_temp.check_true('a month given away raises no invoice',
    app.bill_org_modules(v_other, pg_temp.jan()) is null);

  -- ------------------------------------------------------------------
  -- 7. What the company is shown
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the running total for the month is net of the promotion',
    (public.module_charges(v_org, pg_temp.jan()) ->> 'subtotal')::numeric, 0);
  perform pg_temp.check_eq('and it says what the promotion saved',
    (public.module_charges(v_org, pg_temp.jan()) ->> 'saved')::numeric,
    v_price);

  perform pg_temp.check_eq(
    'the module on offer is priced at the promotion, not the list',
    (select s.promo_price from public.org_module_surface(v_org) s
      where s.module_code = 'multi_company'), 0);
  perform pg_temp.check_eq('and the offer names it',
    (select s.promotion from public.org_module_surface(v_org) s
      where s.module_code = 'multi_company'), 'Quarter off');

  -- ------------------------------------------------------------------
  -- 7b. The offer is priced for THIS company, not for a new one
  -- ------------------------------------------------------------------
  -- A trial on the offer means two different things depending on who
  -- is looking. For a module nobody holds it is "free for your first
  -- thirty days". For one this company switched on in January it is
  -- nothing at all -- their thirty days are long gone, and a screen
  -- that says "free for 30 days" beside a module they have been
  -- billed for since January is the product lying about its own
  -- invoice.
  update public.module_promotions set is_active = false;
  perform pg_temp.promo('Thirty days on us', 'trial', p_module => null,
                        p_trial_days => 30);

  perform pg_temp.check_eq(
    'a module nobody holds is offered at the trial price',
    (select s.promo_price from public.org_module_surface(v_org) s
      where s.module_code = 'legal'), 0);
  perform pg_temp.check_eq('and the offer says it is a trial',
    (select s.promo_kind from public.org_module_surface(v_org) s
      where s.module_code = 'legal'), 'trial');
  perform pg_temp.check_eq('and how long it runs',
    (select s.promo_days from public.org_module_surface(v_org) s
      where s.module_code = 'legal'), 30);

  perform pg_temp.check_true(
    'a module held since long before is not still on its trial',
    not exists (
      select 1 from public.org_module_surface(v_org) s
       where s.module_code = 'multi_company' and s.promotion is not null));
  perform pg_temp.check_eq('and is offered at the list price',
    (select s.promo_price from public.org_module_surface(v_org) s
      where s.module_code = 'multi_company'), v_price);
end $$;

-- ---------------------------------------------------------------------
-- 8. Who may write one
-- ---------------------------------------------------------------------
do $$
declare
  v_org       uuid;
  v_far       uuid;
  v_stranger  uuid;
  v_role   text;
  v_wrote  boolean;
  v_seen   integer;
  v_theirs integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Cuba Sdn Bhd', array['crm']);

  -- A company this user has nothing to do with. Not a second
  -- `test_org`: those belong to the same fixture user, who is a member
  -- of both, and "another company's promotion" would then be one this
  -- user is entitled to see -- an assertion that passes for the wrong
  -- reason.
  v_stranger := pg_temp.another_user('orang-lain-0548@iakauntan.test');
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Jauh Sdn Bhd', 'jauh-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_stranger)
  returning id into v_far;
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- One promotion of each reach, to read back from behind the policy.
  insert into public.module_promotions (name, kind, module_code)
  values ('Open to all', 'free', 'multi_company');
  insert into public.module_promotions (name, kind, module_code, org_id)
  values ('Agreed with them elsewhere', 'free', 'multi_company', v_far);

  -- An owner of a company is an administrator of it, and still not a
  -- platform operator. A company that could write its own promotion
  -- could set its own price.
  perform pg_temp.check_refused(
    'a company cannot give itself a promotion',
    format('select public.platform_save_promotion(null, %L, %L, %L, %L, 30)',
           'I would like this free', 'multi_company', v_org, 'trial'),
    '%platform administrator%', '42501');

  perform pg_temp.check_refused(
    'nor read the whole list through the console',
    'select public.platform_promotions()',
    '%platform administrator%', '42501');

  -- And not around the RPC either. The role has to be switched for
  -- this: the fixture session is the owner, and an owner is not
  -- subject to its own row-level security -- an assertion run without
  -- this passes whatever the policies say.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      insert into public.module_promotions (name, kind, org_id)
      values ('Free for us', 'free', v_org);
      v_wrote := true;
    exception when insufficient_privilege then v_wrote := false;
    end;

    -- What it may see: an offer addressed to everybody, because the
    -- settings screen has to be able to say why the price on it is
    -- lower than the price list. Not what another company was given,
    -- which is a commercial fact about somebody else.
    select count(*) into v_seen from public.module_promotions
     where name = 'Open to all';
    select count(*) into v_theirs from public.module_promotions
     where name = 'Agreed with them elsewhere';
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a company cannot write itself a promotion directly either',
    not v_wrote);
  perform pg_temp.check_eq('it may read an offer open to everybody',
    v_seen, 1);
  perform pg_temp.check_eq('and not one addressed to another company',
    v_theirs, 0);
end $$;

-- ---------------------------------------------------------------------
-- 9. The shape of a promotion
-- ---------------------------------------------------------------------
-- A promotion whose number is missing is one that silently does
-- nothing, which is worse than one that refuses to be written.
do $$
begin
  perform pg_temp.check_refused(
    'a trial with no length is refused',
    'insert into public.module_promotions (name, kind) '
    'values (''Nothing at all'', ''trial'')',
    '%module_promotions_shape%', '23514');

  perform pg_temp.check_refused(
    'a discount of nothing is refused',
    'insert into public.module_promotions (name, kind, percent_off) '
    'values (''Zero off'', ''percent_off'', 0)',
    '%module_promotions_shape%', '23514');

  perform pg_temp.check_refused(
    'a window that ends before it starts is refused',
    'insert into public.module_promotions '
    '(name, kind, starts_on, ends_on) '
    'values (''Backwards'', ''free'', date ''2026-02-01'', date ''2026-01-01'')',
    '%module_promotions_window%', '23514');

  perform pg_temp.check_refused(
    'and a kind nobody prices is refused',
    'insert into public.module_promotions (name, kind) '
    'values (''Magic'', ''wishful'')',
    '%module_promotions_kind_check%', '23514');
end $$;

rollback;

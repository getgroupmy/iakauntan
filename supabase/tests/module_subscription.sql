-- =====================================================================
-- iAkauntan :: the month the modules cost
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/module_subscription.sql
--
-- `platform_modules.monthly_price` has been on screen since 0292 and
-- was charged by nothing. 0488 turned that from an omission into a
-- promise -- its confirmation names the price and says it starts today
-- -- so 0489 writes the invoice that keeps it.
--
-- What is asserted here is the arithmetic and who is exempt from it:
-- a month is pro-rated by the days the module was actually on, core
-- modules are the product rather than an add-on, demo tenants are not
-- customers, and a second run of the same month writes nothing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The month under test is a fixed one with thirty-one days in it, so
-- "twelve days of thirty-one" is a number this file can name rather
-- than one it has to compute alongside the code it is checking.
create or replace function pg_temp.jan()
returns date language sql immutable as $$ select date '2026-01-01' $$;

-- Switch a module on, as at a moment, without going through
-- `set_own_module` -- which stamps `now()` and would make every
-- assertion here depend on the day CI ran.
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

create or replace function pg_temp.amount_for(p_org uuid, p_code text)
returns numeric language sql as $$
  select d.amount from app.module_days_in_month(p_org, pg_temp.jan()) d
   where d.module_code = p_code;
$$;

create or replace function pg_temp.days_for(p_org uuid, p_code text)
returns integer language sql as $$
  select d.days from app.module_days_in_month(p_org, pg_temp.jan()) d
   where d.module_code = p_code;
$$;

do $$
declare
  v_org     uuid;
  v_demo    uuid;
  v_bare    uuid;
  v_price   numeric;
  v_core    text;
  v_inv     uuid;
  v_again   uuid;
  v_row     public.platform_invoices;
  v_n       integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Not the whole catalogue: `test_org` hands out every module by
  -- default, and a company holding all of them has a bill this file
  -- would have to keep in step with the price list.
  v_org  := pg_temp.test_org('Syarikat Langganan Sdn Bhd', array['crm']);
  perform pg_temp.allow_many_companies();
  v_bare := pg_temp.test_org('Syarikat Kosong Sdn Bhd', array['crm']);

  -- A price to do arithmetic against, taken from the catalogue rather
  -- than typed here, so a change to the price list does not read as a
  -- broken assertion.
  select monthly_price into v_price
    from public.platform_modules where code = 'multi_company';
  perform pg_temp.check_true('the add-on under test carries a price',
    v_price > 0);

  -- ------------------------------------------------------------------
  -- The days
  -- ------------------------------------------------------------------
  -- On from before the month began: the whole month.
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2025-11-04 09:00+08');
  perform pg_temp.check_eq('a module held all month is charged the whole month',
    pg_temp.days_for(v_org, 'multi_company'), 31);
  perform pg_temp.check_eq('and the whole month is the whole price',
    pg_temp.amount_for(v_org, 'multi_company'), v_price);

  -- Switched on on the 20th: the 20th to the 31st inclusive.
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-01-20 14:30+08');
  perform pg_temp.check_eq(
    'a module switched on on the 20th is charged for twelve days',
    pg_temp.days_for(v_org, 'multi_company'), 12);
  perform pg_temp.check_eq('and it costs twelve thirty-firsts of the month',
    pg_temp.amount_for(v_org, 'multi_company'),
    round(v_price * 12 / 31, 2));

  -- Two in the morning in Kuala Lumpur is still the previous day in
  -- UTC, which is the time zone this server runs in. The day the
  -- customer agreed to is the Malaysian one.
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-01-20 02:00+08');
  perform pg_temp.check_eq(
    'switched on after midnight in Kuala Lumpur, it starts that day',
    pg_temp.days_for(v_org, 'multi_company'), 12);

  -- Switched off on the 20th: the day it lapses is not charged.
  perform pg_temp.held(v_org, 'multi_company',
    timestamptz '2025-11-04 09:00+08', timestamptz '2026-01-20 00:00+08');
  perform pg_temp.check_eq('and one switched off stops costing that day',
    pg_temp.days_for(v_org, 'multi_company'), 19);

  -- Switched on after the month ended: not this month's bill at all.
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-02-03 09:00+08');
  perform pg_temp.check_true('a module bought in February is not on January''s bill',
    pg_temp.amount_for(v_org, 'multi_company') is null);

  -- ------------------------------------------------------------------
  -- What is not an add-on
  -- ------------------------------------------------------------------
  select code into v_core from public.platform_modules
   where is_core order by code limit 1;
  perform pg_temp.check_true('the catalogue has a core module to test with',
    v_core is not null);

  -- Priced on purpose. Every core module is free today, which makes
  -- `not is_core` and `monthly_price > 0` the same filter and this
  -- assertion a no-op -- it passed against a build that had dropped
  -- the core rule entirely. Put a price on the General Ledger and the
  -- two filters come apart: what is asserted is that being the product
  -- keeps it off the bill, not that being free does.
  update public.platform_modules set monthly_price = 149
   where code = v_core;
  perform pg_temp.held(v_org, v_core, timestamptz '2025-11-04 09:00+08');
  perform pg_temp.check_true('the product itself is not on the bill',
    pg_temp.amount_for(v_org, v_core) is null);
  update public.platform_modules set monthly_price = 0 where code = v_core;

  -- ------------------------------------------------------------------
  -- The invoice
  -- ------------------------------------------------------------------
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-01-20 14:30+08');

  -- The platform is registered for SST at 8%.
  insert into public.platform_settings (key, value)
  values ('platform_issuer', jsonb_build_object(
    'name', 'Kabeer Holdings Sdn Bhd', 'sst_registered', true,
    'sst_rate', 8, 'invoice_prefix', 'KH'))
  on conflict (key) do update set value = excluded.value;

  v_inv := app.bill_org_modules(v_org, pg_temp.jan());
  perform pg_temp.check_true('a company holding an add-on is invoiced',
    v_inv is not null);
  select * into v_row from public.platform_invoices where id = v_inv;

  perform pg_temp.check_eq('the bill is the pro-rated amount',
    v_row.subtotal, round(v_price * 12 / 31, 2));
  perform pg_temp.check_eq('the SST on it is the platform''s rate',
    v_row.tax_amount, round(round(v_price * 12 / 31, 2) * 8 / 100, 2));
  perform pg_temp.check_eq('and the total is the two of them',
    v_row.total_amount, v_row.subtotal + v_row.tax_amount);
  perform pg_temp.check_true('the invoice says which month it is for',
    v_row.description like '%January 2026%');
  perform pg_temp.check_true('and how many days of it were charged',
    v_row.description like '%12/31 days%');
  perform pg_temp.check_true('it falls due in the month after the one billed',
    v_row.issue_date = date '2026-02-01');

  -- Idempotence. The scheduler runs on the first; a scheduler that runs
  -- twice, or a month re-run by hand, must not bill twice.
  v_again := app.bill_org_modules(v_org, pg_temp.jan());
  perform pg_temp.check_eq('running it again bills nothing new',
    v_again, v_inv);
  select count(*) into v_n from public.platform_invoices where org_id = v_org;
  perform pg_temp.check_eq('and there is still one invoice',
    v_n, 1);

  -- ------------------------------------------------------------------
  -- Who gets no invoice
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a company holding no add-ons gets no invoice',
    app.bill_org_modules(v_bare, pg_temp.jan()) is null);

  v_demo := pg_temp.test_org('Syarikat Demo Sdn Bhd', array['crm']);
  update public.organizations set is_demo = true where id = v_demo;
  perform pg_temp.held(v_demo, 'multi_company', timestamptz '2025-11-04 09:00+08');
  perform pg_temp.check_true('a demo company is not invoiced',
    app.bill_org_modules(v_demo, pg_temp.jan()) is null);

  -- ------------------------------------------------------------------
  -- No SST when the platform is not registered for it
  -- ------------------------------------------------------------------
  update public.platform_settings
     set value = value || jsonb_build_object('sst_registered', false)
   where key = 'platform_issuer';
  delete from public.platform_invoices where org_id = v_org;
  v_inv := app.bill_org_modules(v_org, pg_temp.jan());
  select * into v_row from public.platform_invoices where id = v_inv;
  perform pg_temp.check_eq(
    'and no SST at all when the platform is not registered',
    v_row.tax_amount, 0);
  perform pg_temp.check_eq('the rate on the invoice says so too',
    v_row.tax_rate, 0);
end $$;

-- ---------------------------------------------------------------------
-- The scheduler
-- ---------------------------------------------------------------------
-- `bill_the_month` bills the month that just ended, and the daily pass
-- calls it on the first. Asserted separately because it walks every
-- company in the database, so it has to run after the fixtures above
-- have been made rather than in the middle of making them.
do $$
declare
  v_org  uuid;
  v_demo uuid;
  v_n    integer;
  v_inv  integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Syarikat Berjadual Sdn Bhd', array['crm']);
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2025-11-04 09:00+08');

  -- Run as at the first of February: the month that just ended is
  -- January, which is the month the fixture was held through.
  v_n := app.bill_the_month(date '2026-02-01');
  perform pg_temp.check_true('the run bills at least the company set up for it',
    v_n >= 1);
  select count(*) into v_inv from public.platform_invoices
   where org_id = v_org and notes = 'modules:2026-01';
  perform pg_temp.check_eq('and that company has January''s invoice',
    v_inv, 1);

  -- The daily pass on the first does the same thing, which is what
  -- makes any of this actually happen.
  delete from public.platform_invoices where org_id = v_org;
  perform app.run_daily_jobs(date '2026-02-01');
  select count(*) into v_inv from public.platform_invoices
   where org_id = v_org and notes = 'modules:2026-01';
  perform pg_temp.check_eq('the daily pass on the first raises the bill',
    v_inv, 1);

  -- And on any other day it does not.
  delete from public.platform_invoices where org_id = v_org;
  perform app.run_daily_jobs(date '2026-02-02');
  select count(*) into v_inv from public.platform_invoices
   where org_id = v_org;
  perform pg_temp.check_eq('and on the second of the month it does not',
    v_inv, 0);
end $$;

-- ---------------------------------------------------------------------
-- The month in progress
-- ---------------------------------------------------------------------
-- The invoice arrives on the first. Until then an owner who switched
-- something on has agreed to a price and can see nothing, which is
-- 0488's gap moved a month later.
create or replace function pg_temp.charges(p_org uuid, p_month date)
returns jsonb language plpgsql as $$
begin
  return public.module_charges(p_org, p_month);
exception when others then return to_jsonb(SQLERRM);
end $$;

do $$
declare
  v_org   uuid;
  v_clerk uuid;
  v_price numeric;
  v_out   jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Syarikat Berjalan Sdn Bhd', array['crm']);
  select monthly_price into v_price
    from public.platform_modules where code = 'multi_company';
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-01-20 14:30+08');

  v_out := pg_temp.charges(v_org, pg_temp.jan());
  perform pg_temp.check_eq('the month in progress names its month',
    v_out ->> 'month', '2026-01-01');
  perform pg_temp.check_eq('and what it has cost so far',
    (v_out ->> 'subtotal')::numeric, round(v_price * 12 / 31, 2));
  perform pg_temp.check_eq('line by line, with the days on each',
    (v_out -> 'lines' -> 0 ->> 'days')::numeric, 12);
  perform pg_temp.check_eq('and the module it is for',
    v_out -> 'lines' -> 0 ->> 'module_code', 'multi_company');

  -- Holding nothing is an empty list and a zero, not an error and not
  -- a null: the screen has something to render either way.
  perform pg_temp.held(v_org, 'multi_company', timestamptz '2026-03-01 09:00+08');
  v_out := pg_temp.charges(v_org, pg_temp.jan());
  perform pg_temp.check_eq('a company holding nothing is shown a zero',
    (v_out ->> 'subtotal')::numeric, 0);
  perform pg_temp.check_eq('and an empty list rather than nothing at all',
    jsonb_array_length(v_out -> 'lines'), 0);

  v_clerk := pg_temp.another_user('kerani-0489@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accounts_clerk', 'active', now());
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_eq('a clerk is not shown what the company pays',
    pg_temp.charges(v_org, pg_temp.jan()) #>> '{}',
    'Only an administrator may see what the company is billed');

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-0489@iakauntan.test'));
  perform pg_temp.check_eq('nor is somebody outside the company',
    pg_temp.charges(v_org, pg_temp.jan()) #>> '{}',
    'Only an administrator may see what the company is billed');
end $$;

-- ---------------------------------------------------------------------
-- Switching off, through the door the company actually uses
-- ---------------------------------------------------------------------
-- The blocks above set `org_modules` directly, which is the only way to
-- put a fixture in a named month. This one goes through
-- `set_own_module`, because what it is asserting is what that function
-- leaves behind -- and 0488 left nothing: it cleared both dates, so a
-- module held from the 1st to the 26th vanished from the month it was
-- held in.
do $$
declare
  v_org   uuid;
  v_start timestamptz;
  v_row   public.org_modules;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Syarikat Tanggal Sdn Bhd', array['crm']);

  perform public.set_own_module(v_org, 'loyalty', true);
  select * into v_row from public.org_modules
   where org_id = v_org and module_code = 'loyalty';
  v_start := v_row.enabled_at;
  perform pg_temp.check_true('switching one on stamps the day it started',
    v_start is not null);

  -- Pressing Add again on a module already on must not move the start
  -- date: doing so on the 28th would make the first twenty-seven days
  -- of the month disappear off the bill.
  --
  -- Backdated first, and deliberately. `now()` is the transaction's
  -- start time and this whole file is one transaction, so a start date
  -- stamped by the call above and a start date restamped by the call
  -- below are the same timestamp to the microsecond -- the assertion
  -- passed against a build that restarted the month every time.
  v_start := timestamptz '2026-01-05 09:00+08';
  update public.org_modules set enabled_at = v_start
   where org_id = v_org and module_code = 'loyalty';
  perform public.set_own_module(v_org, 'loyalty', true);
  select * into v_row from public.org_modules
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_true(
    'adding a module that is already on does not restart the month',
    v_row.enabled_at = v_start);

  perform public.set_own_module(v_org, 'loyalty', false);
  select * into v_row from public.org_modules
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_true('switching it off leaves the day it started',
    v_row.enabled_at = v_start);
  perform pg_temp.check_true('and stamps the day it stopped',
    v_row.expires_at is not null);
  perform pg_temp.check_true('and it is not held any more',
    not app.has_module(v_org, 'loyalty'));

  -- The part-month. Held from the 1st and switched off on the 26th:
  -- twenty-five days, not nothing.
  update public.org_modules
     set enabled_at = timestamptz '2026-01-01 09:00+08',
         expires_at = timestamptz '2026-01-26 11:00+08'
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_eq(
    'a module switched off mid-month is still billed for the days it was on',
    pg_temp.days_for(v_org, 'loyalty'), 25);

  -- And switched on again, it starts again from today rather than from
  -- whenever it first was.
  perform public.set_own_module(v_org, 'loyalty', true);
  select * into v_row from public.org_modules
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_true('switched on again, it starts again',
    v_row.enabled_at > timestamptz '2026-01-26 11:00+08'
    and v_row.expires_at is null);
  perform pg_temp.check_true('and it is held once more',
    app.has_module(v_org, 'loyalty'));
end $$;

-- ---------------------------------------------------------------------
-- Who may run it
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a tenant cannot invoice itself',
    not has_function_privilege('authenticated',
      'app.bill_org_modules(uuid, date)', 'execute'));
  perform pg_temp.check_true('nor run the month for everybody',
    not has_function_privilege('authenticated',
      'app.bill_the_month(date)', 'execute'));
end $$;

rollback;

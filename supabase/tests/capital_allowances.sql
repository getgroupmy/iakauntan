-- =====================================================================
-- iAkauntan :: Schedule 3 capital allowances
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/capital_allowances.sql
--
-- `0664` produces the Schedule 3 working. Every number in it is
-- statutory arithmetic, so every number in it is asserted, and the
-- assertions are written so that MOVING a rate or a cap fails them.
--
-- The four that would be easiest to get wrong, and are each worth a
-- section:
--
--   1. **No apportionment.** An asset bought in December gets the same
--      allowances as one bought in January. `0084`'s accounting
--      depreciation pro-rates to the month, correctly, and reaching
--      for that here by analogy is the single likeliest mistake --
--      so there is an assertion whose whole job is to fail if somebody
--      does.
--   2. **The motor vehicle cap flows through everything.** Capping
--      qualifying expenditure is not enough: the disposal proceeds
--      have to be restricted in the same proportion, or the relief is
--      given with one hand and taken back with the other.
--   3. **A balancing charge cannot exceed what was claimed.** Selling
--      a written down asset for more than it cost is a capital gain,
--      not a clawback of allowances that were never given.
--   4. **Nothing is ever claimed past the qualifying expenditure.**
--      An asset four years into a 20/20 class is fully written down,
--      and a schedule that keeps giving it 20% a year takes the
--      residual negative.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- An asset in a class, without the ceremony. Returns its id.
create or replace function pg_temp.ca_asset(
  p_org      uuid,
  p_no       text,
  p_class    text,
  p_cost     numeric,
  p_acquired date,
  p_disposed date default null,
  p_proceeds numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code, disposal_date, disposal_proceeds,
     status)
  values
    (p_org, p_no, p_no, p_acquired, p_cost, 'straight_line', 60,
     p_class, p_disposed, p_proceeds,
     case when p_disposed is null then 'active' else 'disposed' end)
  returning id into v_id;
  return v_id;
end; $$;

-- One column of one asset's row, for a year of assessment.
create or replace function pg_temp.ca_figure(
  p_org uuid, p_year integer, p_asset uuid, p_column text)
returns numeric language plpgsql as $$
declare v numeric;
begin
  execute format(
    'select %I from public.capital_allowance_schedule($1, $2)'
    '  where asset_id = $3', p_column)
    into v using p_org, p_year, p_asset;
  return v;
end; $$;

-- ---------------------------------------------------------------------
-- The rates are the published ones, and nothing claims to be verified
-- ---------------------------------------------------------------------
do $$
declare v_rate numeric; v_count integer;
begin
  select initial_rate into v_rate
    from public.capital_allowance_classes where code = 'plant';
  perform pg_temp.check_eq('plant and machinery: initial 20%', v_rate, 0.20);
  select annual_rate into v_rate
    from public.capital_allowance_classes where code = 'plant';
  perform pg_temp.check_eq('plant and machinery: annual 14%', v_rate, 0.14);

  select annual_rate into v_rate
    from public.capital_allowance_classes where code = 'office';
  perform pg_temp.check_eq('office equipment: annual 10%', v_rate, 0.10);

  select annual_rate into v_rate
    from public.capital_allowance_classes where code = 'industrial_building';
  perform pg_temp.check_eq('industrial building: annual 3%', v_rate, 0.03);

  select cost_cap into v_rate
    from public.capital_allowance_classes where code = 'motor_restricted';
  perform pg_temp.check_eq('the restricted motor cap is RM100,000',
    v_rate, 100000);
  select cost_cap into v_rate
    from public.capital_allowance_classes where code = 'motor_200k';
  perform pg_temp.check_eq('and the higher one RM200,000', v_rate, 200000);

  select small_value_threshold into v_rate
    from public.capital_allowance_classes where code = 'small_value';
  perform pg_temp.check_eq('a small value asset is under RM2,000',
    v_rate, 2000);
  select aggregate_cap into v_rate
    from public.capital_allowance_classes where code = 'small_value';
  perform pg_temp.check_eq('and RM20,000 of them a year', v_rate, 20000);

  -- Seeded from published percentages rather than transcribed from the
  -- Act. `0025` uses the same flag for the payroll schedules and means
  -- the same thing by it: check before filing.
  select count(*) into v_count
    from public.capital_allowance_classes where is_verified;
  perform pg_temp.check_eq(
    'nothing seeded claims to have been checked against the Act',
    v_count, 0);

  -- Every class apportions nothing. See the header.
  select count(*) into v_count
    from public.capital_allowance_classes where apportion_first_year;
  perform pg_temp.check_eq(
    'and no class apportions the first year', v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- An ordinary asset, year by year
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_asset uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Mesin Sdn Bhd');

  -- RM10,000 of plant: 20% initial and 14% annual.
  v_asset := pg_temp.ca_asset(v_org, 'P-1', 'plant', 10000,
                              date '2024-03-15');

  perform pg_temp.check_eq('year one: initial allowance is 20%',
    pg_temp.ca_figure(v_org, 2024, v_asset, 'initial'), 2000);
  perform pg_temp.check_eq('year one: annual allowance is given too',
    pg_temp.ca_figure(v_org, 2024, v_asset, 'annual'), 1400);
  perform pg_temp.check_eq('year one: nothing claimed before it',
    pg_temp.ca_figure(v_org, 2024, v_asset, 'prior_claimed'), 0);
  perform pg_temp.check_eq('year one: residual is what is left',
    pg_temp.ca_figure(v_org, 2024, v_asset, 'residual'), 6600);

  perform pg_temp.check_eq('year two: no initial allowance again',
    pg_temp.ca_figure(v_org, 2025, v_asset, 'initial'), 0);
  perform pg_temp.check_eq('year two: the annual one continues',
    pg_temp.ca_figure(v_org, 2025, v_asset, 'annual'), 1400);
  perform pg_temp.check_eq('year two: prior is the first year''s 3,400',
    pg_temp.ca_figure(v_org, 2025, v_asset, 'prior_claimed'), 3400);
  perform pg_temp.check_eq('year two: residual',
    pg_temp.ca_figure(v_org, 2025, v_asset, 'residual'), 5200);

  -- 2,000 initial plus 1,400 a year. By 2029 five annual allowances
  -- have been given -- 9,000 in all -- and 1,000 is left, so 2029 must
  -- give exactly 1,000 rather than a sixth full 1,400.
  perform pg_temp.check_eq(
    'the last year gives only what is left, not a full 14%',
    pg_temp.ca_figure(v_org, 2029, v_asset, 'annual'), 1000);
  perform pg_temp.check_eq('and the residual lands on nothing',
    pg_temp.ca_figure(v_org, 2029, v_asset, 'residual'), 0);
  perform pg_temp.check_eq(
    'a year later there is nothing left to give',
    pg_temp.ca_figure(v_org, 2030, v_asset, 'annual'), 0);
  perform pg_temp.check_eq('and the residual does not go negative',
    pg_temp.ca_figure(v_org, 2030, v_asset, 'residual'), 0);
  -- The claim over the asset's whole life is the cost and not a sen
  -- more. This is the assertion that catches an off-by-one in the
  -- elapsed-years arithmetic, which the year-by-year figures above
  -- would let through if they were all wrong in the same direction.
  perform pg_temp.check_eq(
    'and nothing over its life exceeds what it cost',
    pg_temp.ca_figure(v_org, 2030, v_asset, 'prior_claimed'), 10000);
end $$;

-- ---------------------------------------------------------------------
-- December is January
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_january uuid; v_december uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Bulan Tak Kira Sdn Bhd');

  v_january  := pg_temp.ca_asset(v_org, 'J-1', 'plant', 10000,
                                 date '2024-01-02');
  v_december := pg_temp.ca_asset(v_org, 'D-1', 'plant', 10000,
                                 date '2024-12-31');

  -- THE ONE. Capital allowances are not apportioned for the part of a
  -- year an asset was owned; an asset in use at the end of the basis
  -- period gets the full year. `0084`'s accounting depreciation DOES
  -- pro-rate, correctly, and reaching for `app.months_held` here by
  -- analogy would make the December figure a twelfth of the January
  -- one. This assertion exists to fail if anybody does that.
  perform pg_temp.check_eq(
    'an asset bought on the last day of the year gets a full initial allowance',
    pg_temp.ca_figure(v_org, 2024, v_december, 'initial'),
    pg_temp.ca_figure(v_org, 2024, v_january, 'initial'));
  perform pg_temp.check_eq(
    'and a full annual allowance with it',
    pg_temp.ca_figure(v_org, 2024, v_december, 'annual'),
    pg_temp.ca_figure(v_org, 2024, v_january, 'annual'));
  perform pg_temp.check_eq('which is the whole 20%',
    pg_temp.ca_figure(v_org, 2024, v_december, 'initial'), 2000);
end $$;

-- ---------------------------------------------------------------------
-- The motor vehicle restriction
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_car uuid; v_van uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kereta Mahal Sdn Bhd');

  -- RM300,000, restricted to RM100,000.
  v_car := pg_temp.ca_asset(v_org, 'C-1', 'motor_restricted', 300000,
                            date '2024-06-01');

  perform pg_temp.check_eq('the cost is still the cost',
    pg_temp.ca_figure(v_org, 2024, v_car, 'cost'), 300000);
  perform pg_temp.check_eq(
    'but only RM100,000 of it qualifies',
    pg_temp.ca_figure(v_org, 2024, v_car, 'qualifying'), 100000);
  perform pg_temp.check_eq(
    'so the initial allowance is 20% of the CAP, not of the cost',
    pg_temp.ca_figure(v_org, 2024, v_car, 'initial'), 20000);
  perform pg_temp.check_eq('and the annual one likewise',
    pg_temp.ca_figure(v_org, 2024, v_car, 'annual'), 20000);

  -- A vehicle under the cap is not touched by it.
  v_van := pg_temp.ca_asset(v_org, 'V-1', 'motor_restricted', 80000,
                            date '2024-06-01');
  perform pg_temp.check_eq(
    'a vehicle under the cap qualifies on the whole cost',
    pg_temp.ca_figure(v_org, 2024, v_van, 'qualifying'), 80000);
  perform pg_temp.check_eq('and is allowed 20% of it',
    pg_temp.ca_figure(v_org, 2024, v_van, 'initial'), 16000);
end $$;

-- ---------------------------------------------------------------------
-- Disposal: the balancing adjustment
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_asset uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Jual Balik Sdn Bhd');

  -- Bought 2024 for 10,000 plant; sold 2026 for 3,000.
  -- 2024 gave 3,400 and 2025 gave 1,400, so prior = 4,800 and the
  -- residual entering 2026 is 5,200. Sold for 3,000: a balancing
  -- ALLOWANCE of 2,200.
  v_asset := pg_temp.ca_asset(v_org, 'S-1', 'plant', 10000,
                              date '2024-01-10', date '2026-05-05', 3000);

  perform pg_temp.check_eq(
    'no annual allowance in the year of disposal',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'annual'), 0);
  perform pg_temp.check_eq(
    'selling below the residual gives a balancing allowance',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'balancing_allowance'), 2200);
  perform pg_temp.check_eq('and no charge with it',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'balancing_charge'), 0);
  perform pg_temp.check_eq('the residual is cleared out',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'residual'), 0);

  -- And the year after, it is gone from the schedule altogether.
  perform pg_temp.check_true(
    'an asset sold last year is not in this year''s schedule',
    pg_temp.ca_figure(v_org, 2027, v_asset, 'residual') is null);
end $$;

do $$
declare
  v_org uuid; v_asset uuid; v_charge numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Untung Jual Sdn Bhd');

  -- Same asset, sold in 2026 for 9,000 against a residual of 5,200:
  -- a balancing CHARGE of 3,800.
  v_asset := pg_temp.ca_asset(v_org, 'S-2', 'plant', 10000,
                              date '2024-01-10', date '2026-05-05', 9000);
  perform pg_temp.check_eq(
    'selling above the residual gives a balancing charge',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'balancing_charge'), 3800);
  perform pg_temp.check_eq('and no allowance with it',
    pg_temp.ca_figure(v_org, 2026, v_asset, 'balancing_allowance'), 0);

  -- THE CAP ON THE CHARGE. Sold for MORE than it cost: the excess over
  -- cost is a capital gain, not a clawback of allowances that were
  -- never given. The charge can never exceed what was claimed, which
  -- here is 4,800.
  v_asset := pg_temp.ca_asset(v_org, 'S-3', 'plant', 10000,
                              date '2024-01-10', date '2026-05-05', 25000);
  v_charge := pg_temp.ca_figure(v_org, 2026, v_asset, 'balancing_charge');
  perform pg_temp.check_eq(
    'a charge never exceeds the allowances actually given',
    v_charge, 4800);
end $$;

-- ---------------------------------------------------------------------
-- A capped asset sold: the restriction has to survive the disposal
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_car uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kereta Dijual Sdn Bhd');

  -- RM300,000 car, qualifying on RM100,000. 2024 gave 40,000, so the
  -- residual entering 2025 is 60,000. Sold for RM150,000.
  --
  -- Unrestricted, the proceeds would swamp the residual and produce a
  -- balancing charge of 90,000 on an asset that was only ever allowed
  -- 40,000 -- the restriction given by para 2 and taken straight back.
  -- Restricted in the same proportion the cost was, the proceeds are
  -- 150,000 x 100,000 / 300,000 = 50,000, giving a balancing ALLOWANCE
  -- of 10,000.
  v_car := pg_temp.ca_asset(v_org, 'C-9', 'motor_restricted', 300000,
                            date '2024-01-10', date '2025-07-01', 150000);

  perform pg_temp.check_eq(
    'the proceeds are restricted in the same proportion as the cost',
    pg_temp.ca_figure(v_org, 2025, v_car, 'balancing_allowance'), 10000);
  perform pg_temp.check_eq('so there is no charge',
    pg_temp.ca_figure(v_org, 2025, v_car, 'balancing_charge'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Small value assets, and the cap across all of them
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_one uuid; v_big uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Barang Kecil Sdn Bhd');

  v_one := pg_temp.ca_asset(v_org, 'K-1', 'small_value', 1500,
                            date '2024-02-01');
  perform pg_temp.check_eq(
    'a small value asset is written off in full in year one',
    pg_temp.ca_figure(v_org, 2024, v_one, 'initial'), 1500);
  perform pg_temp.check_eq('with no annual allowance beside it',
    pg_temp.ca_figure(v_org, 2024, v_one, 'annual'), 0);
  perform pg_temp.check_eq('and nothing left',
    pg_temp.ca_figure(v_org, 2024, v_one, 'residual'), 0);
  perform pg_temp.check_eq('nor anything in the year after',
    pg_temp.ca_figure(v_org, 2025, v_one, 'initial'), 0);

  -- At or above the threshold it is not a small value asset at all,
  -- whatever class somebody filed it under. RM2,000 exactly is NOT
  -- under RM2,000, and `<` versus `<=` is one asset's whole treatment.
  --
  -- And it gets NOTHING rather than the class's 100%. Written off in
  -- full because somebody picked the wrong class is the one direction
  -- this must never fail in; the residual then sits at the whole cost,
  -- which is loud on the schedule and is how it gets reclassified.
  v_big := pg_temp.ca_asset(v_org, 'K-2', 'small_value', 2000,
                            date '2024-02-01');
  perform pg_temp.check_eq(
    'exactly RM2,000 is not a small value asset and is not written off',
    pg_temp.ca_figure(v_org, 2024, v_big, 'initial'), 0);
  perform pg_temp.check_eq('nor given an annual allowance instead',
    pg_temp.ca_figure(v_org, 2024, v_big, 'annual'), 0);
  perform pg_temp.check_eq(
    'its residual is the whole cost, which is the signal to reclassify',
    pg_temp.ca_figure(v_org, 2024, v_big, 'residual'), 2000);
  perform pg_temp.check_eq(
    'and it is still nothing the year after, not a late claim',
    pg_temp.ca_figure(v_org, 2025, v_big, 'initial'), 0);
end $$;

do $$
declare
  v_org uuid; v_total numeric; v_i integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Banyak Barang Kecil Sdn Bhd');

  -- Twenty assets at RM1,500 is RM30,000, and the year's cap is
  -- RM20,000.
  for v_i in 1..20 loop
    perform pg_temp.ca_asset(v_org, 'B-' || lpad(v_i::text, 2, '0'),
      'small_value', 1500, date '2024-03-01' + v_i);
  end loop;

  select sum(claimed) into v_total
    from public.capital_allowance_schedule(v_org, 2024);
  perform pg_temp.check_eq(
    'the year''s small value claim is capped at RM20,000',
    v_total, 20000);

  -- And the cap is a cap, not a scaling: the earlier assets are
  -- allowed in full and the one that straddles the line takes what is
  -- left. Thirteen at 1,500 is 19,500, so the fourteenth gets 500.
  perform pg_temp.check_eq(
    'the asset that straddles the cap takes what is left of it',
    (select initial from public.capital_allowance_schedule(v_org, 2024)
      where asset_no = 'B-14'), 500);
  perform pg_temp.check_eq(
    'and the one after it gets nothing',
    (select initial from public.capital_allowance_schedule(v_org, 2024)
      where asset_no = 'B-15'), 0);
end $$;

-- ---------------------------------------------------------------------
-- What is out of the schedule, and who may read it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_land uuid; v_future uuid; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Tanah Dan Bangunan Sdn Bhd');

  -- No class is a real answer, not a gap. Land attracts no capital
  -- allowance and must not appear in the working at all.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'L-1', 'Freehold land', date '2024-01-01', 500000,
          'straight_line', 600, null)
  returning id into v_land;

  select count(*) into v_rows
    from public.capital_allowance_schedule(v_org, 2024)
   where asset_id = v_land;
  perform pg_temp.check_eq(
    'an asset with no class is out of the schedule entirely', v_rows, 0);

  -- Bought after the year in question.
  v_future := pg_temp.ca_asset(v_org, 'F-1', 'plant', 5000,
                               date '2026-01-01');
  select count(*) into v_rows
    from public.capital_allowance_schedule(v_org, 2024)
   where asset_id = v_future;
  perform pg_temp.check_eq(
    'and so is one bought after the year of assessment', v_rows, 0);
end $$;

do $$
declare
  v_org uuid; v_outsider uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Bukan Kau Punya Sdn Bhd');
  perform pg_temp.ca_asset(v_org, 'X-1', 'plant', 1000, date '2024-01-01');

  v_outsider := pg_temp.another_user('outsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_refused(
    'somebody outside the company cannot read its schedule',
    format('select * from public.capital_allowance_schedule(%L, 2024)',
           v_org),
    '%Insufficient privileges%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The rates are the platform's, not a tenant's
-- ---------------------------------------------------------------------
create temp table t_664 as
select pg_temp.test_user() as owner_user;
grant select on t_664 to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from t_664),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare v_rows integer; v_rate numeric;
begin
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');

  -- Readable: a company cannot compute its own schedule without them.
  select count(*) into v_rows from public.capital_allowance_classes;
  perform pg_temp.check_true('the rates are readable by anybody signed in',
    v_rows >= 8);

  -- Not writable. A company that could set its own capital allowance
  -- rates could write its own tax return.
  --
  -- An UPDATE is asserted by its EFFECT, not by a refusal: RLS does not
  -- raise on rows the USING clause hides, it silently updates none of
  -- them. `check_refused` here passed nothing and failed with "it was
  -- not refused at all", which is the right failure -- the update ran
  -- and changed zero rows.
  update public.capital_allowance_classes set annual_rate = 0.99;
  select annual_rate into v_rate
    from public.capital_allowance_classes where code = 'plant';
  perform pg_temp.check_eq('but a company owner cannot change them',
    v_rate, 0.14);

  -- An INSERT does raise, because WITH CHECK is about the row being
  -- written rather than about which rows are visible.
  perform pg_temp.check_refused(
    'nor invent a class of their own',
    'insert into public.capital_allowance_classes '
    '(code, label, initial_rate, annual_rate, effective_from) '
    'values (''mine'', ''Whatever I like'', 1, 1, date ''2024-01-01'')',
    '%row-level security%');
end $$;

reset role;

rollback;

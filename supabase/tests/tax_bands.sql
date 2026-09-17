-- =====================================================================
-- iAkauntan :: the income tax ladder
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_bands.sql
--
-- `app.annual_tax` is what every PCB figure in the payroll engine is
-- built on, and it reads the ten resident individual bands out of
-- `public.tax_brackets`. Those bands are the Income Tax Act's Schedule
-- 1 Part I, as amended for YA 2023, plus the s.6D rebate of RM 400 for
-- a chargeable income not exceeding RM 35,000.
--
-- Before this file, five of the ten bands could be changed and every
-- test in the directory still passed. Changing each rate in turn and
-- re-running showed which:
--
--   * 3%, 6%, 11% and 25% were caught, by the worked examples in
--     `payroll_run.sql` and `statutory.sql`;
--   * 19%, 26%, 28% and 30% were not, because no worked example earns
--     enough to reach them;
--   * 0% and 1% were not, and could not be: the whole of the tax owed
--     below RM 35,000 is smaller than the RM 400 rebate, so a rate
--     change down there produces no different answer from
--     `annual_tax`. What pins those two is the ladder assertion at the
--     end of this file, which ties each band's `cumulative_tax` to the
--     rate of the band beneath it — a rate that moves without its
--     cumulative moving is a table that no longer adds up.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- By name, not by id: the schedule is seeded with a fresh uuid every
-- time the database is built.
create or replace function pg_temp.tax_schedule()
returns uuid language sql stable as $$
  select id from public.statutory_schedules
   where name = 'Income tax scale, resident individual';
$$;

create or replace function pg_temp.tax_on(p_chargeable numeric)
returns numeric language sql stable as $$
  select app.annual_tax(p_chargeable, pg_temp.tax_schedule());
$$;

do $$
begin
  perform pg_temp.check_true('the resident scale is seeded',
    pg_temp.tax_schedule() is not null);
  perform pg_temp.check_eq('and it has ten bands',
    (select count(*)::integer from public.tax_brackets
      where schedule_id = pg_temp.tax_schedule()), 10);

  -- ------------------------------------------------------------------
  -- Below the rebate
  --
  -- s.6D gives an individual whose chargeable income does not exceed
  -- RM 35,000 a rebate of RM 400, which is more than the tax the first
  -- two bands can produce. Somebody earning under RM 35,000 pays
  -- nothing, and that is the single most common answer this function
  -- gives in a Malaysian payroll.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('nothing is due on nothing', pg_temp.tax_on(0), 0);
  perform pg_temp.check_eq('nor on a negative', pg_temp.tax_on(-5000), 0);
  perform pg_temp.check_eq('nor inside the first band',
    pg_temp.tax_on(3000), 0);
  perform pg_temp.check_eq('nor at the top of it', pg_temp.tax_on(5000), 0);
  -- 15,000 at 1% is 150, and the rebate is 400. A rate rise here shows
  -- up as soon as it takes the tax past the rebate, which is what this
  -- assertion is for.
  perform pg_temp.check_eq('nor at the top of the one per cent band',
    pg_temp.tax_on(20000), 0);
  -- And where it stops covering it. 150 + 10,000 x 3% is 450, against
  -- a rebate of 400, so RM 50 is due — the first tax a Malaysian
  -- employee actually pays, and the point the rebate runs out.
  perform pg_temp.check_eq('until the three per cent band outgrows it',
    pg_temp.tax_on(30000), 50.00);

  -- ------------------------------------------------------------------
  -- The cliff at 35,000
  --
  -- The rebate is all or nothing, so one ringgit of chargeable income
  -- costs RM 400.06 in tax. That is the statute, not a bug, and it is
  -- the number an employee notices.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the last income the rebate reaches',
    pg_temp.tax_on(35000), 200.00);
  perform pg_temp.check_eq('and the first that it does not',
    pg_temp.tax_on(35001), 600.06);

  -- ------------------------------------------------------------------
  -- Every band, at a point inside it
  -- ------------------------------------------------------------------
  -- 600 + 15,000 x 6%
  perform pg_temp.check_eq('six per cent to fifty thousand',
    pg_temp.tax_on(50000), 1500.00);
  -- 1,500 + 20,000 x 11%
  perform pg_temp.check_eq('eleven per cent to seventy thousand',
    pg_temp.tax_on(70000), 3700.00);
  -- 3,700 + 10,000 x 19%
  perform pg_temp.check_eq('nineteen per cent above seventy thousand',
    pg_temp.tax_on(80000), 5600.00);
  -- 3,700 + 30,000 x 19%
  perform pg_temp.check_eq('and to a hundred thousand',
    pg_temp.tax_on(100000), 9400.00);
  -- 9,400 + 300,000 x 25%
  perform pg_temp.check_eq('twenty-five per cent to four hundred thousand',
    pg_temp.tax_on(400000), 84400.00);
  -- 84,400 + 100,000 x 26%
  perform pg_temp.check_eq('twenty-six per cent above it',
    pg_temp.tax_on(500000), 110400.00);
  -- 84,400 + 200,000 x 26%
  perform pg_temp.check_eq('and to six hundred thousand',
    pg_temp.tax_on(600000), 136400.00);
  -- 136,400 + 400,000 x 28%
  perform pg_temp.check_eq('twenty-eight per cent above that',
    pg_temp.tax_on(1000000), 248400.00);
  -- 136,400 + 1,400,000 x 28%
  perform pg_temp.check_eq('and to two million',
    pg_temp.tax_on(2000000), 528400.00);
  -- 528,400 + 500,000 x 30%
  perform pg_temp.check_eq('thirty per cent on everything after',
    pg_temp.tax_on(2500000), 678400.00);

  -- Sen in the chargeable income are ignored before the rate is
  -- applied, which is LHDN's practice and the reason `annual_tax`
  -- floors. Without it a chargeable income carrying sen would pay tax
  -- on them at the marginal rate.
  perform pg_temp.check_eq('sen in the chargeable income are ignored',
    pg_temp.tax_on(100000.99), pg_temp.tax_on(100000));
end $$;

-- ---------------------------------------------------------------------
-- The ladder adds up
--
-- Each band's `cumulative_tax` is the tax owed on everything beneath
-- it, so it has to equal the band below's cumulative plus that band's
-- width at that band's rate. This is what pins the 0% and 1% bands,
-- whose rates `annual_tax` can never show on their own: change one and
-- the cumulative of the band above stops following from it.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_prev_cum  numeric := 0;
  v_prev_from numeric := 0;
  v_prev_to   numeric := 0;
  v_prev_rate numeric := null;
  v_first boolean := true;
begin
  for r in select * from public.tax_brackets
            where schedule_id = pg_temp.tax_schedule()
            order by sort_order
  loop
    if v_first then
      perform pg_temp.check_eq('the ladder starts at nothing owed',
        r.cumulative_tax, 0);
      perform pg_temp.check_eq('and at nothing chargeable',
        r.chargeable_from, 0);
      v_first := false;
    else
      perform pg_temp.check_eq(
        'band ' || r.sort_order || ' follows from the one below it',
        r.cumulative_tax,
        round(v_prev_cum
              + (floor(r.chargeable_from) - floor(v_prev_from))
                * v_prev_rate / 100, 2));
      -- And no gap and no overlap: one ringgit above a band's top is
      -- the next band's floor, or an income between them would find no
      -- band at all and be taxed as though it were below the first.
      perform pg_temp.check_eq(
        'band ' || r.sort_order || ' starts where the last one ended',
        floor(r.chargeable_from), v_prev_to);
    end if;
    v_prev_cum  := r.cumulative_tax;
    v_prev_from := r.chargeable_from;
    v_prev_to   := r.chargeable_to;
    v_prev_rate := r.rate_percent;
  end loop;

  perform pg_temp.check_true('and the top band is open ended',
    (select chargeable_to is null from public.tax_brackets
      where schedule_id = pg_temp.tax_schedule()
        and sort_order = 10));
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: a revision does not undo the year
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_estimate_revision_spread.sql
--
-- Measured before `0672` was written: a company estimating RM120,000
-- and revising to RM240,000 in the ninth month was handed twelve
-- instalments of RM20,000 starting in February -- eight of them
-- already past, none of them at a figure that was ever payable on the
-- date beside it.
--
-- s.107C(7). A revision spreads what is LEFT. Each instalment is
-- payable at whatever the estimate in force on its due date said, and
-- the revised total less everything already scheduled is divided over
-- the instalments that remain.
--
-- Four things are asserted and each was a way to get it wrong:
--
--   1. **The instalments already due do not move.** They were payable
--      at the old figure on dates that have passed.
--   2. **The schedule still totals the estimate in force.** A
--      re-spread that lost or gained a ringgit is the first thing
--      anybody notices.
--   3. **Two revisions compose.** The ninth-month one spreads over
--      what is left after the sixth-month one, not after the original.
--   4. **Downward never goes negative.** A negative instalment reads
--      as money coming back on a date when none is.
--
-- `revision_month` is set explicitly throughout. `revise_tax_estimate`
-- derives it from `app.today()`, so a fixture that let it do so would
-- assert something different every month and pass for most of the
-- year by accident.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.co(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.year_of(p_org uuid)
returns uuid language sql stable as $$
  select id from public.fiscal_years
   where org_id = p_org
     and end_date between date '2026-01-01' and date '2026-12-31'
   order by end_date limit 1;
$$;

-- Revise, and pin the month it was made in. See the header.
create or replace function pg_temp.revise_in(
  p_estimate uuid, p_amount numeric, p_month integer)
returns uuid language plpgsql as $$
declare v_new uuid;
begin
  v_new := public.revise_tax_estimate(p_estimate, p_amount);
  update public.tax_estimates set revision_month = p_month where id = v_new;
  return v_new;
end; $$;

-- ---------------------------------------------------------------------
-- An estimate nobody revised is unchanged
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_total numeric; v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Tetap Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  select count(*), sum(amount) into v_count, v_total
    from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('twelve instalments', v_count, 12);
  perform pg_temp.check_eq('of ten thousand each',
    (select amount from public.tax_estimate_schedule(v_est)
      where instalment_no = 1), 10000);
  perform pg_temp.check_eq('coming to the estimate', v_total, 120000);

  perform pg_temp.check_eq('and none of them set by a revision',
    (select count(*) from public.tax_estimate_schedule(v_est)
      where set_by_revision), 0);
end $$;

-- ---------------------------------------------------------------------
-- Revising upward in the ninth month
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_new uuid; v_total numeric; v_early numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Naik Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);
  v_new := pg_temp.revise_in(v_est, 240000, 9);

  -- The first instalment falls in month 2 of the basis period, so
  -- instalment i is in month i+1. A revision in month 9 governs
  -- instalment 8 and after; instalments 1 to 7 were payable at the
  -- old figure on dates that have passed and do not move.
  select amount into v_early from public.tax_estimate_schedule(v_new)
   where instalment_no = 7;
  perform pg_temp.check_eq('what was already due stays where it was',
    v_early, 10000);

  perform pg_temp.check_eq('and is not marked as revised',
    (select set_by_revision::text from public.tax_estimate_schedule(v_new)
      where instalment_no = 7), 'false');

  -- 240,000 less the 70,000 already scheduled, over the five that
  -- remain.
  perform pg_temp.check_eq('the balance is spread over what is left',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 8), 34000);
  perform pg_temp.check_eq('and so is the last',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 12), 34000);

  perform pg_temp.check_eq('the revised ones say so',
    (select count(*) from public.tax_estimate_schedule(v_new)
      where set_by_revision), 5);

  -- The cast. A re-spread that lost or gained a ringgit is the first
  -- thing anybody notices.
  select sum(amount) into v_total from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('and the schedule comes to the revised figure',
    v_total, 240000);
end $$;

-- ---------------------------------------------------------------------
-- Revising in the sixth month
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Enam Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);
  v_new := pg_temp.revise_in(v_est, 180000, 6);

  -- Month 6 is instalment 5. Four already due at 10,000 = 40,000;
  -- 180,000 - 40,000 = 140,000 over eight = 17,500.
  perform pg_temp.check_eq('four were already due',
    (select count(*) from public.tax_estimate_schedule(v_new)
      where not set_by_revision), 4);
  perform pg_temp.check_eq('and the fifth carries the new figure',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 5), 17500);

  select sum(amount) into v_total from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('totalling the revision', v_total, 180000);
end $$;

-- ---------------------------------------------------------------------
-- Two revisions compose
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_six uuid; v_nine uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Dua Kali Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);
  v_six := pg_temp.revise_in(v_est, 180000, 6);
  v_nine := pg_temp.revise_in(v_six, 240000, 9);

  -- The ninth-month revision spreads over what is left after the
  -- SIXTH-month one, not after the original. Instalments 1-4 at
  -- 10,000, 5-7 at 17,500 (from the first revision), and the rest
  -- carry 240,000 - 40,000 - 52,500 = 147,500 over five = 29,500.
  perform pg_temp.check_eq('the original four are untouched',
    (select amount from public.tax_estimate_schedule(v_nine)
      where instalment_no = 4), 10000);
  perform pg_temp.check_eq(
    'the first revision''s instalments keep ITS figure',
    (select amount from public.tax_estimate_schedule(v_nine)
      where instalment_no = 7), 17500);
  perform pg_temp.check_eq('and the second spreads what is left',
    (select amount from public.tax_estimate_schedule(v_nine)
      where instalment_no = 8), 29500);

  select sum(amount) into v_total
    from public.tax_estimate_schedule(v_nine);
  perform pg_temp.check_eq('coming to the latest figure', v_total, 240000);
end $$;

-- ---------------------------------------------------------------------
-- Revising downward never goes below nothing
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; v_total numeric; v_min numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Turun Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);
  -- Seventy thousand had already been scheduled by month 9; revising
  -- to fifty means the year owes less than has been billed.
  v_new := pg_temp.revise_in(v_est, 50000, 9);

  select min(amount) into v_min from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_true('no instalment is negative', v_min >= 0);

  perform pg_temp.check_eq('the remaining ones go to nil',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 9), 0);

  -- The schedule totals what was already scheduled, not the revised
  -- figure: LHDN does not refund through the instalments, and the
  -- excess is recovered at assessment instead.
  select sum(amount) into v_total from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq(
    'and the total is what was already billed, not the revision',
    v_total, 70000);
end $$;

-- ---------------------------------------------------------------------
-- A person's revision spreads the same way
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Runcit Pak Ali');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 60000);

  -- CP500: six instalments two months apart, first in month 3. A
  -- revision in month 6 governs instalment 3 (month 7) onward, so two
  -- are already due at 10,000 and 40,000 spreads over four.
  v_new := pg_temp.revise_in(v_est, 60000, 6);
  perform pg_temp.check_eq('six instalments still',
    (select count(*) from public.tax_estimate_schedule(v_new)), 6);
  perform pg_temp.check_eq('two already due at the old figure',
    (select count(*) from public.tax_estimate_schedule(v_new)
      where not set_by_revision), 2);
  perform pg_temp.check_eq('and the rest carry the balance',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 3), 10000);

  select sum(amount) into v_total from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('adding up to the revision', v_total, 60000);
end $$;

-- ---------------------------------------------------------------------
-- A figure that does not divide evenly still adds up
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Baki Sdn Bhd');
  -- 100,000 over twelve is 8,333.33 and change; revising to 175,000
  -- in month 9 spreads an amount that divides by five no better.
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 100000);
  select sum(amount) into v_total from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('an awkward figure still adds up',
    v_total, 100000);

  v_new := pg_temp.revise_in(v_est, 175000, 9);
  select sum(amount) into v_total from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('and so does an awkward revision of it',
    v_total, 175000);
end $$;

rollback;

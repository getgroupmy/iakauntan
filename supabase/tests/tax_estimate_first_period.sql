-- =====================================================================
-- iAkauntan :: a first basis period
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_estimate_first_period.sql
--
-- `0667` put `first_period` on every estimate and said it existed "so
-- the screen can say the rules differ rather than quietly applying
-- the wrong ones". Nothing read it. `0671` makes the two differences
-- real, and both are worth money:
--
--   1. **Three months from commencing operations**, not thirty days
--      before the basis period opens. For a company incorporated
--      partway through a year the ordinary date has usually already
--      passed, and showing it would be telling somebody they are late
--      for a deadline that was never theirs.
--   2. **A qualifying new SME owes NO instalments** for its first two
--      years of assessment. Twelve rows of demands for money on dates
--      nobody has to meet is worse than an empty list with a sentence
--      under it.
--
-- And the thing this file guards hardest:
--
--   3. **Unknown is not exempt.** Both figures are typed and either
--      may be null. Null schedules the instalments and SAYS the test
--      could not be taken, because skipping instalments that were due
--      is a penalty under s.107C(9) and paying ones that were not is
--      recoverable.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company that commenced operations in the September of a year that
-- opened in January -- so the ordinary CP204 date (30 days before
-- 1 January) is long past by the time it exists.
create or replace function pg_temp.new_co(p_name text)
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

-- ---------------------------------------------------------------------
-- The rules carry the first-period figures
-- ---------------------------------------------------------------------
do $$
declare v integer;
begin
  select first_period_filing_months into v
    from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('a new company has three months', v, 3);

  select first_period_exempt_years into v
    from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('and two years free of instalments', v, 2);

  -- CP500 has no equivalent relief: LHDN issues the estimate from the
  -- preceding assessment, and a person with no preceding assessment
  -- is simply not issued one yet.
  select first_period_exempt_years into v
    from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP500';
  perform pg_temp.check_eq('a person gets neither', v, 0);

  perform pg_temp.check_true('and has no first-period deadline of its own',
    (select first_period_filing_months is null
       from public.tax_estimate_rules
      where year_of_assessment = 2026 and form = 'CP500'));
end $$;

-- ---------------------------------------------------------------------
-- Three months from commencing, not thirty days before the year
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Baharu Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);

  -- An ordinary company: nothing changes.
  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('an ordinary estimate is not a first period',
    not fp.is_first_period);
  perform pg_temp.check_true('so it has no first-period deadline',
    fp.filing_due is null and not fp.filing_due_known);
  perform pg_temp.check_eq('and the ordinary one is thirty days before',
    fp.ordinary_filing_due::text, '2025-12-02');

  -- Now say it is one, and when the business began.
  update public.tax_estimates
     set first_period = true, commenced_on = date '2026-09-15'
   where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('it is now a first period', fp.is_first_period);
  -- Three months from 15 September is the 14th of December: the
  -- period runs from the 15th, so three months of it ends the day
  -- before the 15th comes round again.
  perform pg_temp.check_eq('due three months from commencing',
    fp.filing_due::text, '2026-12-14');
  perform pg_temp.check_true('and the question was answerable',
    fp.filing_due_known);

  -- The ordinary date is still reported, because seeing the two
  -- together is the point: the one this company would otherwise have
  -- been held to passed nine months before it existed.
  perform pg_temp.check_eq('beside the ordinary one it replaces',
    fp.ordinary_filing_due::text, '2025-12-02');
  perform pg_temp.check_true('which had already passed',
    fp.ordinary_filing_due < fp.filing_due);
end $$;

-- ---------------------------------------------------------------------
-- A first period with no commencement date answers nothing
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Tanpa Tarikh Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);
  update public.tax_estimates set first_period = true where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  -- A deadline computed from a date nobody supplied is a deadline
  -- somebody will trust. Null, and the screen asks for the date.
  --
  -- EQUIVALENT MUTANT, written down so the next person does not go
  -- hunting for a test that cannot exist: removing
  -- `e.commenced_on is not null` from the CASE that computes
  -- `filing_due` changes nothing and cannot be killed. Null propagates
  -- through the arithmetic -- `null + make_interval(...)` is null and
  -- `(null)::date` is null -- so the guard is redundant for the DATE.
  -- It is not redundant for `filing_due_known`, which is a boolean
  -- with no null to propagate, and that half is asserted below.
  perform pg_temp.check_true(
    'without a commencement date there is no deadline to give',
    fp.filing_due is null and not fp.filing_due_known);
  perform pg_temp.check_true('but it is still a first period',
    fp.is_first_period);
end $$;

-- ---------------------------------------------------------------------
-- A qualifying new SME owes no instalments
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Kecil Baharu Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);

  -- Twelve instalments before anybody says anything.
  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('an ordinary company pays twelve', v_rows, 12);

  update public.tax_estimates
     set first_period = true,
         commenced_on = date '2026-01-01',
         paid_up_capital = 500000,
         gross_business_income = 1200000
   where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('a small new company is exempt',
    fp.exempt_instalments);
  perform pg_temp.check_true('and the test was actually taken',
    fp.exemption_known);
  perform pg_temp.check_eq('for this year and the next',
    fp.exempt_until_ya, 2027);

  -- THE assertion. Twelve demands for money on dates nobody has to
  -- meet is worse than an empty list with a sentence under it.
  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('so it is handed no instalments at all',
    v_rows, 0);
end $$;

-- ---------------------------------------------------------------------
-- Too big to qualify
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Besar Baharu Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);

  -- Over the capital limit, which is 2.5 million in `company_tax_rates`
  -- -- READ from there rather than copied, so the two definitions of
  -- an SME cannot drift apart.
  update public.tax_estimates
     set first_period = true,
         commenced_on = date '2026-01-01',
         paid_up_capital = 3000000,
         gross_business_income = 1200000
   where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('too much capital is not exempt',
    not fp.exempt_instalments);
  perform pg_temp.check_true('and the test WAS taken -- it failed',
    fp.exemption_known);
  perform pg_temp.check_true('so nothing is exempt until any year',
    fp.exempt_until_ya is null);

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('and the instalments stand', v_rows, 12);

  -- The other limb. Half-known would have passed if only both-null
  -- were tested, which is the mistake `0665` already paid for once.
  update public.tax_estimates
     set paid_up_capital = 500000,
         gross_business_income = 90000000
   where id = v_est;
  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('too much income is not exempt either',
    not fp.exempt_instalments);
  perform pg_temp.check_true('and that test was taken too',
    fp.exemption_known);
end $$;

-- ---------------------------------------------------------------------
-- Unknown is NOT exempt
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Entah Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);
  update public.tax_estimates
     set first_period = true, commenced_on = date '2026-01-01'
   where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('with neither figure it is not exempt',
    not fp.exempt_instalments);
  perform pg_temp.check_true('and it says the test was not taken',
    not fp.exemption_known);

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq(
    'the instalments are scheduled -- the safe direction', v_rows, 12);

  -- One figure is not enough. `0665` had a mutant survive on exactly
  -- this: only both-null was tested, and a half-filled form handed the
  -- benefit to a company nobody had checked.
  update public.tax_estimates set paid_up_capital = 500000
   where id = v_est;
  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('capital alone does not take the test',
    not fp.exemption_known and not fp.exempt_instalments);

  update public.tax_estimates
     set paid_up_capital = null, gross_business_income = 1200000
   where id = v_est;
  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('nor does income alone',
    not fp.exemption_known and not fp.exempt_instalments);
end $$;

-- ---------------------------------------------------------------------
-- Not a first period, whatever else is filled in
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; fp record; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Lama Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);

  -- A fifteen-year-old company that happens to be small. The relief
  -- is for NEW companies, and a test that keyed only on size would
  -- hand it to half the register.
  update public.tax_estimates
     set first_period = false,
         paid_up_capital = 500000,
         gross_business_income = 1200000
   where id = v_est;

  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('a small OLD company is not exempt',
    not fp.exempt_instalments);
  perform pg_temp.check_true('and the test does not arise',
    not fp.exemption_known);

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('it pays its twelve', v_rows, 12);
end $$;

-- ---------------------------------------------------------------------
-- A revision keeps all of it
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; fp record; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Ubah Baharu Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);
  update public.tax_estimates
     set first_period = true,
         commenced_on = date '2026-09-15',
         paid_up_capital = 500000,
         gross_business_income = 1200000
   where id = v_est;

  v_new := public.revise_tax_estimate(v_est, 40000);

  -- The same class of bug `0670` fixed for the form. Without this the
  -- revised row takes the column defaults: the second estimate stops
  -- being a first period, its deadline reverts to one that passed
  -- nine months ago and its exemption disappears -- and the FIRST
  -- schedule was right, which is what makes it hard to see.
  select * into fp from public.tax_estimate_first_period(v_new);
  perform pg_temp.check_true('a revised first period is still one',
    fp.is_first_period);
  perform pg_temp.check_eq('with the same commencement date',
    fp.commenced_on::text, '2026-09-15');
  perform pg_temp.check_eq('and the same deadline',
    fp.filing_due::text, '2026-12-14');
  perform pg_temp.check_true('and the same exemption',
    fp.exempt_instalments);

  select count(*) into v_rows from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('so still no instalments', v_rows, 0);
end $$;

-- ---------------------------------------------------------------------
-- The calendar says the same thing as the estimate
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_due date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.new_co('Syarikat Kalendar Sdn Bhd');

  -- Before an estimate exists there is nothing to follow, and the
  -- calendar shows the ordinary date. Honest rather than convenient:
  -- nothing here can tell a newly incorporated company from one that
  -- has traded fifteen years and only just started keeping its books
  -- in this product.
  select due_date into v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and year_of_assessment = 2026;
  perform pg_temp.check_eq('with no estimate the calendar says the usual',
    v_due::text, '2025-12-02');

  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 24000);
  update public.tax_estimates
     set first_period = true, commenced_on = date '2026-09-15'
   where id = v_est;

  -- And once it does, the two screens agree. Two deadlines for one
  -- obligation is worse than either of them being wrong alone.
  select due_date into v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and year_of_assessment = 2026;
  perform pg_temp.check_eq('and then it follows the estimate',
    v_due::text, '2026-12-14');

  -- The Form C is untouched: seven months after the period closes,
  -- whether the company is new or not.
  select due_date into v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and year_of_assessment = 2026;
  perform pg_temp.check_eq('while the Form C keeps its own rule',
    v_due::text, '2027-07-31');
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: how much of a month a period is
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/months_between.sql
--
-- `app.months_between` multiplies every rent invoice and every strata
-- Charges and sinking-fund line. Two test files reached it before this
-- one — `property.sql` and `strata_preview.sql` — and between them they
-- exercised a whole month, a whole quarter and one part-month. Every
-- one of those is a period that either sits on calendar boundaries or
-- stays inside a single month, and the defect 0288 fixes was in neither
-- of those shapes: a period that starts part way through one month and
-- runs on into others.
--
-- The property the file is built around is the one that made the defect
-- undeniable without arguing about conventions: billing a quarter must
-- come to the same money as billing its three months one at a time.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Whole calendar months are whole numbers
--
-- 0163's own words: a quarter is 3, not 92/30.4. Asserted at three
-- lengths because a decomposition that quietly pro-rated every month
-- would still give 1 for a single one.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a month is one',
    app.months_between(date '2026-01-01', date '2026-01-31'), 1);
  perform pg_temp.check_eq('a quarter is three',
    app.months_between(date '2026-01-01', date '2026-03-31'), 3);
  perform pg_temp.check_eq('a year is twelve',
    app.months_between(date '2026-01-01', date '2026-12-31'), 12);
  perform pg_temp.check_eq('and a year that starts in the middle of one is too',
    app.months_between(date '2026-07-01', date '2027-06-30'), 12);

  -- February's length never shows up in a whole-month count, in a leap
  -- year or out of it.
  perform pg_temp.check_eq('February is one month in a leap year',
    app.months_between(date '2028-02-01', date '2028-02-29'), 1);
  perform pg_temp.check_eq('and one in an ordinary year',
    app.months_between(date '2026-02-01', date '2026-02-28'), 1);
end $$;

-- ---------------------------------------------------------------------
-- Part of a month is that part of it
--
-- Each month is pro-rated by its own length, which is why the same
-- number of days is worth different amounts in different months.
-- ---------------------------------------------------------------------
do $$
begin
  -- The figure `property.sql` has asserted since 0163, restated here
  -- against the function rather than through rent_preview.
  perform pg_temp.check_eq('seventeen of January''s thirty-one days',
    app.months_between(date '2026-01-15', date '2026-01-31'), 0.5484);
  perform pg_temp.check_eq('a single day of January',
    app.months_between(date '2026-01-01', date '2026-01-01'), 0.0323);

  -- Twenty-eight days is a whole month of February and not of January.
  perform pg_temp.check_eq('twenty-eight days of an ordinary February is all of it',
    app.months_between(date '2026-02-01', date '2026-02-28'), 1);
  perform pg_temp.check_eq('but of a leap February it is not',
    app.months_between(date '2028-02-01', date '2028-02-28'), 0.9655);
  perform pg_temp.check_eq('and of January it is less again',
    app.months_between(date '2026-01-01', date '2026-01-28'), 0.9032);
end $$;

-- ---------------------------------------------------------------------
-- A period that starts part way through and runs on
--
-- The shape 0288 fixes. It was the length of the whole period divided
-- by the length of the month it began in, so February and March were
-- priced at January's day rate and the count came out short.
-- ---------------------------------------------------------------------
do $$
begin
  -- 17/31 + 1 + 1. Was 76/31 = 2.4516.
  perform pg_temp.check_eq('mid-January to the end of March',
    app.months_between(date '2026-01-15', date '2026-03-31'), 2.5484);
  -- 1 + 1 + 15/31. Was 74/31 = 2.3871.
  perform pg_temp.check_eq('and the start of January to mid-March',
    app.months_between(date '2026-01-01', date '2026-03-15'), 2.4839);
  -- Both ends ragged: 17/31 + 1 + 15/31.
  perform pg_temp.check_eq('ragged at both ends',
    app.months_between(date '2026-01-15', date '2026-03-15'), 2.0323);

  -- A month's worth of days that does not sit on calendar boundaries is
  -- not one month, because February's days are worth more than
  -- January's. This is the case the fix changed with nothing asserting
  -- it either way: 17/31 + 14/28, where before it was 31/31.
  perform pg_temp.check_eq('thirty-one days across two months is not a month',
    app.months_between(date '2026-01-15', date '2026-02-14'), 1.0484);

  -- Across a year boundary, so the month walk is not doing arithmetic
  -- on the month number alone.
  perform pg_temp.check_eq('mid-November to the end of January',
    app.months_between(date '2026-11-15', date '2027-01-31'), 2.5333);
end $$;

-- ---------------------------------------------------------------------
-- The property that makes the rest of it follow
--
-- Whatever the pro-rating convention, a period must be worth the sum of
-- its parts. It is what proved the old behaviour wrong without needing
-- an argument about conventions — the application disagreed with itself
-- — and it is what any future change has to keep.
-- ---------------------------------------------------------------------
do $$
declare v_whole numeric; v_parts numeric;
begin
  v_whole := app.months_between(date '2026-01-15', date '2026-03-31');
  v_parts := app.months_between(date '2026-01-15', date '2026-01-31')
           + app.months_between(date '2026-02-01', date '2026-02-28')
           + app.months_between(date '2026-03-01', date '2026-03-31');
  perform pg_temp.check_eq('a quarter is worth its three months', v_whole, v_parts);

  -- Split somewhere that is not a month boundary and it is additive to
  -- within a rounding step, not exactly: each call rounds its own
  -- answer to four places, so two calls round twice. Stated as the
  -- bound rather than as equality, because equality is not true and a
  -- test that pretended otherwise would have to be loosened the first
  -- time somebody split a period on the 9th.
  --
  -- Exactness at month boundaries is the case that matters — it is the
  -- one a billing cycle produces — and it holds because a whole month
  -- contributes exactly 1 with nothing to round.
  v_whole := app.months_between(date '2026-01-15', date '2026-03-15');
  v_parts := app.months_between(date '2026-01-15', date '2026-02-09')
           + app.months_between(date '2026-02-10', date '2026-03-15');
  perform pg_temp.check_true('and split mid-month it is additive to the rounding',
    abs(v_whole - v_parts) <= 0.0001);
  perform pg_temp.check_true('which is a rounding step, not a month',
    abs(v_whole - v_parts) < 0.001);
end $$;

-- ---------------------------------------------------------------------
-- A period that ends before it starts
--
-- Both callers refuse one with 22023 before they reach this, so what
-- comes back is a floor rather than a meaning — but a negative number
-- of months multiplied by a rent is a credit note nobody asked for, so
-- it is worth knowing which.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a backwards period is worth nothing, not less than nothing',
    app.months_between(date '2026-03-31', date '2026-01-01'), 0);
  perform pg_temp.check_eq('and backwards inside one month likewise',
    app.months_between(date '2026-01-31', date '2026-01-01'), 0);
end $$;

-- ---------------------------------------------------------------------
-- What a tenant is actually billed
--
-- The arithmetic above is only worth asserting because of this: a
-- managing agent must not be able to change what somebody owes by
-- changing how often the button is pressed. Before 0288, the same
-- tenancy over the same quarter came to RM4,903.20 in one run and
-- RM5,096.80 in three.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sewa Suku Tahun Sdn Bhd');
  v_site uuid; v_tenant uuid; v_unit uuid;
  v_quarterly numeric; v_monthly numeric;
begin
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'Q1', 'Kedai Jalan Suku', 'non_strata') returning id into v_site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'TEN-Q', 'Penyewa pertengahan bulan', 'customer')
  returning id into v_tenant;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (v_org, v_site, 'LOT-1', 'shop') returning id into v_unit;

  -- Moves in on 15 January, at RM2,000 a month.
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (v_org, v_unit, v_tenant, 'T-Q', date '2026-01-15', date '2027-01-14',
          2000, 'active');

  select amount into v_quarterly
    from public.rent_preview(v_site, date '2026-01-01', date '2026-03-31');
  select sum(amount) into v_monthly from (
    select amount from public.rent_preview(v_site, date '2026-01-01', date '2026-01-31')
    union all
    select amount from public.rent_preview(v_site, date '2026-02-01', date '2026-02-28')
    union all
    select amount from public.rent_preview(v_site, date '2026-03-01', date '2026-03-31')
  ) x;

  perform pg_temp.check_eq('the quarter costs what its months cost',
    v_quarterly, v_monthly);
  perform pg_temp.check_eq('which is the back of January and two whole months',
    v_quarterly, 5096.80);
end $$;

rollback;

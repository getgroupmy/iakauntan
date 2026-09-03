-- =====================================================================
-- iAkauntan :: fixed asset and depreciation tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixed_assets.sql
--
-- Depreciation is the one charge in the ledger nobody enters by hand, so
-- nobody checks it either. A run that charges twice, or that stops
-- charging a month early, balances perfectly and is wrong for the rest
-- of the asset's life.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.fa_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- Months held, which decides every figure that follows
--
-- The month of acquisition counts as a whole month. Stated as an
-- assertion because the alternative — pro-rating by days — gives a
-- different first-year charge, and an auditor will eventually check
-- which convention this is.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the month of acquisition counts',
    app.months_held(date '2026-01-15', date '2026-01-31'), 1);
  perform pg_temp.check_eq('and the next one makes two',
    app.months_held(date '2026-01-15', date '2026-02-28'), 2);
  perform pg_temp.check_eq('a full year is twelve',
    app.months_held(date '2026-01-01', date '2026-12-31'), 12);
  perform pg_temp.check_eq('nothing before it was bought',
    app.months_held(date '2026-03-01', date '2026-01-31'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Straight line, and the idempotence the design turns on
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Straight Line Sdn Bhd');
  v_asset uuid; v_run uuid; v_entry uuid; r record;
begin
  -- RM 60,000 over five years is RM 1,000 a month.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, useful_life_months)
  values (v_org, 'FA-001', 'Delivery van', date '2026-01-01', 60000,
          'straight_line', 60)
  returning id into v_asset;

  select * into r from public.depreciation_preview(v_org, date '2026-03-31');
  perform pg_temp.check_eq('three months previewed', r.charge, 3000);
  perform pg_temp.check_eq('and the net book value with it',
    r.net_book_value, 57000);

  v_run := public.run_depreciation(v_org, date '2026-03-31');
  perform pg_temp.check_true('a run was posted', v_run is not null);
  perform pg_temp.check_eq('for what the preview promised',
    (select total_amount from public.depreciation_runs where id = v_run), 3000);

  select gl_entry_id into v_entry from public.depreciation_runs where id = v_run;
  perform pg_temp.check_eq('expense debited',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '6400'), 3000);
  perform pg_temp.check_eq('accumulated depreciation credited',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '1590'), 3000);

  -- The property that separates a depreciation run from a mistake.
  perform pg_temp.check_true('a second run at the same date charges nothing',
    public.run_depreciation(v_org, date '2026-03-31') is null);

  v_run := public.run_depreciation(v_org, date '2026-06-30');
  perform pg_temp.check_eq('and a later one charges only the difference',
    (select total_amount from public.depreciation_runs where id = v_run), 3000);
  perform pg_temp.check_eq('leaving six months accumulated',
    (select accumulated_depreciation from public.fixed_assets where id = v_asset),
    6000);
end $$;

-- ---------------------------------------------------------------------
-- It stops at cost less residual
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Fully Depreciated Sdn Bhd');
  v_asset uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
  values (v_org, 'FA-001', 'Old laptop', date '2026-01-01', 6000, 600,
          'straight_line', 12)
  returning id into v_asset;

  perform public.run_depreciation(v_org, date '2026-12-31');
  perform pg_temp.check_eq('depreciated to cost less residual',
    (select accumulated_depreciation from public.fixed_assets where id = v_asset),
    5400);

  perform pg_temp.check_true('and marked as finished',
    (select status = 'fully_depreciated' from public.fixed_assets where id = v_asset));

  perform public.create_fiscal_year(v_org, date '2027-01-01');
  perform pg_temp.check_true('a year later it has not gone further',
    public.run_depreciation(v_org, date '2027-12-31') is null);
end $$;

-- ---------------------------------------------------------------------
-- Reducing balance compounds monthly
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Reducing Sdn Bhd');
  v_asset uuid; v_accum numeric;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, rate_percent)
  values (v_org, 'FA-001', 'Machine', date '2026-01-01', 100000,
          'reducing_balance', 20)
  returning id into v_asset;

  perform public.run_depreciation(v_org, date '2026-12-31');
  select accumulated_depreciation into v_accum
    from public.fixed_assets where id = v_asset;

  -- 100,000 x (1 - 0.2/12)^12 leaves about RM 81,700, so roughly
  -- RM 18,300 of charge — less than a flat 20% because the base shrinks
  -- every month. Bracketed rather than fixed to the sen so a change of
  -- rounding does not read as a change of method.
  perform pg_temp.check_true('a year of reducing balance is under a flat 20%',
    v_accum > 18000 and v_accum < 18500);
end $$;

-- ---------------------------------------------------------------------
-- Disposal at a gain
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Disposal Sdn Bhd');
  v_asset uuid; v_entry uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, useful_life_months)
  values (v_org, 'FA-001', 'Van', date '2026-01-01', 60000, 'straight_line', 60)
  returning id into v_asset;

  perform public.run_depreciation(v_org, date '2026-06-30');
  -- Six months at RM 1,000 leaves a net book value of RM 54,000. Sold
  -- for RM 58,000, so a gain of RM 4,000.
  v_entry := public.dispose_fixed_asset(v_asset, date '2026-06-30', 58000);

  -- 4930, not 4920. 0156 gave disposals their own accounts: 4920 is
  -- Foreign Exchange Gain in the seeded chart, and a van sold at a
  -- profit was landing there — overstating the foreign exchange
  -- disclosure and hiding the disposal result inside it.
  perform pg_temp.check_eq('gain on disposal',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '4930'), 4000);
  perform pg_temp.check_eq('and none of it reached foreign exchange',
    (select count(*) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code in ('4920', '6500')), 0);
  perform pg_temp.check_eq('the asset comes off at cost',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '1510'), 60000);
  perform pg_temp.check_true('and it is marked disposed',
    (select status = 'disposed' from public.fixed_assets where id = v_asset));

  begin
    perform public.dispose_fixed_asset(v_asset, date '2026-07-31', 100);
    raise exception 'FAIL: the same asset was disposed of twice';
  exception when sqlstate '23514' then
    raise notice 'ok   an asset cannot be disposed of twice';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Disposal catches the depreciation up, and charges what it caught
--
-- Selling in June an asset last depreciated in December would otherwise
-- report six months of unrecognised charge as a gain on sale.
--
-- That much this file always asserted. What it did not assert, and what
-- 0156 fixes, is where the caught-up charge *went*. It was relieved from
-- accumulated depreciation without ever being charged to the profit and
-- loss: 1590 was debited 6,000 having been credited nothing, and the
-- 6,000 of depreciation never reached the expense account. Profit was
-- overstated by exactly the amount stranded on the balance sheet.
--
-- The assertions below are the pair that catches it. Measuring the loss
-- after catching up is necessary and was never sufficient — the loss
-- comes out right either way, because it was always computed from the
-- caught-up figure. What tells the two apart is the expense account and
-- the net of 1590.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Disposal Loss Sdn Bhd');
  v_asset uuid; v_entry uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, useful_life_months)
  values (v_org, 'FA-001', 'Van', date '2026-01-01', 60000, 'straight_line', 60)
  returning id into v_asset;

  -- Never depreciated, sold at the end of June for RM 50,000. Six months
  -- of charge is recognised first, leaving RM 54,000 and a loss of
  -- RM 4,000 — not RM 10,000.
  v_entry := public.dispose_fixed_asset(v_asset, date '2026-06-30', 50000);

  perform pg_temp.check_eq('the loss is measured after catching up',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '6510'), 4000);
  perform pg_temp.check_eq('and the accumulated charge comes off',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '1590'), 6000);

  -- The six months are charged, not merely relieved.
  perform pg_temp.check_eq('the catch-up reaches depreciation expense',
    (select coalesce(sum(l.debit) - sum(l.credit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '6400'), 6000);
  -- Nothing is left behind: accumulated depreciation was credited what
  -- it was debited, so the account is nil once the asset has gone.
  perform pg_temp.check_eq('and accumulated depreciation clears',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code = '1590'), 0);

  -- Which is the whole cost of owning it: RM 60,000 in, RM 50,000 back.
  perform pg_temp.check_eq('profit bears the whole cost of ownership',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code in ('6400', '6510')), 10000);

  -- And it is on the asset's record, where the schedule reads it from.
  perform pg_temp.check_eq('the catch-up is recorded as a charge',
    (select coalesce(sum(amount), 0) from public.depreciation_entries
      where org_id = v_org and asset_id = v_asset), 6000);
end $$;

-- ---------------------------------------------------------------------
-- Disposal on a run date charges nothing extra
--
-- The other side of the case above: when there is nothing to catch up,
-- nothing is invented. A stray run of nil would put an empty line in
-- every asset's history.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Disposal On Time Sdn Bhd');
  v_asset uuid; v_entry uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, useful_life_months)
  values (v_org, 'FA-001', 'Van', date '2026-01-01', 60000, 'straight_line', 60)
  returning id into v_asset;

  perform public.run_depreciation(v_org, date '2026-06-30');
  v_entry := public.dispose_fixed_asset(v_asset, date '2026-06-30', 54000);

  perform pg_temp.check_eq('one run, not two',
    (select count(*) from public.depreciation_runs where org_id = v_org), 1);
  perform pg_temp.check_eq('and one charge against the asset',
    (select count(*) from public.depreciation_entries
      where org_id = v_org and asset_id = v_asset), 1);
  perform pg_temp.check_eq('sold at book value, so neither gain nor loss',
    (select count(*) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code in ('4930', '6510')), 0);
  perform pg_temp.check_eq('accumulated depreciation still clears',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code = '1590'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('depreciation is closed to anon',
    not has_function_privilege('anon',
      'public.run_depreciation(uuid, date)', 'execute'));
  perform pg_temp.check_true('disposal too',
    not has_function_privilege('anon',
      'public.dispose_fixed_asset(uuid, date, numeric, uuid)', 'execute'));
  perform pg_temp.check_true('and the engine is internal',
    not has_function_privilege('authenticated',
      'app.accumulated_depreciation_at(public.fixed_assets, date)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- Reducing balance
--
-- Everything else in this file is straight line, so four things about
-- the other method could be changed with nothing failing: the base it
-- is charged on, the floor at the residual value, the floor at zero,
-- and what an asset is worth before it was bought. Found by changing
-- each and re-running.
--
-- Its own company, because the block above asserts that its company has
-- nothing left to depreciate a year on, and an asset still depreciating
-- in 2027 makes that false.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fa_org('Reducing Balance Sdn Bhd');
  v_rb  uuid;
begin
  -- RM 10,000 at 20% a year, compounded monthly at a twelfth of that,
  -- with RM 2,000 residual.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months, rate_percent)
  values (v_org, 'FA-RB', 'Compressor', date '2026-01-01', 10000, 2000,
          'reducing_balance', 120, 20)
  returning id into v_rb;
  -- Charged on cost, not on cost less residual. Under reducing balance
  -- the residual is a floor, not a smaller base: charging 20% of
  -- RM 8,000 would give RM 1,461.18 after a year and under-depreciate
  -- the asset for its whole life.
  perform pg_temp.check_eq('reducing balance is charged on cost',
    (select app.accumulated_depreciation_at(a, date '2026-12-31')
       from public.fixed_assets a where a.id = v_rb), 1826.48);
  -- And it stops at the residual. Compounding never reaches zero on its
  -- own -- thirty years of it comes to RM 9,976.43 on this asset, which
  -- is RM 1,976.43 more than the company may ever charge.
  perform pg_temp.check_eq('and never takes more than the depreciable amount',
    (select app.accumulated_depreciation_at(a, date '2056-01-01')
       from public.fixed_assets a where a.id = v_rb), 8000.00);
  perform pg_temp.check_eq('so the net book value floors at the residual',
    (select a.cost - app.accumulated_depreciation_at(a, date '2056-01-01')
       from public.fixed_assets a where a.id = v_rb), 2000.00);
  -- Before it was bought there is nothing to depreciate, which a
  -- schedule that starts before the acquisition will ask for.
  perform pg_temp.check_eq('nothing is charged before the asset existed',
    (select app.accumulated_depreciation_at(a, date '2025-06-30')
       from public.fixed_assets a where a.id = v_rb), 0);
  -- The month it arrived in is charged whole, which is the convention
  -- `months_held` implements and not an accident: an asset bought on
  -- the 1st and one bought on the 28th both carry January. Asserted so
  -- that a change to pro-rating by days is a decision somebody makes
  -- rather than one that slips in.
  perform pg_temp.check_eq('the month it arrived in is charged whole',
    (select app.accumulated_depreciation_at(a, date '2026-01-01')
       from public.fixed_assets a where a.id = v_rb), 166.67);
  perform pg_temp.check_eq('however late in that month it arrived',
    (select app.accumulated_depreciation_at(a, date '2026-01-31')
       from public.fixed_assets a where a.id = v_rb), 166.67);
  -- Never negative, whichever method. A negative accumulated
  -- depreciation is an asset worth more than it cost.
  perform pg_temp.check_eq('and no charge is ever negative',
    (select count(*)::integer from public.fixed_assets a,
            lateral (values (date '2025-01-01'), (date '2026-01-01'),
                            (date '2026-06-30'), (date '2056-01-01')) d(on_date)
      where a.org_id = v_org
        and app.accumulated_depreciation_at(a, d.on_date) < 0), 0);
end $$;

rollback;

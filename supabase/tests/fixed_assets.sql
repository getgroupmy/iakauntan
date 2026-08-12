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

  perform pg_temp.check_eq('gain on disposal',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '4920'), 4000);
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
-- Disposal catches the depreciation up first
--
-- Selling in June an asset last depreciated in December would otherwise
-- report six months of unrecognised charge as a gain on sale.
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
      where l.entry_id = v_entry and ac.code = '6500'), 4000);
  perform pg_temp.check_eq('and the accumulated charge comes off',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '1590'), 6000);
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

rollback;

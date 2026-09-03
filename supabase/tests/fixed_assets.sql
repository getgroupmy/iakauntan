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


-- ---------------------------------------------------------------------
-- The eleven a mutation sweep found
-- ---------------------------------------------------------------------
-- Twenty-seven one-line mutants of `dispose_fixed_asset` against seven
-- test files. Sixteen died on the first run, and they are the
-- arithmetic and the journal: the charge caught up to the day it left,
-- the book value, the gain or loss measured against book value and
-- posted to the right side, the accumulated depreciation written back,
-- the asset relieved at COST rather than at book value, the proceeds
-- banked, the catch-up recorded as a depreciation run tying to the
-- schedule.
--
-- The eleven that survived are the front door, the accounts chosen, and
-- the state -- the third function in a row with exactly this split, and
-- the reason it is now the first thing this programme looks at rather
-- than the last.
--
-- Two are worth naming beyond the list.
--
--   THE DATE. `p_date` is the day the asset left, and the journal takes
--   it. Replace it with app.today() and a van sold in March, entered in
--   April, depreciates to March and posts to April -- so the profit and
--   loss disagrees with the schedule behind it, and a locked period
--   does not stop it. Every sweep this session has found a date like
--   this.
--
--   THE BANK. p_bank_account_id says where the money went. Ignored,
--   every disposal lands in the current account, and the reconciliation
--   for the account that actually received it will never balance.
do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_asset  uuid;
  v_other  uuid;
  v_ac_van uuid;
  v_bank   uuid;
  v_bank_ac uuid;
  v_who    uuid;
  v_entry  uuid;
  v_msg    text;
  v_when   date := date '2026-03-31';
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Aset Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- A second bank account, so "where the money went" has two answers
  -- and naming one of them means something.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1125', 'Second account', 'asset', 'bank')
  returning id into v_bank_ac;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance)
  values (v_org, v_bank_ac, 'Disposal proceeds', 'CIMB', '800000000001',
          'MYR', 0, 0)
  returning id into v_bank;

  -- And an account of the asset's own, so "the asset's own account" has
  -- an answer that is not the default.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1515', 'Motor vehicles', 'asset', 'fixed_asset')
  returning id into v_ac_van;

  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months, asset_account_id)
  values (v_org, 'FA-SAPU-1', 'Delivery van', date '2026-01-01', 60000, 0,
          'straight_line', 60, v_ac_van)
  returning id into v_asset;

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.dispose_fixed_asset(gen_random_uuid(), v_when);
    raise exception 'an asset that does not exist was disposed of';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an asset that is not there is refused',
      v_msg like 'Asset % not found');
  end;

  begin
    perform public.dispose_fixed_asset(v_asset, date '2025-12-31');
    raise exception 'an asset was disposed of before it was bought';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'an asset cannot leave before it arrived',
      v_msg,
      'Asset FA-SAPU-1 was acquired on 2026-01-01, after the disposal '
      'date 2025-12-31');
  end;

  v_who := pg_temp.another_user('asset-viewer@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_who, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_who);
  begin
    perform public.dispose_fixed_asset(v_asset, v_when);
    raise exception 'somebody who may not post disposed of an asset';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('and not by somebody who may not post',
      v_msg, 'Insufficient privileges to post');
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ==================================================================
  -- 2. The chart has to have somewhere to put it
  --
  -- Both refusals reached with one fixture: rename 1510 and 1590 out of
  -- the way and the coalesce finds nothing. Without the check the
  -- failure arrives from inside create_gl_entry_internal, about a null
  -- account_id on a line nobody wrote by hand.
  -- ==================================================================
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
  values (v_org, 'FA-SAPU-2', 'Office chair', date '2026-01-01', 1200, 0,
          'straight_line', 60)
  returning id into v_other;

  update public.accounts set code = '1511-moved'
   where org_id = v_org and code = '1510';
  begin
    perform public.dispose_fixed_asset(v_other, v_when);
    raise exception 'an asset was disposed of with nowhere to relieve it';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'with no fixed asset account, the disposal refuses in words',
      v_msg,
      'No fixed asset (1510) or accumulated depreciation (1590) account in '
      'the chart. Add them, or name accounts on the asset.');
  end;
  update public.accounts set code = '1510'
   where org_id = v_org and code = '1511-moved';

  -- The same for the expense account, which is only consulted when
  -- there is a catch-up to charge -- so the asset must have gone
  -- undepreciated, which FA-SAPU-2 has.
  update public.accounts set code = '6401-moved'
   where org_id = v_org and code = '6400';
  begin
    perform public.dispose_fixed_asset(v_other, v_when);
    raise exception
      'an asset was disposed of with its catch-up charged nowhere';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and with no depreciation expense account, likewise',
      v_msg like 'No depreciation expense (6400) account in the chart, and '
                 'FA-SAPU-2 has not been depreciated up to %');
  end;
  update public.accounts set code = '6400'
   where org_id = v_org and code = '6401-moved';

  -- ==================================================================
  -- 3. The accounts actually chosen
  --
  -- The asset carries its own 1515, and the proceeds are banked into
  -- the second account. Both are coalesce fallbacks that could be
  -- ignored, and neither changes a total -- they change which line of
  -- the balance sheet moves, and which bank reconciliation balances.
  -- ==================================================================
  v_entry := public.dispose_fixed_asset(v_asset, v_when, 50000, v_bank);

  perform pg_temp.check_eq(
    'the asset is relieved from the account it was carried in',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_ac_van),
    60000::numeric);
  perform pg_temp.check_eq('and not from the default one',
    (select coalesce(round(sum(gl.credit), 2), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '1510'), 0::numeric);

  perform pg_temp.check_eq('the proceeds reach the account they were paid into',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_bank_ac),
    50000::numeric);
  perform pg_temp.check_eq('and not the current account',
    (select coalesce(round(sum(gl.debit), 2), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '1120'), 0::numeric);

  -- ==================================================================
  -- 4. The day it left is the day it posts
  --
  -- A van sold in March and entered in April is depreciated to March
  -- and posted to April: the profit and loss then disagrees with the
  -- schedule behind it, and a locked period does not stop it.
  -- ==================================================================
  perform pg_temp.check_true('the day it left is not today',
    v_when <> app.today());
  perform pg_temp.check_true('and the journal is dated that day',
    (select e.entry_date = v_when from public.gl_entries e
      where e.id = v_entry));

  -- ==================================================================
  -- 5. What the disposal leaves on the asset and in the schedule
  -- ==================================================================
  perform pg_temp.check_eq('the proceeds are recorded on the asset',
    (select disposal_proceeds from public.fixed_assets where id = v_asset),
    50000::numeric);
  perform pg_temp.check_eq(
    'and the catch-up recorded in the run is the catch-up charged',
    (select r.total_amount from public.depreciation_runs r
      where r.gl_entry_id = v_entry),
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '6400'));
  perform pg_temp.check_true('which is not nothing',
    (select r.total_amount > 0 from public.depreciation_runs r
      where r.gl_entry_id = v_entry));

  -- ==================================================================
  -- 6. A catch-up cannot be negative
  --
  -- `greatest(..., 0)`. An asset already depreciated past what the
  -- straight line says -- a manual adjustment, or a life shortened
  -- after the fact -- would otherwise post a NEGATIVE depreciation
  -- charge, crediting the profit and loss with a write-back nobody
  -- authorised.
  -- ==================================================================
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months, accumulated_depreciation, depreciated_to)
  values (v_org, 'FA-SAPU-3', 'Over-depreciated press', date '2026-01-01',
          12000, 0, 'straight_line', 60, 9000, date '2026-03-31')
  returning id into v_other;

  v_entry := public.dispose_fixed_asset(v_other, v_when, 0, null);
  perform pg_temp.check_eq(
    'an asset already depreciated past the line charges nothing more',
    (select coalesce(round(sum(gl.debit), 2), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '6400'), 0::numeric);
  perform pg_temp.check_eq('and no depreciation run is raised for nothing',
    (select count(*)::integer from public.depreciation_runs r
      where r.gl_entry_id = v_entry), 0);
  perform pg_temp.check_eq(
    'while what it was carrying is still written off in full',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.account_subtype = 'accumulated_depreciation'),
    9000::numeric);

  -- ==================================================================
  -- What the sweep could not kill, and why
  -- ==================================================================
  -- Twenty-seven mutants; twenty-six die against the assertions above.
  -- The twenty-seventh is EQUIVALENT, and it is the `greatest(..., 0)`
  -- the block immediately above is about.
  --
  --     v_catchup := greatest(v_accum - a.accumulated_depreciation, 0);
  --
  -- Remove the greatest and v_catchup goes negative for the press --
  -- and nothing downstream reads it, because all three places that do
  -- are inside `if v_catchup > 0`. The journal line, the depreciation
  -- run and the depreciation entry are all guarded, so a negative and a
  -- zero produce the same books.
  --
  -- The assertions above hold under both, which is the probe: they were
  -- written expecting to kill it and they do not. The greatest is
  -- shadowed by the guards below it, exactly as `posted_at` and the
  -- status check shadow each other in post_manufacturing_order.
  --
  -- Left in place. It states the intent at the point the number is
  -- computed rather than three branches later, and a later edit that
  -- relaxed any of those guards would need it. That is the third
  -- equivalent mutant this programme has recorded rather than worked
  -- around: the round(..., 2) beside a numeric(18, 2) in contra.sql,
  -- the delete before a raise in credit_note_return.sql, and this.
  -- All three are code that is right, doing nothing, and worth keeping.

  raise notice 'ok   fixed assets: the eleven a sweep found';
end $$;

rollback;

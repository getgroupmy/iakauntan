-- =====================================================================
-- iAkauntan :: the assets a depreciation run has to survive
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/depreciation_shapes.sql
--
-- `fixed_assets.sql` opens by saying that depreciation is the one charge
-- in the ledger nobody enters by hand, so nobody checks it either. That
-- is right, and a mutation sweep of the four functions behind it —
-- `app.months_held`, `app.accumulated_depreciation_at`,
-- `public.run_depreciation` and `public.depreciation_preview` — killed
-- 19 of 42 one-line mutants.
--
-- The arithmetic was well covered. What was not covered was every
-- REGISTER SHAPE around it: an asset with a residual value, an asset
-- somebody deleted, an asset bought after the date being run, an asset
-- carrying its own pair of accounts, a chart missing the two the run
-- falls back to, and the run that finds nothing to charge. Each of those
-- is a row in a register a bookkeeper actually keeps.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ds_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end $$;

-- =====================================================================
-- 1. Months held, asked directly
-- =====================================================================
--
-- Two mutants in `app.months_held` are invisible through
-- `accumulated_depreciation_at`, because that function's own
-- `p_as_at < acquisition_date` guard catches what they change. They MASK
-- EACH OTHER: remove the guard and months_held still returns zero;
-- change months_held's `case` and the guard still returns zero. Neither
-- is dead, and the pair is only pinned by asking the smaller function
-- directly.
-- =====================================================================
do $$
begin
  -- Earlier in the SAME month as the acquisition. `date_trunc` makes the
  -- two months equal, so the age is zero and only the `case` decides.
  perform pg_temp.check_eq('a date before the purchase, in the same month',
    app.months_held(date '2026-06-15', date '2026-06-10'), 0);
  perform pg_temp.check_eq('the day itself is one month',
    app.months_held(date '2026-06-15', date '2026-06-15'), 1);
  perform pg_temp.check_eq('and so is the rest of that month',
    app.months_held(date '2026-06-15', date '2026-06-30'), 1);
  -- The month before, which the age already makes negative.
  perform pg_temp.check_eq('the month before is nothing',
    app.months_held(date '2026-06-15', date '2026-05-31'), 0);
  perform pg_temp.check_eq('and a year before is still nothing',
    app.months_held(date '2026-06-15', date '2025-06-15'), 0);

  raise notice 'ok   months held, asked directly';
end $$;

-- =====================================================================
-- 2. A residual value, and the two clamps around it
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_res   uuid;
  v_typo  uuid;
  r       record;
begin
  v_org := pg_temp.ds_org('Nilai Baki Sdn Bhd');

  -- MUTANT: `v_depreciable * months / life` -> `p_asset.cost * ...`.
  -- RM50,000 with a RM5,000 residual over 60 months is RM750 a month,
  -- not RM833.33. Every asset in `fixed_assets.sql` has a residual of
  -- zero, where the two are the same number.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
  values (v_org, 'FA-R1', 'Lorry with a trade-in value', date '2026-01-01',
          50000, 5000, 'straight_line', 60)
  returning id into v_res;

  select * into r from public.depreciation_preview(v_org, date '2026-04-30');
  perform pg_temp.check_eq('the residual is not depreciated away',
    r.charge, 3000);          -- 4 months at 750
  perform pg_temp.check_eq('and the net book value is what is left',
    r.net_book_value, 47000);

  -- MUTANT: `least(greatest(v_target, 0), v_depreciable)` with the
  -- `least` dropped. At the end of the asset's life the accumulated
  -- figure stops at the depreciable amount and the residual stays on
  -- the balance sheet, which is what a residual value IS.
  perform pg_temp.check_eq('over its whole life it stops at the residual',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_res),
      date '2030-12-31'), 45000);
  perform pg_temp.check_eq('and does not keep going afterwards',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_res),
      date '2035-12-31'), 45000);

  -- MUTANT: the `greatest(v_target, 0)` dropped. The check constraint on
  -- `rate_percent` is only `> 0`, so twenty-five per cent typed as 2500
  -- is a number the database accepts. At a monthly factor of
  -- 1 - 2500/1200 the closed form goes negative on even months, and
  -- without the clamp the run would post a CREDIT to depreciation
  -- expense -- income, from a typo in a percentage field.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost,
     method, rate_percent)
  values (v_org, 'FA-R2', 'Rate typed as 2500 rather than 25',
          date '2026-01-01', 10000, 'reducing_balance', 2500)
  returning id into v_typo;

  -- One month in, the closed form says the asset is worth MINUS
  -- RM10,833, so more has come off it than it ever cost: the `least`
  -- stops the accumulated figure at the cost.
  perform pg_temp.check_eq('an absurd rate cannot depreciate past the cost',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_typo),
      date '2026-01-31'), 10000);
  -- Two months in, the same form squares the negative factor and says
  -- the asset is worth MORE than it cost, which would be a charge of
  -- minus RM1,736. The `greatest` stops it at zero.
  perform pg_temp.check_eq('nor make the charge negative',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_typo),
      date '2026-02-28'), 0);

  -- The `v_depreciable <= 0` guard is only reachable at equality,
  -- because the database will not accept a residual above the cost. A
  -- mutant deleting the guard survives -- correctly -- and it survives
  -- BECAUSE OF THAT CONSTRAINT, so the constraint is what is asserted.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
  values (v_org, 'FA-R3', 'Worth exactly its residual', date '2026-01-01',
          8000, 8000, 'straight_line', 60);
  perform pg_temp.check_eq('an asset worth only its residual is not depreciated',
    (select coalesce(sum(p.charge), 0)
       from public.depreciation_preview(v_org, date '2026-12-31') p
      where p.asset_no = 'FA-R3'), 0);
  begin
    insert into public.fixed_assets
      (org_id, asset_no, name, acquisition_date, cost, residual_value,
       method, useful_life_months)
    values (v_org, 'FA-R4', 'Residual above cost', date '2026-01-01',
            1000, 1200, 'straight_line', 60);
    raise exception 'FAIL: a residual above the cost was accepted';
  exception when check_violation then
    raise notice 'ok   a residual above the cost is refused by the database';
  end;

  raise notice 'ok   a residual value, and the two clamps around it';
end $$;

-- =====================================================================
-- 3. Which assets a run touches
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_live   uuid;
  v_gone   uuid;
  v_future uuid;
  v_run    uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ds_org('Daftar Aset Sdn Bhd');

  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-1', 'On the register', date '2026-01-01', 12000,
          'straight_line', 12)
  returning id into v_live;

  -- MUTANT: `deleted_at is null` dropped, in the run AND in the preview.
  -- An asset somebody removed from the register is not an asset; posting
  -- a charge for it puts a number in the accounts that no report will
  -- ever explain.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, deleted_at)
  values (v_org, 'FA-2', 'Taken off the register', date '2026-01-01', 12000,
          'straight_line', 12, now())
  returning id into v_gone;

  -- MUTANT: `acquisition_date <= p_as_at` dropped, in the run AND in the
  -- preview. Running March with an asset bought in June charges three
  -- months of an asset the company does not own yet.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-3', 'Bought in June', date '2026-06-01', 12000,
          'straight_line', 12)
  returning id into v_future;

  perform pg_temp.check_eq('the preview offers one asset',
    (select count(*) from public.depreciation_preview(v_org, date '2026-03-31')), 1);
  perform pg_temp.check_eq('and it is the one on the register',
    (select p.asset_no from public.depreciation_preview(v_org, date '2026-03-31') p),
    'FA-1');

  v_run := public.run_depreciation(v_org, date '2026-03-31');
  perform pg_temp.check_eq('and the run charges only that one',
    (select count(*) from public.depreciation_entries
      where run_id = v_run), 1);
  perform pg_temp.check_eq('for three months of it',
    (select total_amount from public.depreciation_runs where id = v_run), 3000);
  perform pg_temp.check_eq('nothing was charged for the deleted asset',
    (select accumulated_depreciation from public.fixed_assets where id = v_gone), 0);
  perform pg_temp.check_eq('nor for the one not bought yet',
    (select accumulated_depreciation from public.fixed_assets where id = v_future), 0);

  -- MUTANT: `depreciated_to = a.depreciated_to`. The register has to say
  -- how far it has been taken, or the next person cannot tell a run that
  -- has not happened from one that charged nothing.
  perform pg_temp.check_eq('and the asset records how far it was taken',
    (select depreciated_to::text from public.fixed_assets where id = v_live),
    '2026-03-31');

  -- MUTANT: `if v_charge <= 0 then continue` -> `< 0`. Running the same
  -- date twice must add nothing at all: not a second run, and not a row
  -- of zero in the entries.
  perform pg_temp.check_true('running the same date again posts nothing',
    public.run_depreciation(v_org, date '2026-03-31') is null);
  perform pg_temp.check_eq('and leaves no second entry behind',
    (select count(*) from public.depreciation_entries e
      join public.depreciation_runs r on r.id = e.run_id
      where r.org_id = v_org), 1);

  -- MUTANT: `if v_charge <= 0 then continue` -> `< 0`, seen properly.
  -- A run where EVERY asset is up to date is deleted whole, so the zero
  -- rows go with it and the mutant hides. A run with one asset up to
  -- date and one behind keeps the run -- and must still write one entry,
  -- not two.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-4', 'Behind the others', date '2026-04-01', 12000,
          'straight_line', 12);

  -- An asset whose residual IS its cost -- land the company owns and
  -- carries at what it paid, entered on the register so the fixed asset
  -- note foots. There is nothing to charge on it, ever, and the run has
  -- to pass over it silently rather than write a line of nothing.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value, method,
     useful_life_months)
  values (v_org, 'FA-5', 'Land, carried at cost', date '2026-01-01',
          400000, 400000, 'straight_line', 600);

  perform public.run_depreciation(v_org, date '2026-04-30');
  perform pg_temp.check_eq('a mixed run writes no entry for what it cannot charge',
    (select count(*) from public.depreciation_entries e
      join public.depreciation_runs r on r.id = e.run_id
      where r.org_id = v_org and r.run_date = date '2026-04-30'), 2);
  perform pg_temp.check_eq('and leaves the land where it was',
    (select accumulated_depreciation from public.fixed_assets
      where org_id = v_org and asset_no = 'FA-5'), 0);
  perform pg_temp.check_eq('and every entry it wrote is for real money',
    (select count(*) from public.depreciation_entries e
      join public.depreciation_runs r on r.id = e.run_id
      where r.org_id = v_org and e.amount <= 0), 0);

  -- MUTANT: the `delete from depreciation_runs` on an empty run removed.
  -- A run row with no entries and no journal is a line in the audit
  -- trail claiming a posting that never happened.
  perform pg_temp.check_eq('and no empty run is left behind',
    (select count(*) from public.depreciation_runs where org_id = v_org), 2);
  perform pg_temp.check_eq('and every run that exists has its journal',
    (select count(*) from public.depreciation_runs
      where org_id = v_org and gl_entry_id is null), 0);

  raise notice 'ok   which assets a run touches';
end $$;

-- =====================================================================
-- 4. Where the charge is posted
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_own   uuid;
  v_plain uuid;
  v_exp   uuid;
  v_acc   uuid;
  v_run   uuid;
  v_entry uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ds_org('Akaun Susut Sdn Bhd');

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '6410', 'Depreciation — motor vehicles', 'expense',
          'depreciation_expense')
  returning id into v_exp;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1591', 'Accumulated depreciation — motor vehicles', 'asset',
          'accumulated_depreciation')
  returning id into v_acc;

  -- MUTANT: `coalesce(fa.expense_account_id, v_default_expense)` replaced
  -- by the default alone. A company that has split depreciation by class
  -- of asset -- which is what an auditor asks for -- would have every
  -- class posted to one account, and the note to the accounts could not
  -- be produced at all.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, expense_account_id, accumulated_account_id)
  values (v_org, 'FA-V', 'Van with its own accounts', date '2026-01-01',
          12000, 'straight_line', 12, v_exp, v_acc)
  returning id into v_own;

  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-D', 'Desk on the default accounts', date '2026-01-01',
          6000, 'straight_line', 12)
  returning id into v_plain;

  -- MUTANT: the entry dated `current_date` rather than `p_as_at`. A run
  -- for March posted into today's period is a charge in the wrong month
  -- and, once the year is closed, in the wrong year.
  v_run := public.run_depreciation(v_org, date '2026-03-31');
  select gl_entry_id into v_entry
    from public.depreciation_runs where id = v_run;
  perform pg_temp.check_eq('the journal is dated the run date',
    (select entry_date::text from public.gl_entries where id = v_entry),
    '2026-03-31');

  -- Two pairs of accounts, because the two assets do not share them.
  perform pg_temp.check_eq('the van is charged to its own expense account',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_exp), 3000);
  perform pg_temp.check_eq('and credited to its own accumulation',
    (select l.credit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_acc), 3000);
  perform pg_temp.check_eq('the desk falls back to the chart''s 6400',
    (select l.debit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6400'), 1500);
  perform pg_temp.check_eq('and to its 1590',
    (select l.credit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1590'), 1500);
  perform pg_temp.check_eq('which is four lines, not two',
    (select count(*) from public.gl_lines where entry_id = v_entry), 4);

  -- MUTANT: the grouping widened to one row per ASSET. Two desks on the
  -- same pair of accounts are one line in the journal, not two: the
  -- ledger records the charge by account, and the register is where the
  -- charge is recorded by asset. A third asset on the defaults leaves
  -- the line count where it was.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-D2', 'Second desk on the same accounts',
          date '2026-01-01', 6000, 'straight_line', 12);

  v_run := public.run_depreciation(v_org, date '2026-04-30');
  select gl_entry_id into v_entry
    from public.depreciation_runs where id = v_run;
  perform pg_temp.check_eq('three assets on two pairs of accounts is four lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 4);
  perform pg_temp.check_eq('but three entries in the register',
    (select count(*) from public.depreciation_entries where run_id = v_run), 3);
  -- April is one month for the first desk, which is already up to
  -- March, and four for the second, which has never been run: 500 and
  -- 2,000, and they arrive as ONE line of 2,500.
  perform pg_temp.check_eq('and the two desks are one line between them',
    (select l.debit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6400'), 2500);
  perform pg_temp.check_eq('while the van keeps its own',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_exp), 1000);

  raise notice 'ok   where the charge is posted';
end $$;

-- =====================================================================
-- 5. A chart that cannot take the charge, and a person who may not post
-- =====================================================================
do $$
declare
  v_org uuid;
  v_a   uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ds_org('Carta Tak Lengkap Sdn Bhd');

  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months)
  values (v_org, 'FA-X', 'Nowhere to post it', date '2026-01-01', 12000,
          'straight_line', 12)
  returning id into v_a;

  -- MUTANT: `if r.expense_id is null or r.accum_id is null then` -> false.
  -- Without the raise, `create_gl_entry_internal` is handed a null
  -- account_id. A company that has edited its chart -- which `0500` made
  -- possible -- can be missing 6400, and the error has to say what to do
  -- about it rather than fail somewhere further down.
  update public.accounts set code = '6499'
   where org_id = v_org and code = '6400';
  begin
    perform public.run_depreciation(v_org, date '2026-03-31');
    raise exception 'FAIL: depreciation posted with no expense account';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a chart with no 6400 is refused, by name';
  end;
  update public.accounts set code = '6400'
   where org_id = v_org and code = '6499';

  update public.accounts set code = '1599'
   where org_id = v_org and code = '1590';
  begin
    perform public.run_depreciation(v_org, date '2026-03-31');
    raise exception 'FAIL: depreciation posted with no accumulation account';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and a chart with no 1590 likewise';
  end;
  update public.accounts set code = '1590'
   where org_id = v_org and code = '1599';

  -- MUTANT: `if not app.can_post(p_org_id)` -> false, and
  -- `is_org_member` in the preview likewise. Depreciation is a posting
  -- like any other; a viewer may not make one, and an outsider may not
  -- so much as look.
  perform pg_temp.sign_in_as(pg_temp.another_user('nobody@example.test'));
  begin
    perform public.run_depreciation(v_org, date '2026-03-31');
    raise exception 'FAIL: an outsider posted a depreciation run';
  exception when sqlstate '42501' then
    raise notice 'ok   an outsider cannot post a depreciation run';
  end;
  begin
    perform public.depreciation_preview(v_org, date '2026-03-31');
    raise exception 'FAIL: an outsider previewed a depreciation run';
  exception when sqlstate '42501' then
    raise notice 'ok   nor preview one';
  end;
  perform pg_temp.sign_out();

  raise notice 'ok   a chart that cannot take the charge';
end $$;

-- =====================================================================
-- 6. The preview and the run agree, including at the end
-- =====================================================================
do $$
declare
  v_org uuid;
  v_a   uuid;
  r     record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ds_org('Pratonton Sdn Bhd');

  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
  values (v_org, 'FA-P', 'Twelve months, then done', date '2026-01-01',
          12000, 1200, 'straight_line', 12)
  returning id into v_a;

  perform public.run_depreciation(v_org, date '2026-06-30');

  -- MUTANT: the preview's charge without `- a.accumulated_depreciation`,
  -- and without the `greatest(..., 0)`. Six months are already posted;
  -- the preview of the same date must offer nothing more, and the one
  -- after it must offer only the difference.
  select * into r from public.depreciation_preview(v_org, date '2026-06-30');
  perform pg_temp.check_eq('a preview of a date already run offers nothing',
    r.charge, 0);
  perform pg_temp.check_eq('and shows the book value as it stands',
    r.net_book_value, 6600);      -- 12,000 less six months of 900

  select * into r from public.depreciation_preview(v_org, date '2026-09-30');
  perform pg_temp.check_eq('three more months is three more charges',
    r.charge, 2700);
  perform pg_temp.check_eq('and the book value falls by the same',
    r.net_book_value, 3900);

  -- MUTANT: the preview's net book value taken from the accumulated
  -- figure alone rather than from `greatest(target, accumulated)`. The
  -- column is what the asset will be worth AFTER the charge beside it,
  -- which is the only reading that makes the two columns add up.
  perform pg_temp.check_eq('so the row adds up across itself',
    r.net_book_value + r.charge + r.accumulated, r.cost);

  -- MUTANT: a preview of a date BEFORE the last run. Nothing is owed and
  -- nothing may be given back, so the charge is zero and the book value
  -- is where the register already stands.
  select * into r from public.depreciation_preview(v_org, date '2026-02-28');
  perform pg_temp.check_eq('a preview of a date already passed offers nothing',
    r.charge, 0);
  perform pg_temp.check_eq('and does not un-depreciate the asset',
    r.net_book_value, 6600);

  -- MUTANT: `status = 'active'` dropped from the run and from the
  -- preview. Take it to the end of its life and it leaves both.
  perform public.run_depreciation(v_org, date '2026-12-31');
  perform pg_temp.check_eq('at the end of its life it is fully depreciated',
    (select status from public.fixed_assets where id = v_a),
    'fully_depreciated');
  perform pg_temp.check_eq('with the residual still on the books',
    (select cost - accumulated_depreciation from public.fixed_assets
      where id = v_a), 1200);
  perform pg_temp.check_eq('and it is off the preview',
    (select count(*) from public.depreciation_preview(v_org, date '2027-06-30')), 0);
  perform pg_temp.check_true('and off the run',
    public.run_depreciation(v_org, date '2027-06-30') is null);

  -- MUTANT: `v_target >= a.cost - a.residual_value - 0.01`, marking an
  -- asset finished one cent early.
  --
  -- On a straight line that boundary is unreachable with any credible
  -- figures: it needs a monthly charge of one sen. On a REDUCING
  -- balance it is where the asset actually ends, because the closed
  -- form never reaches the depreciable amount -- it approaches it, and
  -- the asset is finished on the month the rounding closes the gap.
  -- RM30,000 at twenty per cent a year is within one sen of finished
  -- after 864 months and finished after 929, which is seventy-seven
  -- years: a reducing-balance asset is not written off, it is rounded
  -- off, and these two dates are what that sentence means.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method, rate_percent)
  values (v_org, 'FA-RB', 'Reducing balance, to the very end',
          date '2026-01-01', 30000, 'reducing_balance', 20)
  returning id into v_a;

  -- The two years those runs post into. Period control refuses a
  -- posting with no fiscal period behind it, which is the right answer
  -- and means a test that posts seventy-seven years out has to open the
  -- years it uses.
  perform public.create_fiscal_year(v_org, date '2097-01-01');
  perform public.create_fiscal_year(v_org, date '2103-01-01');

  -- Month 864 counted from the acquisition month, which the function
  -- counts inclusively.
  perform pg_temp.check_eq('one cent short, after seventy-two years',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_a),
      (date '2026-01-01' + make_interval(months => 863))::date), 29999.99);
  perform public.run_depreciation(v_org,
    (date '2026-01-01' + make_interval(months => 863))::date);
  perform pg_temp.check_eq('and one cent short is not finished',
    (select status from public.fixed_assets where id = v_a), 'active');

  perform pg_temp.check_eq('the last cent lands after seventy-seven',
    app.accumulated_depreciation_at(
      (select f from public.fixed_assets f where f.id = v_a),
      (date '2026-01-01' + make_interval(months => 928))::date), 30000);
  perform public.run_depreciation(v_org,
    (date '2026-01-01' + make_interval(months => 928))::date);
  perform pg_temp.check_eq('and then it is', 
    (select status from public.fixed_assets where id = v_a),
    'fully_depreciated');

  raise notice 'ok   the preview and the run agree';
end $$;

rollback;

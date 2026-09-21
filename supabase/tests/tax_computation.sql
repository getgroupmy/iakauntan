-- =====================================================================
-- iAkauntan :: the Form C computation
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_computation.sql
--
-- `0665` turns the profit the accounts show into the figure Parliament
-- taxes. Every step is statutory and every step is asserted, but five
-- of them are worth naming because getting them wrong produces a
-- computation that still adds up:
--
--   1. **Capital allowances cannot create a loss.** They are set
--      against adjusted income and stop at nothing; what is left is
--      unabsorbed capital allowance carried forward, which is NOT a
--      loss and does not behave like one.
--   2. **Losses come off statutory income, AFTER the allowances.**
--      The other order gives a different answer in every year where
--      both exist.
--   3. **Zakat is a rebate against the tax, capped at it.** Deducting
--      it from income instead is a smaller benefit; letting it exceed
--      the tax invents a refund.
--   4. **The SME bands are two rates, not one.** 17% on the first
--      RM150,000 and 24% above it -- charging 17% on the whole of a
--      RM500,000 chargeable income understates the tax by RM35,000.
--   5. **A balancing charge is income and a balancing allowance is
--      relief.** `0664` produces both on one disposal row and they go
--      to opposite ends of this computation.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.two_lines(
  p_debit uuid, p_credit uuid, p_amount numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('account_id', p_debit, 'debit', p_amount,
                       'credit', 0),
    jsonb_build_object('account_id', p_credit, 'debit', 0,
                       'credit', p_amount));
$$;

-- A company with a 2026 financial year and a computation opened on it.
create or replace function pg_temp.tax_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.tax_comp(p_org uuid)
returns uuid language plpgsql as $$
declare v_fy uuid;
begin
  select id into v_fy from public.fiscal_years
   where org_id = p_org and end_date between date '2026-01-01'
                                         and date '2026-12-31'
   order by end_date limit 1;
  return public.open_tax_computation(p_org, v_fy);
end; $$;

-- Revenue of p_revenue and an expense of p_expense on a named account.
create or replace function pg_temp.trade(
  p_org uuid, p_revenue numeric, p_expense numeric,
  p_expense_code text default '6100')
returns void language plpgsql as $$
declare v_bank uuid; v_sales uuid; v_expense uuid;
begin
  select id into v_bank from public.accounts
   where org_id = p_org and account_subtype = 'bank'
     and not is_group order by code limit 1;
  select id into v_sales from public.accounts
   where org_id = p_org and account_type = 'revenue'
     and not is_group order by code limit 1;
  select id into v_expense from public.accounts
   where org_id = p_org and code = p_expense_code;

  if p_revenue > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_bank, v_sales, p_revenue), 'Sales', 'S-1');
  end if;
  if p_expense > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_expense, v_bank, p_expense), 'Costs', 'E-1');
  end if;
end; $$;

create or replace function pg_temp.tax_figure(
  p_comp uuid, p_column text)
returns numeric language plpgsql as $$
declare v numeric;
begin
  execute format('select %I from public.tax_computation($1)', p_column)
    into v using p_comp;
  return v;
end; $$;

-- The two boolean columns, which `tax_figure` cannot read: `select
-- is_sme into a numeric` fails with "invalid input syntax for type
-- numeric: f". A second function rather than a cast at every call
-- site, because a cast somebody forgets fails at run time with that
-- same unhelpful message.
create or replace function pg_temp.tax_flag(
  p_comp uuid, p_column text)
returns boolean language plpgsql as $$
declare v boolean;
begin
  execute format('select %I from public.tax_computation($1)', p_column)
    into v using p_comp;
  return v;
end; $$;

-- ---------------------------------------------------------------------
-- The rates are the published ones, and nothing claims to be verified
-- ---------------------------------------------------------------------
do $$
declare v numeric; v_count integer;
begin
  select sme_rate into v from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('the SME rate is 17%', v, 0.17);
  select standard_rate into v from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('and the standard rate 24%', v, 0.24);
  select sme_band_limit into v from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('the SME band is the first RM150,000',
    v, 150000);
  select sme_capital_limit into v from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('paid-up capital up to RM2.5m', v, 2500000);
  select sme_turnover_limit into v from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('and gross income up to RM50m', v, 50000000);

  select count(*) into v_count from public.company_tax_rates
   where is_verified;
  perform pg_temp.check_eq(
    'nothing seeded claims to have been checked against the Act',
    v_count, 0);

  select fraction into v from public.tax_treatments
   where code = 'entertainment';
  perform pg_temp.check_eq('entertainment is half disallowed', v, 0.5);
  select fraction into v from public.tax_treatments
   where code = 'depreciation';
  perform pg_temp.check_eq('and depreciation all of it', v, 1);
end $$;

-- ---------------------------------------------------------------------
-- The profit the accounts show, and the year it is assessed in
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Untung Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);

  perform pg_temp.check_eq('the profit is revenue less expenses',
    pg_temp.tax_figure(v_comp, 'profit_before_tax'), 200000);
  perform pg_temp.check_eq(
    'a period ending in 2026 is assessed in 2026',
    pg_temp.tax_figure(v_comp, 'year_of_assessment'), 2026);

  -- Nothing tagged: adjusted income is the profit.
  perform pg_temp.check_eq('with nothing tagged, nothing is added back',
    pg_temp.tax_figure(v_comp, 'add_backs'), 0);
  perform pg_temp.check_eq('and the adjusted income is the profit',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 200000);

  -- Opening it twice hands back the same one rather than refusing.
  perform pg_temp.check_eq('opening the same year twice is idempotent',
    (pg_temp.tax_comp(v_org) = v_comp)::text, 'true');
end $$;

-- ---------------------------------------------------------------------
-- Add-backs come off the chart of accounts
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid; v_acct uuid; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Denda Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);

  select id into v_acct from public.accounts
   where org_id = v_org and code = '6100';
  update public.accounts set tax_treatment = 'penalties' where id = v_acct;

  v_comp := pg_temp.tax_comp(v_org);
  perform pg_temp.check_eq('a non-deductible account is added back whole',
    pg_temp.tax_figure(v_comp, 'add_backs'), 300000);
  perform pg_temp.check_eq('so the adjusted income is the revenue',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 500000);

  -- Half, for entertainment. The fraction is the rule and dropping it
  -- would double this line.
  update public.accounts set tax_treatment = 'entertainment'
   where id = v_acct;
  perform pg_temp.check_eq('entertainment is added back by half',
    pg_temp.tax_figure(v_comp, 'add_backs'), 150000);
  perform pg_temp.check_eq('and the adjusted income follows',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 350000);

  -- The working names the account it came from, which is a reviewer's
  -- first question about any add-back.
  select count(*) into v_rows
    from public.tax_computation_lines(v_comp)
   where kind = 'add_back' and source like '%6100%';
  perform pg_temp.check_eq('and the working says which account', v_rows, 1);
end $$;

-- ---------------------------------------------------------------------
-- A treatment on the wrong side of the ledger
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid; v_rev uuid; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Silap Tanda Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);

  select id into v_rev from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group
   order by code limit 1;
  -- An EXPENSE rule on a REVENUE account.
  update public.accounts set tax_treatment = 'penalties' where id = v_rev;

  v_comp := pg_temp.tax_comp(v_org);

  -- Dropped rather than applied. Applying it would add the whole
  -- revenue back into income -- a figure that still adds up and is
  -- wrong by half a million.
  perform pg_temp.check_eq('a misfiled treatment is not applied',
    pg_temp.tax_figure(v_comp, 'add_backs'), 0);

  -- And it is findable, because nothing else would show it.
  select count(*) into v_rows
    from public.tax_computation_misfiled(v_org) where account_id = v_rev;
  perform pg_temp.check_eq('but it is reported as misfiled', v_rows, 1);
end $$;

-- ---------------------------------------------------------------------
-- The adjustments a tag cannot make
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Tambah Sendiri Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);

  insert into public.tax_adjustments
    (org_id, computation_id, kind, label, amount, reason)
  values (v_org, v_comp, 'add_back', 'Director''s private mileage',
          12000, 'Log book, 40% of motor expenses');
  insert into public.tax_adjustments
    (org_id, computation_id, kind, label, amount, reason)
  values (v_org, v_comp, 'deduct', 'Gain on disposal, not taxable',
          5000, 'Capital in nature');

  perform pg_temp.check_eq('a typed add-back counts',
    pg_temp.tax_figure(v_comp, 'add_backs'), 12000);
  perform pg_temp.check_eq('and a typed deduction counts',
    pg_temp.tax_figure(v_comp, 'deductions'), 5000);
  perform pg_temp.check_eq('both land in the adjusted income',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 207000);
end $$;

-- ---------------------------------------------------------------------
-- Capital allowances, and the order they come in
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Elaun Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);

  -- RM100,000 of plant bought in the basis period: 20% + 14% = 34,000.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'P-1', 'Mesin', date '2026-02-01', 100000,
          'straight_line', 60, 'plant');

  v_comp := pg_temp.tax_comp(v_org);

  perform pg_temp.check_eq('the year''s allowances come from Schedule 3',
    pg_temp.tax_figure(v_comp, 'ca_current'), 34000);
  perform pg_temp.check_eq('they are used against the adjusted income',
    pg_temp.tax_figure(v_comp, 'ca_used'), 34000);
  perform pg_temp.check_eq('leaving the statutory income',
    pg_temp.tax_figure(v_comp, 'statutory_income'), 166000);
  perform pg_temp.check_eq('and nothing carried forward',
    pg_temp.tax_figure(v_comp, 'ca_carried_forward'), 0);
end $$;

do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Elaun Lebih Sdn Bhd');
  -- A small profit and a large allowance.
  perform pg_temp.trade(v_org, 320000, 300000);
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'P-1', 'Mesin', date '2026-02-01', 200000,
          'straight_line', 60, 'plant');

  v_comp := pg_temp.tax_comp(v_org);

  -- THE ONE. 20,000 of adjusted income and 68,000 of allowances.
  -- Allowances are set against adjusted income and STOP at nothing:
  -- they cannot create a loss, and the 48,000 they do not absorb is
  -- unabsorbed capital allowance carried forward -- which is not a
  -- loss and does not behave like one.
  perform pg_temp.check_eq('the allowances available', 
    pg_temp.tax_figure(v_comp, 'ca_current'), 68000);
  perform pg_temp.check_eq('only what the income can absorb is used',
    pg_temp.tax_figure(v_comp, 'ca_used'), 20000);
  perform pg_temp.check_eq('the statutory income lands on nothing',
    pg_temp.tax_figure(v_comp, 'statutory_income'), 0);
  perform pg_temp.check_eq('and the rest is carried forward',
    pg_temp.tax_figure(v_comp, 'ca_carried_forward'), 48000);
  perform pg_temp.check_eq(
    'allowances do not become a loss carried forward',
    pg_temp.tax_figure(v_comp, 'loss_carried_forward'), 0);
end $$;

do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Rugi Sdn Bhd');
  -- A trading loss.
  perform pg_temp.trade(v_org, 100000, 260000);
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'P-1', 'Mesin', date '2026-02-01', 50000,
          'straight_line', 60, 'plant');

  v_comp := pg_temp.tax_comp(v_org);

  perform pg_temp.check_eq('an adjusted loss is reported as one',
    pg_temp.tax_figure(v_comp, 'adjusted_loss'), 160000);
  perform pg_temp.check_eq('the adjusted income is nothing, not negative',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 0);
  perform pg_temp.check_eq('no allowance is used against a loss',
    pg_temp.tax_figure(v_comp, 'ca_used'), 0);
  perform pg_temp.check_eq('the whole claim carries forward',
    pg_temp.tax_figure(v_comp, 'ca_carried_forward'), 17000);
  perform pg_temp.check_eq('and so does the loss, beside it',
    pg_temp.tax_figure(v_comp, 'loss_carried_forward'), 160000);
  perform pg_temp.check_eq('with no tax to pay',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Losses brought forward come off AFTER the allowances
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Rugi Tahun Lepas Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);

  update public.tax_computations
     set capital_allowance_bf = 50000, loss_bf = 80000
   where id = v_comp;

  -- 200,000 adjusted. Allowances 50,000 brought forward -> statutory
  -- 150,000. THEN the loss: 80,000 -> chargeable 70,000.
  --
  -- The other order -- loss first, then allowances -- gives the same
  -- total here and a different one the moment either exceeds the
  -- income, which is why both are asserted separately.
  perform pg_temp.check_eq('brought-forward allowances are used first',
    pg_temp.tax_figure(v_comp, 'ca_used'), 50000);
  perform pg_temp.check_eq('giving the statutory income',
    pg_temp.tax_figure(v_comp, 'statutory_income'), 150000);
  perform pg_temp.check_eq('then the loss comes off that',
    pg_temp.tax_figure(v_comp, 'loss_used'), 80000);
  perform pg_temp.check_eq('leaving the chargeable income',
    pg_temp.tax_figure(v_comp, 'chargeable_income'), 70000);
  perform pg_temp.check_eq('and no loss left over',
    pg_temp.tax_figure(v_comp, 'loss_carried_forward'), 0);

  -- A loss bigger than the statutory income stops at nothing and the
  -- remainder carries forward.
  update public.tax_computations set loss_bf = 400000 where id = v_comp;
  perform pg_temp.check_eq('a loss larger than the income is capped',
    pg_temp.tax_figure(v_comp, 'loss_used'), 150000);
  perform pg_temp.check_eq('the chargeable income is nothing',
    pg_temp.tax_figure(v_comp, 'chargeable_income'), 0);
  perform pg_temp.check_eq('and the rest carries forward',
    pg_temp.tax_figure(v_comp, 'loss_carried_forward'), 250000);
end $$;

-- ---------------------------------------------------------------------
-- The bands
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Kadar Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);

  -- Unknown: neither figure given. The standard rate is charged AND
  -- the computation says it does not know, rather than quietly
  -- assuming the company does not qualify.
  perform pg_temp.check_eq('with no SME figures the test is unknown',
    pg_temp.tax_flag(v_comp, 'sme_known')::text, 'false');
  perform pg_temp.check_eq('and the standard rate is charged',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 48000);

  -- HALF known, which is the state a half-filled form is in and is
  -- the one a careless guard gets wrong. A capital figure under the
  -- limit and no turnover figure at all must still be UNKNOWN: reading
  -- the missing half as passing would hand the 17% band to a company
  -- nobody has tested.
  update public.tax_computations set paid_up_capital = 500000
   where id = v_comp;
  perform pg_temp.check_eq('one figure alone is still unknown',
    pg_temp.tax_flag(v_comp, 'sme_known')::text, 'false');
  perform pg_temp.check_eq('and does not qualify on it',
    pg_temp.tax_flag(v_comp, 'is_sme')::text, 'false');
  perform pg_temp.check_eq('so the standard rate still applies',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 48000);

  -- And the other half alone.
  update public.tax_computations
     set paid_up_capital = null, gross_business_income = 500000
   where id = v_comp;
  perform pg_temp.check_eq('the other figure alone is unknown too',
    pg_temp.tax_flag(v_comp, 'sme_known')::text, 'false');
  perform pg_temp.check_eq('and is charged the standard rate',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 48000);

  -- An SME: 17% on the first 150,000 and 24% on the other 50,000.
  update public.tax_computations
     set paid_up_capital = 500000, gross_business_income = 500000
   where id = v_comp;
  perform pg_temp.check_eq('a small company qualifies',
    pg_temp.tax_flag(v_comp, 'is_sme')::text, 'true');
  perform pg_temp.check_eq(
    'and is charged 17% on the band and 24% above it',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 37500);

  -- Over the capital limit by one ringgit.
  update public.tax_computations set paid_up_capital = 2500001
   where id = v_comp;
  perform pg_temp.check_eq('a ringgit over the capital limit does not',
    pg_temp.tax_flag(v_comp, 'is_sme')::text, 'false');
  perform pg_temp.check_eq('and pays 24% on all of it',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 48000);

  -- Exactly at the limit still qualifies.
  update public.tax_computations set paid_up_capital = 2500000
   where id = v_comp;
  perform pg_temp.check_eq('exactly at the limit still qualifies',
    pg_temp.tax_flag(v_comp, 'is_sme')::text, 'true');

  -- Over the turnover limit.
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 50000001
   where id = v_comp;
  perform pg_temp.check_eq('and turnover disqualifies on its own',
    pg_temp.tax_flag(v_comp, 'is_sme')::text, 'false');
end $$;

do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Bawah Band Sdn Bhd');
  perform pg_temp.trade(v_org, 400000, 300000);
  v_comp := pg_temp.tax_comp(v_org);
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 400000
   where id = v_comp;

  -- 100,000 chargeable, entirely inside the band.
  perform pg_temp.check_eq('an income inside the band is all at 17%',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 17000);
end $$;

-- ---------------------------------------------------------------------
-- Zakat is a rebate, and it is capped
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Zakat Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 500000,
         zakat_paid = 10000
   where id = v_comp;

  perform pg_temp.check_eq('the tax charged is unaffected by zakat',
    pg_temp.tax_figure(v_comp, 'tax_charged'), 37500);
  perform pg_temp.check_eq('which comes off as a rebate',
    pg_temp.tax_figure(v_comp, 'zakat_rebate'), 10000);
  perform pg_temp.check_eq('leaving the tax payable',
    pg_temp.tax_figure(v_comp, 'tax_payable'), 27500);

  -- More zakat than tax. The rebate stops at the tax charged: s.6A(3)
  -- gives relief, not a refund.
  update public.tax_computations set zakat_paid = 90000 where id = v_comp;
  perform pg_temp.check_eq('a rebate never exceeds the tax charged',
    pg_temp.tax_figure(v_comp, 'zakat_rebate'), 37500);
  perform pg_temp.check_eq('so nothing is payable and nothing refunded',
    pg_temp.tax_figure(v_comp, 'tax_payable'), 0);
end $$;

-- ---------------------------------------------------------------------
-- What has already been paid
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Ansuran Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 500000,
         cp204_paid = 30000, s110_tax_deducted = 2000
   where id = v_comp;

  perform pg_temp.check_eq('instalments and deductions come off the tax',
    pg_temp.tax_figure(v_comp, 'tax_payable'), 5500);

  -- Overpaid. The figure goes NEGATIVE rather than stopping at zero:
  -- a refund is a real answer and rounding it away would hide money
  -- the company is owed.
  update public.tax_computations set cp204_paid = 50000 where id = v_comp;
  perform pg_temp.check_eq('and an overpayment is a refund, not a zero',
    pg_temp.tax_figure(v_comp, 'tax_payable'), -14500);
end $$;

-- ---------------------------------------------------------------------
-- A balancing charge is income; a balancing allowance is relief
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Jual Aset Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);

  -- Bought 2024 for 10,000 plant, sold 2026 for 9,000. `0664` puts the
  -- residual at 5,200 entering 2026, so a balancing CHARGE of 3,800.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code, disposal_date, disposal_proceeds,
     status)
  values (v_org, 'S-1', 'Mesin lama', date '2024-01-10', 10000,
          'straight_line', 60, 'plant', date '2026-05-05', 9000,
          'disposed');

  v_comp := pg_temp.tax_comp(v_org);

  perform pg_temp.check_eq('a balancing charge is reported on its own',
    pg_temp.tax_figure(v_comp, 'balancing_charge'), 3800);
  -- Added to income, NOT netted against the allowances. Netting would
  -- reduce a claim instead of increasing the income, which is a
  -- different figure whenever the claim is smaller than the charge.
  perform pg_temp.check_eq('and is added to the adjusted income',
    pg_temp.tax_figure(v_comp, 'adjusted_income'), 203800);
  perform pg_temp.check_eq('while the allowances stay nothing',
    pg_temp.tax_figure(v_comp, 'ca_current'), 0);
end $$;

do $$
declare v_org uuid; v_comp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Jual Rugi Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);

  -- The same asset sold for 3,000 against a 5,200 residual: a
  -- balancing ALLOWANCE of 2,200, which is relief and joins the claim.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code, disposal_date, disposal_proceeds,
     status)
  values (v_org, 'S-2', 'Mesin lama', date '2024-01-10', 10000,
          'straight_line', 60, 'plant', date '2026-05-05', 3000,
          'disposed');

  v_comp := pg_temp.tax_comp(v_org);

  perform pg_temp.check_eq('a balancing allowance joins the claim',
    pg_temp.tax_figure(v_comp, 'ca_current'), 2200);
  perform pg_temp.check_eq('and nothing is charged',
    pg_temp.tax_figure(v_comp, 'balancing_charge'), 0);
  perform pg_temp.check_eq('so the statutory income is lower by it',
    pg_temp.tax_figure(v_comp, 'statutory_income'), 197800);
end $$;

-- ---------------------------------------------------------------------
-- Who may read it and who may open one
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_comp uuid; v_outsider uuid; v_fy uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Rahsia Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  v_comp := pg_temp.tax_comp(v_org);
  select id into v_fy from public.fiscal_years
   where org_id = v_org order by end_date limit 1;

  v_outsider := pg_temp.another_user('taxoutsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_outsider);

  perform pg_temp.check_refused(
    'somebody outside the company cannot read the computation',
    format('select * from public.tax_computation(%L)', v_comp),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor its working',
    format('select * from public.tax_computation_lines(%L)', v_comp),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor open one of their own on it',
    format('select public.open_tax_computation(%L, %L)', v_org, v_fy),
    '%Insufficient privileges%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The rates are the platform's, not a tenant's
-- ---------------------------------------------------------------------
create temp table t_665 as select pg_temp.test_user() as owner_user;
grant select on t_665 to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from t_665),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare v_rate numeric; v_rows integer;
begin
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');

  select count(*) into v_rows from public.tax_treatments;
  perform pg_temp.check_true('the treatments are readable', v_rows >= 10);

  -- By effect, not by refusal: RLS hides rows from an UPDATE rather
  -- than raising on them. `0664`'s assertions learned this the same
  -- way, with "it was not refused at all".
  update public.company_tax_rates set standard_rate = 0.01;
  select standard_rate into v_rate from public.company_tax_rates
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('but a company cannot set its own tax rate',
    v_rate, 0.24);

  perform pg_temp.check_refused(
    'nor invent a treatment of its own',
    'insert into public.tax_treatments (code, label, kind) '
    'values (''mine'', ''Everything is deductible'', ''add_back'')',
    '%row-level security%');
end $$;

reset role;

rollback;

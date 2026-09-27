-- =====================================================================
-- iAkauntan :: Form B and Form P
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_forms_b_and_p.sql
--
-- `0666` adds the other two returns on the machinery `0665` already
-- had. Five things are worth naming:
--
--   1. **The three forms agree about the business.** They share one
--      function, and the assertion that they produce the same adjusted
--      income and the same allowances is the one that stops a
--      partner's Form B disagreeing with the Form P it came from.
--   2. **A partnership pays no tax.** It allocates. A Form P that
--      produced a tax figure would be wrong in the most expensive
--      possible direction.
--   3. **A partner's salary is not an expense.** It is added back and
--      handed to that partner, so the total allocated is the adjusted
--      income PLUS the appropriations -- which is asserted directly,
--      because it is the one sum that catches the add-back being done
--      once, twice or not at all.
--   4. **Reliefs stop at nothing.** More relief than income is not a
--      refund and not a carry-forward.
--   5. **The individual scale is PCB's.** One table, so the monthly
--      estimate and the annual return cannot disagree.
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

create or replace function pg_temp.tax_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.tax_comp(p_org uuid, p_form text)
returns uuid language plpgsql as $$
declare v_fy uuid; v_id uuid;
begin
  select id into v_fy from public.fiscal_years
   where org_id = p_org and end_date between date '2026-01-01'
                                         and date '2026-12-31'
   order by end_date limit 1;
  v_id := public.open_tax_computation(p_org, v_fy);
  update public.tax_computations set form = p_form where id = v_id;
  return v_id;
end; $$;

create or replace function pg_temp.trade(
  p_org uuid, p_revenue numeric, p_expense numeric)
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
   where org_id = p_org and code = '6100';

  if p_revenue > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_bank, v_sales, p_revenue), 'Sales', 'S-1');
  end if;
  if p_expense > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_expense, v_bank, p_expense), 'Costs', 'E-1');
  end if;
end; $$;

create or replace function pg_temp.b_figure(p_comp uuid, p_column text)
returns numeric language plpgsql as $$
declare v numeric;
begin
  execute format(
    'select %I from public.tax_computation_individual($1)', p_column)
    into v using p_comp;
  return v;
end; $$;

-- ---------------------------------------------------------------------
-- The three forms agree about the business
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_c uuid; v_b uuid;
  v_c_adj numeric; v_b_adj numeric;
  v_c_ca numeric; v_b_ca numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Tiga Borang Sdn Bhd');
  perform pg_temp.trade(v_org, 500000, 300000);
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'P-1', 'Mesin', date '2026-02-01', 100000,
          'straight_line', 60, 'plant');

  v_c := pg_temp.tax_comp(v_org, 'C');

  select adjusted_income, ca_current into v_c_adj, v_c_ca
    from public.tax_computation(v_c);
  select adjusted_income, ca_current into v_b_adj, v_b_ca
    from public.tax_computation_individual(v_c);

  -- THE ONE. Both read `app.tax_business_income`, so there is one
  -- answer rather than two that happen to match today. A partner's
  -- Form B disagreeing with the Form P it came from is an error
  -- nobody finds until LHDN does.
  perform pg_temp.check_eq(
    'Form C and Form B compute the same adjusted income',
    v_b_adj, v_c_adj);
  perform pg_temp.check_eq('and the same capital allowances',
    v_b_ca, v_c_ca);
  perform pg_temp.check_eq('which is the figure Schedule 3 produced',
    v_c_ca, 34000);
end $$;

-- ---------------------------------------------------------------------
-- Form B: the business is one source among several
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Encik Ali');
  perform pg_temp.trade(v_org, 200000, 140000);
  v_b := pg_temp.tax_comp(v_org, 'B');

  perform pg_temp.check_eq('the business gives its statutory income',
    pg_temp.b_figure(v_b, 'statutory_business'), 60000);
  perform pg_temp.check_eq('with no other source yet',
    pg_temp.b_figure(v_b, 'other_income'), 0);
  perform pg_temp.check_eq('the aggregate is the business alone',
    pg_temp.b_figure(v_b, 'aggregate_income'), 60000);

  insert into public.tax_other_income
    (org_id, computation_id, kind, label, amount)
  values (v_org, v_b, 'employment', 'Salary from Kedai Lain', 36000),
         (v_org, v_b, 'rental', 'Shoplot in Ipoh', 12000);

  perform pg_temp.check_eq('other sources join it',
    pg_temp.b_figure(v_b, 'other_income'), 48000);
  perform pg_temp.check_eq('at aggregate income',
    pg_temp.b_figure(v_b, 'aggregate_income'), 108000);
end $$;

-- ---------------------------------------------------------------------
-- Donations come off aggregate income and stop at nothing
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Derma');
  perform pg_temp.trade(v_org, 200000, 140000);
  v_b := pg_temp.tax_comp(v_org, 'B');

  update public.tax_computations set approved_donations = 10000
   where id = v_b;
  perform pg_temp.check_eq('an approved donation is allowed',
    pg_temp.b_figure(v_b, 'donations_allowed'), 10000);
  perform pg_temp.check_eq('and reduces the total income',
    pg_temp.b_figure(v_b, 'total_income'), 50000);

  -- Larger than the income. The excess is simply lost: it is not a
  -- loss to carry anywhere, and a total income below nothing would
  -- make every figure after it wrong.
  update public.tax_computations set approved_donations = 90000
   where id = v_b;
  perform pg_temp.check_eq('a donation larger than the income is capped',
    pg_temp.b_figure(v_b, 'donations_allowed'), 60000);
  perform pg_temp.check_eq('and the total income is nothing, not negative',
    pg_temp.b_figure(v_b, 'total_income'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Reliefs, and the scale
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Pelepasan');
  perform pg_temp.trade(v_org, 300000, 180000);
  v_b := pg_temp.tax_comp(v_org, 'B');

  -- 120,000 statutory. Reliefs of 9,000 + 4,000 + 2,500 = 15,500,
  -- leaving 104,500 chargeable.
  insert into public.tax_relief_claims
    (org_id, computation_id, relief_code, label, amount)
  values (v_org, v_b, 'individual', 'Individual', 9000),
         (v_org, v_b, 'epf', 'EPF', 4000),
         (v_org, v_b, 'lifestyle', 'Lifestyle', 2500);

  perform pg_temp.check_eq('the reliefs claimed',
    pg_temp.b_figure(v_b, 'reliefs_claimed'), 15500);
  perform pg_temp.check_eq('come off the total income',
    pg_temp.b_figure(v_b, 'chargeable_income'), 104500);

  -- The scale: 9,400 cumulative at 100,000, then 25% of the 4,500
  -- above it. Measured from 100,000 and not from 100,000.01 -- the
  -- published bands start a sen above the last, and measuring the
  -- marginal slice from the sen loses money on every boundary.
  perform pg_temp.check_eq('taxed at the resident individual scale',
    pg_temp.b_figure(v_b, 'tax_charged'), 9400 + 1125);
end $$;

do $$
declare v_org uuid; v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Pelepasan Banyak');
  perform pg_temp.trade(v_org, 200000, 180000);
  v_b := pg_temp.tax_comp(v_org, 'B');

  -- 20,000 of income and 50,000 of relief. Reliefs stop at nothing:
  -- more relief than income is not a refund and not a carry-forward.
  insert into public.tax_relief_claims
    (org_id, computation_id, label, amount)
  values (v_org, v_b, 'Everything', 50000);

  perform pg_temp.check_eq('more relief than income leaves nothing',
    pg_temp.b_figure(v_b, 'chargeable_income'), 0);
  perform pg_temp.check_eq('and no tax',
    pg_temp.b_figure(v_b, 'tax_charged'), 0);
  perform pg_temp.check_eq('and nothing payable',
    pg_temp.b_figure(v_b, 'tax_payable'), 0);
end $$;

-- ---------------------------------------------------------------------
-- The rebate under the threshold
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_b uuid; v_tax numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Rebat');
  perform pg_temp.trade(v_org, 60000, 20000);
  v_b := pg_temp.tax_comp(v_org, 'B');
  insert into public.tax_relief_claims
    (org_id, computation_id, label, amount)
  values (v_org, v_b, 'Individual', 9000);

  -- 31,000 chargeable, which is under the 35,000 threshold.
  perform pg_temp.check_eq('the chargeable income',
    pg_temp.b_figure(v_b, 'chargeable_income'), 31000);
  perform pg_temp.check_eq('a rebate applies under the threshold',
    pg_temp.b_figure(v_b, 'rebate'), 400);

  v_tax := pg_temp.b_figure(v_b, 'tax_charged');
  perform pg_temp.check_eq('and comes off the tax',
    pg_temp.b_figure(v_b, 'tax_payable'), v_tax - 400);

  -- Over the threshold by a ringgit: no rebate at all. It is a cliff
  -- rather than a taper, which is what the Act says and is the sort of
  -- edge a `<=` against a `<` gets wrong.
  insert into public.tax_relief_claims
    (org_id, computation_id, label, amount)
  values (v_org, v_b, 'Less relief', -0);
  update public.tax_relief_claims set amount = 4999
   where computation_id = v_b and label = 'Individual';
  perform pg_temp.check_eq('the chargeable income is now over it',
    pg_temp.b_figure(v_b, 'chargeable_income'), 35001);
  perform pg_temp.check_eq('so there is no rebate',
    pg_temp.b_figure(v_b, 'rebate'), 0);

  -- Exactly at the threshold still gets it.
  update public.tax_relief_claims set amount = 5000
   where computation_id = v_b and label = 'Individual';
  perform pg_temp.check_eq('exactly at the threshold still does',
    pg_temp.b_figure(v_b, 'rebate'), 400);
end $$;

do $$
declare v_org uuid; v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Zakat Sendiri');
  perform pg_temp.trade(v_org, 60000, 20000);
  v_b := pg_temp.tax_comp(v_org, 'B');
  insert into public.tax_relief_claims
    (org_id, computation_id, label, amount)
  values (v_org, v_b, 'Individual', 9000);
  update public.tax_computations set zakat_paid = 99999 where id = v_b;

  -- Two reliefs against one tax. Between them they cannot exceed it,
  -- and the rebate is taken first -- so the zakat rebate is what is
  -- left after it rather than the whole tax again.
  perform pg_temp.check_eq(
    'the rebate and the zakat together never exceed the tax',
    pg_temp.b_figure(v_b, 'rebate')
      + pg_temp.b_figure(v_b, 'zakat_rebate'),
    pg_temp.b_figure(v_b, 'tax_charged'));
  perform pg_temp.check_eq('so nothing is payable',
    pg_temp.b_figure(v_b, 'tax_payable'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Form P: a partnership is not a taxable person
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_p uuid;
  v_total numeric; v_ali numeric; v_abu numeric;
  v_adj numeric; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Ali dan Abu');
  -- 500,000 revenue, 300,000 expenses INCLUDING the partners' salaries.
  perform pg_temp.trade(v_org, 500000, 300000);
  v_p := pg_temp.tax_comp(v_org, 'P');

  insert into public.tax_partners
    (org_id, computation_id, name, share_percent, salary,
     interest_on_capital, sort_order)
  values
    (v_org, v_p, 'Ali', 60, 36000, 2000, 1),
    (v_org, v_p, 'Abu', 40, 24000, 1000, 2);

  select count(*) into v_rows
    from public.tax_partnership_allocation(v_p);
  perform pg_temp.check_eq('both partners are allocated to', v_rows, 2);

  select adjusted_income into v_adj from public.tax_computation(v_p);
  perform pg_temp.check_eq('the adjusted income as the accounts show it',
    v_adj, 200000);

  select statutory_income into v_ali
    from public.tax_partnership_allocation(v_p) where name = 'Ali';
  select statutory_income into v_abu
    from public.tax_partnership_allocation(v_p) where name = 'Abu';

  -- Ali: 60% of 200,000 = 120,000, plus 36,000 salary and 2,000
  -- interest, less 60% of nothing in allowances = 158,000.
  perform pg_temp.check_eq('a partner gets their share and their salary',
    v_ali, 158000);
  perform pg_temp.check_eq('and so does the other', v_abu, 105000);

  -- THE SUM THAT MATTERS. Everything allocated comes to the adjusted
  -- income PLUS the appropriations, which is the partnership's real
  -- figure once the salaries are added back. This is the one assertion
  -- that catches the add-back being done twice, or not at all.
  select sum(statutory_income) into v_total
    from public.tax_partnership_allocation(v_p);
  perform pg_temp.check_eq(
    'and between them they take the whole of it',
    v_total, 200000 + 63000);

  -- The same identity, stated by the summary the screen reads, so a
  -- half-entered Form P shows it rather than adding up quietly to the
  -- wrong number.
  perform pg_temp.check_eq('the summary agrees with the allocation',
    (select total_allocated from public.tax_partnership_summary(v_p)),
    v_total);
  perform pg_temp.check_eq(
    'and says what the partnership''s own adjusted income is',
    (select partnership_adjusted
       from public.tax_partnership_summary(v_p)),
    200000 + 63000);
  perform pg_temp.check_eq('with the shares coming to a hundred',
    (select shares_total from public.tax_partnership_summary(v_p)), 100);
end $$;

do $$
declare v_org uuid; v_p uuid; v_total numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Ali dan Abu Elaun');
  perform pg_temp.trade(v_org, 500000, 300000);
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, method,
     useful_life_months, ca_class_code)
  values (v_org, 'P-1', 'Mesin', date '2026-02-01', 100000,
          'straight_line', 60, 'plant');
  v_p := pg_temp.tax_comp(v_org, 'P');

  insert into public.tax_partners
    (org_id, computation_id, name, share_percent, sort_order)
  values (v_org, v_p, 'Ali', 60, 1), (v_org, v_p, 'Abu', 40, 2);

  -- The allowances belong to the partners, not to the partnership: it
  -- has no income of its own to set them against. 34,000 split 60/40.
  perform pg_temp.check_eq('allowances follow the same ratio',
    (select capital_allowances
       from public.tax_partnership_allocation(v_p) where name = 'Ali'),
    20400);
  select sum(capital_allowances) into v_total
    from public.tax_partnership_allocation(v_p);
  perform pg_temp.check_eq('and all of them are allocated',
    v_total, 34000);

  -- And they come OFF the partner's statutory income. The fixture
  -- above has no fixed asset, so a mutant that stopped subtracting
  -- them survived there -- every figure was the same because every
  -- allowance was nothing. 60% of 200,000 less 60% of 34,000.
  perform pg_temp.check_eq(
    'and a partner''s statutory income is net of their share of them',
    (select statutory_income
       from public.tax_partnership_allocation(v_p) where name = 'Ali'),
    120000 - 20400);
  select sum(statutory_income) into v_total
    from public.tax_partnership_allocation(v_p);
  perform pg_temp.check_eq(
    'so between them they take the income less the allowances',
    v_total, 200000 - 34000);
end $$;

do $$
declare v_org uuid; v_p uuid; v_share numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Ali dan Abu Rugi');
  -- A loss.
  perform pg_temp.trade(v_org, 100000, 180000);
  v_p := pg_temp.tax_comp(v_org, 'P');
  insert into public.tax_partners
    (org_id, computation_id, name, share_percent, sort_order)
  values (v_org, v_p, 'Ali', 60, 1), (v_org, v_p, 'Abu', 40, 2);

  -- `app.tax_business_income` reports an adjusted income of nothing
  -- and a loss of 80,000 beside it, so a partner's share of the
  -- divisible income is nothing. The LOSS is the partnership's to
  -- carry and is not allocated here -- worth pinning, because a share
  -- of a loss silently allocated as income would be the worst
  -- possible answer.
  select share_of_divisible into v_share
    from public.tax_partnership_allocation(v_p) where name = 'Ali';
  perform pg_temp.check_eq('a loss year allocates no income', v_share, 0);
end $$;

-- ---------------------------------------------------------------------
-- Who may read them
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_b uuid; v_outsider uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.tax_org('Kedai Rahsia Peribadi');
  perform pg_temp.trade(v_org, 200000, 140000);
  v_b := pg_temp.tax_comp(v_org, 'B');

  v_outsider := pg_temp.another_user('bpoutsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_outsider);

  perform pg_temp.check_refused(
    'an outsider cannot read a Form B',
    format('select * from public.tax_computation_individual(%L)', v_b),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor a partnership allocation',
    format('select * from public.tax_partnership_allocation(%L)', v_b),
    '%Insufficient privileges%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The individual scale is the one PCB uses
-- ---------------------------------------------------------------------
do $$
declare v_count integer;
begin
  -- One scale, not two. A second copy would be a second thing to
  -- change when the Budget moves it, and nothing would say which of
  -- them PCB was using.
  select count(*) into v_count
    from public.statutory_schedules s
   where s.body = 'pcb';
  perform pg_temp.check_eq(
    'there is exactly one resident individual scale', v_count, 1);

  select count(*) into v_count from public.individual_tax_rebates
   where is_verified;
  perform pg_temp.check_eq(
    'and nothing seeded claims to have been checked against the Act',
    v_count, 0);
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: CP204 estimates
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_estimates.sql
--
-- `0667` is the half of the year that runs before the numbers exist. A
-- company says what it thinks it will owe, pays that monthly, and is
-- penalised if it guessed too low.
--
-- Four things are worth naming:
--
--   1. **The schedule adds up to the estimate.** Twelve equal
--      instalments of a figure that does not divide by twelve come to
--      a few sen out, and an instalment plan that does not total the
--      thing it pays is the first thing anybody notices.
--   2. **The floor and the exposure are different questions.** An
--      estimate can clear 85% of last year's comfortably and still be
--      penalised, because the penalty is measured against what was
--      ACTUALLY owed.
--   3. **The tolerance is a share of the actual, not of the estimate.**
--      Measured the other way, a company that estimated nothing would
--      be penalised on nothing.
--   4. **A revision keeps the original.** The floor for next year is
--      measured against the revised figure and the original has to
--      survive to be compared with.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.est_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.est_year(p_org uuid)
returns uuid language sql stable as $$
  select id from public.fiscal_years
   where org_id = p_org
     and end_date between date '2026-01-01' and date '2026-12-31'
   order by end_date limit 1;
$$;

-- ---------------------------------------------------------------------
-- The rules are the published ones
-- ---------------------------------------------------------------------
-- Every lookup here names the FORM as well as the year. It did not,
-- until `0670` gave the table a second row per year for CP500 -- at
-- which point `select ... into` was picking whichever row the heap
-- handed back first, and this file went on passing because that
-- happened to be the CP204 one. It stopped being the CP204 one when
-- `0671` rewrote the rows, and the assertion that had been measuring
-- nothing in particular finally said so.
--
-- `select ... into` takes the first row and does not complain about
-- the rest, so widening a table's key can silently change what an
-- older test measures. Naming the key is the fix; the lesson is that
-- a green suite is not evidence a query still means what it did.
do $$
declare v numeric; v_count integer; v_months integer[];
begin
  select floor_percent_of_prior into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('an estimate must be 85% of last year''s',
    v, 85);
  select under_tolerance_percent into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('the under-estimation tolerance is 30%', v, 30);
  select under_penalty_percent into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('and the penalty on the excess is 10%', v, 10);
  select instalments into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('paid in twelve instalments', v, 12);

  select revision_months into v_months from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('revisable in the sixth and ninth months',
    array_to_string(v_months, ','), '6,9');

  select count(*) into v_count from public.tax_estimate_rules
   where is_verified;
  perform pg_temp.check_eq(
    'nothing seeded claims to have been checked against the Act',
    v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- The instalments
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_total numeric; v_rows integer;
  v_first date; v_last date; v_amount numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Ansuran Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.est_year(v_org), 120000);

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('twelve instalments', v_rows, 12);

  select amount into v_amount from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('each of ten thousand', v_amount, 10000);

  -- The first falls in the SECOND month of the basis period, on the
  -- fifteenth. A schedule starting in the first month pays a month
  -- early for twelve years running.
  select due_on into v_first from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('the first is due in the second month',
    v_first::text, '2026-02-15');
  select due_on into v_last from public.tax_estimate_schedule(v_est)
   where instalment_no = 12;
  perform pg_temp.check_eq('and the last a year after that',
    v_last::text, '2027-01-15');
end $$;

do $$
declare v_org uuid; v_est uuid; v_total numeric; v_last numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Baki Sen Sdn Bhd');
  -- 100,000 / 12 is 8,333.333... Twelve of 8,333.33 is 99,999.96.
  v_est := public.open_tax_estimate(v_org, pg_temp.est_year(v_org), 100000);

  select sum(amount) into v_total from public.tax_estimate_schedule(v_est);
  -- THE ONE. The last instalment carries the rounding, so the schedule
  -- totals the estimate exactly. Without it the plan is four sen short
  -- of the thing it pays.
  perform pg_temp.check_eq('the instalments total the estimate exactly',
    v_total, 100000);

  select amount into v_last from public.tax_estimate_schedule(v_est)
   where instalment_no = 12;
  perform pg_temp.check_eq('with the last one carrying the difference',
    v_last, 8333.37);
end $$;

-- ---------------------------------------------------------------------
-- The floor against last year
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_meets boolean; v_known boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Lantai Sdn Bhd');
  -- Last year's was 100,000, so the floor is 85,000.
  v_est := public.open_tax_estimate(
    v_org, pg_temp.est_year(v_org), 85000, 100000);

  select meets_floor into v_meets
    from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_eq('exactly 85% clears the floor',
    v_meets::text, 'true');

  update public.tax_estimates set estimated_tax = 84999 where id = v_est;
  select meets_floor into v_meets
    from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_eq('a ringgit under does not',
    v_meets::text, 'false');

  -- Unknown reads as NOT meeting it. A tick beside a figure nobody has
  -- checked is worse than an honest question mark.
  update public.tax_estimates set prior_estimate = null where id = v_est;
  select meets_floor, floor_known into v_meets, v_known
    from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_eq('with no prior year the floor is unknown',
    v_known::text, 'false');
  perform pg_temp.check_eq('and unknown does not read as met',
    v_meets::text, 'false');
end $$;

-- ---------------------------------------------------------------------
-- The exposure, which is a different question
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_comp uuid; v_fy uuid;
  v_bank uuid; v_sales uuid; v_expense uuid;
  v_actual numeric; v_short numeric; v_tol numeric;
  v_excess numeric; v_penalty numeric; v_known boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Terkurang Sdn Bhd');
  v_fy := pg_temp.est_year(v_org);

  -- A real year: 500,000 revenue less 300,000 costs, and an SME, so
  -- the tax charged is 37,500.
  select id into v_bank from public.accounts
   where org_id = v_org and account_subtype = 'bank' and not is_group
   order by code limit 1;
  select id into v_sales from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group
   order by code limit 1;
  select id into v_expense from public.accounts
   where org_id = v_org and code = '6100';

  perform public.post_manual_journal(v_org, date '2026-06-30',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 500000, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 500000)),
    'Sales', 'S-1');
  perform public.post_manual_journal(v_org, date '2026-06-30',
    jsonb_build_array(
      jsonb_build_object('account_id', v_expense, 'debit', 300000, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 300000)),
    'Costs', 'E-1');

  v_comp := public.open_tax_computation(v_org, v_fy);
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 500000
   where id = v_comp;

  -- Estimated 10,000 against an actual 37,500.
  v_est := public.open_tax_estimate(v_org, v_fy, 10000, 5000);

  select actual_tax, actual_known, shortfall, tolerance_amount,
         excess_over_tolerance, penalty
    into v_actual, v_known, v_short, v_tol, v_excess, v_penalty
    from public.tax_estimate_exposure(v_est, v_comp);

  perform pg_temp.check_eq('the actual liability is known once computed',
    v_known::text, 'true');
  perform pg_temp.check_eq('and is the tax charged', v_actual, 37500);
  perform pg_temp.check_eq('the shortfall is the difference',
    v_short, 27500);
  -- 30% OF THE ACTUAL, not of the estimate. The other way round a
  -- company that estimated nothing would be penalised on nothing.
  perform pg_temp.check_eq('the tolerance is 30% of what was owed',
    v_tol, 11250);
  perform pg_temp.check_eq('the excess beyond it', v_excess, 16250);
  perform pg_temp.check_eq('and the penalty is 10% of that',
    v_penalty, 1625);

  -- This estimate CLEARS the floor -- 10,000 against a floor of 4,250 --
  -- and is still penalised. Two questions, two answers.
  perform pg_temp.check_eq(
    'an estimate can clear the floor and still be penalised',
    (select meets_floor from public.tax_estimate_exposure(v_est, v_comp))
      ::text, 'true');
end $$;

do $$
declare
  v_org uuid; v_est uuid; v_comp uuid; v_fy uuid;
  v_bank uuid; v_sales uuid; v_expense uuid; v_penalty numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Cukup Sdn Bhd');
  v_fy := pg_temp.est_year(v_org);

  select id into v_bank from public.accounts
   where org_id = v_org and account_subtype = 'bank' and not is_group
   order by code limit 1;
  select id into v_sales from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group
   order by code limit 1;
  select id into v_expense from public.accounts
   where org_id = v_org and code = '6100';

  perform public.post_manual_journal(v_org, date '2026-06-30',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 500000, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 500000)),
    'Sales', 'S-1');
  perform public.post_manual_journal(v_org, date '2026-06-30',
    jsonb_build_array(
      jsonb_build_object('account_id', v_expense, 'debit', 300000, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 300000)),
    'Costs', 'E-1');

  v_comp := public.open_tax_computation(v_org, v_fy);
  update public.tax_computations
     set paid_up_capital = 100000, gross_business_income = 500000
   where id = v_comp;

  -- 37,500 actual, 30% tolerance = 11,250. An estimate of 26,250 is
  -- exactly on the line and costs nothing.
  v_est := public.open_tax_estimate(v_org, v_fy, 26250, 5000);
  select penalty into v_penalty
    from public.tax_estimate_exposure(v_est, v_comp);
  perform pg_temp.check_eq('an estimate exactly on the tolerance costs nothing',
    v_penalty, 0);

  -- Over-estimating costs nothing either. There is no penalty for
  -- being cautious, and a shortfall clamped at nothing is what says so.
  update public.tax_estimates set estimated_tax = 99000 where id = v_est;
  perform pg_temp.check_eq('and neither does over-estimating',
    (select shortfall from public.tax_estimate_exposure(v_est, v_comp)), 0);
  perform pg_temp.check_eq('with no penalty',
    (select penalty from public.tax_estimate_exposure(v_est, v_comp)), 0);
end $$;

do $$
declare v_org uuid; v_est uuid; v_known boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Belum Tahu Sdn Bhd');
  v_est := public.open_tax_estimate(
    v_org, pg_temp.est_year(v_org), 10000, 5000);

  -- No computation to measure against. The floor question can still be
  -- answered; the exposure one cannot, and says so rather than
  -- reporting a penalty of nothing.
  select actual_known into v_known
    from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_eq(
    'without a computation the exposure is unknown',
    v_known::text, 'false');
  perform pg_temp.check_true('and the penalty is null, not zero',
    (select penalty from public.tax_estimate_exposure(v_est)) is null);
  perform pg_temp.check_eq('while the floor is still answered',
    (select meets_floor from public.tax_estimate_exposure(v_est))::text,
    'true');
end $$;

-- ---------------------------------------------------------------------
-- Revising one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_new uuid; v_status text;
  v_prior numeric; v_revises uuid; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Ubah Sdn Bhd');
  v_est := public.open_tax_estimate(
    v_org, pg_temp.est_year(v_org), 50000, 60000);

  v_new := public.revise_tax_estimate(v_est, 80000);
  perform pg_temp.check_true('a revision is a new row', v_new <> v_est);

  select status into v_status from public.tax_estimates where id = v_est;
  perform pg_temp.check_eq('and supersedes the old one',
    v_status, 'superseded');

  -- THE ONE. The original survives, because next year's floor is
  -- measured against the REVISED figure and this year's against the
  -- one before it -- an overwrite would lose whichever was needed.
  select count(*) into v_rows from public.tax_estimates
   where fiscal_year_id = pg_temp.est_year(v_org);
  perform pg_temp.check_eq('both are kept', v_rows, 2);

  select revises_id into v_revises from public.tax_estimates
   where id = v_new;
  perform pg_temp.check_eq('and the revision points at what it replaced',
    v_revises::text, v_est::text);

  -- The floor is still last year's figure, not the estimate being
  -- replaced. Carrying the superseded one forward would let a company
  -- ratchet its own floor down by revising twice.
  select prior_estimate into v_prior from public.tax_estimates
   where id = v_new;
  perform pg_temp.check_eq(
    'the floor is still measured against last year',
    v_prior, 60000);

  -- Opening again hands back the live one rather than making a third.
  perform pg_temp.check_eq('opening it again returns the live one',
    (public.open_tax_estimate(v_org, pg_temp.est_year(v_org)))::text,
    v_new::text);

  perform pg_temp.check_refused(
    'a negative revision is refused',
    format('select public.revise_tax_estimate(%L, -1)', v_new),
    '%cannot be negative%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_fy uuid; v_outsider uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.est_org('Kedai Rahsia Anggaran');
  v_fy := pg_temp.est_year(v_org);
  v_est := public.open_tax_estimate(v_org, v_fy, 10000);

  v_outsider := pg_temp.another_user('estoutsider@iakauntan.test');
  perform pg_temp.sign_in_as(v_outsider);

  perform pg_temp.check_refused(
    'an outsider cannot read the schedule',
    format('select * from public.tax_estimate_schedule(%L)', v_est),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor the exposure',
    format('select * from public.tax_estimate_exposure(%L)', v_est),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor open one',
    format('select public.open_tax_estimate(%L, %L, 1)', v_org, v_fy),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor revise one',
    format('select public.revise_tax_estimate(%L, 1)', v_est),
    '%Insufficient privileges%', '42501');
end $$;

rollback;

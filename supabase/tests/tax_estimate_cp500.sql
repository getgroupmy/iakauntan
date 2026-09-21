-- =====================================================================
-- iAkauntan :: CP500, and why the form has to be asked
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_estimate_cp500.sql
--
-- `0667` built the estimate machinery company-shaped: twelve monthly
-- instalments on the fifteenth, with a floor of 85% of last year's.
-- That is CP204 under s.107C and it is right for a company. A sole
-- proprietor pays under s.107B -- CP500 -- on a different rhythm
-- entirely, and `open_tax_estimate` did not ask.
--
-- So this file is mostly about the difference, because the failure it
-- guards against is not an absence. It is a sole proprietor being
-- handed twelve wrong dates printed with the confidence of right ones:
--
--   1. **Six instalments, not twelve**, two months apart, on the 30th.
--   2. **No floor.** LHDN issues a CP500 rather than the taxpayer
--      proposing one, so reporting an estimate as failing a floor
--      would be inventing a rule. `floor_applies` is what separates
--      "does not arise" from "cannot be checked".
--   3. **The 30th of a month that has no 30th.** February. The date
--      clamps rather than raising, which is why `0668`'s
--      `app.tax_filing_fixed_date` is reused instead of `make_date`.
--   4. **A revision keeps the form.** Otherwise the revised row takes
--      the column default and a sole proprietor becomes a company from
--      the second estimate on -- the original bug, one step later.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.person_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  -- A person's basis year IS the calendar year under s.21, so the
  -- CP500 months are both calendar months and months of the period.
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
-- The rules are the published ones, and there are now two sets
-- ---------------------------------------------------------------------
do $$
declare v numeric; v_count integer; v_months integer[];
begin
  select count(*) into v_count from public.tax_estimate_rules
   where year_of_assessment = 2026;
  perform pg_temp.check_eq('a year of assessment has two rhythms in it',
    v_count, 2);

  select instalments into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP500';
  perform pg_temp.check_eq('a person pays in six instalments', v, 6);

  select months_between into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP500';
  perform pg_temp.check_eq('two months apart', v, 2);

  select instalment_day into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP500';
  perform pg_temp.check_eq('on the thirtieth', v, 30);

  -- The company rules are untouched. `0670` widened the table and a
  -- widening that moved the existing rows would be the worse bug.
  select instalments into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('and a company still pays twelve', v, 12);

  select instalment_day into v from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP204';
  perform pg_temp.check_eq('on the fifteenth', v, 15);

  perform pg_temp.check_true('a CP500 has no floor',
    exists (select 1 from public.tax_estimate_rules
             where year_of_assessment = 2026 and form = 'CP500'
               and not has_floor));
  perform pg_temp.check_true('and a CP204 does',
    exists (select 1 from public.tax_estimate_rules
             where year_of_assessment = 2026 and form = 'CP204'
               and has_floor));

  select revision_months into v_months from public.tax_estimate_rules
   where year_of_assessment = 2026 and form = 'CP500';
  perform pg_temp.check_eq('a person revises by the sixth month',
    array_to_string(v_months, ','), '6');

  select count(*) into v_count from public.tax_estimate_rules
   where is_verified;
  perform pg_temp.check_eq(
    'and nothing seeded claims to have been checked against the Act',
    v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- Which form, decided from the entity type
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a sole proprietor pays CP500',
    app.tax_estimate_form('sole_proprietor'), 'CP500');
  perform pg_temp.check_eq('so does an enterprise',
    app.tax_estimate_form('enterprise'), 'CP500');
  perform pg_temp.check_eq('and an individual',
    app.tax_estimate_form('individual'), 'CP500');
  perform pg_temp.check_eq('a Sdn Bhd pays CP204',
    app.tax_estimate_form('sdn_bhd'), 'CP204');
  perform pg_temp.check_eq('and an LLP, which is taxed as a company',
    app.tax_estimate_form('llp'), 'CP204');
  -- An entity type nobody recognises gets the company form, which is
  -- what this product mostly holds. Wrong in the direction that shows
  -- up as twelve dates rather than six silent ones.
  perform pg_temp.check_eq('and anything unrecognised gets CP204',
    app.tax_estimate_form('something_nobody_added'), 'CP204');
end $$;

-- ---------------------------------------------------------------------
-- The schedule a person actually gets
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_rows integer; v_total numeric;
  v_d1 date; v_d2 date; v_d6 date; v_amount numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.person_org('Kedai Runcit Pak Din');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 60000);

  perform pg_temp.check_eq('opening it picks CP500 without being asked',
    (select form from public.tax_estimates where id = v_est), 'CP500');

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('six instalments, not twelve', v_rows, 6);

  select amount into v_amount from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('of ten thousand each', v_amount, 10000);

  -- March, May and January of the following year. The dates are the
  -- whole point: twelve monthly ones would be wrong six times over
  -- and look exactly as confident.
  select due_on into v_d1 from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('the first falls on 30 March',
    v_d1::text, '2026-03-30');

  select due_on into v_d2 from public.tax_estimate_schedule(v_est)
   where instalment_no = 2;
  perform pg_temp.check_eq('the second two months later, not one',
    v_d2::text, '2026-05-30');

  select due_on into v_d6 from public.tax_estimate_schedule(v_est)
   where instalment_no = 6;
  perform pg_temp.check_eq('and the last in the January after',
    v_d6::text, '2027-01-30');

  -- The cast still adds up. A rhythm change that lost a sen would be
  -- the first thing anybody noticed.
  select sum(amount) into v_total from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('and they come to the estimate exactly',
    v_total, 60000);
end $$;

-- ---------------------------------------------------------------------
-- A company's schedule is untouched
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_rows integer; v_first date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Syarikat Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  perform pg_temp.check_eq('a company still opens a CP204',
    (select form from public.tax_estimates where id = v_est), 'CP204');

  select count(*) into v_rows from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('with twelve instalments', v_rows, 12);

  select due_on into v_first from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('the first in the second month, on the 15th',
    v_first::text, '2026-02-15');
end $$;

-- ---------------------------------------------------------------------
-- The 30th of a month that has no 30th
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_due date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Februari');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  -- A period starting in December puts an instalment in February --
  -- which has no 30th. `make_date(2027, 2, 30)` RAISES, so the whole
  -- schedule would fail rather than one date being wrong.
  perform public.create_fiscal_year(v_org, date '2026-12-01');

  v_est := public.open_tax_estimate(
    v_org,
    (select id from public.fiscal_years where org_id = v_org
      order by end_date desc limit 1),
    12000);

  -- Month 3 of a period opening in December is February.
  select due_on into v_due from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('a 30th asked of February is the 28th',
    v_due::text, '2027-02-28');
end $$;

-- ---------------------------------------------------------------------
-- No floor is not the same as an unknown floor
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; e record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.person_org('Kedai Tanpa Lantai');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 1000);

  select * into e from public.tax_estimate_exposure(v_est);

  perform pg_temp.check_eq('the exposure says which form it is',
    e.form, 'CP500');

  -- THE assertion this section exists for. A CP500 estimate of a
  -- thousand ringgit against a prior year of anything does not FAIL a
  -- floor -- there is no floor to fail. `0667` could only say "not
  -- met", which reads as a red mark against a rule that does not
  -- exist.
  perform pg_temp.check_true('a CP500 has no floor to fail',
    not e.floor_applies);
  perform pg_temp.check_true('so nothing is required of it',
    e.floor_required is null);
  perform pg_temp.check_true('and the question is not merely unanswered',
    not e.floor_known);

  -- Even with last year's figure typed in, which is the state that
  -- would otherwise make a floor computable.
  update public.tax_estimates set prior_estimate = 80000 where id = v_est;
  select * into e from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_true(
    'and typing last year''s figure does not conjure one',
    not e.floor_applies and e.floor_required is null);
end $$;

-- ---------------------------------------------------------------------
-- A company's floor still works
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; e record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Berlantai Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_est := public.open_tax_estimate(
    v_org, pg_temp.year_of(v_org), 60000, 80000);

  select * into e from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_true('a CP204 still has a floor', e.floor_applies);
  perform pg_temp.check_eq('of 85% of last year''s',
    e.floor_required, 68000);
  perform pg_temp.check_true('which sixty thousand does not clear',
    not e.meets_floor);
  perform pg_temp.check_true('and the question was answerable',
    e.floor_known);
end $$;

-- ---------------------------------------------------------------------
-- A revision keeps the form
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.person_org('Kedai Ubah Pak Mail');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 60000);
  v_new := public.revise_tax_estimate(v_est, 90000);

  -- Without this the revised row takes the column default -- CP204 --
  -- and the sole proprietor becomes a company from the second
  -- estimate on. The original bug, one step later, and harder to see
  -- because the first schedule was right.
  perform pg_temp.check_eq('a revised CP500 is still a CP500',
    (select form from public.tax_estimates where id = v_new), 'CP500');

  select count(*) into v_rows from public.tax_estimate_schedule(v_new);
  perform pg_temp.check_eq('and still pays in six', v_rows, 6);

  perform pg_temp.check_eq('the original is kept',
    (select status from public.tax_estimates where id = v_est),
    'superseded');
end $$;

rollback;

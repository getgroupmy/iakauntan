-- =====================================================================
-- iAkauntan :: the tax stack, as one year
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_stack_end_to_end.sql
--
-- `0664` through `0674` each assert their own piece. Nothing asserts
-- that the pieces AGREE, and this stretch has already produced two
-- cases where a later migration quietly changed what an earlier test
-- measured:
--
--   * `0670` gave `tax_estimate_rules` a second row per year, after
--     which `tax_estimates.sql` was reading whichever row the heap
--     handed back — and passing, because that happened to be the
--     right one.
--   * `0671` rewrote those rows and it finally said so.
--
-- A per-migration test cannot catch that. This walks one company
-- through one year in the order a person would — open the
-- computation, open the estimate, revise it, pay instalments, file
-- the return — and after each step asks the OTHER surfaces whether
-- they agree. Two screens printing different answers about one
-- obligation is worse than either being wrong alone, and the calendar
-- and the home-screen tile are two screens.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A 30 June year end, for the reason `tax_filing_calendar.sql` gives:
-- a December one makes the basis period, the year of assessment and
-- the calendar year agree, and every clock error passes.
--
-- The year is 2026-27 rather than 2025-26 on purpose. A CP204 is due
-- thirty days BEFORE its period opens, and `tax_upcoming_filings`
-- shows a year either side of today -- so the 2025-26 estimate's
-- deadline fell 478 days ago and is correctly off the calendar
-- altogether. Asserting the calendar can see it would have been
-- asserting a bug.
create or replace function pg_temp.june_co(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-07-01');
  return v_org;
end; $$;

create or replace function pg_temp.fy_of(p_org uuid)
returns uuid language sql stable as $$
  select id from public.fiscal_years
   where org_id = p_org and end_date = date '2027-06-30' limit 1;
$$;

-- What the dashboard tile says, so each step can ask it.
create or replace function pg_temp.tile(p_org uuid, p_key text)
returns text language sql stable as $$
  select public.module_dashboard(p_org) -> 'tax' ->> p_key;
$$;

-- ---------------------------------------------------------------------
-- The year, in order
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_comp uuid; v_est uuid; v_rev uuid;
  v_count integer; v_due date; r record; s record; e record;
  v_sched numeric; v_paid numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.june_co('Kedai Setahun Sdn Bhd');
  v_fy := pg_temp.fy_of(v_org);

  -- ===== 1. The calendar knows what is owed before anything exists ==
  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2027-06-30';
  perform pg_temp.check_eq('a Form C is owed from the start', v_count, 1);

  -- And the tile is reading the same function, so it agrees.
  --
  -- This compares the two; it does not pin the BOUNDARY. Whether a
  -- return due exactly today counts as overdue needs an obligation
  -- falling on today, which takes a fixture built for it — a
  -- financial year starting thirty days from now, so its CP204 lands
  -- on today. That lives in `tax_dashboard_tile.sql`, and a mutant
  -- flipping `<` to `<=` survives here for want of it. Reproducing
  -- the fixture would be re-testing the boundary in a file whose job
  -- is whether the layers agree.
  perform pg_temp.check_eq('and the tile agrees about what is overdue',
    pg_temp.tile(v_org, 'overdue'),
    (select count(*)::text from public.tax_upcoming_filings(v_org, 120)
      where due_date < app.today()));

  -- ===== 2. Open the computation ====================================
  v_comp := public.open_tax_computation(v_org, v_fy);
  perform pg_temp.check_true('a computation opens', v_comp is not null);

  -- The calendar now knows there is a working behind the Form C. A
  -- deadline with nothing behind it and one somebody has started are
  -- different things, and the screen offers a way in only for the
  -- second.
  select computation_id into r
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2027-06-30';
  perform pg_temp.check_true('and the calendar can see it',
    r.computation_id = v_comp);

  -- ===== 3. Open the estimate =======================================
  v_est := public.open_tax_estimate(v_org, v_fy, 120000);

  -- `0670`: the form comes from the entity type, not from whoever
  -- pressed the button.
  perform pg_temp.check_eq('a company opens a CP204',
    (select form from public.tax_estimates where id = v_est), 'CP204');

  -- `0667` + `0672`: twelve instalments totalling the estimate.
  select count(*), sum(amount) into v_count, v_sched
    from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('with twelve instalments', v_count, 12);
  perform pg_temp.check_eq('adding up to the estimate', v_sched, 120000);

  -- And the calendar can see the estimate, the same way it saw the
  -- computation.
  select estimate_id into r
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and period_to = date '2027-06-30';
  perform pg_temp.check_true('the calendar can see the estimate too',
    r.estimate_id = v_est);

  -- ===== 4. Pay the first three instalments =========================
  perform public.record_tax_instalment(v_est, 1, date '2026-08-15', 10000);
  perform public.record_tax_instalment(v_est, 2, date '2026-09-15', 10000);
  perform public.record_tax_instalment(v_est, 3, date '2026-10-15', 10000);

  select * into s from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('three paid', s.instalments_paid, 3);
  perform pg_temp.check_eq('thirty thousand of it', s.paid_total, 30000);

  -- The tile reads the SAME summary, so it cannot disagree.
  perform pg_temp.check_eq('and the tile counts the same arrears',
    pg_temp.tile(v_org, 'instalments_overdue'), s.overdue_count::text);

  -- ===== 5. Revise upward in the ninth month ========================
  v_rev := public.revise_tax_estimate(v_est, 240000);
  update public.tax_estimates set revision_month = 9 where id = v_rev;

  -- `0672`: what was already due does not move.
  perform pg_temp.check_eq('the paid instalments keep their figure',
    (select amount from public.tax_estimate_schedule(v_rev)
      where instalment_no = 2), 10000);
  perform pg_temp.check_eq('and the balance spreads over what is left',
    (select amount from public.tax_estimate_schedule(v_rev)
      where instalment_no = 8), 34000);

  -- `0673`: and the payments made before the revision survive it.
  select * into s from public.tax_estimate_payment_summary(v_rev);
  perform pg_temp.check_eq('the three payments are still counted',
    s.instalments_paid, 3);
  perform pg_temp.check_eq('and still total thirty thousand',
    s.paid_total, 30000);

  -- The calendar now points at the REVISION rather than the original,
  -- because the original is superseded.
  select estimate_id into r
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and period_to = date '2027-06-30';
  perform pg_temp.check_true('and the calendar follows the revision',
    r.estimate_id = v_rev);

  -- ===== 6. File the Form C =========================================
  perform public.record_tax_filing(
    v_org, 'form_c', date '2027-06-30', 'filed', date '2028-01-20',
    'ACK-END-TO-END');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2027-06-30';
  perform pg_temp.check_eq('the Form C comes off the calendar', v_count, 0);

  -- It moved rather than vanished.
  perform pg_temp.check_eq('and its acknowledgement is readable',
    (select reference from public.tax_filing_history(v_org, 100)
      where filing_type = 'form_c'), 'ACK-END-TO-END');

  -- And the CP204 is untouched by it: one obligation being dealt with
  -- must not take another off, which is the whole reason `0669` keys
  -- on the type AND the period.
  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and period_to = date '2027-06-30';
  perform pg_temp.check_eq('while the CP204 is still there', v_count, 1);

  -- ===== 7. And next year is a different obligation =================
  -- A company has consecutive years, and the key is the type AND the
  -- period. With ONE year on the books, a join that matched any
  -- recorded filing of the right type gives the same answers as the
  -- correct one — so the second year is what makes the assertion
  -- above a statement about the period rather than about the type.
  perform public.create_fiscal_year(v_org, date '2027-07-01');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2028-06-30';
  perform pg_temp.check_eq(
    'next year''s Form C is owed however this year''s was dealt with',
    v_count, 1);

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2027-06-30';
  perform pg_temp.check_eq('and this year''s stays filed', v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- A sole proprietor walks a different path through the same code
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_comp uuid; v_est uuid; e record;
  v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Runcit Setahun');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  -- A person's basis year IS the calendar year under s.21.
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_fy := (select id from public.fiscal_years
            where org_id = v_org and end_date = date '2026-12-31');

  -- `0668`: no Form C, a Form B instead.
  perform pg_temp.check_eq('no Form C for a person',
    (select count(*) from public.tax_upcoming_filings(v_org, 3650)
      where filing_type = 'form_c'), 0);
  perform pg_temp.check_true('but a Form B',
    exists (select 1 from public.tax_upcoming_filings(v_org, 3650)
             where filing_type = 'form_b'));

  -- `0670`: and a CP500, on six bimonthly instalments.
  v_est := public.open_tax_estimate(v_org, v_fy, 60000);
  perform pg_temp.check_eq('a person opens a CP500',
    (select form from public.tax_estimates where id = v_est), 'CP500');
  select count(*) into v_count from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('paying in six', v_count, 6);
  perform pg_temp.check_eq('the first on 30 March',
    (select due_on::text from public.tax_estimate_schedule(v_est)
      where instalment_no = 1), '2026-03-30');

  -- `0670`: and no floor to fail, which is not the same as failing one.
  select * into e from public.tax_estimate_exposure(v_est);
  perform pg_temp.check_true('with no floor to fall short of',
    not e.floor_applies);

  -- `0666`: the individual computation runs on the same business
  -- income the company one does.
  v_comp := public.open_tax_computation(v_org, v_fy);
  perform pg_temp.check_true('and an individual computation opens',
    v_comp is not null);
  perform pg_temp.check_true('which produces a figure',
    exists (select 1 from public.tax_computation_individual(v_comp)));
end $$;

-- ---------------------------------------------------------------------
-- A new company gets the new company's rules all the way through
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_est uuid; fp record; v_due date; v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Syarikat Setahun Baharu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_fy := (select id from public.fiscal_years
            where org_id = v_org and end_date = date '2026-12-31');

  v_est := public.open_tax_estimate(v_org, v_fy, 24000);
  update public.tax_estimates
     set first_period = true,
         commenced_on = date '2026-09-15',
         paid_up_capital = 500000,
         gross_business_income = 1200000
   where id = v_est;

  -- `0671`: exempt, so no instalments at all.
  select * into fp from public.tax_estimate_first_period(v_est);
  perform pg_temp.check_true('a qualifying new SME is exempt',
    fp.exempt_instalments);
  select count(*) into v_count from public.tax_estimate_schedule(v_est);
  perform pg_temp.check_eq('and is handed no instalments', v_count, 0);

  -- Which the summary and the tile both have to agree about: a
  -- company owing nothing is not a company behind on everything.
  perform pg_temp.check_eq('the summary counts none overdue',
    (select overdue_count
       from public.tax_estimate_payment_summary(v_est)), 0);
  perform pg_temp.check_eq('and neither does the tile',
    pg_temp.tile(v_org, 'instalments_overdue'), '0');

  -- `0671`: and the CALENDAR takes its CP204 date from the estimate,
  -- so the two screens cannot print different deadlines.
  select due_date into v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp204' and year_of_assessment = 2026;
  perform pg_temp.check_eq('the calendar follows the estimate''s deadline',
    v_due::text, fp.filing_due::text);
  perform pg_temp.check_eq('which is three months from commencing',
    v_due::text, '2026-12-14');
end $$;

rollback;

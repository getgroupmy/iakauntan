-- =====================================================================
-- iAkauntan :: the LHDN filing calendar
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_filing_calendar.sql
--
-- `0668` computes every income tax deadline from the company's own
-- periods. The reason it is worth asserting rather than eyeballing is
-- that a **December year end makes every clock in it agree**: the
-- basis period, the year of assessment and the calendar year of
-- remuneration all end on the same day, so a Form E measured from the
-- wrong one still comes out right, and a test built on a December year
-- end would pass over all of it.
--
-- So the company here has a **30 June year end**, and the assertions
-- are the four places the clocks come apart:
--
--   1. **Seven months from the day FOLLOWING the close**, which is one
--      day later than seven months from the close. 31 January, not
--      30 January -- and 30 January is late.
--   2. **CP204 is due before the period it estimates begins.** A
--      company with a June year end furnishes it in the June BEFORE,
--      which is nineteen months before the Form C for the same period.
--   3. **Form E is a calendar year.** Its date happens to land on the
--      same arithmetic as Form B's, but the period it covers is
--      1 January to 31 December, and a row naming the company's own
--      July-to-June period beside it would send somebody reconciling
--      EA forms to the wrong twelve months.
--   4. **The last day of February is a null, not a 28.** 2028 is a
--      leap year and the answer moves.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The obligations are the published ones
-- ---------------------------------------------------------------------
do $$
declare v_count integer; v_text text;
begin
  select count(*) into v_count from public.tax_filing_types;
  perform pg_temp.check_true('there are obligations seeded', v_count > 0);

  select count(*) into v_count from public.tax_filing_types
   where is_verified;
  perform pg_temp.check_eq(
    'and none of them claims to have been checked against the Act',
    v_count, 0);

  -- A Form C against a sole proprietorship is not a tidy-up; it is a
  -- person being told to file a company return.
  select array_to_string(applies_to, ',') into v_text
    from public.tax_filing_types where code = 'form_c';
  perform pg_temp.check_true('Form C is for companies only',
    v_text not like '%sole_proprietor%' and v_text like '%sdn_bhd%');

  select array_to_string(applies_to, ',') into v_text
    from public.tax_filing_types where code = 'form_b';
  perform pg_temp.check_true('and Form B is not for a company',
    v_text not like '%sdn_bhd%');

  -- An LLP files its own return and a conventional partnership does
  -- not. Getting these the wrong way round gives one of them a return
  -- that taxes nobody and the other a tax bill it does not owe.
  select array_to_string(applies_to, ',') into v_text
    from public.tax_filing_types where code = 'form_pt';
  perform pg_temp.check_eq('an LLP files a Form PT', v_text, 'llp');

  select array_to_string(applies_to, ',') into v_text
    from public.tax_filing_types where code = 'form_p';
  perform pg_temp.check_eq('a partnership files a Form P',
    v_text, 'partnership');

  -- The employer obligations are marked as such, or a company with no
  -- payroll is handed three deadlines it does not have.
  select count(*) into v_count from public.tax_filing_types
   where code in ('form_e', 'form_ea') and needs_employees;
  perform pg_temp.check_eq('Form E and Form EA need an employer',
    v_count, 2);

  select count(*) into v_count from public.tax_filing_types
   where code in ('form_c', 'form_b', 'cp204') and needs_employees;
  perform pg_temp.check_eq('and the returns themselves do not',
    v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- Seven months from the day FOLLOWING the close
-- ---------------------------------------------------------------------
do $$
declare v_due date;
begin
  -- A June year end. Seven months from 1 July ends on 31 January, and
  -- the shorter arithmetic -- 30 June plus seven months -- gives the
  -- 30th, which is a day late.
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_due from public.tax_filing_types where code = 'form_c';
  perform pg_temp.check_eq('a June year end files its Form C on 31 January',
    v_due::text, '2027-01-31');

  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2026-01-01', date '2026-12-31')
    into v_due from public.tax_filing_types where code = 'form_c';
  perform pg_temp.check_eq('a December year end on 31 July',
    v_due::text, '2027-07-31');

  -- February is where the two spellings differ by a day in the other
  -- direction: 28 February plus seven months is 28 September, and the
  -- answer is the 30th.
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-03-01', date '2026-02-28')
    into v_due from public.tax_filing_types where code = 'form_c';
  perform pg_temp.check_eq('and a February year end on 30 September',
    v_due::text, '2026-09-30');
end $$;

-- ---------------------------------------------------------------------
-- CP204 is due before the year it estimates
-- ---------------------------------------------------------------------
do $$
declare v_cp204 date; v_form_c date; v_rev date;
begin
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_cp204 from public.tax_filing_types where code = 'cp204';
  perform pg_temp.check_eq(
    'the estimate is furnished thirty days before the period opens',
    v_cp204::text, '2025-06-01');

  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_form_c from public.tax_filing_types where code = 'form_c';
  -- Nineteen months apart for the same basis period, which is the
  -- reason somebody who thinks of tax as a year-end job misses it.
  perform pg_temp.check_true(
    'which is more than a year before the return for the same period',
    v_form_c - v_cp204 > 365);

  -- The sixth month of a period opening 1 July 2025 is December, and
  -- the revision is allowed to the end of it.
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_rev from public.tax_filing_types where code = 'cp204a_6';
  perform pg_temp.check_eq('the sixth month closes on 31 December',
    v_rev::text, '2025-12-31');

  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_rev from public.tax_filing_types where code = 'cp204a_9';
  perform pg_temp.check_eq('and the ninth on 31 March',
    v_rev::text, '2026-03-31');

  -- Against a January-to-December period the same rows give the months
  -- `0667` computes its revision window from. If these two ever
  -- disagree, one of the screens is telling somebody the wrong month.
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2026-01-01', date '2026-12-31')
    into v_rev from public.tax_filing_types where code = 'cp204a_6';
  perform pg_temp.check_eq('a calendar year revises by 30 June',
    v_rev::text, '2026-06-30');
end $$;

-- ---------------------------------------------------------------------
-- A person's return is due in the year AFTER the year of assessment
-- ---------------------------------------------------------------------
do $$
declare v_due date; v_org uuid; v_count integer; v_from date; v_to date;
begin
  -- The off-by-a-year that costs a year. A basis period ending in 2026
  -- is year of assessment 2026 and its Form B is due on 30 June 2027 --
  -- and a calendar that put it on 30 June 2026 would show it as already
  -- filed-or-late for the whole of the year it actually covers.
  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2026-01-01', date '2026-12-31')
    into v_due from public.tax_filing_types where code = 'form_b';
  perform pg_temp.check_eq('YA 2026''s Form B is due 30 June 2027',
    v_due::text, '2027-06-30');

  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2026-01-01', date '2026-12-31')
    into v_due from public.tax_filing_types where code = 'form_p';
  perform pg_temp.check_eq('and so is the Form P the partners read it from',
    v_due::text, '2027-06-30');

  -- And a person actually sees it. A Sdn Bhd fixture would never
  -- exercise this branch at all: it is the one the entity type keeps
  -- from them.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Runcit Pak Mat');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c';
  perform pg_temp.check_eq('a sole proprietor files no Form C', v_count, 0);

  select period_from, period_to, due_date into v_from, v_to, v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_b';
  perform pg_temp.check_eq('but a Form B, on their own basis period',
    v_from::text || '..' || v_to::text, '2026-01-01..2026-12-31');
  perform pg_temp.check_eq('due the June after the year of assessment',
    v_due::text, '2027-06-30');
end $$;

-- ---------------------------------------------------------------------
-- The last day of February is a null
-- ---------------------------------------------------------------------
do $$
declare v_due date;
begin
  perform pg_temp.check_eq('the last day of February 2027 is the 28th',
    app.tax_filing_fixed_date(2027, 2, null)::text, '2027-02-28');
  perform pg_temp.check_eq('and of February 2028 the 29th',
    app.tax_filing_fixed_date(2028, 2, null)::text, '2028-02-29');

  -- A day past the end of the month is the end of the month rather
  -- than an error. `make_date(2027, 2, 31)` raises, which is why this
  -- is counted forward from the first rather than built from parts.
  perform pg_temp.check_eq('a 31st asked of February is the 28th',
    app.tax_filing_fixed_date(2027, 2, 31)::text, '2027-02-28');
  perform pg_temp.check_eq('and of April the 30th',
    app.tax_filing_fixed_date(2027, 4, 31)::text, '2027-04-30');

  select app.tax_filing_due(basis, days_before, months_after,
                            period_month, due_month, due_day,
                            date '2025-07-01', date '2026-06-30')
    into v_due from public.tax_filing_types where code = 'form_ea';
  perform pg_temp.check_eq('the EA forms are due by the end of February',
    v_due::text, '2027-02-28');
end $$;

-- ---------------------------------------------------------------------
-- What a company actually sees
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_count integer;
  v_from date; v_to date; v_due date; v_grace date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Tarikh Sdn Bhd');
  -- A June year end, so the clocks come apart.
  v_fy := public.create_fiscal_year(v_org, date '2025-07-01');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650);
  perform pg_temp.check_true('a company has obligations', v_count > 0);

  -- Form E and Form EA are an employer's, and this company has nobody
  -- on the payroll. Listing them anyway trains somebody to ignore the
  -- list, which is the only way this feature fails.
  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type in ('form_e', 'form_ea');
  perform pg_temp.check_eq(
    'and a company with no payroll is not told to file a Form E',
    v_count, 0);

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type in ('form_b', 'form_p', 'form_pt');
  perform pg_temp.check_eq(
    'nor is a Sdn Bhd told to file a Form B, P or PT', v_count, 0);

  -- The period beside a Form C is the company's own.
  select period_from, period_to, due_date, efiling_due_date
    into v_from, v_to, v_due, v_grace
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('the Form C names the basis period',
    v_from::text || '..' || v_to::text, '2025-07-01..2026-06-30');
  perform pg_temp.check_eq('and is due seven months after it',
    v_due::text, '2027-01-31');
  -- The concession is beside the date, never instead of it -- and it
  -- is a MONTH, which from 31 January is 28 February. Thirty days
  -- would be 2 March, two days past a deadline somebody filed against.
  perform pg_temp.check_eq('with the e-filing concession shown apart',
    v_grace::text, '2027-02-28');
  perform pg_temp.check_true('which is later than the statutory date',
    v_grace > v_due);
end $$;

-- ---------------------------------------------------------------------
-- Form E covers a calendar year, whatever the company's year end is
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_from date; v_to date; v_due date;
  v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kilang Gaji Sdn Bhd');
  v_fy := public.create_fiscal_year(v_org, date '2025-07-01');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E001', 'Siti binti Rahman', date '2025-08-01', 'active');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_e';
  perform pg_temp.check_true('an employer is told to file a Form E',
    v_count > 0);

  select period_from, period_to, due_date into v_from, v_to, v_due
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_e' and due_date = date '2027-03-31';

  -- THE assertion this file exists for. The company's own period is
  -- 1 July to 30 June; the Form E beside it covers a calendar year,
  -- and a row that said otherwise would send somebody reconciling
  -- their EA forms to twelve months no Form E has ever covered.
  perform pg_temp.check_eq('but the Form E covers a calendar year',
    v_from::text || '..' || v_to::text, '2026-01-01..2026-12-31');
  perform pg_temp.check_eq('and is due on 31 March of the next one',
    v_due::text, '2027-03-31');

  -- The same company's Form C, for comparison: same table, same call,
  -- a different period and a different date.
  select period_from, period_to into v_from, v_to
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('while its Form C still names its own',
    v_from::text || '..' || v_to::text, '2025-07-01..2026-06-30');
end $$;

-- ---------------------------------------------------------------------
-- What is already late stays in the list
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_overdue integer; v_left integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Lewat Sdn Bhd');
  -- A period that closed long enough ago for its return to be late.
  v_fy := public.create_fiscal_year(v_org, app.today() - 700);

  select count(*) into v_overdue
    from public.tax_upcoming_filings(v_org, 30)
   where is_overdue;
  perform pg_temp.check_true(
    'an obligation already missed is still on the list', v_overdue > 0);

  -- Dropping it the day after it was due is exactly backwards: that is
  -- the day it starts costing money.
  select min(days_left) into v_left
    from public.tax_upcoming_filings(v_org, 30) where is_overdue;
  perform pg_temp.check_true('and it is reported as days past, not days left',
    v_left < 0);
end $$;

-- ---------------------------------------------------------------------
-- A stranger sees nothing
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Sulit Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  v_other := pg_temp.another_user('nosy@example.com');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'somebody outside the company cannot read its deadlines',
    format('select count(*) from public.tax_upcoming_filings(%L, 365)',
           v_org),
    'Not a member of organization%', '42501');
end $$;

rollback;

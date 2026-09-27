-- =====================================================================
-- iAkauntan :: the taxman's queue on the home screen
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_dashboard_tile.sql
--
-- `0304` put the Registrar's deadlines on the home screen and argued
-- for it: a date nobody navigates to is a date nobody meets. `0674`
-- makes the same argument for LHDN, whose penalties are larger.
--
-- What is asserted is the part that could quietly go wrong:
--
--   1. **A return and an instalment are different clocks.** A company
--      up to date on its returns and behind on its instalments has to
--      show as behind, and the two counts must not be folded into one
--      number that is true of neither.
--   2. **The tile reuses the screens' own functions.** Every figure
--      comes from `tax_upcoming_filings` and
--      `tax_estimate_payment_summary`, so filing something there takes
--      it off the tile as well. A second implementation of "overdue"
--      would drift, and the tile would be the copy nobody could check.
--   3. **A superseded estimate is not counted twice.** A revision
--      leaves two rows for one year, and counting both would double
--      every instalment figure on the home screen.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A year that closed long enough ago for its returns to be late.
create or replace function pg_temp.late_co(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, app.today() - 700);
  return v_org;
end; $$;

-- ---------------------------------------------------------------------
-- The tile is there, and it counts what the screen counts
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_dash jsonb; v_screen integer; v_due date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.late_co('Kedai Papan Sdn Bhd');

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('a company with books gets a tax card',
    v_dash ? 'tax');

  -- The same number the calendar screen shows, because it is the same
  -- function. A tile that counted the rows itself would be a second
  -- implementation of "overdue".
  select count(*) into v_screen
    from public.tax_upcoming_filings(v_org, 120)
   where due_date < app.today();
  perform pg_temp.check_eq('and its overdue count is the screen''s',
    (v_dash -> 'tax' ->> 'overdue')::integer, v_screen);
  perform pg_temp.check_true('which is not nothing, for this company',
    v_screen > 0);

  -- Which form, not just when: "Form C on 31 January" is what goes in
  -- the diary and "something on 31 January" is not.
  select min(due_date) into v_due
    from public.tax_upcoming_filings(v_org, 120)
   where due_date >= app.today();
  if v_due is not null then
    perform pg_temp.check_eq('the next date is the screen''s too',
      (v_dash -> 'tax' ->> 'next_due')::date::text, v_due::text);
    perform pg_temp.check_true('and it says which form',
      (v_dash -> 'tax' ->> 'next_form') is not null);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Due today is not yet late, and the tile says which form
-- ---------------------------------------------------------------------
-- A CP204 is due thirty days BEFORE the basis period opens, so a year
-- starting thirty days from now has one due exactly today. That is
-- the only deadline in this system whose date can be put on today
-- deliberately, and without it three separate things here cannot be
-- told apart from their opposites.
do $$
declare
  v_org uuid; v_dash jsonb; v_today date := app.today(); v_period date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Hari Ini Sdn Bhd');
  perform public.create_fiscal_year(v_org, v_today + 30);

  v_dash := public.module_dashboard(v_org);

  -- Strictly before today. Telling somebody they are late for a
  -- deadline they still have all day to meet sends them to argue with
  -- LHDN about a date they have not missed.
  perform pg_temp.check_eq('a return due TODAY is not overdue',
    (v_dash -> 'tax' ->> 'overdue')::integer, 0);
  perform pg_temp.check_true('it is due soon instead',
    (v_dash -> 'tax' ->> 'due_soon')::integer > 0);
  perform pg_temp.check_eq('and today is the date on the tile',
    (v_dash -> 'tax' ->> 'next_due')::date::text, v_today::text);

  -- Which form, not just when. "CP204 today" is what goes in the
  -- diary; "something today" is not.
  perform pg_temp.check_eq('with the form named', 
    (v_dash -> 'tax' ->> 'next_form'), 'CP204');

  -- And the window is the one the tile claims. Widening it would
  -- quietly start reporting a next date more than four months out as
  -- though it were imminent, which is the opposite of what a tile
  -- headed "due within a month" is for.
  perform pg_temp.check_true('inside the window the tile reads',
    (v_dash -> 'tax' ->> 'next_due')::date <= v_today + 120);

  -- And the window has to be the NARROW one. Deal with today's CP204
  -- and this company's next obligation is its sixth-month revision,
  -- about two hundred days out — inside a ten-year window and outside
  -- the four-month one the tile is for. Without this, widening the
  -- window changes nothing any assertion can see, and a tile headed
  -- "due within a month" starts quoting dates from next year.
  select period_to into v_period
    from public.tax_upcoming_filings(v_org, 120)
   where filing_type = 'cp204';
  perform public.record_tax_filing(
    v_org, 'cp204', v_period, 'filed', v_today);

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true(
    'with it dealt with, nothing is inside the window at all',
    (v_dash -> 'tax' ->> 'next_due') is null);
  perform pg_temp.check_eq('and nothing is due soon',
    (v_dash -> 'tax' ->> 'due_soon')::integer, 0);

  -- Though there IS something further out, which is what makes the
  -- assertion above a statement about the window rather than about an
  -- empty company.
  perform pg_temp.check_true('while the calendar still has one',
    exists (select 1 from public.tax_upcoming_filings(v_org, 3650)
             where due_date > v_today + 120));
end $$;

-- ---------------------------------------------------------------------
-- Filing something takes it off the tile
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_before integer; v_after integer; r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.late_co('Kedai Failkan Sdn Bhd');

  v_before := (public.module_dashboard(v_org) -> 'tax' ->> 'overdue')::integer;
  perform pg_temp.check_true('something is overdue to begin with',
    v_before > 0);

  -- Record the oldest one as filed. Because the tile reads
  -- `tax_upcoming_filings`, which `0669` taught to drop what has been
  -- dealt with, this has to move the tile without the tile knowing
  -- anything about filings.
  select filing_type, period_to into r
    from public.tax_upcoming_filings(v_org, 120)
   where due_date < app.today()
   order by due_date limit 1;
  perform public.record_tax_filing(
    v_org, r.filing_type, r.period_to, 'filed', app.today());

  v_after := (public.module_dashboard(v_org) -> 'tax' ->> 'overdue')::integer;
  perform pg_temp.check_eq('and filing one takes it off the tile',
    v_after, v_before - 1);
end $$;

-- ---------------------------------------------------------------------
-- Returns and instalments are different clocks
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_dash jsonb; v_fy uuid; r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Ansuran Papan Sdn Bhd');
  -- A year that STARTED long enough ago for instalments to be past,
  -- but whose returns are not yet due.
  v_fy := public.create_fiscal_year(v_org, app.today() - 200);
  v_est := public.open_tax_estimate(v_org, v_fy, 120000);

  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_true('instalments are behind',
    (v_dash -> 'tax' ->> 'instalments_overdue')::integer > 0);

  -- Now clear the returns. A period that has STARTED always has an
  -- overdue CP204 behind it -- the estimate is due thirty days before
  -- the period opens -- so the only way to separate the two clocks is
  -- to deal with the returns and see whether the instalments move.
  for r in select filing_type, period_to
             from public.tax_upcoming_filings(v_org, 120)
            where due_date < app.today() loop
    perform public.record_tax_filing(
      v_org, r.filing_type, r.period_to, 'filed', app.today());
  end loop;

  -- Folding the two into one count would give a number true of
  -- neither: "three overdue" where one is a Form C and two are
  -- instalments tells somebody neither what to do nor what it costs.
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('with every RETURN dealt with',
    (v_dash -> 'tax' ->> 'overdue')::integer, 0);
  perform pg_temp.check_true('the instalments are still behind',
    (v_dash -> 'tax' ->> 'instalments_overdue')::integer > 0);

  -- Paying them moves the instalment figure and leaves the other
  -- alone.
  perform public.record_tax_instalment(v_est, 1);
  perform public.record_tax_instalment(v_est, 2);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq('paying two takes two off',
    (v_dash -> 'tax' ->> 'instalments_overdue')::integer,
    (select overdue_count from public.tax_estimate_payment_summary(v_est)));
end $$;

-- ---------------------------------------------------------------------
-- A superseded estimate is not counted twice
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_est uuid; v_new uuid;
  v_dash jsonb; v_one integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Ubah Papan Sdn Bhd');
  v_fy := public.create_fiscal_year(v_org, app.today() - 200);
  v_est := public.open_tax_estimate(v_org, v_fy, 120000);

  v_one := (public.module_dashboard(v_org) -> 'tax'
              ->> 'instalments_overdue')::integer;
  perform pg_temp.check_true('one estimate is behind', v_one > 0);

  -- A revision leaves TWO rows for one year. Counting both would
  -- double every instalment figure on the home screen -- and it would
  -- look plausible, because the number would still go up and down
  -- with the payments.
  v_new := public.revise_tax_estimate(v_est, 180000);
  v_dash := public.module_dashboard(v_org);
  perform pg_temp.check_eq(
    'and after a revision there is still only one being counted',
    (v_dash -> 'tax' ->> 'instalments_overdue')::integer,
    (select overdue_count
       from public.tax_estimate_payment_summary(v_new)));
end $$;

-- ---------------------------------------------------------------------
-- A stranger gets nothing, and the other tiles are untouched
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_dash jsonb; v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.late_co('Kedai Lain Papan Sdn Bhd');

  v_dash := public.module_dashboard(v_org);
  -- The tax block is an ADDITION, and `module_dashboard` has to be
  -- rewritten whole to add one — plpgsql has no way to append to a
  -- body. A rewrite that dropped a block while adding mine would pass
  -- every assertion about the new block and nothing else would
  -- notice, so the other seven are named here.
  perform pg_temp.check_true('the new tile is there', v_dash ? 'tax');
  perform pg_temp.check_true('and so are the seven that were',
    v_dash ? 'ticketing' and v_dash ? 'pos' and v_dash ? 'inventory'
      and v_dash ? 'hr' and v_dash ? 'payroll' and v_dash ? 'crm'
      and v_dash ? 'secretarial');

  v_other := pg_temp.another_user('nodash@example.com');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused('an outsider gets no dashboard at all',
    format('select public.module_dashboard(%L)', v_org),
    'Not a member of this organization%', '42501');
end $$;

rollback;

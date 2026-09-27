-- =====================================================================
-- iAkauntan :: recording what was done about a deadline
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_filings_recorded.sql
--
-- `0668` computes the obligations. `0669` lets somebody say one has
-- been dealt with, and the whole value of it is in WHICH things take a
-- row off the list and which do not:
--
--   * **Filed takes it off. In preparation does not.** Opening a
--     Form C is not filing it, and a calendar that cleared on the
--     intention to do something would be worse than one that never
--     cleared at all.
--   * **"Does not apply" takes it off and keeps the reason.** The
--     constraint refuses a dismissal with nothing written against it,
--     because a CP58 somebody clicked away has to be findable when
--     LHDN asks about it.
--   * **One obligation is not another.** A Form E and a Form C can
--     both sit against one fiscal year over two different periods, so
--     recording one must not clear the other.
--   * **An obligation this company does not have cannot be recorded.**
--     A sole proprietor ticking off a Form C has marked as done a
--     return they do not file, and has not filed the one they do.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A June year end, for the same reason `tax_filing_calendar.sql` uses
-- one: a December year end makes the basis period and the calendar
-- year agree, and the Form-E-is-not-Form-C assertion below would then
-- pass whatever the key was.
create or replace function pg_temp.filed_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2025-07-01');
  return v_org;
end; $$;

-- ---------------------------------------------------------------------
-- Filed takes it off the list; in preparation does not
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_before integer; v_after integer; v_id uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Rekod Sdn Bhd');

  select count(*) into v_before
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('the Form C is on the list to start with',
    v_before, 1);

  -- Opening it is not filing it.
  v_id := public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'in_preparation');
  select count(*) into v_after
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('starting it does NOT take it off',
    v_after, 1);

  -- And the list says which state it is in, so the screen can show
  -- the difference rather than looking identical to an untouched one.
  perform pg_temp.check_eq('and the list says it has been started',
    (select status from public.tax_upcoming_filings(v_org, 3650)
      where filing_type = 'form_c' and period_to = date '2026-06-30'),
    'in_preparation');

  -- Filing it does.
  v_id := public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-01-20', 'ACK-1');
  select count(*) into v_after
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('filing it does', v_after, 0);

  -- The same row updated rather than a second, rival claim about one
  -- Form C.
  select count(*) into v_after from public.tax_filings
   where org_id = v_org and filing_type = 'form_c';
  perform pg_temp.check_eq('and there is still only one record of it',
    v_after, 1);

  -- Nothing disappeared -- it moved.
  perform pg_temp.check_eq('the acknowledgement is readable afterwards',
    (select reference from public.tax_filing_history(v_org, 100)
      where filing_type = 'form_c'), 'ACK-1');
end $$;

-- ---------------------------------------------------------------------
-- A filing is the type AND the period
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kilang Dua Tarikh Sdn Bhd');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E001', 'Aminah binti Yusof', date '2025-08-01', 'active');

  -- The Form C covers 1 Jul 2025 to 30 Jun 2026; the Form E beside it
  -- covers the calendar year 2026. Two obligations, one fiscal year,
  -- two different periods.
  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-01-20');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_e' and period_to = date '2026-12-31';
  perform pg_temp.check_eq(
    'filing the Form C leaves the Form E exactly where it was',
    v_count, 1);

  -- And the other way round, which is the direction a key on the
  -- fiscal year alone would get wrong.
  perform public.record_tax_filing(v_org, 'form_e', date '2026-12-31',
                                   'filed', date '2027-03-20');
  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_e' and period_to = date '2026-12-31';
  perform pg_temp.check_eq('and now the Form E has gone too', v_count, 0);

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('the filed Form C stays gone', v_count, 0);

  -- And the NEXT year's Form C is a different obligation entirely.
  -- This needs a SECOND fiscal year to say anything at all: with one
  -- year on the books, a join that matched any recorded filing of the
  -- right type -- ignoring the period completely -- gives exactly the
  -- same answers as the correct one. A mutant that dropped the period
  -- from the join survived until this existed.
  perform public.create_fiscal_year(v_org, date '2026-07-01');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2027-06-30';
  perform pg_temp.check_eq(
    'but next year''s Form C is untouched by this year''s being filed',
    v_count, 1);

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_e' and period_to = date '2027-12-31';
  perform pg_temp.check_eq('and so is next year''s Form E', v_count, 1);
end $$;

-- ---------------------------------------------------------------------
-- A dismissal carries a reason
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_count integer; v_notes text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Tanpa Ejen Sdn Bhd');

  -- A CP58 appears for every trading company because the threshold is
  -- about payments to agents this schema does not track. Dismissing it
  -- is the point of `not_applicable` -- and it has to say why.
  perform pg_temp.check_refused(
    'an obligation cannot be dismissed without a reason',
    format('select public.record_tax_filing(%L, ''cp58'', '
           'date ''2026-12-31'', ''not_applicable'')', v_org),
    '%tax_filings_dismissal_has_a_reason%');

  perform public.record_tax_filing(
    v_org, 'cp58', date '2026-12-31', 'not_applicable', null, null,
    'No agents, dealers or distributors were paid anything.');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'cp58';
  perform pg_temp.check_eq('with one, it comes off the list', v_count, 0);

  select notes into v_notes
    from public.tax_filing_history(v_org, 100) where filing_type = 'cp58';
  perform pg_temp.check_eq('and the reason survives where LHDN can be '
    'answered from it',
    v_notes, 'No agents, dealers or distributors were paid anything.');
end $$;

-- ---------------------------------------------------------------------
-- Filed means filed on a date
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_when date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Tarikh Kosong Sdn Bhd');

  -- No date given: today, rather than an error about a column. A
  -- person recording a filing almost always means "now".
  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed');
  select filed_on into v_when from public.tax_filings
   where org_id = v_org and filing_type = 'form_c';
  perform pg_temp.check_eq('a filing with no date is filed today',
    v_when::text, app.today()::text);
end $$;

-- ---------------------------------------------------------------------
-- Late is its own answer
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_late boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Lambat Sdn Bhd');

  -- Due 31 January 2027; filed in March. The two dates sit in
  -- different columns of the same row, and whether one is after the
  -- other is what a penalty is assessed on.
  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-03-05');
  select was_late into v_late
    from public.tax_filing_history(v_org, 100) where filing_type = 'form_c';
  perform pg_temp.check_true('a filing after the due date reads as late',
    v_late);

  perform public.clear_tax_filing(v_org, 'form_c', date '2026-06-30');
  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-01-20');
  select was_late into v_late
    from public.tax_filing_history(v_org, 100) where filing_type = 'form_c';
  perform pg_temp.check_true('and one before it does not', not v_late);

  -- On the day itself is ON TIME. The boundary, because `>=` reads
  -- identically to `>` on every date except the one a person filing
  -- at the last minute actually used -- and telling them they were
  -- late when they were not is the same defect as the reverse, in the
  -- direction that erodes trust in the rest of the screen.
  perform public.clear_tax_filing(v_org, 'form_c', date '2026-06-30');
  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-01-31');
  select was_late into v_late
    from public.tax_filing_history(v_org, 100) where filing_type = 'form_c';
  perform pg_temp.check_true('and filing on the due date itself is on time',
    not v_late);
end $$;

-- ---------------------------------------------------------------------
-- Clearing puts it back
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_count integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Batal Sdn Bhd');

  perform public.record_tax_filing(v_org, 'form_c', date '2026-06-30',
                                   'filed', date '2027-01-20');
  perform public.clear_tax_filing(v_org, 'form_c', date '2026-06-30');

  select count(*) into v_count
    from public.tax_upcoming_filings(v_org, 3650)
   where filing_type = 'form_c' and period_to = date '2026-06-30';
  perform pg_temp.check_eq('clearing a record puts the deadline back',
    v_count, 1);

  select count(*) into v_count
    from public.tax_filing_history(v_org, 100);
  perform pg_temp.check_eq('and the record is gone rather than hidden',
    v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- An obligation this company does not have cannot be recorded
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Runcit Pak Samad');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- A sole proprietor ticking off a Form C has marked as done a
  -- return they do not file, and has not filed the one they do.
  perform pg_temp.check_refused(
    'a sole proprietor cannot tick off a Form C',
    format('select public.record_tax_filing(%L, ''form_c'', '
           'date ''2026-12-31'', ''filed'', current_date)', v_org),
    'No form_c obligation%', '22023');

  -- Their own return records perfectly well.
  perform public.record_tax_filing(v_org, 'form_b', date '2026-12-31',
                                   'filed', date '2027-06-10');
  perform pg_temp.check_eq('but their Form B does',
    (select count(*) from public.tax_upcoming_filings(v_org, 3650)
      where filing_type = 'form_b'), 0);

  -- And a filing type nobody has heard of is refused by name, rather
  -- than inserted and found later by a foreign key message.
  perform pg_temp.check_refused(
    'and an invented form is refused by name',
    format('select public.record_tax_filing(%L, ''form_zzz'', '
           'date ''2026-12-31'')', v_org),
    'Unknown filing type%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- Who may do it
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.filed_org('Kedai Sulit Rekod Sdn Bhd');

  v_other := pg_temp.another_user('outsider@example.com');
  perform pg_temp.sign_in_as(v_other);

  perform pg_temp.check_refused(
    'somebody outside the company cannot record a filing',
    format('select public.record_tax_filing(%L, ''form_c'', '
           'date ''2026-06-30'', ''filed'', current_date)', v_org),
    'Not permitted to record a tax filing%', '42501');

  perform pg_temp.check_refused(
    'nor clear one',
    format('select public.clear_tax_filing(%L, ''form_c'', '
           'date ''2026-06-30'')', v_org),
    'Not permitted to clear a tax filing%', '42501');

  perform pg_temp.check_refused(
    'nor read what was recorded',
    format('select count(*) from public.tax_filing_history(%L, 10)', v_org),
    'Not a member of organization%', '42501');
end $$;

rollback;

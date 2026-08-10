-- =====================================================================
-- iAkauntan :: ledger and fiscal period tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger.sql
--
-- The rules that stop the books drifting: a journal must balance, it
-- must land inside a period, and a closed period must refuse it. Runs
-- inside a transaction that is rolled back at the end.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A fiscal year, and the runway after it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_fy1 uuid;
  v_fy2 uuid;
  v_start date;
begin
  v_org := pg_temp.test_org('Ledger Co');

  -- create_organization is not used here, so the first year is explicit.
  v_fy1 := public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.check_eq('a fiscal year gets twelve periods',
    (select count(*) from public.fiscal_periods where fiscal_year_id = v_fy1), 12);
  perform pg_temp.check_true('and it ends a day short of a year',
    (select end_date = date '2026-12-31' from public.fiscal_years where id = v_fy1));

  -- With no date given, the next year continues from the last one rather
  -- than recomputing from the organization's year end and colliding.
  v_fy2 := public.create_fiscal_year(v_org);
  select start_date into v_start from public.fiscal_years where id = v_fy2;
  perform pg_temp.check_true('the next year starts the day the last one ends',
    v_start = date '2027-01-01');

  -- An overlap would give one date two periods, and app.period_for_date
  -- would then pick between them arbitrarily.
  begin
    perform public.create_fiscal_year(v_org, date '2027-06-01');
    raise exception 'FAIL: an overlapping fiscal year was accepted';
  exception when sqlstate '23505' then
    raise notice 'ok   an overlapping fiscal year is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_ar  uuid;
  v_rev uuid;
  v_per uuid;
  v_e   uuid;
begin
  v_org := pg_temp.test_org('Posting Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_ar  from public.accounts where org_id = v_org and code = '1210';
  select id into v_rev from public.accounts where org_id = v_org and code = '4100';

  -- A date no period covers used to post with a null fiscal_period_id,
  -- which put the entry beyond the reach of period locking entirely.
  begin
    perform public.create_gl_entry(v_org, date '2030-05-05',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 100)),
      'outside every fiscal year');
    raise exception 'FAIL: posted to a date no fiscal period covers';
  exception when sqlstate '23514' then
    raise notice 'ok   a date outside every fiscal year is refused';
  end;

  -- An unbalanced journal never reaches the ledger.
  begin
    perform public.create_gl_entry(v_org, date '2026-02-10',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 90)),
      'unbalanced');
    raise exception 'FAIL: an unbalanced journal posted';
  exception when sqlstate '23514' then
    raise notice 'ok   an unbalanced journal is refused';
  end;

  -- A good one lands, and carries the period it belongs to.
  v_e := public.create_gl_entry(v_org, date '2026-02-10',
    'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 100)),
    'good entry');
  perform pg_temp.check_true('a posted entry carries its fiscal period',
    (select fiscal_period_id is not null from public.gl_entries where id = v_e));

  -- Closing a period is what makes the rule above worth anything.
  select id into v_per from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-02-01';
  perform public.set_fiscal_period_status(v_per, 'closed');
  begin
    perform public.create_gl_entry(v_org, date '2026-02-11',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 5, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 5)),
      'into a closed period');
    raise exception 'FAIL: posted into a closed period';
  exception when sqlstate '23514' then
    raise notice 'ok   a closed period refuses a posting';
  end;

  -- Closed reopens; locked is year-end sign-off and does not.
  perform public.set_fiscal_period_status(v_per, 'open');
  perform public.set_fiscal_period_status(v_per, 'locked');
  begin
    perform public.set_fiscal_period_status(v_per, 'open');
    raise exception 'FAIL: a locked period was reopened';
  exception when sqlstate '22023' then
    raise notice 'ok   a locked period cannot be reopened';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who may do any of this
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_per uuid;
begin
  v_org := pg_temp.test_org('Guarded Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_per from public.fiscal_periods
   where org_id = v_org and period_no = 1;

  perform pg_temp.sign_out();

  begin
    perform public.create_fiscal_year(v_org, date '2028-01-01');
    raise exception 'FAIL: a non-member created a fiscal year';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot create a fiscal year';
  end;

  begin
    perform public.set_fiscal_period_status(v_per, 'closed');
    raise exception 'FAIL: a non-member closed a period';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot close a period';
  end;
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: a lodgement is recorded as it happened (0816)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/corp_filings_recorded.sql
--
-- `corp_upcoming_filings` drops a deadline once its filing says it was
-- lodged, and `corp_mark_lodged` is what asks that the lodgement could
-- have happened. Before `0816` a client could write `corp_filings`
-- directly: an Annual Return nobody had lodged was typed in as lodged
-- in 2099 and left the overdue list, and a real lodgement's date and
-- SSM reference were rewritten by hand. Asked as the owner, with the
-- role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cf (org uuid, e uuid, uid uuid);
grant select on t_cf to authenticated;

do $$
declare
  v_org uuid;
  v_e   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Lewat Lodge Sdn Bhd', array['secretarial']);
  -- Incorporated 12 March 2024: an Annual Return on each anniversary,
  -- due thirty days after it.
  insert into public.corp_entities
    (org_id, name, registration_no, entity_type, incorporated_on,
     financial_year_end_day, financial_year_end_month, registered_office)
  values (v_org, 'Lewat Sdn Bhd', '202401011111', 'sdn_bhd',
          date '2024-03-12', 31, 12, 'Level 8, Menara ABC, KL')
  returning id into v_e;
  insert into t_cf values (v_org, v_e, pg_temp.test_user());
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d      t_cf;
  v_2025 uuid;
  v_2026 uuid;
begin
  select * into d from t_cf;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('the 2025 Annual Return is overdue, since 11 April 2025',
    (select f.due_date || '/' || f.status from public.corp_upcoming_filings(d.org, 120) f
      where f.filing_type = 'annual_return' and f.trigger_date = date '2025-03-12'),
    '2025-04-11/due');

  -- What was measured: a deadline nobody lodged, typed in as lodged.
  perform pg_temp.check_refused('a lodgement is not typed in',
    format($q$insert into public.corp_filings
                (org_id, entity_id, filing_type, trigger_date, due_date,
                 status, lodged_on, ssm_reference)
              values (%L, %L, 'annual_return', date '2025-03-12',
                      date '2025-04-11', 'lodged', date '2099-01-01', 'MADE-UP')$q$,
           d.org, d.e),
    'permission denied for table corp_filings', '42501');
  perform pg_temp.check_eq('so the 2025 Annual Return is still overdue',
    (select count(*)::integer from public.corp_upcoming_filings(d.org, 120) f
      where f.filing_type = 'annual_return' and f.trigger_date = date '2025-03-12'
        and f.status = 'due'), 1);

  -- The road: taken up, and lodged, through the functions.
  v_2025 := public.corp_open_filing(d.e, 'annual_return', date '2025-03-12');
  v_2026 := public.corp_open_filing(d.e, 'annual_return', date '2026-03-12');
  perform public.corp_mark_lodged(v_2026, date '2026-09-30', 'SSM-REAL-1', 50);
  perform pg_temp.check_true('the 2026 one is lodged, by whom and when',
    (select status = 'lodged' and lodged_on = date '2026-09-30'
            and ssm_reference = 'SSM-REAL-1' and lodged_by = d.uid
       from public.corp_filings where id = v_2026));
  perform pg_temp.check_eq('and the list no longer asks for it',
    (select count(*)::integer from public.corp_upcoming_filings(d.org, 120) f
      where f.filing_type = 'annual_return' and f.trigger_date = date '2026-03-12'), 0);

  perform pg_temp.check_refused('its date is not moved by hand',
    format($q$update public.corp_filings set lodged_on = date '2025-01-01' where id = %L$q$, v_2026),
    'permission denied for table corp_filings', '42501');
  perform pg_temp.check_refused('nor its reference rewritten',
    format($q$update public.corp_filings set ssm_reference = 'REWRITTEN' where id = %L$q$, v_2026),
    'permission denied for table corp_filings', '42501');
  perform pg_temp.check_refused('nor the lodgement deleted',
    format('delete from public.corp_filings where id = %L', v_2026),
    'permission denied for table corp_filings', '42501');
  perform pg_temp.check_refused('nor an open deadline marked not applicable',
    format($q$update public.corp_filings set status = 'not_applicable' where id = %L$q$, v_2025),
    'permission denied for table corp_filings', '42501');
  perform pg_temp.check_refused('and recording it again is refused by the function',
    format($q$select public.corp_mark_lodged(%L, date '2026-10-01', 'SSM-OTHER')$q$, v_2026),
    'That filing was lodged on 30 Sep 2026. Recording it again would write '
    'over the reference SSM gave it.', '23514');

  perform pg_temp.check_true('so the lodgement reads as it happened',
    (select lodged_on = date '2026-09-30' and ssm_reference = 'SSM-REAL-1'
       from public.corp_filings where id = v_2026));
  perform pg_temp.check_eq('and the 2025 one is still owed, being worked on',
    (select f.status::text from public.corp_upcoming_filings(d.org, 120) f
      where f.filing_type = 'annual_return' and f.trigger_date = date '2025-03-12'),
    'in_preparation');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the filings',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'corp_filings'
        and cmd <> 'SELECT'), 0);
end $$;

rollback;

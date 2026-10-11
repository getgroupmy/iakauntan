-- =====================================================================
-- iAkauntan :: a filing is recorded as it was (0810)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_records.sql
--
-- `tax_filing_history` says whether a filing was late from the date it
-- was due and the date it was filed, and `tax_estimate_schedule` says
-- whether a CP204 instalment was. Before `0810` a client could write
-- both tables directly: a Form C filed a month late read on time once
-- its due date was moved by hand. Asked as the owner, with the role
-- `authenticated`; the functions are asked to go on recording.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tr (org uuid, est uuid, form_c_due date, cp204_due date);
grant select on t_tr to authenticated;

do $$
declare r t_tr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Rekod Cukai Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2025-07-01');
  r.form_c_due := (select due_date from public.tax_upcoming_filings(r.org, 3650)
                    where filing_type = 'form_c' and period_to = date '2026-06-30');
  r.est := public.open_tax_estimate(r.org,
    (select id from public.fiscal_years
      where org_id = r.org and start_date = date '2025-07-01'), 120000);
  r.cp204_due := (select due_on from public.tax_estimate_schedule(r.est)
                   where instalment_no = 1);
  insert into t_tr select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The Form C
-- =====================================================================
do $$
declare
  d    t_tr;
  v_id uuid;
begin
  select * into d from t_tr;
  perform pg_temp.check_eq('the owner records as a client', current_user, 'authenticated');
  perform pg_temp.check_true('and the Form C has a due date to be late against',
    d.form_c_due is not null);

  -- Filed a month after it was due, through the function.
  v_id := public.record_tax_filing(d.org, 'form_c', date '2026-06-30', 'filed',
                                   d.form_c_due + 30);
  perform pg_temp.check_true('a Form C filed a month after its due date reads late',
    (select was_late from public.tax_filing_history(d.org) where filing_id = v_id));

  perform pg_temp.check_refused('its due date is not moved to meet it',
    format('update public.tax_filings set due_date = filed_on where id = %L', v_id),
    'permission denied for table tax_filings', '42501');
  perform pg_temp.check_refused('nor its filing date moved back',
    format('update public.tax_filings set filed_on = due_date where id = %L', v_id),
    'permission denied for table tax_filings', '42501');
  perform pg_temp.check_refused('nor a filing typed in with dates of its own',
    format($q$insert into public.tax_filings
                (org_id, filing_type, period_to, due_date, status, filed_on)
              values (%L, 'form_c', date '2027-06-30', date '2028-12-31', 'filed', date '2027-07-01')$q$,
           d.org),
    'permission denied for table tax_filings', '42501');
  perform pg_temp.check_refused('nor the record deleted',
    format('delete from public.tax_filings where id = %L', v_id),
    'permission denied for table tax_filings', '42501');
  perform pg_temp.check_true('so it still reads late',
    (select was_late from public.tax_filing_history(d.org) where filing_id = v_id));
end $$;

-- =====================================================================
-- The CP204 instalment
-- =====================================================================
do $$
declare d t_tr;
begin
  select * into d from t_tr;

  -- Paid ten days late, through the function.
  perform public.record_tax_instalment(d.est, 1, d.cp204_due + 10);
  perform pg_temp.check_true('an instalment paid ten days after it was due reads late',
    (select paid_late from public.tax_estimate_schedule(d.est) where instalment_no = 1));

  perform pg_temp.check_refused('its payment date is not moved back',
    format('update public.tax_estimate_payments set paid_on = %L where root_estimate_id = %L',
           d.cp204_due, d.est),
    'permission denied for table tax_estimate_payments', '42501');
  perform pg_temp.check_refused('nor an instalment typed in that the schedule has not got',
    format($q$insert into public.tax_estimate_payments
                (org_id, root_estimate_id, recorded_against_id, instalment_no, paid_on, amount)
              values (%L, %L, %L, 13, %L, 10000)$q$, d.org, d.est, d.est, d.cp204_due),
    'permission denied for table tax_estimate_payments', '42501');
  perform pg_temp.check_refused('nor one deleted',
    format('delete from public.tax_estimate_payments where root_estimate_id = %L', d.est),
    'permission denied for table tax_estimate_payments', '42501');
  perform pg_temp.check_true('so it still reads late',
    (select paid_late from public.tax_estimate_schedule(d.est) where instalment_no = 1));

  -- And the functions undo what they recorded.
  perform public.clear_tax_instalment(d.est, 1);
  perform pg_temp.check_true('a recorded instalment is cleared through its function',
    (select paid_on is null from public.tax_estimate_schedule(d.est) where instalment_no = 1));
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on either',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('tax_filings', 'tax_estimate_payments')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;

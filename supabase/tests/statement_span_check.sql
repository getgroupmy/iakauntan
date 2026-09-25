-- =====================================================================
-- iAkauntan :: the lines between two balances
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statement_span_check.sql
--
-- `0713`. `0369` checks a statement against its own running balance,
-- which is the only defence there is against a line that never
-- arrived -- and it checked only ADJACENT lines that both carry one.
--
-- Measured on a real nine-page Hong Leong current account statement:
-- 95 transaction lines, 21 with a balance beside them, 74 without. The
-- check that exists to catch a missing line was looking at 21 of them.
--
-- A span is the same arithmetic with the adjacency dropped: two printed
-- balances must bridge across everything between them. So the four
-- things here are
--
--   1. a run of unbalanced lines is checked as a whole, and a hole in
--      the middle of it is refused
--   2. the same run, intact, imports
--   3. the same again on a newest-first export, where the span runs
--      backwards and getting it the wrong way round would refuse every
--      correct statement from half the banks in the country
--   4. `0369`'s own adjacent-pair case, which is a span of one
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.span_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name); v_acct uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_acct from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, account_type)
  values (v_org, v_acct, 'Hong Leong current', 'Hong Leong', '7994', 'current');
  return v_org;
end;
$$;

create or replace function pg_temp.bank(p_org uuid)
returns uuid language sql stable as $$
  select id from public.bank_accounts where org_id = p_org limit 1;
$$;

-- A line. `p_balance` null is the Hong Leong case: the bank printed
-- none beside this entry.
create or replace function pg_temp.line(
  p_date text, p_desc text, p_amount text, p_balance text default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'transaction_date', p_date, 'description', p_desc,
    'amount', p_amount, 'running_balance', p_balance));
$$;

-- ---------------------------------------------------------------------
-- 1. The run, intact
--
-- 1000.00, then four lines the bank printed no balance against, then
-- 700.00. -50 -120 +30 -160 is -300, and 1000 - 300 is 700.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.span_org('Rentang Betul Sdn Bhd');
  v_bank uuid;
  v_out  jsonb;
begin
  v_bank := pg_temp.bank(v_org);
  v_out := public.import_bank_transactions(v_bank, jsonb_build_array(
    pg_temp.line('2026-08-01', 'OPENING ENTRY', '0.00', '1000.00'),
    pg_temp.line('2026-08-02', 'CARD PURCHASE',  '-50.00'),
    pg_temp.line('2026-08-03', 'SUPPLIER PAYMENT', '-120.00'),
    pg_temp.line('2026-08-04', 'CUSTOMER RECEIPT', '30.00'),
    pg_temp.line('2026-08-05', 'BANK CHARGE', '-160.00', '700.00')
  ));

  perform pg_temp.check_eq('five lines went in',
    (v_out ->> 'imported')::integer, 5);
  -- One span closed. Under 0369 this statement had NOTHING to check:
  -- no two lines carrying a balance were adjacent.
  perform pg_temp.check_eq('and the run between the two balances was checked',
    (v_out ->> 'balance_checks')::integer, 1);
  -- One span, four lines inside it. A screen reporting spans would say
  -- "1" of a statement whose arithmetic proved four.
  perform pg_temp.check_eq('and it names how many LINES that span proved',
    (v_out ->> 'lines_proved')::integer, 4);
  perform pg_temp.check_eq('the closing balance is the last one printed',
    (v_out ->> 'closing_balance')::numeric, 700.00);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. The same run with a line missing
--
-- Drop the -120.00 and the remaining three come to -180, so the
-- statement should close at 820 and says 700. Under `0369` this
-- imported silently and the account was short by 120 for ever.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.span_org('Rentang Bolong Sdn Bhd');
  v_bank uuid;
begin
  v_bank := pg_temp.bank(v_org);

  perform pg_temp.check_refused(
    'a line dropped from the middle of a run is refused',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_bank, jsonb_build_array(
        pg_temp.line('2026-08-01', 'OPENING ENTRY', '0.00', '1000.00'),
        pg_temp.line('2026-08-02', 'CARD PURCHASE',  '-50.00'),
        pg_temp.line('2026-08-04', 'CUSTOMER RECEIPT', '30.00'),
        pg_temp.line('2026-08-05', 'BANK CHARGE', '-160.00', '700.00')
      )::text),
    '%should come to 820.00%', '23514');

  perform pg_temp.check_refused(
    'and it names the run to go and look at',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_bank, jsonb_build_array(
        pg_temp.line('2026-08-01', 'OPENING ENTRY', '0.00', '1000.00'),
        pg_temp.line('2026-08-02', 'CARD PURCHASE',  '-50.00'),
        pg_temp.line('2026-08-04', 'CUSTOMER RECEIPT', '30.00'),
        pg_temp.line('2026-08-05', 'BANK CHARGE', '-160.00', '700.00')
      )::text),
    '%over lines 2 to 4%', '23514');

  perform pg_temp.check_eq('and nothing of it was kept',
    (select count(*)::integer from public.bank_transactions
      where bank_account_id = v_bank), 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Newest first, which is the same statement upside down
--
-- The dates run backwards, so the direction is read off them and the
-- span runs backwards with them: the balance printed on a line is the
-- previous balance with everything from that line down to the one above
-- this taken back off. Getting this the wrong way round would refuse
-- every correct statement from every bank that exports newest first.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.span_org('Terbaru Dahulu Sdn Bhd');
  v_bank uuid;
  v_out  jsonb;
begin
  v_bank := pg_temp.bank(v_org);
  v_out := public.import_bank_transactions(v_bank, jsonb_build_array(
    pg_temp.line('2026-08-05', 'BANK CHARGE', '-160.00', '700.00'),
    pg_temp.line('2026-08-04', 'CUSTOMER RECEIPT', '30.00'),
    pg_temp.line('2026-08-03', 'SUPPLIER PAYMENT', '-120.00'),
    pg_temp.line('2026-08-02', 'CARD PURCHASE',  '-50.00'),
    pg_temp.line('2026-08-01', 'OPENING ENTRY', '0.00', '1000.00')
  ));

  perform pg_temp.check_eq('five lines went in the other way round',
    (v_out ->> 'imported')::integer, 5);
  perform pg_temp.check_eq('and the backwards run was checked too',
    (v_out ->> 'balance_checks')::integer, 1);
  -- The balance at the LATEST date, which going backwards is the first
  -- line rather than the last.
  perform pg_temp.check_eq('the closing balance is still the latest one',
    (v_out ->> 'closing_balance')::numeric, 700.00);
end;
$$;

do $$
declare
  v_org  uuid := pg_temp.span_org('Terbaru Bolong Sdn Bhd');
  v_bank uuid;
begin
  v_bank := pg_temp.bank(v_org);
  perform pg_temp.check_refused(
    'a hole in a backwards run is refused as well',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_bank, jsonb_build_array(
        pg_temp.line('2026-08-05', 'BANK CHARGE', '-160.00', '700.00'),
        pg_temp.line('2026-08-04', 'CUSTOMER RECEIPT', '30.00'),
        pg_temp.line('2026-08-02', 'CARD PURCHASE',  '-50.00'),
        pg_temp.line('2026-08-01', 'OPENING ENTRY', '0.00', '1000.00')
      )::text),
    '%should come to 880.00%', '23514');
end;
$$;

-- ---------------------------------------------------------------------
-- 4. And 0369's own case, which is a span of one
--
-- Every line carrying a balance. Nothing about this changed, and a
-- statement that imported before this migration must import after it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.span_org('Setiap Baris Sdn Bhd');
  v_bank uuid;
  v_out  jsonb;
begin
  v_bank := pg_temp.bank(v_org);
  v_out := public.import_bank_transactions(v_bank, jsonb_build_array(
    pg_temp.line('2026-08-01', 'CUSTOMER RECEIPT', '1526.14', '5318.06'),
    pg_temp.line('2026-08-02', 'SUPPLIER PAYMENT', '-1375.98', '3942.08'),
    pg_temp.line('2026-08-03', 'BANK CHARGE', '-462.85', '3479.23')
  ));

  perform pg_temp.check_eq('three lines, every one with a balance',
    (v_out ->> 'imported')::integer, 3);
  perform pg_temp.check_eq('and two pairs checked, exactly as 0369 counted them',
    (v_out ->> 'balance_checks')::integer, 2);
  -- Two spans of one line each, so here the two numbers agree.
  perform pg_temp.check_eq('and two lines proved by them',
    (v_out ->> 'lines_proved')::integer, 2);
end;
$$;

do $$
declare
  v_org  uuid := pg_temp.span_org('Setiap Baris Salah Sdn Bhd');
  v_bank uuid;
begin
  v_bank := pg_temp.bank(v_org);
  perform pg_temp.check_refused(
    'and a pair that does not bridge is still refused, over one line',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_bank, jsonb_build_array(
        pg_temp.line('2026-08-01', 'CUSTOMER RECEIPT', '1526.14', '5318.06'),
        pg_temp.line('2026-08-02', 'SUPPLIER PAYMENT', '-1375.98', '4000.00')
      )::text),
    '%over lines 2 to 2%', '23514');
end;
$$;

rollback;

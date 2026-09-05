-- =====================================================================
-- iAkauntan :: a retired account is not a missing one
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_revival.sql
--
-- Thirteen helpers in `app` reach for an account by code and make it if
-- the company has not got one: the account a disposal gain goes to, the
-- one an opening balance is squared against, the one withholding tax
-- sits in, the one a cheque waits on. Every one of them is called
-- during a posting, on a chart the company is free to edit.
--
-- A company that tidies its chart and RETIRES an account it is not
-- using is the ordinary case. `accounts_org_id_code_key` holds one
-- account per code whether it is retired or not, so a helper that needs
-- 2145 and finds a retired 2145 has exactly two wrong answers available
-- and one right one:
--
--   * INSERT — raises on the unique key, and the whole posting fails.
--     That was five of them until 0532.
--   * RETURN THE RETIRED ROW — nothing raises, the entry is really
--     posted, the trial balance really balances, and the account it is
--     on is filtered out of every screen. That was the other eight
--     until 0539, and it is the worse of the two because nothing says
--     so.
--   * REVIVE IT, which is what all thirteen now do.
--
-- This file retires the account each helper wants, calls the helper,
-- and asserts that what comes back is the same row, alive again. It is
-- written as a loop over the thirteen rather than as thirteen blocks,
-- because the assertion is the same one thirteen times and a helper
-- added next year should join the list rather than need a new block.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid := pg_temp.test_org('Carta Kemas Sdn Bhd');
  v_call  text;
  v_code  text;
  v_was   uuid;
  v_got   uuid;
  v_n     integer := 0;
  -- Each helper, and the code it reaches for. Two of them take an
  -- argument that decides which code, so both arms are listed.
  v_cases text[][] := array[
    array['app.absorption_account(%L)',                  '5350'],
    array['app.cheque_account(%L, ''incoming'')',        '1140'],
    array['app.cheque_account(%L, ''outgoing'')',        '2115'],
    array['app.deferred_revenue_account(%L)',            '2127'],
    array['app.deposit_account(%L, ''customer'')',       '2125'],
    array['app.deposit_account(%L, ''supplier'')',       '1235'],
    array['app.deposit_account(%L, ''forfeited'')',      '6610'],
    array['app.disposal_account(%L, true)',              '4930'],
    array['app.disposal_account(%L, false)',             '6510'],
    array['app.goods_in_transit_account(%L)',            '1320'],
    array['app.landed_cost_account(%L)',                 '5400'],
    array['app.opening_balance_account(%L)',             '3200'],
    array['app.property_expense_account(%L, ''quit_rent'')',  '6296'],
    array['app.property_expense_account(%L, ''assessment'')', '6297'],
    array['app.property_income_account(%L, ''maintenance'')', '4810'],
    array['app.property_income_account(%L, ''sinking'')',     '4820'],
    array['app.property_income_account(%L, ''rent'')',        '4830'],
    array['app.stall_purchases_account(%L)',             '5150'],
    array['app.time_income_account(%L)',                 '4840'],
    array['app.withholding_account(%L)',                 '2145']
  ];
  v_row   text[];
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  foreach v_row slice 1 in array v_cases loop
    v_call := v_row[1];
    v_code := v_row[2];

    -- Make sure the account exists, whatever the seeded chart has, by
    -- asking the helper for it once.
    execute format('select ' || v_call, v_org) into v_was;
    perform pg_temp.check_true(
      format('%s answers with an account', v_code), v_was is not null);

    -- The company retires it. Not deletes — the row stays, which is the
    -- whole of the problem.
    update public.accounts
       set deleted_at = now(), is_active = false
     where id = v_was;

    -- And the helper is asked again, mid-posting, as it would be.
    execute format('select ' || v_call, v_org) into v_got;

    perform pg_temp.check_eq(
      format('%s comes back as the same account, not a second one',
             v_code), v_got, v_was);
    perform pg_temp.check_true(
      format('%s is alive again rather than posted to while retired',
             v_code),
      (select deleted_at is null and is_active
         from public.accounts where id = v_got));
    perform pg_temp.check_eq(
      format('and the chart still holds one %s', v_code),
      (select count(*) from public.accounts
        where org_id = v_org and code = v_code), 1);
    v_n := v_n + 1;
  end loop;

  perform pg_temp.check_eq('every helper that makes an account was tried',
    v_n, array_length(v_cases, 1));

  -- ------------------------------------------------------------------
  -- The list is the whole list
  --
  -- A helper added next year that reaches for an account by code and
  -- does not go through `app.revive_account` is the fourteenth instance
  -- of this fault. Counting them here is what makes that a failing
  -- build rather than a thing somebody notices in a year.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'and every helper that makes one revives one',
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname like '%\_account'
       and p.prosrc like '%insert into public.accounts%'
       and p.prosrc not like '%revive_account%'), 0);

  -- ------------------------------------------------------------------
  -- What revival will not do
  --
  -- `app.revive_account` brings back a RETIRED account of that code. It
  -- is not a way to reach a live one, and it is not a way to reach
  -- another company's: a helper that leaned on it for either would be
  -- leaning on the wrong thing.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('reviving a live account changes nothing',
    app.revive_account(v_org, '2145') is null);
  perform pg_temp.check_true('and there is nothing to revive that is not there',
    app.revive_account(v_org, '9999') is null);
  perform pg_temp.check_true(
    'nor anything in a company this one is not',
    app.revive_account(pg_temp.test_org('Carta Lain Sdn Bhd'), '2145')
      is null);
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: a card owes what an account holds
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_card_statement_import.sql
--
-- `0712`. `bank_accounts.account_type` has permitted `credit_card`
-- since `0003` and nothing read it, so a card statement imported as
-- though its balance column meant what a current account's means. It
-- does not: a card prints what you OWE, and a purchase raises it.
--
-- The failure that follows is the expensive kind, because every figure
-- involved is correct. `suggest_bank_matches` reads
-- `bank_transactions.amount > 0` as money in and offers RECEIPTS; a
-- month of card spending imported as printed arrives positive and is
-- offered as income. The card reconciles against itself, the statement
-- foots, and the profit is wrong by the whole of it.
--
-- Four things are asserted here, and each of them is one direction of
-- that:
--
--   1. a card's lines are STORED NEGATED, amount and balance together
--   2. a current account is untouched
--   3. the balance chain is still checked, and its refusal still quotes
--      the figures AS PRINTED, because somebody is holding the paper
--   4. `closing_balance` comes back the way the ledger signs it, which
--      is the way `bank_reconciliation_status` already computes the
--      book balance for a liability
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company, a current account and a card, on the same books.
create or replace function pg_temp.card_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name); v_acct uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_acct from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, account_type)
  values (v_org, v_acct, 'Maybank current', 'Maybank', '4001', 'current'),
         (v_org, v_acct, 'Maybank card', 'Maybank', '4011', 'credit_card');
  return v_org;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_type text)
returns uuid language sql stable as $$
  select id from public.bank_accounts
   where org_id = p_org and account_type = p_type limit 1;
$$;

-- One line of the statement, exactly as a reading of the paper gives it.
create or replace function pg_temp.line(
  p_date text, p_desc text, p_amount text, p_balance text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'transaction_date', p_date, 'description', p_desc,
    'amount', p_amount, 'running_balance', p_balance);
$$;

-- ---------------------------------------------------------------------
-- 1. A card statement, stored the way the books mean it
--
-- The figures are fixture `011_credit_card_standard` from the SmartScan
-- corpus, which is eight lines footing from 11583.30 to 9397.28. Three
-- of them are here: a purchase, a charge, and a payment off the card.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org('Kad Kredit Sdn Bhd');
  v_card uuid;
  v_out  jsonb;
  v_n    integer;
begin
  v_card := pg_temp.acct(v_org, 'credit_card');

  v_out := public.import_bank_transactions(v_card, jsonb_build_array(
    -- Owing 11583.30 before any of this.
    pg_temp.line('2026-08-01', 'CARD PURCHASE',  '1009.79', '12593.09'),
    pg_temp.line('2026-08-02', 'BANK CHARGE',    '1663.96', '14257.05'),
    pg_temp.line('2026-08-03', 'PAYMENT - THANK YOU', '-4859.77', '9397.28')
  ));

  perform pg_temp.check_eq('three lines went in',
    (v_out ->> 'imported')::integer, 3);
  perform pg_temp.check_eq('and all three were checked against the one before',
    (v_out ->> 'balance_checks')::integer, 2);

  -- The purchase. On the paper it RAISES the balance; in the books it
  -- is money leaving, and `suggest_bank_matches` has to be able to
  -- offer an expense for it.
  perform pg_temp.check_eq('a card purchase is stored as money out',
    (select amount from public.bank_transactions
      where bank_account_id = v_card and description = 'CARD PURCHASE'),
    -1009.79);
  perform pg_temp.check_eq('and the balance beside it with it',
    (select running_balance from public.bank_transactions
      where bank_account_id = v_card and description = 'CARD PURCHASE'),
    -12593.09);
  perform pg_temp.check_eq('so it is a withdrawal, not a deposit',
    (select transaction_type from public.bank_transactions
      where bank_account_id = v_card and description = 'CARD PURCHASE'),
    'withdrawal');

  -- And paying the card off is the only line on it that is money in.
  perform pg_temp.check_eq('paying the card is money in',
    (select amount from public.bank_transactions
      where bank_account_id = v_card and description = 'PAYMENT - THANK YOU'),
    4859.77);

  perform pg_temp.check_eq('nothing on a card is a deposit but the payment',
    (select count(*)::integer from public.bank_transactions
      where bank_account_id = v_card and transaction_type = 'deposit'), 1);

  -- The closing figure, signed the way `bank_reconciliation_status`
  -- computes the book balance for the liability behind it: owing
  -- 9397.28 is a balance of -9397.28, not of 9397.28.
  perform pg_temp.check_eq('the closing balance comes back as the ledger signs it',
    (v_out ->> 'closing_balance')::numeric, -9397.28);

  -- Every stored row still satisfies the chain it was checked on.
  select count(*) into v_n from (
    select amount, running_balance,
           lag(running_balance) over (order by transaction_date) as prev
      from public.bank_transactions where bank_account_id = v_card) s
   where prev is not null and round(prev + amount, 2) <> round(running_balance, 2);
  perform pg_temp.check_eq('and the chain survives being negated', v_n, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. A current account on the same books is untouched
--
-- The whole of this migration is one flag read off one column, and the
-- way that goes wrong is by being read for everybody.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.card_org('Akaun Semasa Sdn Bhd');
  v_cur uuid;
  v_out jsonb;
begin
  v_cur := pg_temp.acct(v_org, 'current');

  v_out := public.import_bank_transactions(v_cur, jsonb_build_array(
    pg_temp.line('2026-08-01', 'CUSTOMER RECEIPT', '1526.14', '5318.06'),
    pg_temp.line('2026-08-02', 'SUPPLIER PAYMENT', '-1375.98', '3942.08')
  ));

  perform pg_temp.check_eq('both lines went in',
    (v_out ->> 'imported')::integer, 2);
  perform pg_temp.check_eq('a receipt into a current account is still positive',
    (select amount from public.bank_transactions
      where bank_account_id = v_cur and description = 'CUSTOMER RECEIPT'),
    1526.14);
  perform pg_temp.check_eq('and its balance is still what the bank printed',
    (select running_balance from public.bank_transactions
      where bank_account_id = v_cur and description = 'CUSTOMER RECEIPT'),
    5318.06);
  perform pg_temp.check_eq('the closing balance is not negated either',
    (v_out ->> 'closing_balance')::numeric, 3942.08);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. The chain is still checked, and the refusal still quotes the paper
--
-- `0369` refuses a statement whose balances do not bridge, and its
-- message names three figures so that somebody holding the statement
-- can go and find the line. Negating them before the check would have
-- produced a perfectly accurate sentence about numbers that appear
-- nowhere on the page.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org('Kad Rosak Sdn Bhd');
  v_card uuid;
begin
  v_card := pg_temp.acct(v_org, 'credit_card');

  perform pg_temp.check_refused(
    'a card statement with a line missing is refused',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_card, jsonb_build_array(
        pg_temp.line('2026-08-01', 'CARD PURCHASE', '1009.79', '12593.09'),
        -- 14257.05 is what this should come to. A line was dropped.
        pg_temp.line('2026-08-02', 'BANK CHARGE',   '1663.96', '15000.00')
      )::text),
    '%12593.09%', '23514');

  perform pg_temp.check_refused(
    'and the figures it names are the ones printed, not the negated ones',
    format($q$ select public.import_bank_transactions(%L, %L::jsonb) $q$,
      v_card, jsonb_build_array(
        pg_temp.line('2026-08-01', 'CARD PURCHASE', '1009.79', '12593.09'),
        pg_temp.line('2026-08-02', 'BANK CHARGE',   '1663.96', '15000.00')
      )::text),
    '%should come to 14257.05%', '23514');
end;
$$;

-- ---------------------------------------------------------------------
-- 4. And the same statement twice is still the same statement
--
-- The already-here check compares the STORED figures, and a card's
-- stored figures are not the ones that arrived. Comparing one against
-- the other would import every card statement afresh on every attempt.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org('Kad Dua Kali Sdn Bhd');
  v_card uuid;
  v_rows jsonb;
  v_out  jsonb;
begin
  v_card := pg_temp.acct(v_org, 'credit_card');
  v_rows := jsonb_build_array(
    pg_temp.line('2026-08-01', 'CARD PURCHASE', '1009.79', '12593.09'),
    pg_temp.line('2026-08-02', 'BANK CHARGE',   '1663.96', '14257.05'));

  perform public.import_bank_transactions(v_card, v_rows);
  v_out := public.import_bank_transactions(v_card, v_rows);

  perform pg_temp.check_eq('the second import takes nothing',
    (v_out ->> 'imported')::integer, 0);
  perform pg_temp.check_eq('and says so',
    (v_out ->> 'skipped')::integer, 2);
end;
$$;

rollback;

-- =====================================================================
-- iAkauntan :: bank-to-bank transfer
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_transfers.sql
--
-- The assertion that earns its place here is that a transfer is not a
-- cash flow. Both ends are cash, so nothing has entered or left the
-- business, and a transfer that showed up as operating cash would
-- flatter every set of accounts the company files — by as much as
-- somebody cared to shuffle between their own accounts on the last day
-- of the year.
--
-- After that: the three amounts have to reconcile, a residual is only
-- exchange when the currencies actually differ, and voiding puts the
-- money back.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.tr_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.accounts where org_id = p_org and code = p_code;
$$;

-- A bank account with a general ledger account of its own, so the two
-- ends of a transfer are distinguishable in the nominal.
create or replace function pg_temp.bank(
  p_org uuid, p_name text, p_code text, p_currency char(3) default 'MYR')
returns uuid language plpgsql as $$
declare v_acct uuid; v_id uuid;
begin
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (p_org, p_code, p_name, 'asset', 'bank', false,
          (select id from public.accounts where org_id = p_org and code = '1100'),
          1000)
  returning id into v_acct;

  insert into public.bank_accounts
    (org_id, name, account_id, currency, is_active)
  values (p_org, p_name, v_acct, p_currency, true)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.balance(
  p_org uuid, p_code text, p_as_at date default date '2026-12-31')
returns numeric language sql as $$
  select coalesce(
    (select closing_balance from public.report_trial_balance(p_org, null, p_as_at)
      where code = p_code), 0);
$$;

create or replace function pg_temp.cf(
  p_org uuid, p_label text)
returns numeric language sql as $$
  select coalesce((select amount from public.report_cash_flow(
                     p_org, date '2026-01-01', date '2026-12-31')
                    where label = p_label), 0);
$$;

-- ---------------------------------------------------------------------
-- Moving money, and the bank keeping some of it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Transfer Sdn Bhd');
  v_current uuid; v_savings uuid; v_id uuid;
begin
  v_current := pg_temp.bank(v_org, 'Current account', '1121');
  v_savings := pg_temp.bank(v_org, 'Savings account', '1122');

  -- Seed the current account so there is something to move.
  perform public.post_manual_journal(v_org, date '2026-01-02',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1121'),
                         'debit', 50000, 'credit', 0, 'description', 'Opening'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 50000, 'description', 'Opening')),
    'Capital introduced');

  v_id := public.create_bank_transfer(
    p_from_account_id => v_current,
    p_to_account_id => v_savings,
    p_amount_sent => 10010,
    p_transfer_date => date '2026-03-01',
    p_amount_received => 10000,
    p_bank_charges => 10,
    p_reference => 'IBG 20260301');
  perform public.post_bank_transfer(v_id);

  perform pg_temp.check_eq('the current account is down by what left it',
    pg_temp.balance(v_org, '1121'), 50000 - 10010);
  perform pg_temp.check_eq('the savings account has what arrived',
    pg_temp.balance(v_org, '1122'), 10000);
  perform pg_temp.check_eq('and the bank kept the difference',
    pg_temp.balance(v_org, '6300'), 10);

  -- The reason this is a document rather than two journal lines.
  perform pg_temp.check_true('both ends are one movement, findable from either',
    (select count(*) from public.bank_transfers
      where from_account_id = v_current and to_account_id = v_savings) = 1);

  perform pg_temp.check_true('and it is posted, with a reference to match',
    (select status = 'posted' and gl_entry_id is not null
        and reference = 'IBG 20260301'
       from public.bank_transfers where id = v_id));

  -- The assertion the file exists for. Fifty thousand of capital came
  -- in; shuffling ten thousand of it between two of the company's own
  -- accounts changed nothing except the tenner the bank took.
  perform pg_temp.check_eq('a transfer is not a cash flow',
    pg_temp.cf(v_org, 'Net movement in cash'), 50000 - 10);
  perform pg_temp.check_eq('only the fee reaches the statement',
    pg_temp.cf(v_org, 'Profit for the period'), -10);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What it will not accept
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Refuse Transfer Sdn Bhd');
  v_other uuid := pg_temp.tr_org('Somebody Else Sdn Bhd');
  v_a uuid; v_b uuid; v_theirs uuid;
begin
  -- `tr_org` signed in as the same fixture user for both, so the guard
  -- being tested is the organization boundary rather than the login.
  v_theirs := pg_temp.bank(v_other, 'Their account', '1121');
  v_a := pg_temp.bank(v_org, 'Current account', '1121');
  v_b := pg_temp.bank(v_org, 'Savings account', '1122');

  begin
    perform public.create_bank_transfer(v_a, v_a, 1000, date '2026-03-01');
    raise exception 'FAIL: transferred from an account to itself';
  exception when sqlstate '22023' then
    raise notice 'ok   an account cannot pay itself';
  end;

  begin
    perform public.create_bank_transfer(v_a, v_theirs, 1000, date '2026-03-01');
    raise exception 'FAIL: moved money into another company';
  exception when sqlstate '42501' then
    raise notice 'ok   the organization boundary holds';
  end;

  -- One currency at both ends, so the three figures are arithmetic. A
  -- residual here is a typo, and burying it in an exchange account is
  -- how a wrong bank balance survives a year.
  begin
    perform public.create_bank_transfer(
      v_a, v_b, 1000, date '2026-03-01',
      p_amount_received => 900, p_bank_charges => 10);
    raise exception 'FAIL: accepted amounts that do not add up';
  exception when sqlstate '22023' then
    raise notice 'ok   the three amounts have to reconcile';
  end;

  begin
    perform public.create_bank_transfer(v_a, v_b, 0, date '2026-03-01');
    raise exception 'FAIL: transferred nothing';
  exception when sqlstate '22023' then
    raise notice 'ok   a transfer needs an amount';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Across currencies, where a residual is real
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Foreign Transfer Sdn Bhd');
  v_usd uuid; v_myr uuid; v_id uuid;
begin
  v_usd := pg_temp.bank(v_org, 'USD account', '1121', 'USD');
  v_myr := pg_temp.bank(v_org, 'Ringgit account', '1122', 'MYR');

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date)
  values (v_org, 'USD', 'MYR', 4.50, date '2026-03-01');

  perform public.post_manual_journal(v_org, date '2026-01-02',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1121'),
                         'debit', 90000, 'credit', 0, 'description', 'Opening'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 90000, 'description', 'Opening')),
    'Capital introduced');

  -- Nothing to assume across a currency: it has to be told what landed.
  begin
    perform public.create_bank_transfer(v_usd, v_myr, 1000, date '2026-03-01');
    raise exception 'FAIL: guessed what arrived in another currency';
  exception when sqlstate '22023' then
    raise notice 'ok   it asks how much actually arrived';
  end;

  -- 1,000 USD at 4.50 is 4,500 ringgit; 4,400 arrived, so the bank's
  -- rate was worse than the table's by 100.
  v_id := public.create_bank_transfer(
    p_from_account_id => v_usd, p_to_account_id => v_myr,
    p_amount_sent => 1000, p_transfer_date => date '2026-03-01',
    p_amount_received => 4400);
  perform pg_temp.check_eq('the shortfall is exchange, not a missing hundred',
    (select fx_difference from public.bank_transfers where id = v_id), 100);

  perform public.post_bank_transfer(v_id);
  perform pg_temp.check_eq('and it is posted as a loss',
    pg_temp.balance(v_org, '6500'), 100);
  perform pg_temp.check_eq('the ringgit account has what arrived',
    pg_temp.balance(v_org, '1122'), 4400);
  perform pg_temp.check_eq('the dollar account is down by the base value of it',
    pg_temp.balance(v_org, '1121'), 90000 - 4500);

  -- Still not a cash flow: the exchange difference is the only thing
  -- that reaches the profit and loss.
  perform pg_temp.check_eq('a foreign transfer moves no cash either',
    pg_temp.cf(v_org, 'Net movement in cash'), 90000 - 100);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Undoing one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Undo Sdn Bhd');
  v_a uuid; v_b uuid; v_id uuid;
begin
  v_a := pg_temp.bank(v_org, 'Current account', '1121');
  v_b := pg_temp.bank(v_org, 'Savings account', '1122');

  perform public.post_manual_journal(v_org, date '2026-01-02',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1121'),
                         'debit', 20000, 'credit', 0, 'description', 'Opening'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 20000, 'description', 'Opening')),
    'Capital introduced');

  v_id := public.create_bank_transfer(v_a, v_b, 5000, date '2026-03-01');
  perform public.post_bank_transfer(v_id);
  perform pg_temp.check_eq('sent', pg_temp.balance(v_org, '1122'), 5000);

  perform public.void_bank_transfer(v_id, 'Keyed against the wrong account');

  -- Reversed rather than deleted: a statement already reconciled
  -- against the entry should not lose what it was matched to.
  perform pg_temp.check_eq('the money is back where it started',
    pg_temp.balance(v_org, '1121'), 20000);
  perform pg_temp.check_eq('and none of it is in the other account',
    pg_temp.balance(v_org, '1122'), 0);
  perform pg_temp.check_true('with the reason on the record',
    (select status = 'void' and notes like '%wrong account%'
       from public.bank_transfers where id = v_id));
  perform pg_temp.check_true('and the original journal still there',
    (select gl_entry_id is not null from public.bank_transfers where id = v_id));

  begin
    perform public.void_bank_transfer(v_id);
    raise exception 'FAIL: voided the same transfer twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a transfer is only voided once';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who can move the money
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a stranger cannot move money between accounts',
    not has_function_privilege('anon',
      'public.create_bank_transfer(uuid, uuid, numeric, date, numeric, numeric, text, text)',
      'execute')
    and not has_function_privilege('anon',
      'public.post_bank_transfer(uuid)', 'execute')
    and not has_function_privilege('anon',
      'public.void_bank_transfer(uuid, text)', 'execute'));

  perform pg_temp.check_true('a member can',
    has_function_privilege('authenticated',
      'public.create_bank_transfer(uuid, uuid, numeric, date, numeric, numeric, text, text)',
      'execute')
    and has_function_privilege('authenticated',
      'public.post_bank_transfer(uuid)', 'execute'));

  -- These rows say how much money the company has and where it is.
  perform pg_temp.check_true('the transfers are closed to anon',
    not has_table_privilege('anon', 'public.bank_transfers', 'select'));
  perform pg_temp.check_true('and readable by members',
    has_table_privilege('authenticated', 'public.bank_transfers', 'select'));
end $$;

rollback;

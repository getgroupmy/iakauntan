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

-- ---------------------------------------------------------------------
-- Undoing one, and the balance the app actually reads
--
-- `Undo Sdn Bhd` above asserts the ledger after a void, which is the
-- audited number.  It is not the number the app puts on the screen:
-- `bank_accounts.current_balance` is a running figure the two transfer
-- functions maintain by hand, and sweeping `void_bank_transfer` found
-- every line of that arithmetic unasserted.  The sending account could
-- be left short, the receiving account could keep the money, the bank
-- charges could go missing, and the trial balance would still be
-- right — the ledger and the balance on the screen would simply
-- disagree, which is the worst of the three outcomes because nothing
-- looks wrong until somebody reconciles.
--
-- The reversal's date was open too, and so were the two refusals: a
-- transfer already deleted, and a void by somebody with no right to
-- post.  The double-void refusal was asserted only by its SQLSTATE,
-- which `reverse_gl_entry` raises as well, so the message is checked
-- here instead.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Undo Baki Sdn Bhd');
  v_a uuid; v_b uuid; v_id uuid; v_gone uuid; v_rev uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg text;
begin
  v_a := pg_temp.bank(v_org, 'Current account', '1121');
  v_b := pg_temp.bank(v_org, 'Savings account', '1122');

  -- Sent, received and the fee are three different numbers, so a void
  -- that puts back only some of them is visible.
  v_id := public.create_bank_transfer(
    p_from_account_id => v_a, p_to_account_id => v_b,
    p_amount_sent => 10010, p_transfer_date => date '2026-03-01',
    p_amount_received => 10000, p_bank_charges => 10);
  perform public.post_bank_transfer(v_id);

  perform pg_temp.check_eq('the running balance is down by sent plus fee',
    (select current_balance from public.bank_accounts where id = v_a), -10010);
  perform pg_temp.check_eq('and up at the other end by what arrived',
    (select current_balance from public.bank_accounts where id = v_b), 10000);

  -- The fee is inside the ten thousand and ten, not beside it: the
  -- journal credits this account 10,010 and debits the tenner to 6300.
  -- Taking the charge off twice was 0504. `resync_bank_balance` is the
  -- definition of the figure, so the two have to agree.
  perform pg_temp.check_eq('and the running balance agrees with the ledger',
    public.resync_bank_balance(v_a), -10010);

  -- ------------------------------------------------------------------
  -- A transfer that is no longer there
  -- ------------------------------------------------------------------
  v_gone := public.create_bank_transfer(v_a, v_b, 100, date '2026-03-02');
  update public.bank_transfers set deleted_at = now() where id = v_gone;
  begin
    perform public.void_bank_transfer(v_gone, 'Never happened');
    raise exception 'FAIL voided a transfer that had been deleted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a deleted transfer is not there to void';
  end;

  -- ------------------------------------------------------------------
  -- Who may undo it
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-pindah@example.test'));
  begin
    perform public.void_bank_transfer(v_id, 'Not mine to void');
    raise exception 'FAIL a stranger voided another company''s transfer';
  exception when sqlstate '42501' then
    -- `reverse_gl_entry` refuses a stranger too, with the same
    -- SQLSTATE and one word less, so the message is what says which
    -- of the two turned them away. Whole message, not a fragment.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody who cannot post cannot void either',
      v_msg = 'Insufficient privileges to post');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and the money did not move on the attempt',
    (select current_balance from public.bank_accounts where id = v_b), 10000);

  -- ------------------------------------------------------------------
  -- Undone
  -- ------------------------------------------------------------------
  v_rev := public.void_bank_transfer(v_id, 'Keyed against the wrong account');

  -- Dated the day of the transfer, not the day somebody noticed. A
  -- reversal posted into a later month moves profit between periods.
  perform pg_temp.check_true('the reversal is dated the day of the transfer',
    (select entry_date = date '2026-03-01' from public.gl_entries
      where id = v_rev));
  perform pg_temp.check_eq('the sending account has the money and the fee back',
    (select current_balance from public.bank_accounts where id = v_a), 0);
  perform pg_temp.check_eq('and the receiving account is not still holding it',
    (select current_balance from public.bank_accounts where id = v_b), 0);

  begin
    perform public.void_bank_transfer(v_id, 'Again');
    raise exception 'FAIL voided the same transfer twice';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and it is the transfer refusing, not the ledger',
      v_msg like '%is already void%');
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Undoing one that crossed a currency
--
-- `current_balance` is carried in the base currency, so both legs of a
-- void have to be converted on the way back out. A thousand dollars
-- put back as a thousand ringgit leaves the account wrong by three and
-- a half thousand, and only a foreign account can show it: with the
-- ringgit side at a rate of one, either conversion could be dropped
-- and the same-currency case would not notice. So it is done in both
-- directions.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Pindah Mata Wang Sdn Bhd');
  v_usd uuid; v_myr uuid; v_myr2 uuid; v_usd2 uuid; v_id uuid;
begin
  v_usd  := pg_temp.bank(v_org, 'USD account', '1121', 'USD');
  v_myr  := pg_temp.bank(v_org, 'Ringgit account', '1122', 'MYR');
  v_myr2 := pg_temp.bank(v_org, 'Ringgit account two', '1123', 'MYR');
  v_usd2 := pg_temp.bank(v_org, 'USD account two', '1124', 'USD');

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date)
  values (v_org, 'USD', 'MYR', 4.50, date '2026-03-01');

  -- Dollars out: 1,000 USD at 4.50 is 4,500 ringgit of base value,
  -- and 4,400 arrived, so 100 was exchange.
  v_id := public.create_bank_transfer(
    p_from_account_id => v_usd, p_to_account_id => v_myr,
    p_amount_sent => 1000, p_transfer_date => date '2026-03-01',
    p_amount_received => 4400);
  perform public.post_bank_transfer(v_id);
  perform pg_temp.check_eq('the dollar account is down by its base value',
    (select current_balance from public.bank_accounts where id = v_usd), -4500);

  perform public.void_bank_transfer(v_id, 'Wrong account');
  perform pg_temp.check_eq('and the void puts back ringgit, not dollars',
    (select current_balance from public.bank_accounts where id = v_usd), 0);
  perform pg_temp.check_eq('with the ringgit end emptied too',
    (select current_balance from public.bank_accounts where id = v_myr), 0);

  -- Ringgit in: the conversion is on the receiving side this time.
  v_id := public.create_bank_transfer(
    p_from_account_id => v_myr2, p_to_account_id => v_usd2,
    p_amount_sent => 4500, p_transfer_date => date '2026-03-01',
    p_amount_received => 1000);
  perform public.post_bank_transfer(v_id);
  perform pg_temp.check_eq('the dollar account holds the base value of it',
    (select current_balance from public.bank_accounts where id = v_usd2), 4500);

  perform public.void_bank_transfer(v_id, 'Wrong account');
  perform pg_temp.check_eq('and the void takes back ringgit, not dollars',
    (select current_balance from public.bank_accounts where id = v_usd2), 0);
  perform pg_temp.check_eq('leaving the sending account whole',
    (select current_balance from public.bank_accounts where id = v_myr2), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Posting one: what it refuses, and what it carries onto the journal
--
-- Sweeping `post_bank_transfer` killed fifteen of twenty mutants and
-- left the same shape behind as everywhere else: every figure in the
-- journal and every running balance was caught, and none of the three
-- refusals was. A transfer already deleted, a transfer already posted,
-- and a stranger posting one all went through in silence.
--
-- The date and the reference survived too. Both are how a transfer is
-- found again: the date decides which month's accounts it lands in,
-- and the reference is what somebody types into the search box when
-- the bank statement says IBG and nothing else.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.tr_org('Catat Pindahan Sdn Bhd');
  v_a uuid; v_b uuid; v_id uuid; v_gone uuid; v_entry uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg text;
begin
  v_a := pg_temp.bank(v_org, 'Current account', '1121');
  v_b := pg_temp.bank(v_org, 'Savings account', '1122');

  -- ------------------------------------------------------------------
  -- A transfer that is no longer there
  -- ------------------------------------------------------------------
  v_gone := public.create_bank_transfer(v_a, v_b, 100, date '2026-03-02');
  update public.bank_transfers set deleted_at = now() where id = v_gone;
  begin
    perform public.post_bank_transfer(v_gone);
    raise exception 'FAIL posted a transfer that had been deleted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a deleted transfer is not there to post';
  end;

  v_id := public.create_bank_transfer(
    p_from_account_id => v_a, p_to_account_id => v_b,
    p_amount_sent => 2000, p_transfer_date => date '2026-03-01',
    p_reference => 'IBG 20260301');

  -- ------------------------------------------------------------------
  -- Who may post it
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-catat@example.test'));
  begin
    perform public.post_bank_transfer(v_id);
    raise exception 'FAIL a stranger posted another company''s transfer';
  exception when sqlstate '42501' then
    -- `create_gl_entry` would refuse them as well, further down, and
    -- its wording ends '...to post to the ledger', so this has to be
    -- the whole message rather than a fragment of it: a `like` on
    -- 'privileges to post' is satisfied by either function.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody outside the company cannot post it',
      v_msg = 'Insufficient privileges to post');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and it is still sitting in draft',
    (select status = 'draft' and gl_entry_id is null
       from public.bank_transfers where id = v_id));

  -- ------------------------------------------------------------------
  -- Posted once, and only once
  -- ------------------------------------------------------------------
  v_entry := public.post_bank_transfer(v_id);

  perform pg_temp.check_true('the journal is dated the day of the transfer',
    (select entry_date = date '2026-03-01' from public.gl_entries
      where id = v_entry));
  perform pg_temp.check_true('and carries the reference the bank will quote',
    (select reference = 'IBG 20260301' from public.gl_entries
      where id = v_entry));

  begin
    perform public.post_bank_transfer(v_id);
    raise exception 'FAIL posted the same transfer twice';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a transfer is only posted once',
      v_msg like '%already posted%');
  end;
  perform pg_temp.check_eq('so there is one journal for it, not two',
    (select count(*)::integer from public.gl_entries
      where source_table = 'bank_transfers' and source_id = v_id), 1);

  perform pg_temp.sign_out();
end $$;

rollback;

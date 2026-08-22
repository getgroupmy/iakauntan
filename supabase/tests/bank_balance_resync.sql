-- =====================================================================
-- iAkauntan :: rebuilding a bank balance from the ledger
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_balance_resync.sql
--
-- resync_bank_balance is run by import_opening_balances, and
-- opening_trial_balance.sql and opening_stock.sql already drive that
-- import -- so the function executes on every run of those files and a
-- crash in it would be caught. What is not caught is a wrong answer:
-- neither file mentions current_balance, so the number it writes has
-- never been asserted.
--
-- The number is
--
--   opening_balance + sum(debit - credit) over posted lines on the
--   bank's own GL account
--
-- and it is what the bank reconciliation screen reconciles against a
-- statement. Three parts of that expression can be wrong quietly, and
-- each is asserted below: the sign, the opening balance, and which
-- account's lines are summed.
--
-- The fourth, `and e.status = 'posted'`, cannot be. It was written
-- against a state the system no longer produces: 0102 stopped
-- reverse_gl_entry marking the original void -- "a reversal leaves the
-- original standing" -- and nothing else writes a gl_entry that is not
-- posted, the column defaulting to 'posted' and the ledger being closed
-- to writes from the API. Removing the filter changes no answer, so no
-- test can catch its removal. Said here rather than left looking
-- covered.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_owner   uuid := pg_temp.test_user();
  v_bank    uuid;
  v_acct    uuid;
  v_other   uuid;
  v_cash    uuid;
  v_entry   uuid;
  v_got     numeric;
  v_took    boolean;
begin
  v_org := pg_temp.test_org('Baki Bank Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);

  select id into v_acct from public.accounts
   where org_id = v_org and code = '1120';          -- Bank
  select id into v_cash from public.accounts
   where org_id = v_org and code = '1110';          -- Cash in hand

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, opening_balance, current_balance)
  values (v_org, v_acct, 'Current account', 'Maybank', 5000, 0)
  returning id into v_bank;

  -- ==================================================================
  -- The opening balance, before anything has moved
  -- ==================================================================
  perform pg_temp.check_eq('with no ledger movement it is the opening balance',
    public.resync_bank_balance(v_bank), 5000.00);
  perform pg_temp.check_eq('and the row is written, not only returned',
    (select current_balance from public.bank_accounts where id = v_bank),
    5000.00);

  -- ==================================================================
  -- Money in and money out
  -- ==================================================================
  -- 2,000 into the bank out of the cash box.
  perform public.post_manual_journal(v_org, date '2026-02-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_acct, 'debit', 2000, 'credit', 0),
      jsonb_build_object('account_id', v_cash, 'debit', 0, 'credit', 2000)),
    'Banked the takings', 'JV-1');

  perform pg_temp.check_eq('a debit raises the balance',
    public.resync_bank_balance(v_bank), 7000.00);

  -- 800 out again.
  perform public.post_manual_journal(v_org, date '2026-02-02',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 800, 'credit', 0),
      jsonb_build_object('account_id', v_acct, 'debit', 0, 'credit', 800)),
    'Drew cash', 'JV-2');

  -- The sign is the whole point: a credit on a bank account is money
  -- leaving. Inverted, this reads 7,800 and the reconciliation screen
  -- shows a balance the bank has never heard of.
  perform pg_temp.check_eq('and a credit lowers it',
    public.resync_bank_balance(v_bank), 6200.00);

  -- ==================================================================
  -- What does not count
  -- ==================================================================
  -- Another account's movements are not this bank's.
  perform public.post_manual_journal(v_org, date '2026-02-03',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 999, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.accounts
          where org_id = v_org and code = '1130'),   -- Petty cash, a leaf
        'debit', 0, 'credit', 999)),
    'Nothing to do with the bank', 'JV-3');
  perform pg_temp.check_eq('another account''s movement is not this bank''s',
    public.resync_bank_balance(v_bank), 6200.00);

  -- A reversed entry nets itself out, which is how the ledger cancels
  -- something rather than deleting it -- and 0102's point is that both
  -- entries stay posted and visible, the correction being the mirror
  -- rather than the disappearance of the original.
  select id into v_entry from public.gl_entries
   where org_id = v_org and reference = 'JV-2';
  perform public.reverse_gl_entry(v_entry, date '2026-02-04');
  perform pg_temp.check_eq('a reversal puts the money back',
    public.resync_bank_balance(v_bank), 7000.00);
  perform pg_temp.check_eq('with both entries left standing and posted',
    (select count(*) from public.gl_entries
      where org_id = v_org and reference = 'JV-2' and status = 'posted'), 2);

  -- ==================================================================
  -- A second bank account on its own GL account
  --
  -- The function's own comment says it assumes one bank account per GL
  -- account. Two accounts with two GL accounts stay independent, which
  -- is the setup that assumption describes.
  -- ==================================================================
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, opening_balance, current_balance)
  values (v_org, v_cash, 'Petty cash', 'In the safe', 100, 0)
  returning id into v_other;
  -- 2,000 in, 800 out, 800 back out again, 999 in: cash is +2,199 net
  -- of the bank's own movements, on top of its 100 opening.
  perform pg_temp.check_eq('a second account tracks its own GL account',
    public.resync_bank_balance(v_other), 100.00 + (-2000 + 800 - 800 + 999));
  perform pg_temp.check_eq('and the first is untouched by the second',
    (select current_balance from public.bank_accounts where id = v_bank),
    7000.00);

  -- ==================================================================
  -- Who may run it
  -- ==================================================================
  begin
    perform public.resync_bank_balance(gen_random_uuid());
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('a bank account that does not exist is refused',
    not v_took);

  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.resync_bank_balance(v_bank);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('and a stranger cannot rebuild somebody''s balance',
    not v_took);
  perform pg_temp.check_eq('leaving it as it was',
    (select current_balance from public.bank_accounts where id = v_bank),
    7000.00);

  perform pg_temp.sign_out();
end $$;

rollback;

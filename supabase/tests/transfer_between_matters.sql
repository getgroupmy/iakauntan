-- =====================================================================
-- iAkauntan :: a journal on the client side
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transfer_between_matters.sql
--
-- `0690`. Money already held for one matter becomes money held for
-- another: a deposit paid into the wrong file, a related matter opened
-- and the balance carried across, a correction. `0021` defined
-- `transfer_in` and `transfer_out` for it and nothing ever wrote either.
--
-- The assertions that matter, and every one of them is about a way this
-- could look right and be wrong:
--
--   * THE STATUTORY GUARD STILL BITES. A matter may not transfer money
--     it does not hold. Written as two `client_account_transactions`
--     rows precisely so `app.assert_client_funds` applies -- a journal
--     straight to `gl_lines` would have bypassed the one control the
--     Solicitors' Accounts Rules turn on, in the feature most likely to
--     break it.
--   * NO MONEY MOVES. The client bank account is untouched. Posting a
--     bank leg each way would net to zero and still hand the
--     reconciliation two entries the statement never saw.
--   * BOTH MATTERS' LEDGERS SHOW IT. Netting to zero at the firm level
--     is right; showing nothing on either file is not.
--   * AND THE TOTAL HELD IS UNCHANGED, which is what makes it a
--     transfer rather than a receipt and a payment.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_c     uuid;
  v_m1    uuid;
  v_m2    uuid;
  v_bank  uuid;
  v_liab  uuid;
  v_txn   uuid;
  v_entry uuid;
  v_n     integer;
  v_amt   numeric;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Guaman Dua Sdn Bhd');
  perform public.setup_legal_module(v_org);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', app.today())::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_c, v_owner)
  returning id into v_m1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'Purchase of another', v_c, v_owner)
  returning id into v_m2;

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;
  select id into v_liab from public.accounts
   where org_id = v_org and code = '2300';

  -- Money in, on the first matter.
  perform public.receive_client_money(v_m1, 5000.00);

  -- -------------------------------------------------------------------
  -- The guard, before anything else
  --
  -- More than is held, refused. This is the whole reason the transfer
  -- is written as client transactions rather than as a journal.
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a matter cannot transfer money it does not hold',
    format($q$select public.transfer_between_matters(%L, %L, 9000,
             'Wrong file')$q$, v_m1, v_m2),
    '%cannot transfer%');

  perform pg_temp.check_refused(
    'and the same matter twice is refused, not quietly done',
    format($q$select public.transfer_between_matters(%L, %L, 100,
             'To itself')$q$, v_m1, v_m1),
    '%two different matters%');

  perform pg_temp.check_refused(
    'a transfer with no explanation is refused',
    format($q$select public.transfer_between_matters(%L, %L, 100, '   ')$q$,
           v_m1, v_m2),
    '%Say why%');

  perform pg_temp.check_refused(
    'and so is a negative one',
    format($q$select public.transfer_between_matters(%L, %L, -100,
             'Backwards')$q$, v_m1, v_m2),
    '%positive amount%');

  -- -------------------------------------------------------------------
  -- The transfer itself
  -- -------------------------------------------------------------------
  v_txn := public.transfer_between_matters(
    v_m1, v_m2, 1500.00, 'Deposit paid into the wrong file');

  perform pg_temp.check_eq(
    'the paying matter holds less',
    public.matter_client_balance(v_m1), 3500.00);
  perform pg_temp.check_eq(
    'and the receiving matter holds it instead',
    public.matter_client_balance(v_m2), 1500.00);

  -- What makes it a transfer rather than a payment and a receipt.
  select coalesce(sum(t.amount), 0) into v_amt
    from public.client_account_transactions t
   where t.org_id = v_org and t.status <> 'void';
  perform pg_temp.check_eq(
    'and the firm holds the same total it did before', v_amt, 5000.00);

  -- The two rows, using the types `0021` defined and nothing wrote.
  select count(*) into v_n from public.client_account_transactions
   where org_id = v_org and transaction_type = 'transfer_out';
  perform pg_temp.check_eq('one leg out', v_n, 1);
  select count(*) into v_n from public.client_account_transactions
   where org_id = v_org and transaction_type = 'transfer_in';
  perform pg_temp.check_eq('and one leg in', v_n, 1);

  -- -------------------------------------------------------------------
  -- No money moved
  --
  -- The client bank account is where it was. A bank leg each way would
  -- net to zero at the account and still put two movements through the
  -- reconciliation that the statement has never heard of.
  -- -------------------------------------------------------------------
  select gl_entry_id into v_entry from public.client_account_transactions
   where id = v_txn;
  perform pg_temp.check_true('the transfer posted', v_entry is not null);

  select count(*) into v_n from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = v_entry and a.code = '1150';
  perform pg_temp.check_eq(
    'and it touches the client bank account not at all', v_n, 0);

  select count(*) into v_n from public.gl_lines
   where entry_id = v_entry and account_id = v_liab;
  perform pg_temp.check_eq(
    'both lines are client monies held', v_n, 2);

  select sum(debit) - sum(credit) into v_amt from public.gl_lines
   where entry_id = v_entry;
  perform pg_temp.check_eq('and the entry nets to nothing', v_amt, 0.00);

  -- -------------------------------------------------------------------
  -- Both files show it
  --
  -- One entry, two matters -- the shape `0688`'s assertion was written
  -- for. Netting to zero at the firm is right; showing nothing on
  -- either matter would not be.
  -- -------------------------------------------------------------------
  select sum(debit) into v_amt from public.gl_lines
   where entry_id = v_entry and matter_id = v_m1;
  perform pg_temp.check_eq(
    'the paying matter is debited, because we owe that client less',
    v_amt, 1500.00);

  select sum(credit) into v_amt from public.gl_lines
   where entry_id = v_entry and matter_id = v_m2;
  perform pg_temp.check_eq(
    'and the receiving matter credited, because we owe that one more',
    v_amt, 1500.00);

  select count(*) into v_n
    from public.report_matter_ledger(v_org, v_m1);
  perform pg_temp.check_true(
    'so the audit pull for the paying matter shows it', v_n > 0);
  select count(*) into v_n
    from public.report_matter_ledger(v_org, v_m2);
  perform pg_temp.check_true(
    'and so does the one for the receiving matter', v_n > 0);

  -- -------------------------------------------------------------------
  -- Emptying a matter exactly is fine
  --
  -- The deferred trigger looks after BOTH rows land, so a transfer that
  -- leaves the paying matter at zero is not an overdraft.
  -- -------------------------------------------------------------------
  perform public.transfer_between_matters(
    v_m1, v_m2, 3500.00, 'The rest of it, same client');
  perform pg_temp.check_eq(
    'a matter can be emptied exactly',
    public.matter_client_balance(v_m1), 0.00);
end $$;

-- ---------------------------------------------------------------------
-- Two firms
-- ---------------------------------------------------------------------
do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_mine   uuid;
  v_theirs uuid;
  v_c      uuid;
  v_m1     uuid;
  v_m2     uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_mine := pg_temp.test_org('Firm A Sdn Bhd');
  v_theirs := pg_temp.test_org('Firm B Sdn Bhd');
  perform public.setup_legal_module(v_mine);
  perform public.setup_legal_module(v_theirs);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_mine, 'C1', 'A client', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_mine, 'A-1', 'Ours', v_c, v_owner) returning id into v_m1;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_theirs, 'C2', 'Their client', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_theirs, 'B-1', 'Theirs', v_c, v_owner) returning id into v_m2;

  perform pg_temp.check_refused(
    'money cannot be transferred between two firms'' matters',
    format($q$select public.transfer_between_matters(%L, %L, 10,
             'Across the street')$q$, v_m1, v_m2),
    '%different firms%');
end $$;

rollback;

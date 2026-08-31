-- =====================================================================
-- iAkauntan :: client money, and the two rules it is held under
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/client_account.sql
--
-- A law firm holding money for a client holds it under the Solicitors'
-- Accounts Rules 1990, and two of those rules are absolute:
--
--   1. Client money is kept in a client account, separate from the
--      firm's own. It is never mixed with office money.
--   2. Money held for one client is not used for another. A client
--      ledger cannot go into debit, however healthy the account is
--      overall.
--
-- The second is enforced by app.assert_client_funds, a deferred
-- constraint trigger, and nothing tested it. The first was enforced
-- halfway: post_client_transaction checked is_client_account when
-- choosing the ledger account and then updated the balance of whatever
-- bank account the transaction named, so client money entered against
-- the office account debited 1150 in the ledger and landed in the
-- office account in the bank register. 0282 refuses it.
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
  v_c1      uuid;
  v_c2      uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_bank    uuid;
  v_office  uuid;
  v_office_acct uuid;
  v_txn     uuid;
  v_entry   uuid;
  v_msg     text;
  v_posted_twice boolean;
  r         record;
  v_n       numeric;
begin
  v_org := pg_temp.test_org('Guaman Probe & Rakan', array['legal']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'legal', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);

  perform public.setup_legal_module(v_org);
  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;
  perform pg_temp.check_true('the legal setup made a client account',
    v_bank is not null);
  perform pg_temp.check_true('and the accounts it posts to',
    exists (select 1 from public.accounts
             where org_id = v_org and code in ('1150', '2300')
             having count(*) = 2));

  -- The firm's own current account, which is where this goes wrong.
  select id into v_office_acct from public.accounts
   where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, account_type, is_client_account, is_active)
  values (v_org, v_office_acct, 'Office Current', 'current', false, true)
  returning id into v_office;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL2', 'Encik Rajan', 'customer') returning id into v_c2;
  insert into public.matters
    (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_c1, pg_temp.test_user())
  returning id into v_m1;
  insert into public.matters
    (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'A tenancy dispute', v_c2, pg_temp.test_user())
  returning id into v_m2;

  -- ==================================================================
  -- Money in, and what it does to the books
  -- ==================================================================
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m1, 'CT-1', date '2026-02-02', 'receipt',
          v_bank, 50000, 'MYR', 'Deposit on account')
  returning id into v_txn;
  v_entry := public.post_client_transaction(v_txn);

  perform pg_temp.check_eq('a receipt debits the client bank',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1150'), 50000.00);
  -- Client money is a liability and never income. If this ever landed
  -- in revenue the firm would be paying tax on money it does not own.
  perform pg_temp.check_eq('and credits what the firm owes the client',
    (select l.credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2300'), 50000.00);
  perform pg_temp.check_eq('the entry balances',
    (select sum(debit) - sum(credit) from public.gl_lines
      where entry_id = v_entry), 0.00);
  perform pg_temp.check_eq('the transaction is marked posted',
    (select status::text from public.client_account_transactions
      where id = v_txn), 'posted');
  perform pg_temp.check_eq('by whoever posted it',
    (select posted_by from public.client_account_transactions
      where id = v_txn), v_owner);
  perform pg_temp.check_eq('and the client account balance moves',
    (select current_balance from public.bank_accounts where id = v_bank),
    50000.00);

  -- A flag rather than `raise ... exception when others`: that shape
  -- catches the FAIL it raises itself and can never fail. The refusal
  -- carries no errcode, so there is no sqlstate to catch instead.
  begin
    perform public.post_client_transaction(v_txn);
    v_posted_twice := true;
  exception when others then v_posted_twice := false;
  end;
  perform pg_temp.check_true('and it cannot be posted twice',
    not v_posted_twice);
  perform pg_temp.check_eq('the ledger holds one entry for it, not two',
    (select count(*) from public.gl_entries
      where source_table = 'client_account_transactions'
        and source_id = v_txn), 1);

  -- ==================================================================
  -- Money out, within what is held
  -- ==================================================================
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m1, 'CT-2', date '2026-02-10', 'payment',
          v_bank, -20000, 'MYR', 'Paid to the vendor''s solicitors')
  returning id into v_txn;
  v_entry := public.post_client_transaction(v_txn);

  perform pg_temp.check_eq('a payment credits the client bank',
    (select l.credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1150'), 20000.00);
  perform pg_temp.check_eq('and reduces what is owed to the client',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2300'), 20000.00);
  perform pg_temp.check_eq('leaving thirty thousand in the client account',
    (select current_balance from public.bank_accounts where id = v_bank),
    30000.00);

  -- ==================================================================
  -- Rule 1: client money is not office money
  -- ==================================================================
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m2, 'CT-3', date '2026-02-11', 'receipt',
          v_office, 8000, 'MYR', 'Into the wrong account')
  returning id into v_txn;
  begin
    perform public.post_client_transaction(v_txn);
    raise exception 'FAIL: client money was posted against the office account';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('the refusal names the account',
      v_msg like '%Office Current%');
    raise notice 'ok   client money cannot be posted to the office account';
  end;

  perform pg_temp.check_eq('and nothing reached the office balance',
    (select current_balance from public.bank_accounts where id = v_office),
    0.00);
  perform pg_temp.check_eq('nor the client account',
    (select current_balance from public.bank_accounts where id = v_bank),
    30000.00);
  perform pg_temp.check_eq('and the entry was never written',
    (select count(*) from public.gl_entries
      where source_table = 'client_account_transactions'
        and source_id = v_txn), 0);
  delete from public.client_account_transactions where id = v_txn;

  -- ==================================================================
  -- Rule 2: one client's money is not another's
  --
  -- The firm is holding RM30,000, all of it Puan Aminah's. Encik Rajan
  -- has nothing on account, so there is nothing to pay out for him --
  -- however much is sitting in the client account overall.
  -- ==================================================================
  -- app.assert_client_funds is a deferred constraint trigger, so it does
  -- not fire on the statement -- it fires when the transaction commits,
  -- and this file never commits. Forcing it immediate is what makes the
  -- refusals below real; the deferred case is asserted on its own terms
  -- further down.
  set constraints assert_client_funds immediate;

  begin
    insert into public.client_account_transactions
      (org_id, matter_id, transaction_no, transaction_date, transaction_type,
       bank_account_id, amount, currency, description)
    values (v_org, v_m2, 'CT-4', date '2026-02-12', 'payment',
            v_bank, -5000, 'MYR', 'Funded from the other client''s money');
    raise exception 'FAIL: one matter was funded from another';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('the refusal names the matter',
      v_msg like '%M-2%');
    perform pg_temp.check_true('and says by how much it would be overdrawn',
      v_msg like '%5000.00%');
    raise notice 'ok   one client''s money cannot fund another''s matter';
  end;

  -- Overdrawing a matter that does have funds is refused on the amount,
  -- not on the matter being empty.
  begin
    insert into public.client_account_transactions
      (org_id, matter_id, transaction_no, transaction_date, transaction_type,
       bank_account_id, amount, currency, description)
    values (v_org, v_m1, 'CT-5', date '2026-02-12', 'payment',
            v_bank, -30000.01, 'MYR', 'One sen more than is held');
    raise exception 'FAIL: a matter was overdrawn by a sen';
  exception when sqlstate '23514' then
    raise notice 'ok   and a matter cannot be overdrawn by a single sen';
  end;

  -- Exactly what is held is allowed. The rule is "not in debit", not
  -- "keep something back".
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m1, 'CT-6', date '2026-02-12', 'payment',
          v_bank, -30000, 'MYR', 'The balance, paid out on completion');
  perform pg_temp.check_eq('paying out the whole balance is allowed',
    (select coalesce(sum(amount), 0) from public.client_account_transactions
      where matter_id = v_m1 and status <> 'void'), 0.00);
  delete from public.client_account_transactions where transaction_no = 'CT-6';

  -- The trigger is deferred, and that is deliberate: within one
  -- transaction the payment out may be written before the receipt that
  -- funds it, and what matters is where the matter stands at commit.
  -- With the check immediate the first row below would be refused on
  -- its own, which is the difference deferring makes.
  set constraints assert_client_funds deferred;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m2, 'CT-7', date '2026-02-13', 'payment',
          v_bank, -4000, 'MYR', 'Paid out first'),
         (v_org, v_m2, 'CT-8', date '2026-02-13', 'receipt',
          v_bank, 4000, 'MYR', 'Funded in the same breath');
  perform pg_temp.check_eq(
    'a payment and the receipt funding it may be written in either order',
    (select coalesce(sum(amount), 0) from public.client_account_transactions
      where matter_id = v_m2 and status <> 'void'), 0.00);
  -- And the pair really does satisfy the guard rather than dodge it:
  -- making the check immediate now runs it against the pending rows.
  set constraints assert_client_funds immediate;
  raise notice 'ok   and the pair still satisfies the guard at commit';

  -- Voiding the receipt that funded a payment overdraws the matter, so
  -- the same guard has to catch it on the way out as on the way in.
  begin
    update public.client_account_transactions
       set status = 'void' where transaction_no = 'CT-8';
    raise exception 'FAIL: voiding the funding receipt left the matter overdrawn';
  exception when sqlstate '23514' then
    raise notice 'ok   voiding a receipt cannot leave a matter overdrawn';
  end;

  begin
    delete from public.client_account_transactions where transaction_no = 'CT-8';
    raise exception 'FAIL: deleting the funding receipt left the matter overdrawn';
  exception when sqlstate '23514' then
    raise notice 'ok   nor can deleting one';
  end;

  -- ==================================================================
  -- Who may post it
  -- ==================================================================
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, currency, description)
  values (v_org, v_m1, 'CT-9', date '2026-02-14', 'receipt',
          v_bank, 1000, 'MYR', 'A further deposit')
  returning id into v_txn;

  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.post_client_transaction(v_txn);
    raise exception 'FAIL: a stranger posted a client transaction';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot post client money';
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.sign_out();
end $$;

rollback;

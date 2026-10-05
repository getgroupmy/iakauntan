-- =====================================================================
-- iAkauntan :: the client's money, moved between their own matters
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_transfer.sql
--
-- `app.client_txn_type` has had `transfer_in` and `transfer_out` since
-- `0021` and nothing ever wrote either. `0358` writes them as a pair,
-- and the pair is the whole design: one `transfer_out` on its own is
-- money taken off a matter and put nowhere, posted exactly like a
-- payment and reconcilable against nothing.
--
-- Three claims, and the middle one is the statutory one:
--
--   1. The money moves between matters and the *ledger does not*. Both
--      legs are the same two accounts with the signs reversed, so the
--      client bank and the client-monies-held liability finish where
--      they started. Nothing left the bank.
--   2. Two matters of two different clients cannot be joined this way,
--      whatever the balances are. Money held for one client is that
--      client's.
--   3. A matter cannot move out what it does not hold. `0021`'s
--      deferred trigger is the control; this asserts the refusal
--      arrives with the matter and the figure in it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_bank  uuid;
  v_them  uuid;
  v_other uuid;
  v_sale  uuid;
  v_lease uuid;
  v_theirs uuid;
  v_ids   uuid[];
  v_deposit uuid;
  v_bank_before numeric;
  v_liab_before numeric;
  v_refused boolean;
  v_msg   text;
begin
  v_org := pg_temp.test_org('Guaman Pindah & Rakan', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);
  perform public.setup_legal_module(v_org);

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_them;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL2', 'Encik Rajan', 'customer') returning id into v_other;

  -- Her conveyance, finished, with a balance still held; and her new
  -- tenancy, which is where she wants it.
  -- `fee_earner` since `0383`: an open file is somebody's, because
  -- time is recorded by whoever is signed in and without one nothing
  -- says whose matter it is when they are away.
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_them, pg_temp.test_user())
  returning id into v_sale;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'A tenancy', v_them, pg_temp.test_user())
  returning id into v_lease;
  -- Somebody else's matter entirely.
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-3', 'A dispute', v_other, pg_temp.test_user())
  returning id into v_theirs;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_sale, 'CT-1', date '2026-02-02', 'receipt',
          v_bank, 5000, 'Deposit on account')
  returning id into v_deposit;
  perform public.post_client_transaction(v_deposit);

  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_bank_before
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = v_org and a.code = '1150';
  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_liab_before
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = v_org and a.code = '2300';

  -- ------------------------------------------------------------------
  -- Her money follows her to her other matter
  -- ------------------------------------------------------------------
  -- BY NAME, which is how the app calls it and is the one call shape
  -- these assertions never made. `0690` put a second signature beside
  -- this one; five named arguments fitted both, PostgREST calls every
  -- function by name, and the matter screen's transfer stopped working
  -- the moment it applied -- while this file went on passing, because
  -- a POSITIONAL call resolves without complaint.
  --
  -- So the call here is the app's. A test that exercises a shape
  -- nothing in the product uses is a test that can be green over a
  -- dead feature, which is `docs/widget-tests.md`'s argument arriving
  -- in SQL. See `0696`.
  v_ids := public.transfer_between_matters(
    p_from        => v_sale,
    p_to          => v_lease,
    p_amount      => 2000,
    p_date        => date '2026-03-01',
    p_description => 'Balance follows the client');

  perform pg_temp.check_eq('the conveyance is left holding three thousand',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_sale and t.status <> 'void'), 3000.00);
  perform pg_temp.check_eq('and the tenancy holds the two that moved',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_lease and t.status <> 'void'), 2000.00);

  -- Both legs, both posted, and typed as what they are. A pair written
  -- as two payments would balance the same way and say something false
  -- about where the money went.
  perform pg_temp.check_eq('written as a transfer out',
    (select t.transaction_type::text from public.client_account_transactions t
      where t.id = v_ids[1]), 'transfer_out');
  perform pg_temp.check_eq('and a transfer in',
    (select t.transaction_type::text from public.client_account_transactions t
      where t.id = v_ids[2]), 'transfer_in');
  perform pg_temp.check_true('both posted',
    (select count(*) = 2 from public.client_account_transactions t
      where t.id = any(v_ids) and t.status = 'posted'));
  -- Each leg names the other, because a transfer whose other half
  -- cannot be found is a payment with a friendly description.
  perform pg_temp.check_eq('the outgoing leg names where it went',
    (select t.reference from public.client_account_transactions t
      where t.id = v_ids[1]), 'M-2');
  perform pg_temp.check_eq('and the incoming leg where it came from',
    (select t.reference from public.client_account_transactions t
      where t.id = v_ids[2]), 'M-1');

  -- The claim the whole design rests on.
  perform pg_temp.check_eq('the client bank is exactly where it was',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l join public.accounts a on a.id = l.account_id
      where a.org_id = v_org and a.code = '1150'), v_bank_before);
  perform pg_temp.check_eq('and so is what the firm owes its clients',
    (select coalesce(sum(l.credit) - sum(l.debit), 0)
       from public.gl_lines l join public.accounts a on a.id = l.account_id
      where a.org_id = v_org and a.code = '2300'), v_liab_before);

  -- ------------------------------------------------------------------
  -- Somebody else's matter, which is the breach
  -- ------------------------------------------------------------------
  v_refused := false;
  begin
    perform public.transfer_between_matters(v_sale, v_theirs, 1000);
  exception when others then
    v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'money held for one client may not be applied for another', v_refused);
  -- The message names both, because the ordinary way this happens is a
  -- mistyped matter number in a list where both are open, and "not
  -- allowed" does not tell somebody which row they picked.
  perform pg_temp.check_true('and the refusal names both clients: ' || v_msg,
    v_msg like '%Aminah%' and v_msg like '%Rajan%');
  perform pg_temp.check_eq('with nothing moved',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_theirs and t.status <> 'void'), 0.00);

  -- ------------------------------------------------------------------
  -- More than the matter holds
  -- ------------------------------------------------------------------
  v_refused := false;
  begin
    perform public.transfer_between_matters(v_sale, v_lease, 9000);
  exception when others then
    v_refused := true; v_msg := sqlerrm;
  end;
  -- Worth knowing what this is actually asserting. `assert_client_funds`
  -- is `deferrable initially deferred`, so inside this transaction it
  -- does not fire at all — the file rolls back and commit never comes.
  -- What refuses here is `transfer_between_matters`' own check, and
  -- removing that one line makes this assertion fail while the trigger
  -- stays silent. In a session that does several things before
  -- committing, that check is the only thing that says no in time.
  perform pg_temp.check_true('a matter cannot move out what it does not hold',
    v_refused);
  perform pg_temp.check_true('saying which matter and how much: ' || v_msg,
    v_msg like '%M-1%' and v_msg like '%3000%');

  -- And the two refusals above are refusals rather than the function
  -- being broken: the same call for an amount it does hold goes through.
  perform public.transfer_between_matters(v_sale, v_lease, 3000);
  perform pg_temp.check_eq('the conveyance is now empty',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_sale and t.status <> 'void'), 0.00);

  -- ------------------------------------------------------------------
  -- The small refusals
  -- ------------------------------------------------------------------
  v_refused := false;
  begin
    perform public.transfer_between_matters(v_lease, v_lease, 100);
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('a matter cannot transfer to itself', v_refused);

  v_refused := false;
  begin
    perform public.transfer_between_matters(v_lease, v_sale, 0);
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('and nothing is not an amount', v_refused);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The eight a mutation run found this file could not see
-- ---------------------------------------------------------------------
--
-- `transfer_between_matters` has been redefined five times (0358, 0690,
-- 0696, 0698, 0739, and 0743 for what this block found) and this is the
-- only file that calls it. On 5 October it was mutated nineteen ways:
-- ten died against the assertions above, and the nine below are what
-- the rest of this file is for. With one calling file, nothing else in
-- the suite could rescue them.
--
--     python3 scripts/mutate_sql.py \
--       supabase/migrations/0743_which_client_account_when_there_are_two.sql \
--       supabase/tests/matter_transfer.sql \
--       supabase/tests/mutants/transfer_between_matters.py
--
-- Five were plain missing assertions: a deleted matter, another
-- company's matter, a company without the legal module, a stranger, and
-- a VOID transaction counting as money held.
--
-- The other four are about WHICH BANK ACCOUNT the money moves through,
-- and they survived because the fixture above has exactly one: the
-- client account `setup_legal_module` creates. With one account, "a
-- client account", "an active account" and "the default account" are
-- the same row, and no assertion can say which rule picked it -- the
-- twelfth entry in docs/widget-tests.md, in SQL again.
--
-- Enriching the fixture is not enough on its own, because the four
-- rules cannot all be observed in ONE company. `0741` gives
-- bank_accounts a unique index on `(org_id) where is_default and
-- is_active`, so a company has at most one default active account: if
-- the office account is the default (needed to show that
-- `is_client_account` is what excludes it) then no client account is,
-- and `is_default desc` has nothing to order. Hence two firms below,
-- each configured so that two of the rules disagree.
--
-- Two of the nine are regulatory rather than arithmetic, and are the
-- reason this block is worth its length: client money paid out of the
-- OFFICE account, and money held for one client applied for another,
-- are the two things the client-account rules exist to prevent.
do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_firm_b uuid;
  v_other_org uuid;
  v_plain  uuid;
  v_client uuid;
  v_m1     uuid;
  v_m2     uuid;
  v_gone   uuid;
  v_far    uuid;
  v_ca1    uuid;
  v_ca2    uuid;
  v_office uuid;
  v_shut   uuid;
  v_cb1    uuid;
  v_cb2    uuid;
  v_bm1    uuid;
  v_bm2    uuid;
  v_txn    uuid;
  v_void   uuid;
  v_ids    uuid[];
  v_used   uuid;
  v_again  uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();

  -- ==================================================================
  -- Firm A: the DEFAULT client account wins over another open one
  -- ==================================================================
  v_org := pg_temp.test_org('Wang Klien Sdn Bhd', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.setup_legal_module(v_org);

  select b.id into v_ca1 from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;
  update public.bank_accounts set is_default = true where id = v_ca1;
  v_ca2 := pg_temp.test_bank_account(v_org, 'Akaun klien kedua',
    p_client => true, p_default => false);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL', 'Puan Sofia', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'W-1', 'Satu', v_client, v_owner) returning id into v_m1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'W-2', 'Dua', v_client, v_owner) returning id into v_m2;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_m1, 'WCT-1', date '2026-02-02', 'receipt',
          v_ca1, 1000, 'On account') returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  v_ids := public.transfer_between_matters(v_m1, v_m2, 400);
  select t.bank_account_id into v_used
    from public.client_account_transactions t where t.id = v_ids[1];
  perform pg_temp.check_eq(
    'with two open client accounts, the DEFAULT one is used',
    v_used, v_ca1);
  perform pg_temp.check_true('and the other open one is a real alternative',
    v_ca2 is not null and v_ca2 <> v_ca1);

  -- ------------------------------------------------------------------
  -- A VOID transaction is not money the matter holds
  -- ------------------------------------------------------------------
  -- 600 left on W-1. A voided receipt for 5,000 must not make 5,600
  -- movable: `status <> 'void'` in the sufficiency check is the only
  -- thing between a bounced cheque and an overdrawn client ledger.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, status)
  values (v_org, v_m1, 'WCT-V', date '2026-02-03', 'receipt',
          v_ca1, 5000, 'Cheque that bounced', 'void')
  returning id into v_void;
  perform pg_temp.check_eq('the void receipt is on the matter',
    (select count(*)::integer from public.client_account_transactions
      where matter_id = v_m1 and status = 'void'), 1);
  perform pg_temp.check_eq('but what the matter holds ignores it',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_m1 and t.status <> 'void'), 600.00);
  perform pg_temp.check_refused(
    'so a void receipt does not fund a transfer',
    format('select public.transfer_between_matters(%L, %L, 1000)',
           v_m1, v_m2),
    '%holds only%', '23514');

  -- ------------------------------------------------------------------
  -- A DELETED matter is not a matter
  -- ------------------------------------------------------------------
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'W-9', 'Ditutup', v_client, v_owner) returning id into v_gone;
  update public.matters set deleted_at = now() where id = v_gone;
  perform pg_temp.check_refused('money cannot be moved FROM a deleted matter',
    format('select public.transfer_between_matters(%L, %L, 100)',
           v_gone, v_m2),
    '%move money from%', 'P0002');
  perform pg_temp.check_refused('nor TO one',
    format('select public.transfer_between_matters(%L, %L, 100)',
           v_m2, v_gone),
    '%move money to%', 'P0002');

  -- ------------------------------------------------------------------
  -- Another COMPANY's matter is out of reach
  -- ------------------------------------------------------------------
  -- The client is given the same NAME in both firms, so the client_id
  -- check cannot be what refuses this -- it has to be the `org_id` on
  -- the destination lookup.
  v_other_org := pg_temp.test_org('Firma Lain Sdn Bhd', array['legal']);
  perform public.setup_legal_module(v_other_org);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_other_org, 'CL', 'Puan Sofia', 'customer') returning id into v_far;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_other_org, 'X-1', 'Jauh', v_far, v_owner) returning id into v_far;
  perform pg_temp.check_refused(
    'client money does not cross from one company to another',
    format('select public.transfer_between_matters(%L, %L, 100)',
           v_m1, v_far),
    '%move money to%', 'P0002');

  -- ------------------------------------------------------------------
  -- A company that does not hold the legal module
  -- ------------------------------------------------------------------
  v_plain := pg_temp.test_org('Kedai Biasa Sdn Bhd', array['accounting']);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_plain, 'CL', 'Encik Ali', 'customer') returning id into v_far;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_plain, 'P-1', 'Satu', v_far, v_owner) returning id into v_gone;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_plain, 'P-2', 'Dua', v_far, v_owner) returning id into v_far;
  perform pg_temp.check_refused(
    'a company without the legal module holds no client money to move',
    format('select public.transfer_between_matters(%L, %L, 100)',
           v_gone, v_far),
    '%legal module%', '42501');

  -- ------------------------------------------------------------------
  -- And somebody who cannot post cannot move it
  -- ------------------------------------------------------------------
  -- The WHOLE message, not `%privileges%`. The fragment version of this
  -- assertion let the mutant that deletes this guard SURVIVE: with
  -- `can_post` gone the stranger gets further and is turned away by
  -- another guard whose message also contains the word, so the
  -- assertion passed either way. `bank_transfers.sql` already records
  -- the same trap in the same words -- "the message is what says which
  -- of the two turned them away".
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-klien@example.test'));
  perform pg_temp.check_refused(
    'a stranger cannot move a firm''s client money',
    format('select public.transfer_between_matters(%L, %L, 100)',
           v_m1, v_m2),
    'Insufficient privileges to move client money', '42501');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and the attempt moved nothing',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_m1 and t.status <> 'void'), 600.00);

  -- ==================================================================
  -- Firm B: the office account is the company default
  -- ==================================================================
  -- Configured the way a real firm is: the current account it trades
  -- from is the company default, so NO client account is the default.
  -- That makes `is_client_account` the only thing keeping client money
  -- out of the office account, and leaves `is_default desc` with
  -- nothing to order -- which is what 0743 is about.
  v_firm_b := pg_temp.test_org('Peguam Dua Akaun', array['legal']);
  perform public.create_fiscal_year(v_firm_b, date '2026-01-01');
  perform public.setup_legal_module(v_firm_b);

  v_office := pg_temp.test_bank_account(v_firm_b, 'Akaun pejabat',
    p_client => false, p_default => true);
  -- A CLOSED client account that still carries the default flag. `0741`
  -- permits it -- its index covers only `is_default and is_active` --
  -- and it is the only way to show that `is_active` is what keeps a
  -- shut account out, since otherwise the default office account wins.
  v_shut := pg_temp.test_bank_account(v_firm_b, 'Akaun klien lama',
    p_client => true, p_default => false, p_active => false);
  update public.bank_accounts set is_default = true where id = v_shut;

  select b.id into v_cb1 from public.bank_accounts b
   where b.org_id = v_firm_b and b.is_client_account and b.is_active;
  v_cb2 := pg_temp.test_bank_account(v_firm_b, 'Akaun klien B',
    p_client => true, p_default => false);
  -- CB2 is inserted SECOND and dated EARLIER, so the correct answer and
  -- the physical-order answer are different rows. Without a tiebreak
  -- after `is_default desc` the query returns CB1; with 0743's
  -- `created_at, id` it returns CB2. A fixture where the right row is
  -- also the first row cannot tell those two apart.
  update public.bank_accounts set created_at = now() - interval '2 days'
   where id = v_cb2;
  update public.bank_accounts set created_at = now() - interval '1 day'
   where id = v_cb1;

  perform pg_temp.check_eq('the firm has four accounts: office, two open '
    'client accounts and a closed one',
    (select count(*)::integer from public.bank_accounts
      where org_id = v_firm_b), 4);
  perform pg_temp.check_true('the office account is the company default, '
    'so no client account is',
    (select is_default from public.bank_accounts where id = v_office)
    and not exists (select 1 from public.bank_accounts
                     where org_id = v_firm_b and is_client_account
                       and is_active and is_default));

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_firm_b, 'CLB', 'Encik Bakri', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_firm_b, 'B-1', 'Satu', v_client, v_owner) returning id into v_bm1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_firm_b, 'B-2', 'Dua', v_client, v_owner) returning id into v_bm2;
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_firm_b, v_bm1, 'BCT-1', date '2026-02-02', 'receipt',
          v_cb1, 2000, 'On account') returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  v_ids := public.transfer_between_matters(v_bm1, v_bm2, 500);
  select t.bank_account_id into v_used
    from public.client_account_transactions t where t.id = v_ids[1];

  perform pg_temp.check_true(
    'client money never moves through the OFFICE account',
    v_used <> v_office);
  perform pg_temp.check_true('nor through a CLOSED client account',
    v_used <> v_shut);
  perform pg_temp.check_eq(
    'and with no default client account, the OLDEST open one, not '
    'whichever row the plan reaches first',
    v_used, v_cb2);

  -- Determinism, which is the whole point of 0743: the same call twice
  -- returns the same account. Before 0743 this query had no tiebreak
  -- after `is_default desc`, and rewriting a row's NAME was enough to
  -- change the answer.
  update public.bank_accounts set name = name || ' (dikemas kini)'
   where id = v_cb2;
  v_ids := public.transfer_between_matters(v_bm2, v_bm1, 100);
  select t.bank_account_id into v_again
    from public.client_account_transactions t where t.id = v_ids[1];
  perform pg_temp.check_eq(
    'and rewriting a row does not change which account is chosen',
    v_again, v_used);

  perform pg_temp.sign_out();
end $$;

rollback;

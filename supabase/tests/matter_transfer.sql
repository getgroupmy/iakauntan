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
  insert into public.matters (org_id, matter_no, name, client_id)
  values (v_org, 'M-1', 'Sale of a house', v_them) returning id into v_sale;
  insert into public.matters (org_id, matter_no, name, client_id)
  values (v_org, 'M-2', 'A tenancy', v_them) returning id into v_lease;
  -- Somebody else's matter entirely.
  insert into public.matters (org_id, matter_no, name, client_id)
  values (v_org, 'M-3', 'A dispute', v_other) returning id into v_theirs;

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
  v_ids := public.transfer_between_matters(
    v_sale, v_lease, 2000, date '2026-03-01', 'Balance follows the client');

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

rollback;

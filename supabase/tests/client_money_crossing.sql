-- =====================================================================
-- iAkauntan :: client money crossing to the office side
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/client_money_crossing.sql
--
-- `client_account.sql` asserts the two rules client money is held
-- under: it stays in the client account, and one client's money never
-- funds another's. This file is about the one lawful moment it leaves
-- -- a rendered bill settled out of money the firm already holds --
-- and it exists because until 0549 that movement lost the money.
--
-- `transfer_to_office` has been in the type enum since 0021 and the
-- matter screen offered it. `post_client_transaction` posts every type
-- the same way: client bank on one leg, 2300 on the other. So a
-- transfer reduced the client ledger, balanced, and stopped. The office
-- account was never debited and the invoice was never settled. Section
-- 1 below measures exactly that against the old shape, so the file
-- would have failed before 0549 rather than describing a bug in prose.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A firm, a client account, an office account, and a matter holding
-- ten thousand ringgit against a five thousand ringgit bill.
create or replace function pg_temp.firm()
returns table (org uuid, matter uuid, other_matter uuid, stranger_matter uuid,
               invoice uuid, other_invoice uuid, stranger_invoice uuid,
               client_bank uuid, office_bank uuid)
language plpgsql as $$
declare
  v_org uuid; v_client uuid; v_stranger uuid;
  v_m uuid; v_m2 uuid; v_ms uuid;
  v_inv uuid; v_inv2 uuid; v_invs uuid;
  v_client_bank uuid; v_office uuid; v_txn uuid;
begin
  v_org := pg_temp.test_org('Guaman Salmah & Rakan', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.setup_legal_module(v_org);

  select b.id into v_client_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account limit 1;

  select b.id into v_office from public.bank_accounts b
   where b.org_id = v_org and not b.is_client_account limit 1;
  if v_office is null then
    -- This used to hang the office account on 1100 "Cash and Bank",
    -- which is a GROUP: the firm's own money sat on the parent of its
    -- own client account, so a crossing from client to office moved
    -- between a child and its parent and the difference was invisible.
    v_office := pg_temp.test_bank_account(
      v_org, 'Office account', 'current', 'MYR', 0, 0, '111');
  end if;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-SALMAH', 'Puan Salmah', 'customer') returning id into v_client;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-RAHIM', 'Encik Rahim', 'customer') returning id into v_stranger;

  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_org, 'M-1', 'Sale of 12 Jalan Bunga', v_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_m;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_org, 'M-2', 'Her tenancy dispute', v_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_m2;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_org, 'M-3', 'His litigation', v_stranger,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_ms;

  -- Ten thousand on account for the first matter, through the door the
  -- receipt screen now uses.
  perform public.receive_client_money(
    v_m, 10000, date '2026-03-01', 'Deposit on account');

  -- A bill on each matter, so "the money went to the wrong one" is a
  -- thing this file can actually try.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, matter_id, currency,
     subtotal, total_amount, status)
  values (v_org, 'invoice', 'INV-M1', date '2026-03-05', v_client, v_m,
          'MYR', 5000, 5000, 'posted')
  returning id into v_inv;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, matter_id, currency,
     subtotal, total_amount, status)
  values (v_org, 'invoice', 'INV-M2', date '2026-03-05', v_client, v_m2,
          'MYR', 3000, 3000, 'posted')
  returning id into v_inv2;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, matter_id, currency,
     subtotal, total_amount, status)
  values (v_org, 'invoice', 'INV-M3', date '2026-03-05', v_stranger, v_ms,
          'MYR', 4000, 4000, 'posted')
  returning id into v_invs;

  return query select v_org, v_m, v_m2, v_ms, v_inv, v_inv2, v_invs,
                      v_client_bank, v_office;
end $$;

create or replace function pg_temp.bank_balance(p_bank uuid)
returns numeric language sql as $$
  select current_balance from public.bank_accounts where id = p_bank;
$$;

create or replace function pg_temp.paid(p_invoice uuid)
returns numeric language sql as $$
  select coalesce(paid_amount, 0) from public.sales_documents where id = p_invoice;
$$;

-- ---------------------------------------------------------------------
-- 1. The transfer arrives
-- ---------------------------------------------------------------------
do $$
declare
  f record;
  v_office_before numeric; v_client_before numeric;
  v_receipt uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  perform pg_temp.check_eq('the matter holds what was received',
    public.matter_client_balance(f.matter), 10000::numeric);
  perform pg_temp.check_eq('and it is in the client account, not the office',
    pg_temp.bank_balance(f.client_bank), 10000::numeric);
  perform pg_temp.check_eq('the office account has nothing of it',
    pg_temp.bank_balance(f.office_bank), 0::numeric);

  v_office_before := pg_temp.bank_balance(f.office_bank);
  v_client_before := pg_temp.bank_balance(f.client_bank);

  v_receipt := public.settle_from_client_account(
    f.matter, f.invoice, 4000, date '2026-03-10', f.office_bank);

  -- The three things the old one-legged transfer did not do. Each of
  -- these fails against the shape this migration replaced.
  perform pg_temp.check_eq('the office account receives it',
    pg_temp.bank_balance(f.office_bank), v_office_before + 4000);
  perform pg_temp.check_eq('and the bill it was raised for is paid',
    pg_temp.paid(f.invoice), 4000::numeric);
  perform pg_temp.check_eq('the matter holds four thousand less',
    public.matter_client_balance(f.matter), 6000::numeric);
  perform pg_temp.check_eq('which left the client account',
    pg_temp.bank_balance(f.client_bank), v_client_before - 4000);

  -- The client ledger records the crossing, and names the bill.
  perform pg_temp.check_eq('the client ledger records it as a transfer',
    (select t.transaction_type::text
       from public.client_account_transactions t
      where t.matter_id = f.matter and t.invoice_id = f.invoice),
    'transfer_to_office');
  perform pg_temp.check_true('and it is posted, not left in draft',
    (select t.status = 'posted' and t.gl_entry_id is not null
       from public.client_account_transactions t
      where t.matter_id = f.matter and t.invoice_id = f.invoice));
  perform pg_temp.check_true('the receipt says where the money came from',
    (select r.notes like '%client account%'
       from public.receipts r where r.id = v_receipt));
end $$;

-- ---------------------------------------------------------------------
-- 2. Whose money settles whose bill
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- The same client, a different matter. A client ledger is kept per
  -- matter, so this is not "her money paying her bill" -- it is one
  -- matter's money paying another's.
  perform pg_temp.check_refused(
    'one matter''s money cannot settle another''s bill',
    format('select public.settle_from_client_account(%L, %L, 1000)',
           f.matter, f.other_invoice),
    '%belongs to another matter%', '23514');

  -- A different client entirely.
  perform pg_temp.check_refused(
    'and certainly not another client''s',
    format('select public.settle_from_client_account(%L, %L, 1000)',
           f.matter, f.stranger_invoice),
    '%belongs to another matter%', '23514');

  perform pg_temp.check_eq('neither attempt moved anything',
    public.matter_client_balance(f.matter), 10000::numeric);
  perform pg_temp.check_eq('and neither bill was touched',
    pg_temp.paid(f.other_invoice) + pg_temp.paid(f.stranger_invoice),
    0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 3. The two ceilings
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- More than the matter holds. The deferred trigger from 0021 would
  -- catch this at COMMIT; the point of refusing first is the message.
  perform pg_temp.check_refused(
    'a matter cannot pay out more than it holds',
    format('select public.settle_from_client_account(%L, %L, 12000)',
           f.matter, f.invoice),
    '%holds 10000.00 and cannot transfer 12000.00%', '23514');

  -- More than the bill asks for. Client money paid beyond a bill has
  -- not become the firm's; it is still the client's, and it must not be
  -- parked in the office account as credit.
  perform pg_temp.check_refused(
    'and cannot overpay the bill',
    format('select public.settle_from_client_account(%L, %L, 6000)',
           f.matter, f.invoice),
    '%owes 5000.00 and cannot take 6000.00%', '23514');

  perform pg_temp.check_refused(
    'nor transfer nothing at all',
    format('select public.settle_from_client_account(%L, %L, 0)',
           f.matter, f.invoice),
    '%positive amount%', '23514');

  perform pg_temp.check_eq('the matter still holds all of it',
    public.matter_client_balance(f.matter), 10000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 4. It has to leave the client account
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- A "transfer" into the client account has moved nothing and has
  -- recorded that it did, twice.
  perform pg_temp.check_refused(
    'the money has to leave the client account',
    format('select public.settle_from_client_account(%L, %L, 1000, null, %L)',
           f.matter, f.invoice, f.client_bank),
    '%is a client account%', '23514');

  perform pg_temp.check_eq('and nothing moved',
    public.matter_client_balance(f.matter), 10000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 5. The one-legged transfer is gone
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- What the matter screen used to write: a transfer with nothing on
  -- the other end of it. This is the row that lost the money.
  perform pg_temp.check_refused(
    'a transfer with no invoice on it is refused',
    format('insert into public.client_account_transactions '
           '(org_id, matter_id, transaction_no, transaction_date, '
           ' transaction_type, bank_account_id, amount) '
           'values (%L, %L, ''CT-BY-HAND'', date ''2026-03-10'', '
           ' ''transfer_to_office''::app.client_txn_type, %L, -1000)',
           f.org, f.matter, f.client_bank),
    '%has to name the bill it settles%', '23514');

  perform pg_temp.check_eq('so the matter is untouched',
    public.matter_client_balance(f.matter), 10000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 6. Money in and money out, on account
-- ---------------------------------------------------------------------
do $$
declare
  f record;
  v_before numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- A disbursement paid on the client's behalf: stamp duty, out of
  -- their money, not the firm's.
  perform public.pay_from_client_account(
    f.matter, 1500, 'Lembaga Hasil Dalam Negeri', date '2026-03-11',
    'Stamp duty');
  perform pg_temp.check_eq('a disbursement reduces what the matter holds',
    public.matter_client_balance(f.matter), 8500::numeric);
  perform pg_temp.check_eq('and it records who was paid',
    (select t.payee from public.client_account_transactions t
      where t.matter_id = f.matter and t.amount = -1500),
    'Lembaga Hasil Dalam Negeri');

  perform pg_temp.check_refused(
    'and a disbursement cannot overdraw the matter either',
    format('select public.pay_from_client_account(%L, 9000)', f.matter),
    '%holds 8500.00 and cannot pay out 9000.00%', '23514');

  -- Nothing is not an amount. A zero movement posts a journal with two
  -- zero legs and leaves a line on a client's ledger that says nothing
  -- happened, which is not the same as nothing happening.
  perform pg_temp.check_refused(
    'a payment of nothing is refused',
    format('select public.pay_from_client_account(%L, 0)', f.matter),
    '%positive amount%', '23514');
  perform pg_temp.check_refused(
    'and so is a receipt of nothing',
    format('select public.receive_client_money(%L, 0)', f.matter),
    '%positive amount%', '23514');

  -- The refund at the end of a matter is the same movement with a
  -- different name on it, because a client asking "what happened to my
  -- money" is owed the difference.
  perform public.pay_from_client_account(
    f.matter, 500, 'Puan Salmah', date '2026-03-12', 'Balance returned',
    null, null, true);
  perform pg_temp.check_eq('a refund is recorded as a refund',
    (select t.transaction_type::text
       from public.client_account_transactions t
      where t.matter_id = f.matter and t.amount = -500),
    'refund');

  -- Everything that happened to this matter is on one ledger, in order.
  perform pg_temp.check_eq('every movement is on the matter''s ledger',
    (select count(*) from public.client_account_transactions t
      where t.matter_id = f.matter and t.status = 'posted'),
    3::numeric);

  -- And the last payment on a matter is always the exact one: whatever
  -- is left goes back to the client and the ledger closes at zero. A
  -- ceiling that refused the balance itself would leave every closed
  -- matter holding a few ringgit for ever.
  perform public.pay_from_client_account(
    f.matter, public.matter_client_balance(f.matter), 'Puan Salmah',
    date '2026-03-20', 'Balance returned on closing', null, null, true);
  perform pg_temp.check_eq('a matter may pay out exactly what it holds',
    public.matter_client_balance(f.matter), 0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 6b. Client money has one place it may be held
-- ---------------------------------------------------------------------
-- A firm that bought the legal module and never ran the setup has no
-- client account. The refusal has to say what is missing and why it
-- cannot simply use the office account instead -- that substitution is
-- the breach the Solicitors' Accounts Rules are mostly about.
do $$
declare
  v_org    uuid;
  v_client uuid;
  v_matter uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Guaman Belum Sedia', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  -- Deliberately no setup_legal_module: no client account exists.

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Encik Baru', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_org, 'M-1', 'A matter with nowhere to put the money', v_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_matter;

  perform pg_temp.check_refused(
    'with no client account, money may not simply go somewhere else',
    format('select public.receive_client_money(%L, 1000)', v_matter),
    '%client money may not be held anywhere else%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- 7. Exactly the balance, exactly the bill, and no bank named
-- ---------------------------------------------------------------------
-- Every boundary in this function is a `>`, and a `>=` in any of them
-- turns "you may pay the bill in full" into "you may not". The last
-- transfer on a matter is always the exact one: the bill is rendered
-- for what is held, and the matter closes at zero.
do $$
declare
  f        record;
  v_matter uuid;
  v_client uuid;
  v_inv    uuid;
  v_office_before numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  select client_id into v_client from public.matters where id = f.matter;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (f.org, 'M-4', 'Her probate', v_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_matter;

  perform public.receive_client_money(v_matter, 5000, date '2026-03-01');
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, matter_id, currency,
     subtotal, total_amount, status)
  values (f.org, 'invoice', 'INV-M4', date '2026-03-05', v_client, v_matter,
          'MYR', 5000, 5000, 'posted')
  returning id into v_inv;

  v_office_before := pg_temp.bank_balance(f.office_bank);

  -- No bank named: it has to find the office account by itself, and
  -- the client account is sitting right beside it in the same table.
  perform public.settle_from_client_account(
    v_matter, v_inv, 5000, date '2026-03-10');

  perform pg_temp.check_eq('a matter may transfer exactly what it holds',
    public.matter_client_balance(v_matter), 0::numeric);
  perform pg_temp.check_eq('and pay the bill in full',
    pg_temp.paid(v_inv), 5000::numeric);
  perform pg_temp.check_eq(
    'with no bank named it lands in the office account',
    pg_temp.bank_balance(f.office_bank), v_office_before + 5000);
  perform pg_temp.check_eq('and not back in the client one',
    pg_temp.bank_balance(f.client_bank), 10000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 8. A bill nobody attributed to a matter
-- ---------------------------------------------------------------------
-- `sales_documents.matter_id` is nullable and a bill can be raised
-- without it. Such a bill is still somebody's: it may be settled from
-- the client's own matter, and from nobody else's.
do $$
declare
  f        record;
  v_client uuid;
  v_loose  uuid;
  v_theirs uuid;
  v_stranger uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  select client_id into v_client from public.matters where id = f.matter;
  select client_id into v_stranger from public.matters where id = f.stranger_matter;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     subtotal, total_amount, status)
  values (f.org, 'invoice', 'INV-LOOSE', date '2026-03-05', v_client,
          'MYR', 1000, 1000, 'posted')
  returning id into v_loose;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     subtotal, total_amount, status)
  values (f.org, 'invoice', 'INV-THEIRS', date '2026-03-05', v_stranger,
          'MYR', 1000, 1000, 'posted')
  returning id into v_theirs;

  perform public.settle_from_client_account(
    f.matter, v_loose, 1000, date '2026-03-10', f.office_bank);
  perform pg_temp.check_eq(
    'a bill with no matter on it may be settled by its own client''s money',
    pg_temp.paid(v_loose), 1000::numeric);

  perform pg_temp.check_refused(
    'and not by somebody else''s',
    format('select public.settle_from_client_account(%L, %L, 1000, null, %L)',
           f.matter, v_theirs, f.office_bank),
    '%not addressed to the client of matter%', '23514');
  perform pg_temp.check_eq('which left that bill alone',
    pg_temp.paid(v_theirs), 0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 9. Who may, and which firms may at all
-- ---------------------------------------------------------------------
do $$
declare
  f       record;
  v_org   uuid;
  v_other uuid;
  v_client uuid;
  v_matter uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into f from pg_temp.firm();

  -- A firm that never bought the legal module has no client account and
  -- no business reaching any of this.
  perform pg_temp.allow_many_companies();
  v_other := pg_temp.test_org('Kedai Runcit Aman', array['crm']);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_other, 'C-1', 'Sesiapa', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_other, 'M-X', 'Not a law firm', v_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id into v_matter;

  perform pg_temp.check_refused(
    'a firm without the legal module cannot reach any of it',
    format('select public.receive_client_money(%L, 100)', v_matter),
    '%part of the legal module%', '42501');
  perform pg_temp.check_refused(
    'not to pay out of it either',
    format('select public.pay_from_client_account(%L, 100)', v_matter),
    '%part of the legal module%', '42501');
  perform pg_temp.check_refused(
    'nor to transfer to office',
    format('select public.settle_from_client_account(%L, %L, 100)',
           v_matter, f.invoice),
    '%part of the legal module%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The eight a mutation run found this file could not see
-- ---------------------------------------------------------------------
--
-- `0549`'s three movers -- money in, money out, and the crossing to
-- office -- were mutated twenty-two ways on 5 October. Thirteen died
-- against the assertions above; eight survived, and the other file that
-- names any of them (`client_account.sql`) killed NONE of the
-- twenty-two, so the union is this file alone.
--
--     python3 scripts/mutate_sql.py \
--       supabase/migrations/0549_the_transfer_that_has_to_arrive_somewhere.sql \
--       supabase/tests/client_money_crossing.sql \
--       supabase/tests/mutants/client_money_crossing.py
--
-- They fell into three families, and all three had already been found
-- the same day in `matter_transfer.sql`:
--
--   * THREE unasserted `can_post` guards -- one in each function. A
--     stranger could pay money onto a matter, pay money out of it, and
--     cross it to office, and nothing said no.
--   * `status <> 'void'` in the payout check, so a bounced receipt
--     funded a disbursement.
--   * FOUR bank-selection rules on `receive_client_money` collapsed
--     into one account. `firm()` above makes one client account and one
--     office account, and with the ordering landing on the client one
--     regardless, "a client account", "an active account", "the default
--     account" and "the oldest account" were indistinguishable.
--
-- As in matter_transfer, the four cannot all be observed in ONE
-- company: `0741` allows at most one default ACTIVE account, so showing
-- that `is_client_account` is what excludes the office account requires
-- the office account to be the default -- and then no client account is
-- one, and `is_default desc` has nothing to order. Two firms again.
--
-- A new block rather than a change to `pg_temp.firm()`, which nine
-- blocks above depend on.
do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_x      uuid;
  v_y      uuid;
  v_client uuid;
  v_m      uuid;
  v_m2     uuid;
  v_xc1    uuid;
  v_xc2    uuid;
  v_office uuid;
  v_shut   uuid;
  v_yc1    uuid;
  v_yc2    uuid;
  v_txn    uuid;
  v_void   uuid;
  v_used   uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();

  -- ==================================================================
  -- Firm X: three strangers' refusals, the void, and the default rule
  -- ==================================================================
  v_x := pg_temp.test_org('Peguam Wang Masuk', array['legal']);
  perform public.create_fiscal_year(v_x, date '2026-01-01');
  perform public.setup_legal_module(v_x);

  select b.id into v_xc1 from public.bank_accounts b
   where b.org_id = v_x and b.is_client_account;
  update public.bank_accounts set is_default = true where id = v_xc1;
  v_xc2 := pg_temp.test_bank_account(v_x, 'Akaun klien kedua',
    p_client => true, p_default => false);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_x, 'CL', 'Puan Noraini', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_x, 'X-1', 'Satu', v_client, v_owner, v_owner) returning id into v_m;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_x, 'X-2', 'Dua', v_client, v_owner, v_owner)
  returning id into v_m2;

  -- Money in, so there is something to pay out of.
  v_txn := public.receive_client_money(v_m, 5000, date '2026-02-02',
                                       'On account');
  select t.bank_account_id into v_used
    from public.client_account_transactions t where t.id = v_txn;
  perform pg_temp.check_eq(
    'with two open client accounts, money in lands in the DEFAULT one',
    v_used, v_xc1);
  perform pg_temp.check_true('and the other is a real alternative',
    v_xc2 is not null and v_xc2 <> v_xc1);

  -- ------------------------------------------------------------------
  -- A void receipt does not fund a disbursement
  -- ------------------------------------------------------------------
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, status)
  values (v_x, v_m, 'XCT-V', date '2026-02-03', 'receipt',
          v_xc1, 9000, 'Cheque that bounced', 'void')
  returning id into v_void;
  perform pg_temp.check_eq('the void receipt is on the matter',
    (select count(*)::integer from public.client_account_transactions
      where matter_id = v_m and status = 'void'), 1);
  perform pg_temp.check_eq('but what the matter holds ignores it',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_m and t.status <> 'void'), 5000.00);
  perform pg_temp.check_refused(
    'so a void receipt does not fund a disbursement',
    format('select public.pay_from_client_account(%L, 6000)', v_m),
    '%holds 5000.00 and cannot pay out 6000.00%', '23514');

  -- ------------------------------------------------------------------
  -- A stranger may do none of the three
  -- ------------------------------------------------------------------
  -- The WHOLE message, not `%privileges%`. All three functions raise
  -- `Insufficient privileges to move client money`, and other guards
  -- elsewhere raise `Insufficient privileges to post` -- so a fragment
  -- assertion passes against the wrong one. That is exactly how the
  -- can_post mutant on `transfer_between_matters` survived earlier the
  -- same day, and `bank_transfers.sql` records the trap in almost these
  -- words: "the message is what says which of the two turned them
  -- away".
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-wang@example.test'));
  perform pg_temp.check_refused(
    'a stranger cannot pay money ONTO a matter',
    format('select public.receive_client_money(%L, 100)', v_m),
    'Insufficient privileges to move client money', '42501');
  perform pg_temp.check_refused(
    'a stranger cannot pay money OUT of one',
    format('select public.pay_from_client_account(%L, 100)', v_m),
    'Insufficient privileges to move client money', '42501');
  perform pg_temp.check_refused(
    'a stranger cannot cross it to office either',
    format('select public.settle_from_client_account(%L, %L, 100)',
           v_m, gen_random_uuid()),
    'Insufficient privileges to move client money', '42501');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and none of the three attempts moved anything',
    (select coalesce(sum(t.amount), 0) from public.client_account_transactions t
      where t.matter_id = v_m and t.status <> 'void'), 5000.00);

  -- ==================================================================
  -- Firm Y: the office account is the company default
  -- ==================================================================
  -- The ordinary configuration for a firm: it trades from its office
  -- current account, so that is the company default and NO client
  -- account is. `is_client_account` is then the only thing keeping
  -- client money out of it.
  v_y := pg_temp.test_org('Peguam Akaun Pejabat', array['legal']);
  perform public.create_fiscal_year(v_y, date '2026-01-01');
  perform public.setup_legal_module(v_y);

  v_office := pg_temp.test_bank_account(v_y, 'Akaun pejabat',
    p_client => false, p_default => true);
  -- A CLOSED client account still carrying the default flag. 0741's
  -- index covers only `is_default and is_active`, so this is allowed --
  -- and it is the only way to show that `is_active` is what keeps a
  -- shut account out, since otherwise the default office account wins.
  v_shut := pg_temp.test_bank_account(v_y, 'Akaun klien lama',
    p_client => true, p_default => false, p_active => false);
  update public.bank_accounts set is_default = true where id = v_shut;

  select b.id into v_yc1 from public.bank_accounts b
   where b.org_id = v_y and b.is_client_account and b.is_active;
  v_yc2 := pg_temp.test_bank_account(v_y, 'Akaun klien B',
    p_client => true, p_default => false);
  -- YC2 is created SECOND and dated EARLIER, so the correct row and the
  -- first row are different ones. Without the `created_at` tiebreak the
  -- query returns whichever the scan reaches first; with it, YC2. A
  -- fixture where the right account is also the first account cannot
  -- tell the two apart.
  --
  -- The ORDER of these two updates matters, and getting it wrong cost a
  -- survivor: an UPDATE rewrites the row at the end of the heap, so
  -- whichever is updated LAST is scanned last. YC1 is updated first and
  -- YC2 second, which puts YC1 ahead of YC2 physically while YC2 stays
  -- the older by `created_at` -- so the two orderings disagree. Done
  -- the other way round, both orderings answer YC2 and the mutant that
  -- deletes the tiebreak survives, which is what happened on the first
  -- attempt.
  update public.bank_accounts set created_at = now() - interval '1 day'
   where id = v_yc1;
  update public.bank_accounts set created_at = now() - interval '2 days'
   where id = v_yc2;

  perform pg_temp.check_true('the office account is the company default, '
    'so no OPEN client account is',
    (select is_default from public.bank_accounts where id = v_office)
    and not exists (select 1 from public.bank_accounts
                     where org_id = v_y and is_client_account
                       and is_active and is_default));

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_y, 'CLY', 'Encik Faizal', 'customer') returning id into v_client;
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (v_y, 'Y-1', 'Satu', v_client, v_owner, v_owner) returning id into v_m;

  v_txn := public.receive_client_money(v_m, 3000, date '2026-02-02',
                                       'On account');
  select t.bank_account_id into v_used
    from public.client_account_transactions t where t.id = v_txn;

  perform pg_temp.check_true(
    'client money IN never lands in the OFFICE account',
    v_used <> v_office);
  perform pg_temp.check_true('nor in a CLOSED client account',
    v_used <> v_shut);
  perform pg_temp.check_eq(
    'and with no default client account, the OLDEST open one, not '
    'whichever row the plan reaches first',
    v_used, v_yc2);

  perform pg_temp.sign_out();
end $$;

rollback;

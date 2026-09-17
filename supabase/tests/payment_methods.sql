-- =====================================================================
-- iAkauntan :: the fee the bank took, and where it lands
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payment_methods.sql
--
-- `0635`. Three posting paths debited a bank charge to a hardcoded
-- account 6300, and `gl_lines.account_id` is NOT NULL, so a company
-- whose chart has no 6300 did not fall back to anything -- it aborted
-- the posting with a constraint violation naming neither the receipt
-- nor the charge.
--
-- The assertions that matter, in the order they matter:
--
--   * **nothing moves for a company that configures nothing.** This is
--     the whole safety argument for touching three posting functions,
--     so it is asserted on all three by posting with no payment method
--     in existence and reading the account the charge landed on.
--   * **the fallback chain is ordered.** Method, then company default,
--     then 6300 -- and an unset step is skipped, not failed.
--   * **the missing-account case explains itself.** A sentence naming
--     6300, not a not-null violation.
--   * **the rate is offered, never applied.** `bank_charges` after a
--     posting is what the document said, whatever the method charges.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company that can post, with a bank account and an open year.
create or replace function pg_temp.pm_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1110'),
          'Current', 'current', 'MYR');
  return v_org;
end;
$$;

create or replace function pg_temp.pm_bank(p_org uuid)
returns uuid language sql as $$
  select id from public.bank_accounts where org_id = p_org limit 1;
$$;

create or replace function pg_temp.pm_contact(p_org uuid, p_name text, p_type text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, upper(left(p_name, 4)) || '-' || substr(gen_random_uuid()::text, 1, 8),
          p_name, p_type::app.contact_type)
  returning id into v_id;
  return v_id;
end;
$$;

-- The account code a posting's bank-charge line landed on. Null when
-- the journal has no charge line at all, which is a different failure
-- from landing in the wrong place and reads differently here.
create or replace function pg_temp.charge_code(p_entry uuid)
returns text language sql as $$
  select a.code from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = p_entry and l.description like 'Bank charges%'
   limit 1;
$$;

-- ---------------------------------------------------------------------
-- 1. A company that configures nothing posts exactly where it did
--
-- The reason this migration is allowed to touch three posting
-- functions at all. If any of these three moves, the change is not the
-- no-op it claims to be.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Tiada Kaedah Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_cust uuid := pg_temp.pm_contact(v_org, 'Pelanggan', 'customer');
  v_supp uuid := pg_temp.pm_contact(v_org, 'Pembekal', 'supplier');
  v_rcp uuid; v_pay uuid; v_entry uuid;
  v_bank2 uuid; v_tr uuid;
begin
  perform pg_temp.check_eq('the company has no payment methods at all',
    (select count(*)::int from public.payment_methods where org_id = v_org), 0);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, base_amount, bank_charges, status)
  values (v_org, 'RCP-1', date '2026-03-10', v_cust, v_bank,
          'MYR', 1, 1000, 1000, 15, 'draft')
  returning id into v_rcp;
  v_entry := public.post_receipt(v_rcp);

  perform pg_temp.check_eq('a receipt charge still lands on 6300',
    pg_temp.charge_code(v_entry), '6300');
  perform pg_temp.check_eq('and it is the amount the document said',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6300'), 15.00);
  -- The bank is debited NET of the charge, which is the arithmetic the
  -- restatement must not have disturbed.
  perform pg_temp.check_eq('and the bank is debited net of it',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1110'), 985.00);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, base_amount, bank_charges, status)
  values (v_org, 'PAY-1', date '2026-03-11', v_supp, v_bank,
          'MYR', 1, 500, 500, 8, 'draft')
  returning id into v_pay;
  v_entry := public.post_purchase_payment(v_pay);

  perform pg_temp.check_eq('a payment charge still lands on 6300',
    pg_temp.charge_code(v_entry), '6300');
  perform pg_temp.check_eq('and the bank is credited gross of it',
    (select l.credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1110'), 508.00);

  -- The third path. A transfer names no payment method by design.
  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Savings', 'savings', 'MYR')
  returning id into v_bank2;

  v_tr := public.create_bank_transfer(
    v_bank, v_bank2, 200, date '2026-03-12', 195, 5, 'TRF ref', null);
  v_entry := public.post_bank_transfer(v_tr);
  perform pg_temp.check_eq('a transfer fee still lands on 6300',
    pg_temp.charge_code(v_entry), '6300');
  perform pg_temp.check_eq('and it is the fee the transfer named',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6300'), 5.00);
end $$;

-- ---------------------------------------------------------------------
-- 2. The fallback chain, one step at a time
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Rantaian Kaedah Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_6300 uuid := (select id from public.accounts where org_id = v_org and code = '6300');
  v_6311 uuid;
  v_6321 uuid;
  v_dflt uuid;
  v_strp uuid;
  v_other uuid;
  v_other_acct uuid;
  v_other_pm uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6311', 'Merchant fees', 'expense', 'finance_cost')
  returning id into v_6311;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6321', 'Card fees', 'expense', 'finance_cost')
  returning id into v_6321;

  perform pg_temp.check_eq('with nothing configured it is 6300',
    app.bank_charge_account(v_org, null), v_6300);

  -- A method that exists is not thereby the company's default. This
  -- one has an account of its own and is not the default, so a lookup
  -- that forgot to ask `is_default` would find it and be wrong.
  perform public.save_payment_method(
    v_org, 'Bukan Lalai', null, '08', v_bank, v_6311, 0, 0, false, true, 9, null);
  perform pg_temp.check_eq('a method that is not the default is not the default',
    app.bank_charge_account(v_org, null), v_6300);

  -- A method with NO charge account of its own is not an error. It is
  -- a method that uses the company's, which is the ordinary case for
  -- "Cash at the counter".
  v_dflt := public.save_payment_method(
    v_org, 'Tunai', null, '01', v_bank, null, 0, 0, true, true, 0, null);
  perform pg_temp.check_eq('a method with no account of its own falls through',
    app.bank_charge_account(v_org, v_dflt), v_6300);

  -- The company default now has one.
  perform public.save_payment_method(
    v_org, 'Tunai', v_dflt, '01', v_bank, v_6311, 0, 0, true, true, 0, null);
  perform pg_temp.check_eq('the company default beats 6300',
    app.bank_charge_account(v_org, null), v_6311);
  perform pg_temp.check_eq('and a method with none still takes the default',
    app.bank_charge_account(v_org, v_dflt), v_6311);

  v_strp := public.save_payment_method(
    v_org, 'Stripe', null, '03', v_bank, v_6321, 2.9, 1, false, true, 1, null);
  perform pg_temp.check_eq('a named method beats the company default',
    app.bank_charge_account(v_org, v_strp), v_6321);
  perform pg_temp.check_eq('and naming none still gets the default',
    app.bank_charge_account(v_org, null), v_6311);

  -- The method lookup is scoped by org_id as well as by id. An id that
  -- is not this company's method resolves to the company's own default
  -- rather than to whatever that id points at.
  perform pg_temp.check_eq('an id that is not this company''s method falls through',
    app.bank_charge_account(v_org, gen_random_uuid()), v_6311);

  -- And an id that IS a payment method, but somebody else's. A random
  -- uuid above matches nothing whether or not the lookup asks for the
  -- org, so on its own it proves nothing about the scoping; this is
  -- the id that would resolve to another company's ledger account.
  perform pg_temp.allow_many_companies();
  v_other := pg_temp.pm_org('Syarikat Lain Sdn Bhd');
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_other, '6331', 'Yuran orang lain', 'expense', 'finance_cost')
  returning id into v_other_acct;
  v_other_pm := public.save_payment_method(
    v_other, 'Kaedah Mereka', null, '03', pg_temp.pm_bank(v_other),
    v_other_acct, 0, 0, false, true, 0, null);

  perform pg_temp.check_eq('another company''s method is not consulted',
    app.bank_charge_account(v_org, v_other_pm), v_6311);
  perform pg_temp.check_true('and that method really does have its own account',
    app.bank_charge_account(v_other, v_other_pm) = v_other_acct);
end $$;

-- ---------------------------------------------------------------------
-- 3. No account to put it in says so
--
-- The behaviour that DOES change. Before 0635 this was
-- "null value in column account_id ... violates not-null constraint".
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Tiada Enam Tiga Sdn Bhd');
begin
  delete from public.accounts where org_id = v_org and code = '6300';

  perform pg_temp.check_refused(
    'with no 6300 and no method it names the account',
    format('select app.bank_charge_account(%L::uuid, null)', v_org),
    '%6300%', 'P0002');
  perform pg_temp.check_refused(
    'and it says what to do about it',
    format('select app.bank_charge_account(%L::uuid, null)', v_org),
    '%payment method%');
end $$;

-- ---------------------------------------------------------------------
-- 4. A method redirects the charge, and only the charge
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Kaedah Bayaran Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_cust uuid := pg_temp.pm_contact(v_org, 'Pelanggan', 'customer');
  v_supp uuid := pg_temp.pm_contact(v_org, 'Pembekal', 'supplier');
  v_6321 uuid;
  v_strp uuid;
  v_rcp uuid; v_pay uuid; v_entry uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6321', 'Card fees', 'expense', 'finance_cost')
  returning id into v_6321;

  v_strp := public.save_payment_method(
    v_org, 'Stripe', null, '03', v_bank, v_6321, 2.9, 1, false, true, 0, null);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     payment_method_id, currency, exchange_rate, amount, base_amount,
     bank_charges, status)
  values (v_org, 'RCP-2', date '2026-03-10', v_cust, v_bank, v_strp,
          'MYR', 1, 1000, 1000, 30, 'draft')
  returning id into v_rcp;
  v_entry := public.post_receipt(v_rcp);

  perform pg_temp.check_eq('the charge follows the method',
    pg_temp.charge_code(v_entry), '6321');
  perform pg_temp.check_eq('nothing landed on 6300',
    (select count(*)::int from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6300'), 0);

  -- The other side of the same wire. A supplier payment names a
  -- method too, and it has its own call to the resolver -- so without
  -- this the payment side's argument could be replaced by null and
  -- nothing here would notice.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     payment_method_id, currency, exchange_rate, amount, base_amount,
     bank_charges, status)
  values (v_org, 'PAY-2', date '2026-03-11', v_supp, v_bank, v_strp,
          'MYR', 1, 500, 500, 12, 'draft')
  returning id into v_pay;
  v_entry := public.post_purchase_payment(v_pay);

  perform pg_temp.check_eq('a payment''s charge follows the method too',
    pg_temp.charge_code(v_entry), '6321');
  perform pg_temp.check_eq('and it is the amount the payment said',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6321'), 12.00);

  -- The rate is 2.9% + 1, which on 1000 is 30.00 -- the same number the
  -- document happens to carry. So the assertion that posting does not
  -- APPLY the rate needs a document that disagrees with it.
  perform pg_temp.check_eq('suggested_charge is the stated rate',
    public.suggested_charge(v_strp, 1000), 30.00);
end $$;

-- ---------------------------------------------------------------------
-- 5. The rate is offered, never applied
--
-- A receipt whose charge disagrees with the method's rate keeps its
-- own figure. A ledger that recomputed from master data would stop
-- reproducing the moment somebody edited the rate.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Kadar Bukan Catatan Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_cust uuid := pg_temp.pm_contact(v_org, 'Pelanggan', 'customer');
  v_strp uuid;
  v_rcp uuid; v_entry uuid;
begin
  v_strp := public.save_payment_method(
    v_org, 'Stripe', null, '03', v_bank, null, 2.9, 1, false, true, 0, null);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     payment_method_id, currency, exchange_rate, amount, base_amount,
     bank_charges, status)
  values (v_org, 'RCP-3', date '2026-03-10', v_cust, v_bank, v_strp,
          'MYR', 1, 1000, 1000, 5, 'draft')
  returning id into v_rcp;
  v_entry := public.post_receipt(v_rcp);

  perform pg_temp.check_eq('the posting uses the document figure',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6300'), 5.00);
  perform pg_temp.check_eq('not the 30.00 the rate would have come to',
    public.suggested_charge(v_strp, 1000), 30.00);
  perform pg_temp.check_eq('and the document is unchanged by posting',
    (select bank_charges from public.receipts where id = v_rcp), 5.00);

  -- A refund is a negative amount, and a provider does not pay its fee
  -- back. Clamped rather than signed, so the suggestion is never a
  -- credit somebody accepts without reading.
  perform pg_temp.check_eq('a negative amount suggests the fixed part only',
    public.suggested_charge(v_strp, -1000), 1.00);
  perform pg_temp.check_eq('and zero suggests the fixed part',
    public.suggested_charge(v_strp, 0), 1.00);
end $$;

-- ---------------------------------------------------------------------
-- 6. One default, and saving a second moves it
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Satu Lalai Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_a uuid; v_b uuid;
begin
  v_a := public.save_payment_method(
    v_org, 'Tunai', null, '01', v_bank, null, 0, 0, true, true, 0, null);
  v_b := public.save_payment_method(
    v_org, 'Cek', null, '02', v_bank, null, 0, 0, true, true, 1, null);

  perform pg_temp.check_eq('exactly one method is the default',
    (select count(*)::int from public.payment_methods
      where org_id = v_org and is_default and deleted_at is null), 1);
  perform pg_temp.check_eq('and it is the one saved last',
    (select id from public.payment_methods
      where org_id = v_org and is_default and deleted_at is null), v_b);

  -- The index, not just the function that respects it.
  perform pg_temp.check_refused(
    'a second default cannot be written directly either',
    format('update public.payment_methods set is_default = true where id = %L', v_a),
    '%payment_methods_one_default%');
end $$;

-- ---------------------------------------------------------------------
-- 7. Names, archiving, and the documents that already name one
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Nama Kaedah Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_cust uuid := pg_temp.pm_contact(v_org, 'Pelanggan', 'customer');
  v_a uuid; v_rcp uuid; v_6321 uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6321', 'Card fees', 'expense', 'finance_cost')
  returning id into v_6321;
  -- With an account of ITS OWN, so that consulting an archived method
  -- would land somewhere different from the fallback. Given none, the
  -- lookup returns null whether or not it asks about deleted_at, and
  -- the assertion below holds with the archiving ignored.
  v_a := public.save_payment_method(
    v_org, 'Stripe', null, '03', v_bank, v_6321, 2.9, 1, true, true, 0, null);

  perform pg_temp.check_refused(
    'two live methods cannot share a name',
    format('select public.save_payment_method(%L::uuid, %L)', v_org, 'Stripe'),
    '%payment_methods_name_key%');
  perform pg_temp.check_refused(
    'and case is not a difference',
    format('select public.save_payment_method(%L::uuid, %L)', v_org, 'STRIPE'),
    '%payment_methods_name_key%');
  perform pg_temp.check_refused(
    'a method needs a name',
    format('select public.save_payment_method(%L::uuid, %L)', v_org, '   '),
    '%needs a name%', '23514');

  -- A receipt names it, then it is retired.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     payment_method_id, currency, exchange_rate, amount, base_amount, status)
  values (v_org, 'RCP-4', date '2026-03-10', v_cust, v_bank, v_a,
          'MYR', 1, 100, 100, 'draft')
  returning id into v_rcp;

  perform public.archive_payment_method(v_a);

  perform pg_temp.check_eq('the receipt still names it',
    (select payment_method_id from public.receipts where id = v_rcp), v_a);
  -- Not "the flag was cleared" -- `archive_payment_method` leaves it
  -- alone, deliberately, and nothing reads it on an archived row. What
  -- matters is that the company no longer HAS a default, which is the
  -- question every reader actually asks.
  perform pg_temp.check_eq('the company no longer has a default method',
    (select count(*)::int from public.payment_methods
      where org_id = v_org and is_default and deleted_at is null), 0);
  perform pg_temp.check_eq('so the charge falls back to 6300',
    app.bank_charge_account(v_org, null),
    (select id from public.accounts where org_id = v_org and code = '6300'));
  perform pg_temp.check_eq('and it is gone from the list',
    (select count(*)::int from public.payment_methods_for(v_org)), 0);

  -- The name comes free again, which is the point of a partial index.
  perform pg_temp.check_true('the name can be used again',
    public.save_payment_method(
      v_org, 'Stripe', null, '03', v_bank, null, 0, 0, false, true, 0, null)
    is not null);

  -- An archived method is still a method, so a posting that names one
  -- must not silently lose its account: the resolver skips it and the
  -- fallback takes over, rather than returning null. It has 6321 of
  -- its own, so a resolver that consulted it would land there.
  perform pg_temp.check_eq('an archived method falls back rather than failing',
    app.bank_charge_account(v_org, v_a),
    (select id from public.accounts where org_id = v_org and code = '6300'));
  perform pg_temp.check_true('and it did have an account to be tempted by',
    v_6321 is not null);
end $$;

-- ---------------------------------------------------------------------
-- 8. Another company's accounts are not available
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := pg_temp.pm_org('Syarikat A Sdn Bhd');
  v_b uuid;
  v_b_acct uuid;
  v_b_bank uuid;
begin
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.pm_org('Syarikat B Sdn Bhd');
  v_b_acct := (select id from public.accounts where org_id = v_b and code = '6300');
  v_b_bank := pg_temp.pm_bank(v_b);

  perform pg_temp.check_refused(
    'a charge account from another company is refused',
    format('select public.save_payment_method(%L::uuid, %L, null, null, null, %L::uuid)',
           v_a, 'Silang', v_b_acct),
    '%charge_account_same_org%');
  perform pg_temp.check_refused(
    'and so is a bank account',
    format('select public.save_payment_method(%L::uuid, %L, null, null, %L::uuid)',
           v_a, 'Silang Bank', v_b_bank),
    '%bank_account_same_org%');
end $$;

-- ---------------------------------------------------------------------
-- 9. Who may write one
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.pm_org('Kebenaran Kaedah Sdn Bhd');
  v_other uuid := pg_temp.another_user('outsider@iakauntan.test');
  v_id    uuid;
  v_seen  integer;
  v_role  text;
begin
  v_id := public.save_payment_method(v_org, 'Tunai');

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a stranger cannot write a payment method',
    format('select public.save_payment_method(%L::uuid, %L)', v_org, 'Sendiri'),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor archive one',
    format('select public.archive_payment_method(%L::uuid)', v_id),
    '%Insufficient privileges%', '42501');
  -- The read is the RLS policy rather than a guard inside a function,
  -- so it only means anything under the role the policy is written
  -- for. Asserted, because this file otherwise runs as the owner of
  -- the tables and would pass with the policy deleted.
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*)::int into v_seen
      from public.payment_methods where org_id = v_org;
  end;
  reset role;
  perform pg_temp.check_true('the read ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('nor read the company''s methods', v_seen, 0);

  -- The RPC is SECURITY DEFINER, so RLS does not cover it and the
  -- assertion above says nothing about this path. It has its own
  -- is_org_member check, and this is what asserts it.
  perform pg_temp.check_eq('nor reach them through the function',
    (select count(*)::int from public.payment_methods_for(v_org)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 10. A change to one is in the audit trail
--
-- It names two ledger accounts. A quiet edit redirects money, which is
-- the test 0055 applied to bank_accounts and accounts.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pm_org('Jejak Kaedah Sdn Bhd');
  v_bank uuid := pg_temp.pm_bank(v_org);
  v_id   uuid;
begin
  v_id := public.save_payment_method(
    v_org, 'Tunai', null, '01', v_bank, null, 0, 0, false, true, 0, null);
  perform public.save_payment_method(
    v_org, 'Tunai', v_id, '01', v_bank,
    (select id from public.accounts where org_id = v_org and code = '6300'),
    0, 0, false, true, 0, null);

  perform pg_temp.check_true('the change is recorded',
    (select count(*) from public.audit_logs
      where org_id = v_org and table_name = 'payment_methods'
        and action = 'update') >= 1);
  perform pg_temp.check_true('and so is the creation',
    (select count(*) from public.audit_logs
      where org_id = v_org and table_name = 'payment_methods'
        and action = 'insert') >= 1);
end $$;

rollback;

\echo 'payment_methods.sql passed'

-- ---------------------------------------------------------------------
-- 0549  The transfer that has to arrive somewhere
-- ---------------------------------------------------------------------
-- A law firm's receipts and payments are not one stream but two, and
-- keeping them apart is the whole of the Solicitors' Accounts Rules
-- 1990. 0021 built the client side properly -- `matters`,
-- `client_account_transactions`, and a deferred constraint trigger that
-- will not let one client's money fund another's matter. What was never
-- built is the door between the two sides, and the one that exists is
-- open at the far end.
--
-- ### The money that went nowhere
--
-- `client_txn_type` has carried `transfer_to_office` since 0021 --
-- "settling a rendered bill from client funds", which is the single
-- most common movement in a conveyancing practice. The matter screen
-- offers it. And `post_client_transaction` posts every transaction the
-- same way, whatever its type: the client bank on one leg, 2300 Client
-- monies held on the other.
--
-- So a transfer of four thousand from a matter holding ten thousand:
--
--     client bank    10,000 -> 6,000     the money left
--     2300 liability 10,000 -> 6,000     we owe the client less
--     OFFICE BANK         0 ->     0     it never arrived
--     the invoice     unpaid -> unpaid   nothing was settled
--
-- Measured, not reasoned about: the probe is in this migration's test.
-- The entry balances, so nothing complains. The firm's books say the
-- money is gone and say nothing about where it went, while the bank
-- statement for the office account says it arrived. The bill it was
-- raised to pay is still outstanding and will be chased.
--
-- ### What a transfer actually is
--
-- Two movements, not one, and the second is an ordinary receipt:
--
--   * on the client side, money leaves: Dr 2300, Cr client bank. That
--     is what `post_client_transaction` already does.
--   * on the office side, money arrives and settles a bill: Dr office
--     bank, Cr receivable. That is what `post_receipt` already does.
--
-- Both already exist and were never joined. `settle_from_client_account`
-- below is the join, and it is the only lawful way for money to cross
-- from one side to the other.
--
-- ### The rules it enforces, and why each one
--
--   * **The invoice must be the matter's.** Money held for Puan Salmah's
--     conveyance cannot settle Encik Rahim's litigation bill, and it
--     cannot settle Puan Salmah's OTHER matter either -- a client
--     ledger is per matter. This is the same rule 0166 enforces for
--     ordinary customers, at the point where breaking it is easiest.
--   * **Not more than the matter holds.** The deferred trigger from
--     0021 would catch it at COMMIT; this refuses first, so the message
--     names the shortfall rather than the constraint.
--   * **Not more than the invoice owes.** An overpayment out of client
--     money is money taken from a client and held as office credit,
--     which is precisely what rule 8 forbids.
--   * **The office account is not the client account.** A "transfer"
--     that lands back in the client bank has moved nothing and has
--     falsified the ledger twice.
--
-- ### And the door is closed behind it
--
-- A `transfer_to_office` row written by hand -- which is what the
-- matter screen did -- is refused from now on: the type requires an
-- invoice, and only this function sets one. The one-legged transfer
-- cannot be written again.
--
-- ### The other two movements
--
-- `receive_client_money` and `pay_from_client_account` are thin, and
-- they exist so the receipt and payment screens have something to call
-- that carries the module check, the permission check and the posting
-- in one step, rather than three inserts and a hope. Money on account
-- for a matter is not income and must never touch a sales document;
-- that is why the receipt screen cannot simply raise a receipt with no
-- allocation.
--
-- ### Mutants
--
-- Run against `supabase/tests/client_money_crossing.sql`, each named
-- with the assertion that kills it:
--   * the office bank not debited -- "the office account receives it";
--   * the invoice not settled -- "and the bill it was raised for is
--     paid";
--   * the client ledger not reduced -- "the matter holds four thousand
--     less";
--   * another matter's invoice allowed -- "one matter's money cannot
--     settle another's bill";
--   * another client's invoice allowed -- the same assertion;
--   * more than is held allowed -- "a matter cannot pay out more than
--     it holds";
--   * more than the invoice owes allowed -- "and cannot overpay the
--     bill";
--   * the client account accepted as the destination -- "the money has
--     to leave the client account";
--   * a hand-written transfer still possible -- "a transfer with no
--     invoice on it is refused";
--   * the module gate dropped -- "a firm without the legal module
--     cannot reach any of it";
--   * `can_post` dropped -- "a clerk who may not post cannot move
--     client money".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Money in: received to hold, not to keep
-- ---------------------------------------------------------------------
create or replace function public.receive_client_money(
  p_matter uuid,
  p_amount numeric,
  p_date date default null,
  p_description text default null,
  p_reference text default null,
  p_payment_mode text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org   uuid;
  v_bank  uuid;
  v_id    uuid;
begin
  select m.org_id into v_org from public.matters m where m.id = p_matter;
  if v_org is null then
    raise exception 'There is no such matter' using errcode = 'P0002';
  end if;
  if not app.has_module(v_org, 'legal') then
    raise exception 'Client accounting is part of the legal module'
      using errcode = '42501';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Money received on account has to be a positive amount'
      using errcode = '23514';
  end if;

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account and b.is_active
   order by b.is_default desc, b.created_at
   limit 1;
  if v_bank is null then
    raise exception 'No client account is configured. Run the legal setup '
                    'first: client money may not be held anywhere else.'
      using errcode = '23514';
  end if;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, payment_mode_code,
     created_by)
  values (v_org, p_matter,
          public.next_document_number(v_org, 'client_txn'),
          coalesce(p_date, app.today()), 'receipt',
          v_bank, p_amount,
          coalesce(p_description, 'Received on account'),
          p_reference, p_payment_mode, auth.uid())
  returning id into v_id;

  perform public.post_client_transaction(v_id);
  return v_id;
end $$;

comment on function public.receive_client_money is
  'Money received from a client to hold on account for a matter. Client '
  'money, not income: it reaches the client account and 2300, and no '
  'sales document. See 0549.';

revoke all on function public.receive_client_money(
  uuid, numeric, date, text, text, text) from public, anon;
grant execute on function public.receive_client_money(
  uuid, numeric, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Money out: paid on the client's behalf
-- ---------------------------------------------------------------------
create or replace function public.pay_from_client_account(
  p_matter uuid,
  p_amount numeric,
  p_payee text default null,
  p_date date default null,
  p_description text default null,
  p_reference text default null,
  p_payment_mode text default null,
  p_refund boolean default false)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org   uuid;
  v_bank  uuid;
  v_held  numeric(18, 2);
  v_no    text;
  v_id    uuid;
begin
  select m.org_id, m.matter_no into v_org, v_no
    from public.matters m where m.id = p_matter;
  if v_org is null then
    raise exception 'There is no such matter' using errcode = 'P0002';
  end if;
  if not app.has_module(v_org, 'legal') then
    raise exception 'Client accounting is part of the legal module'
      using errcode = '42501';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment out of the client account has to be a '
                    'positive amount' using errcode = '23514';
  end if;

  -- Refused here as well as by the deferred trigger, so the message
  -- names the matter and the shortfall while the person is still
  -- looking at the form rather than at a constraint violation.
  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_matter and t.status <> 'void';
  if p_amount > v_held then
    raise exception
      'Matter % holds % and cannot pay out %. Money held for one matter '
      'cannot fund another.',
      v_no, to_char(v_held, 'FM999999990.00'),
      to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account and b.is_active
   order by b.is_default desc, b.created_at
   limit 1;
  if v_bank is null then
    raise exception 'No client account is configured' using errcode = '23514';
  end if;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, payee, reference,
     payment_mode_code, created_by)
  values (v_org, p_matter,
          public.next_document_number(v_org, 'client_txn'),
          coalesce(p_date, app.today()),
          -- Cast, because a CASE of two string literals is `text` and
          -- the column is `app.client_txn_type`. A bare literal coerces
          -- from `unknown`; a CASE does not.
          (case when p_refund then 'refund' else 'payment' end)
            ::app.client_txn_type,
          v_bank, -p_amount,
          coalesce(p_description,
                   case when p_refund then 'Refund to client'
                        else 'Paid on the client''s behalf' end),
          p_payee, p_reference, p_payment_mode, auth.uid())
  returning id into v_id;

  perform public.post_client_transaction(v_id);
  return v_id;
end $$;

comment on function public.pay_from_client_account is
  'A disbursement paid out of client money for a matter, or the refund '
  'of what is left at the end of one. Refuses to overdraw the matter. '
  'See 0549.';

revoke all on function public.pay_from_client_account(
  uuid, numeric, text, date, text, text, text, boolean) from public, anon;
grant execute on function public.pay_from_client_account(
  uuid, numeric, text, date, text, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- The crossing
-- ---------------------------------------------------------------------
create or replace function public.settle_from_client_account(
  p_matter uuid,
  p_invoice uuid,
  p_amount numeric,
  p_date date default null,
  p_office_bank uuid default null,
  p_reference text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org        uuid;
  v_matter_no  text;
  v_client     uuid;
  v_inv        public.sales_documents;
  v_held       numeric(18, 2);
  v_owing      numeric(18, 2);
  v_bank       uuid;
  v_is_client  boolean;
  v_txn        uuid;
  v_receipt    uuid;
begin
  select m.org_id, m.matter_no, m.client_id
    into v_org, v_matter_no, v_client
    from public.matters m where m.id = p_matter;
  if v_org is null then
    raise exception 'There is no such matter' using errcode = 'P0002';
  end if;
  if not app.has_module(v_org, 'legal') then
    raise exception 'Client accounting is part of the legal module'
      using errcode = '42501';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;

  select * into v_inv from public.sales_documents d
   where d.id = p_invoice and d.org_id = v_org;
  if v_inv.id is null then
    raise exception 'There is no such invoice' using errcode = 'P0002';
  end if;

  -- Whose bill it is. A matter's money settles that matter's bill and
  -- nothing else: not another client's, and not the same client's other
  -- matter, because a client ledger is kept per matter. An invoice
  -- raised without a matter on it is allowed through only when it is
  -- addressed to this matter's client -- that is a bill for this
  -- client's work that nobody attributed, not somebody else's.
  if v_inv.matter_id is not null then
    if v_inv.matter_id <> p_matter then
      raise exception
        'Invoice % belongs to another matter. Money held for matter % '
        'cannot settle it.', v_inv.doc_no, v_matter_no
        using errcode = '23514';
    end if;
  elsif v_inv.contact_id is distinct from v_client then
    raise exception
      'Invoice % is not addressed to the client of matter %. One '
      'client''s money cannot settle another''s bill.',
      v_inv.doc_no, v_matter_no
      using errcode = '23514';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'A transfer to office has to be a positive amount'
      using errcode = '23514';
  end if;

  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_matter and t.status <> 'void';
  if p_amount > v_held then
    raise exception
      'Matter % holds % and cannot transfer %. Money held for one matter '
      'cannot fund another.',
      v_matter_no, to_char(v_held, 'FM999999990.00'),
      to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  v_owing := coalesce(v_inv.total_amount, 0) - coalesce(v_inv.paid_amount, 0);
  if p_amount > v_owing then
    raise exception
      'Invoice % owes % and cannot take %. Client money paid beyond a '
      'bill is still the client''s.',
      v_inv.doc_no, to_char(v_owing, 'FM999999990.00'),
      to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  -- Where it lands. Named, or the default office account -- never the
  -- client account, which would be a transfer that moved nothing while
  -- recording that it had.
  if p_office_bank is not null then
    select b.id, b.is_client_account into v_bank, v_is_client
      from public.bank_accounts b
     where b.id = p_office_bank and b.org_id = v_org;
    if v_bank is null then
      raise exception 'There is no such bank account' using errcode = 'P0002';
    end if;
    if v_is_client then
      raise exception
        'The money has to leave the client account. % is a client '
        'account.', (select name from public.bank_accounts where id = v_bank)
        using errcode = '23514';
    end if;
  else
    select b.id into v_bank from public.bank_accounts b
     where b.org_id = v_org and not b.is_client_account and b.is_active
     order by b.is_default desc, b.created_at
     limit 1;
    if v_bank is null then
      raise exception 'No office account is configured to receive it'
        using errcode = '23514';
    end if;
  end if;

  -- Leg one: the money leaves the client account. `invoice_id` is what
  -- makes this a lawful transfer rather than the one-legged kind, and
  -- the trigger below refuses one without it.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, invoice_id, created_by)
  select v_org, p_matter,
         public.next_document_number(v_org, 'client_txn'),
         coalesce(p_date, app.today()), 'transfer_to_office',
         b.id, -p_amount,
         'Transfer to office, invoice ' || v_inv.doc_no,
         p_reference, p_invoice, auth.uid()
    from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account and b.is_active
   order by b.is_default desc, b.created_at
   limit 1
  returning id into v_txn;

  if v_txn is null then
    raise exception 'No client account is configured' using errcode = '23514';
  end if;
  perform public.post_client_transaction(v_txn);

  -- Leg two: it arrives in the office account and settles the bill.
  -- An ordinary receipt through the ordinary path, so the receivable,
  -- the bank balance, the allocation and the audit trail are the same
  -- ones every other receipt writes.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id, reference, notes, created_by)
  values (v_org, public.next_document_number(v_org, 'receipt'),
          coalesce(p_date, app.today()), v_inv.contact_id,
          p_amount, p_amount,
          coalesce(v_inv.currency, 'MYR'), 1, v_bank, p_reference,
          'From client account, matter ' || v_matter_no, auth.uid())
  returning id into v_receipt;

  perform public.allocate_with_discount(v_receipt, p_invoice, p_amount, null,
                                        coalesce(p_date, app.today()));

  -- And posted, which is the step that debits the office bank and
  -- credits the receivable. `allocate_with_discount` settles the
  -- invoice; it does not post the receipt, and a receipt left in draft
  -- is the same disappearance in a different place -- the client ledger
  -- down, the bill marked paid, and the office account still empty.
  -- The order is the settlement screen's own: allocate, then post.
  perform public.post_receipt(v_receipt);
  return v_receipt;
end $$;

comment on function public.settle_from_client_account is
  'Settles a rendered bill out of the client money held for its matter: '
  'the money leaves the client account AND arrives in the office one, '
  'which is what makes it a transfer rather than a disappearance. '
  'See 0549.';

revoke all on function public.settle_from_client_account(
  uuid, uuid, numeric, date, uuid, text) from public, anon;
grant execute on function public.settle_from_client_account(
  uuid, uuid, numeric, date, uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- And the one-legged transfer cannot be written again
-- ---------------------------------------------------------------------
-- Before this, `transfer_to_office` was a row anybody could insert, and
-- the matter screen did. It reduced the client ledger and settled
-- nothing. The type now requires the invoice it settles, and
-- `settle_from_client_account` is the only thing that sets one.
create or replace function app.assert_transfer_settles_something()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.transaction_type = 'transfer_to_office'
     and new.invoice_id is null then
    raise exception
      'A transfer to office has to name the bill it settles. Money moved '
      'off a matter and onto nothing leaves the office account short and '
      'the invoice outstanding.'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists assert_transfer_settles_something
  on public.client_account_transactions;
create trigger assert_transfer_settles_something
  before insert or update on public.client_account_transactions
  for each row execute function app.assert_transfer_settles_something();

-- ---------------------------------------------------------------------
-- What a matter holds, for the screens that ask before typing
-- ---------------------------------------------------------------------
create or replace function public.matter_client_balance(p_matter uuid)
returns numeric
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select coalesce(sum(t.amount), 0)
    from public.client_account_transactions t
    join public.matters m on m.id = t.matter_id
   where t.matter_id = p_matter
     and t.status <> 'void'
     and app.is_org_member(m.org_id);
$$;

comment on function public.matter_client_balance(uuid) is
  'What is held in the client account for one matter, right now. '
  'See 0549.';

revoke all on function public.matter_client_balance(uuid) from public, anon;
grant execute on function public.matter_client_balance(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- The demo law firm, showing the crossing it was showing wrongly
-- ---------------------------------------------------------------------
-- Restated from the built definition of `app.demo_legal_guaman`, not
-- from 0430's text, with one block changed and nothing else touched.
--
-- 0430 seeded a `transfer_to_office` of 4,500 with no invoice on it,
-- and its own comment called that "the only lawful way the firm's fee
-- crosses from client to office". It was not lawful and it did not
-- cross: the client ledger went down, the office account was never
-- debited, and no bill existed for it to settle. The trigger added
-- above refuses that row now, which is how this was found -- the demo
-- rebuild failed.
--
-- What it seeds instead is the order the rules impose: a fee is billed,
-- and only then is money taken out of client account against it.
CREATE OR REPLACE FUNCTION app.demo_legal_guaman(p_org uuid, p_owner uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $$
declare
  v_today  date := app.today();
  v_client uuid;
  v_office uuid;
  v_office_acct uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid;
  v_txn uuid;
  v_rate numeric(18, 2) := 450.00;
  v_inv1 uuid;
  v_inv2 uuid;
  v_held numeric(18, 2);
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  -- The client account, 1150 and 2300, all from the setup function
  -- rather than by hand: a client account this seed created itself
  -- might not be one `is_client_account` recognises, and then the whole
  -- demo would be office money wearing a label.
  perform public.setup_legal_module(p_org);
  select b.id into v_client from public.bank_accounts b
   where b.org_id = p_org and b.is_client_account;
  if v_client is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Guaman Aziz: skipped, the legal setup made no client account.';
  end if;

  select id into v_office_acct from public.accounts
   where org_id = p_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     account_type, is_client_account, opening_balance, current_balance,
     is_default, is_active)
  values (p_org, v_office_acct, 'Office Current', 'Maybank', '514022331',
          'MYR', 'current', false, 0, 0, true, true)
  returning id into v_office;

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-001', 'Puan Aminah Yusof', 'customer',
          'aminah@guamanaziz.demo') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-002', 'Encik Rajan Menon', 'customer',
          'rajan@guamanaziz.demo') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-003', 'Lim Holdings Sdn Bhd', 'customer',
          'accounts@limholdings.demo') returning id into v_c3;

  v_m1 := public.open_matter(
    p_org, 'M-2026-001', 'Sale of a house at Taman Seri',
    v_c1, 'Chong Wei Seng', 'conveyancing', p_owner, p_owner,
    null, v_rate, null);
  v_m2 := public.open_matter(
    p_org, 'M-2026-002', 'Tenancy dispute — Lot 14 Jalan Ampang',
    v_c2, 'Harta Sewa Sdn Bhd', 'litigation', p_owner, p_owner,
    null, v_rate, null);
  v_m3 := public.open_matter(
    p_org, 'M-2026-003', 'Shareholders'' agreement',
    v_c3, null, 'corporate', p_owner, p_owner,
    6000, v_rate, null);

  -- ------------------------------------------------------------------
  -- The client-money cycle, on the conveyancing matter
  -- ------------------------------------------------------------------
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     created_by)
  values (p_org, v_m1, 'CT-2026-001', v_today - 45, 'receipt',
          v_client, 50000, 'MYR',
          'Deposit and completion money on account', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- Negative, because `post_client_transaction` takes the amount as the
  -- caller signs it: `v_amount := v_txn.amount` and the double entry is
  -- built from `greatest(v_amount, 0)` and `greatest(-v_amount, 0)`.
  -- Money out written as a positive number would debit the client bank
  -- again -- the demo would show RM96,800 held against RM50,000 ever
  -- received, and the books would still balance.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     payee, created_by)
  values (p_org, v_m1, 'CT-2026-002', v_today - 20, 'payment',
          v_client, -42300, 'MYR',
          'Balance purchase price to the vendor''s solicitors',
          'Tetuan Chong & Co', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- The only lawful way the firm's fee crosses from client to office,
  -- and 0549 is where it became lawful. This block used to write the
  -- transfer on its own: the client ledger went down by 4,500, the
  -- office account was never debited, and there was no bill for it to
  -- settle. The demo showed the movement doing the wrong thing, which
  -- is worse than not showing it.
  --
  -- A fee is billed first, because that is the order the rules impose:
  -- money is not taken out of client account until there is a rendered
  -- bill to take it against.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, matter_id,
     status, currency, exchange_rate, subject, created_by)
  values (p_org, 'invoice',
          app.next_document_number_internal(p_org, 'invoice'),
          v_today - 14, v_today, v_c1, v_m1, 'draft', 'MYR', 1,
          'Fees and disbursements on the completed sale', p_owner)
  returning id into v_inv1;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, account_id)
  select p_org, v_inv1, 1, 'item',
         'Professional fees, sale of the property', 1, 4500, a.id
    from public.accounts a
   where a.org_id = p_org and a.account_type = 'revenue'
   order by a.code
   limit 1;

  perform public.post_sales_document(v_inv1);

  -- And then the crossing, both legs: out of the client account, into
  -- the office one, against that bill.
  perform public.settle_from_client_account(
    v_m1, v_inv1, 4500, v_today - 12, v_office);

  -- ------------------------------------------------------------------
  -- Time, on the two matters that are billed by the hour
  -- ------------------------------------------------------------------
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_m2, p_owner, v_today - 30,
     'Client attendance and review of the tenancy agreement', 'ATTEND',
     90, v_rate, round(90 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 26,
     'Letter of demand drafted and sent', 'DRAFT',
     120, v_rate, round(120 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 18,
     'Telephone attendance on the opposing solicitors', 'ATTEND',
     30, v_rate, round(30 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 15,
     'Internal file note after the without-prejudice call', 'ADMIN',
     20, v_rate, round(20 / 60.0 * v_rate, 2), false),
    -- More hours than the agreed fee covers, which is what
    -- `report_matters_over_agreed_fee` exists to say out loud.
    (p_org, v_m3, p_owner, v_today - 40,
     'First draft of the shareholders'' agreement', 'DRAFT',
     360, v_rate, round(360 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 33,
     'Two rounds of amendments after the board meeting', 'DRAFT',
     300, v_rate, round(300 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 22,
     'Completion meeting and execution', 'ATTEND',
     240, v_rate, round(240 / 60.0 * v_rate, 2), true);

  -- The litigation matter is billed; the corporate one is not, so the
  -- over-the-agreed-fee report has an open matter to report on rather
  -- than a closed one nobody can act on.
  v_inv2 := public.bill_matter_time(v_m2, v_today - 40, v_today,
                                    v_today + 14);

  -- Read from the bank account the postings moved, not recomputed from
  -- the transactions with a sign convention of this function's own. A
  -- summary that does its own arithmetic can agree with itself while
  -- disagreeing with the ledger, which is how the sign error above
  -- survived its first run: the sentence said RM3,200 and the client
  -- account held RM96,800.
  select current_balance into v_held
    from public.bank_accounts where id = v_client;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Guaman Aziz: 3 matters for 3 clients, RM%s still held in the '
    'client account after completion money out and the fee transferred '
    'to office, one matter billed by the hour and one over its agreed '
    'fee.', to_char(v_held, 'FM999,999,990.00'));
end $$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if not exists (
    select 1 from pg_trigger
     where tgname = 'assert_transfer_settles_something'
       and tgrelid = 'public.client_account_transactions'::regclass) then
    raise exception '0549: the one-legged transfer is still writable';
  end if;
end $do$;

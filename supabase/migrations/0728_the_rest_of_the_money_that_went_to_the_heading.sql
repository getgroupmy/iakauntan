-- =====================================================================
-- iAkauntan :: 0728 the rest of the money that went to the heading
--
-- `0727` stopped `post_expense` crediting account 1120 when an expense
-- named no bank account. 1120 is "Bank Accounts": `0012` seeds it with
-- `is_group = false`, so it is postable, and `upsert_bank_account`
-- (`0529`) hangs every real account a company adds beneath it in the
-- range 1121-1199. Crediting the heading therefore produces an entry
-- that balances, reports, and reconciles against nothing -- no bank
-- balance moves and no statement line can ever match it.
--
-- That was not one function. Every `code = '1120'` in the schema was
-- read, and the same fallback stood in five more places:
--
--   settle_deposit         0505   a refund out of no account
--   create_deposit         0506   a deposit into no account
--   clear_pdc              0506   a cheque cleared into no account
--   post_purchase_payment  0635   a supplier paid from no account
--   post_receipt_internal  0635   money received into no account
--
-- and once more in `app.demo_legal_guaman` (`0549`), which is a demo
-- seeder rather than a posting path.
--
-- The first four are closed below. The last two are NOT, and the
-- reasons are different for each -- see the two sections after the
-- functions. Nothing here is guessed: each base was taken from
-- `pg_get_functiondef` on production and checked by md5 before a line
-- of it was changed.
--
-- ---------------------------------------------------------------------
-- Why 380 files of assertions never caught it
--
-- Worth writing down, because it is the twelfth entry for
-- `docs/widget-tests.md`'s list and the first one that is about SQL.
--
-- Every fixture in `supabase/tests/` that needs a bank account writes
--
--     insert into public.bank_accounts (org_id, account_id, ...)
--     values (v_org, (select id from public.accounts
--                      where org_id = v_org and code = '1120'), ...)
--
-- -- it hangs the bank account on 1120 ITSELF. So in every test, the
-- fallback and the named account resolve to the same row, and no
-- assertion can tell them apart. `deposits.sql` even asserts "the money
-- leaves the bank" by checking the credit on `code = '1120'`, which was
-- true whether the function found the account it was handed or fell
-- through to the heading.
--
-- The assertions added with this migration give their fixtures a CHILD
-- account, the way `upsert_bank_account` does, so that "credited 1121"
-- and "credited 1120" are different observations.
--
-- ---------------------------------------------------------------------
-- There is always an account to name
--
-- Refusing is only reasonable if every real payment can name one, and
-- it can: `bank_accounts.account_type` has permitted `cash` and
-- `ewallet` since `0003`, so a till or a petty cash box is an ordinary
-- `bank_accounts` row with a ledger account of its own. That is also
-- the shape the user chose for expenses when they asked for "paid from"
-- to be required, and the same rule now reads the same way on all four
-- of these paths: money arrives in, or leaves, an account somebody
-- named.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.settle_deposit(p_deposit uuid, p_kind text, p_amount numeric, p_reason text DEFAULT NULL::text, p_bank uuid DEFAULT NULL::uuid, p_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_note   public.deposit_notes;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_other  uuid;
  v_bank   uuid;
  v_bank_id uuid;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date := coalesce(p_date, app.today());
begin
  select * into v_note from public.deposit_notes where id = p_deposit;
  if v_note.id is null then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_note.org_id,
        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_note.status = 'void' then
    raise exception 'That deposit was voided.' using errcode = '23514';
  end if;
  if p_kind not in ('refund', 'forfeit') then
    raise exception 'A deposit is either given back or kept.'
      using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'That has to be for something.' using errcode = '23514';
  end if;
  if v_amount > v_note.balance_amount then
    raise exception 'Deposit % has % left and this would take %.',
      v_note.deposit_no, v_note.balance_amount, v_amount using errcode = '23514';
  end if;
  if p_kind = 'forfeit' and coalesce(trim(p_reason), '') = '' then
    raise exception
      'Say why. A deposit kept without a reason is the one the customer '
      'rings about.' using errcode = '23514';
  end if;

  -- Resolve the bank account ONCE, and check it belongs to this company
  -- before anything is written with it. It used to be checked only in
  -- the lookup that picks the ledger account, while the event row and
  -- the running balance below used the raw argument -- so naming
  -- another company's bank account moved THEIR balance, recorded THEIR
  -- account against this deposit, and posted this company's side to its
  -- own 1120 fallback, leaving both companies wrong.
  v_bank_id := coalesce(p_bank, v_note.bank_account_id);
  if v_bank_id is not null and not exists (
       select 1 from public.bank_accounts b
        where b.id = v_bank_id and b.org_id = v_note.org_id) then
    raise exception
      'That bank account belongs to another company.' using errcode = '42501';
  end if;

  v_held := app.deposit_account(v_note.org_id, v_note.kind::text);

  if p_kind = 'refund' then
    -- A refund that names no account used to be credited to 1120 Bank
    -- Accounts -- the heading the real accounts hang under -- which
    -- moved no bank balance and showed on no reconciliation. There is
    -- no account to guess: say which one the money left.
    if v_bank_id is null then
      raise exception
        'Say which account the refund is paid out of. Without one there '
        'is no bank balance to move and nothing for a reconciliation to '
        'match.' using errcode = '23514';
    end if;
    select a.id into v_bank from public.bank_accounts b
      join public.accounts a on a.id = b.account_id
     where b.id = v_bank_id and b.org_id = v_note.org_id;
    v_other := v_bank;
  else
    -- A customer walking away from his deposit is our income; us
    -- walking away from one we paid is our loss. Two accounts, because
    -- they are two different things and netting them would hide both.
    v_other := app.deposit_account(v_note.org_id,
                 case when v_note.kind = 'customer' then 'income' else 'expense' end);
  end if;
  if v_other is null then
    raise exception 'This company has no account to settle it to.'
      using errcode = 'P0002';
  end if;

  if v_note.kind = 'customer' then
    -- The liability goes; the money leaves, or becomes income.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_other, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', 0, 'credit', v_amount));
  else
    -- The asset goes; the money comes back, or becomes a loss.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_other, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    v_note.org_id, v_on, 'deposit', v_lines,
    initcap(p_kind) || ' of deposit ' || v_note.deposit_no,
    'deposit_notes', p_deposit);

  insert into public.deposit_events
    (org_id, deposit_id, kind, event_date, amount, reason, bank_account_id,
     gl_entry_id, created_by)
  values (v_note.org_id, p_deposit, p_kind::app.deposit_event_kind, v_on,
          v_amount, nullif(trim(coalesce(p_reason, '')), ''),
          case when p_kind = 'refund' then v_bank_id end,
          v_entry, auth.uid());

  if p_kind = 'refund' then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_note.kind = 'customer' then -v_amount else v_amount end
     where id = v_bank_id;
  end if;

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.create_deposit(p_org uuid, p_kind text, p_contact uuid, p_date date, p_amount numeric, p_bank uuid DEFAULT NULL::uuid, p_mode text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id     uuid;
  v_no     text;
  v_bank   uuid;
  v_held   uuid;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_cur    character(3);
  v_rate   numeric(18, 8);
  v_lines  jsonb;
  v_entry  uuid;
  v_module text := case when p_kind = 'customer' then 'sales' else 'purchases' end;
begin
  if not app.can_write_module(p_org, v_module) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if p_kind not in ('customer', 'supplier') then
    raise exception 'A deposit is either taken from a customer or paid to a '
      'supplier.' using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'A deposit has to be for something.' using errcode = '23514';
  end if;
  if not exists (select 1 from public.contacts c
                  where c.id = p_contact and c.org_id = p_org) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;

  -- Foreign deposits are refused for the reason 0272 refuses foreign
  -- contras: what is held is worth a different number of ringgit on the
  -- day it is applied, and which rate that difference is struck at is
  -- an answer this cannot guess.
  v_cur  := app.base_currency(p_org);
  v_rate := 1;

  -- The account is checked ONCE, here, and refused if it is somebody
  -- else's. It used to be checked only in this lookup, which resolves
  -- the ledger account; the row written below and the running balance
  -- updated at the end both used p_bank raw, so naming another
  -- company's account put this company's deposit into THEIR balance.
  if p_bank is not null and not exists (
       select 1 from public.bank_accounts b
        where b.id = p_bank and b.org_id = p_org) then
    raise exception
      'That bank account belongs to another company.' using errcode = '42501';
  end if;

  -- A deposit that names no account used to be posted to 1120 Bank
  -- Accounts -- the heading the real accounts hang under -- which moved
  -- no bank balance and showed on no reconciliation. A cash till is a
  -- `bank_accounts` row of type `cash` (permitted since `0003`), so
  -- there is always an account to name.
  if p_bank is null then
    raise exception
      'Say which account the deposit moved through. Without one there is '
      'no bank balance to move and nothing for a reconciliation to '
      'match.' using errcode = '23514';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank and b.org_id = p_org;
  if v_bank is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
  end if;

  v_held := app.deposit_account(p_org, p_kind);
  v_no   := app.next_document_number_internal(p_org, 'deposit');

  insert into public.deposit_notes
    (org_id, deposit_no, deposit_date, kind, contact_id, currency,
     exchange_rate, amount, bank_account_id, payment_mode_code, reference,
     balance_amount, notes, created_by)
  values (p_org, v_no, coalesce(p_date, app.today()), p_kind::app.deposit_kind,
          p_contact, v_cur, v_rate, v_amount, p_bank, p_mode, p_reference,
          v_amount, p_notes, auth.uid())
  returning id into v_id;

  if p_kind = 'customer' then
    -- Money in, and a liability for money the company would have to
    -- give back.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));
  else
    -- Money out, and an asset for money the supplier is holding.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    p_org, coalesce(p_date, app.today()), 'deposit', v_lines,
    'Deposit ' || v_no, 'deposit_notes', v_id);

  update public.deposit_notes set gl_entry_id = v_entry where id = v_id;

  update public.bank_accounts
     set current_balance = current_balance
           + case when p_kind = 'customer' then v_amount else -v_amount end
   where id = p_bank;

  return v_id;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.clear_pdc(p_id uuid, p_on date DEFAULT NULL::date, p_bank uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_c     public.post_dated_cheques;
  v_held  uuid;
  v_bank  uuid;
  v_bid   uuid;
  v_lines jsonb;
  v_entry uuid;
  v_on    date;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_c.status not in ('held', 'deposited') then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;

  v_on  := coalesce(p_on, app.today());
  v_bid := coalesce(p_bank, v_c.bank_account_id);
  -- Same check, same reason: `v_bid` was org-checked only in the lookup
  -- that resolves the ledger account, while the balance update at the
  -- end and the cheque row both used it raw.
  if v_bid is not null and not exists (
       select 1 from public.bank_accounts b
        where b.id = v_bid and b.org_id = v_c.org_id) then
    raise exception
      'That bank account belongs to another company.' using errcode = '42501';
  end if;
  -- A cheque that cleared, cleared somewhere. Without an account this
  -- used to debit 1120 Bank Accounts -- the heading the real accounts
  -- hang under -- so the cheque read as cleared while no bank balance
  -- moved and no reconciliation could match it.
  if v_bid is null then
    raise exception
      'Say which account the cheque cleared through. Without one there is '
      'no bank balance to move and nothing for a reconciliation to '
      'match.' using errcode = '23514';
  end if;
  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_bid and b.org_id = v_c.org_id;
  if v_bank is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
  end if;

  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);

  if v_c.direction = 'incoming' then
    -- Now, and only now, it is money.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' cleared',
        'debit', v_c.amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' cleared',
        'debit', 0, 'credit', v_c.amount));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' presented',
        'debit', v_c.amount, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' presented',
        'debit', 0, 'credit', v_c.amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    v_c.org_id, v_on, 'cheque', v_lines,
    'Cheque ' || v_c.pdc_no || ' cleared', 'post_dated_cheques', p_id);

  update public.bank_accounts
     set current_balance = current_balance
           + case when v_c.direction = 'incoming' then v_c.amount
                  else -v_c.amount end
   where id = v_bid;

  update public.post_dated_cheques
     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,
         bank_account_id = v_bid
   where id = p_id;
  return v_entry;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.post_purchase_payment(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_pay       public.purchase_payments;
  v_entries   jsonb := '[]'::jsonb;
  v_bank_acct uuid;
  v_ap_acct   uuid;
  v_entry_id  uuid;
  v_rate      numeric(18, 8);
  v_total     numeric(18, 2);
  v_fx        numeric(18, 2) := 0;
begin
  select * into v_pay from public.purchase_payments where id = p_id;
  if not found then raise exception 'Payment % not found', p_id; end if;
  if not app.can_post(v_pay.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_pay.gl_entry_id is not null then
    raise exception 'Payment % is already posted', v_pay.payment_no;
  end if;

  v_rate := coalesce(v_pay.exchange_rate, 1);

  -- A payment that names no account used to be credited to 1120 Bank
  -- Accounts -- the heading the real accounts hang under -- which moved
  -- no bank balance and showed on no reconciliation. The supplier was
  -- paid from somewhere; the row has to say where.
  --
  -- The lookup is not org-scoped and does not need to be:
  -- `0160`'s `purchase_payments_bank_account_same_org` already makes
  -- the pair agree, so an id on this row is this company's or the
  -- insert never happened.
  if v_pay.bank_account_id is null then
    raise exception
      'Payment % does not say which account it was paid from. Without one '
      'there is no bank balance to move and nothing for a reconciliation '
      'to match.', v_pay.payment_no using errcode = '23514';
  end if;

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_pay.bank_account_id;
  if v_bank_acct is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
  end if;

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_pay.org_id and code = '2110'))
    into v_ap_acct from public.contacts c where c.id = v_pay.contact_id;

  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ap_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);

  if coalesce(v_pay.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.bank_charge_account(v_pay.org_id, v_pay.payment_method_id),
      'description', 'Bank charges',
      'debit', round(v_pay.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', 0, 'credit', v_total, 'contact_id', v_pay.contact_id);

  v_fx := app.realised_fx_on_settlement(p_id, false, v_pay.currency, v_rate);

  if v_fx > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ap_acct, 'description', 'Exchange gain on ' || v_pay.payment_no,
      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_pay.contact_id);
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_pay.org_id, true),
      'description', 'Exchange gain on ' || v_pay.payment_no,
      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_fx < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_pay.org_id, false),
      'description', 'Exchange loss on ' || v_pay.payment_no,
      'debit', -v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ap_acct, 'description', 'Exchange loss on ' || v_pay.payment_no,
      'debit', 0, 'credit', -v_fx, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_pay.contact_id);
  end if;

  v_entry_id := public.create_gl_entry(
    v_pay.org_id, v_pay.payment_date, 'payment'::app.journal_source, v_entries,
    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, v_pay.reference,
    v_pay.currency, v_rate);

  update public.purchase_payments
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_pay.amount * v_rate, 2),
         fx_gain_loss = v_fx,
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance - v_total
   where id = v_pay.bank_account_id;

  return v_entry_id;
end;
$function$

;

-- ---------------------------------------------------------------------
-- The published descriptions
-- ---------------------------------------------------------------------
--
-- `docs/api/openapi.json` and `llms.txt` are generated from these: the
-- summary is the FIRST SENTENCE and the description is the whole
-- comment. So each one below is the text production already carries
-- with one sentence added -- never a rewrite, which is how `2185` went
-- red by replacing four documented refusals with one.

comment on function public.settle_deposit(uuid, text, numeric, text, uuid, date) is
  'Gives a deposit back or keeps it. A customer''s forfeited deposit is '
  'income; one we paid and lost is an expense. A REFUND has to name the '
  'account it is paid out of: one that named none was credited to 1120 '
  'Bank Accounts, the heading the real accounts hang under, so no bank '
  'balance moved and no reconciliation could match it. A forfeit names '
  'none, because no money moved.';

comment on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text) is
  'Records a deposit taken from a customer or paid to a supplier, and '
  'posts it: money moved, and a LIABILITY for a customer deposit rather '
  'than revenue, because it is not earned until the invoice it is held '
  'against exists. THIS IS THE UNPROTECTED OVERLOAD. `0307` added one '
  'taking `p_idempotency_key` as a further argument, and a retried call '
  'that omits the key resolves HERE and takes the money twice. Anything '
  'that can be retried -- a browser, a queue, an integration -- should '
  'call the protected form. The bank account is required: one that named '
  'none was posted to 1120 Bank Accounts, the heading the real accounts '
  'hang under, so no bank balance moved and no reconciliation could '
  'match it.';

comment on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text, text) is
  'Records and posts a deposit taken from a customer or paid to a '
  'supplier, once. THE FORM TO CALL: a retry with the same '
  '`p_idempotency_key` returns the first call''s deposit rather than '
  'taking the money twice, and the same key with different arguments is '
  'refused. A customer deposit posts as a LIABILITY rather than revenue, '
  'because it is not earned until the invoice it is held against exists. '
  'The key has no default, because a call that omits it resolves to the '
  'unprotected original (`0307`). The bank account is required, for the '
  'reason `0728` gives.';

comment on function public.clear_pdc(uuid, date, uuid) is
  'Records that a post-dated cheque actually cleared, which is the '
  'moment it stops being a promise and becomes money: the bank balance '
  'moves and the receivable or payable is discharged. Accepts a cheque '
  'that is `held` or `deposited` and nothing else. The bank account, if '
  'given, is checked against the cheque''s own company -- it was once '
  'org-checked only in the lookup that resolves the ledger account, '
  'while the balance update and the cheque row used it raw. One has to '
  'be known, from the argument or from the cheque: without it the clear '
  'used to debit 1120 Bank Accounts, so the cheque read as cleared while '
  'no bank balance moved.';

comment on function public.post_purchase_payment(uuid) is
  'Posts a payment to a supplier: money out of the bank, the payable '
  'discharged, and any exchange difference struck as its own line. '
  'Refuses a payment already posted, so a retry cannot pay twice. Needs '
  '`can_post`. Returns the journal''s id. Refuses a payment that does '
  'not say which account it was paid from: one that named none was '
  'credited to 1120 Bank Accounts, the heading the real accounts hang '
  'under, so no bank balance moved and no reconciliation could match it.';

-- ---------------------------------------------------------------------
-- NOT changed (1): app.post_receipt_internal
-- ---------------------------------------------------------------------
--
-- This one cannot simply refuse, and the reason is in production.
--
-- Eleven posted receipts have no bank account -- RCP-2026-00001 and its
-- neighbours across five companies -- and every one of them came from
-- the counter. `pos_tender_types.bank_account_id` is what a sale's
-- receipt takes its account from, and all thirteen tender types that
-- exist have it null, CASH and CARD and EWALLET alike. So every
-- counter sale in the product debits the 1120 heading today, which also
-- means refusing here would stop the till rather than correct it.
--
-- `0357` already met one corner of this -- it stopped an on-account
-- tender banking money the shop never took -- and its header names the
-- fallback as the mechanism.
--
-- The fix is not a refusal, it is the missing fact: where each tender's
-- money lands. Cash belongs in a till account; a card and an e-wallet
-- settle into a bank account days later, net of a fee, which is a
-- merchant-settlement arrangement this schema does not model and cannot
-- be guessed from here. That is a question for the user and a piece of
-- work of its own, so this migration leaves the receipt path exactly as
-- it found it rather than half-closing it.
--
-- ---------------------------------------------------------------------
-- NOT changed (2): app.demo_legal_guaman
-- ---------------------------------------------------------------------
--
-- `0549` seeds a demo law firm and reaches for 1120 directly. It is
-- demo data, not a rule, and it is reseeded rather than migrated -- so
-- it belongs with the demo books and not in a migration that changes
-- what the product refuses. Named here so the next reader of
-- `grep -n "'1120'"` knows it was seen and left.
--
-- ---------------------------------------------------------------------
-- And one thing deliberately left inconsistent
-- ---------------------------------------------------------------------
--
-- `post_expense` refuses a null bank account outright (`0727`). The
-- three deposit and cheque functions below refuse it too. But a
-- FORFEITED deposit still names no account, and that is correct: no
-- money moved, so there is nothing to name. `settle_deposit` therefore
-- refuses on `refund` only, and `deposits.sql` asserts both halves.

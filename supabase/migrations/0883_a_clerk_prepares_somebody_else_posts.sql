-- =====================================================================
-- iAkauntan :: 0883 a clerk prepares, somebody else posts
--
-- The README gives the Accounts Clerk "prepares documents but cannot
-- post -- preparation and approval stay in different hands". Seven
-- functions post a journal the moment they are called and asked only
-- `can_write_module`, which a clerk passes: `create_contra`,
-- `create_deposit`, `apply_deposit`, `settle_deposit`, `record_pdc`,
-- `clear_pdc` and `bounce_pdc`. Their neighbour `record_settlement`,
-- which records the receipts and payments, asks `can_post`.
--
-- Measured on 14 October 2026, locally, with the role `authenticated`:
-- an `accounts_clerk`, for whom `can_post` is false, took a customer
-- deposit through `create_deposit`, and the ledger held one posted
-- journal from it. None of the seven has a draft: the call is the
-- posting.
--
-- Production held one clerk on 14 October, and no deposit, contra or
-- post-dated cheque.
--
-- Answered "these ask can_post too": each asks `app.can_post` straight
-- after the guard it had, and refuses in one sentence. The idempotent
-- overloads with a trailing key call these, so they follow. Voiding any
-- of them already asked `can_post`, through `reverse_gl_entry`. Stock
-- transfers and landed costs post too, and are warehouse work; they
-- stay as they are.
--
-- Each body is `pg_get_functiondef` of what was applied, with the one
-- block added.
-- =====================================================================

-- create_contra
CREATE OR REPLACE FUNCTION public.create_contra(p_org uuid, p_date date, p_invoices jsonb, p_bills jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id       uuid;
  v_e        jsonb;
  v_base     character(3) := app.base_currency(p_org);
  v_inv_tot  numeric(18, 2) := 0;
  v_bill_tot numeric(18, 2) := 0;
  v_cust     uuid;
  v_sup      uuid;
  v_doc      record;
  v_amt      numeric(18, 2);
  v_ar       uuid;
  v_ap       uuid;
  v_lines    jsonb := '[]'::jsonb;
  v_entry    uuid;
begin
  if not app.can_write_module(p_org, 'sales')
     or not app.can_write_module(p_org, 'purchases') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if not app.can_post(p_org) then
    raise exception
      'A contra posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
      using errcode = '42501';
  end if;
  if jsonb_array_length(coalesce(p_invoices, '[]'::jsonb)) = 0
     or jsonb_array_length(coalesce(p_bills, '[]'::jsonb)) = 0 then
    raise exception
      'A contra needs something on both sides: an invoice to settle and '
      'a bill to settle it against.' using errcode = '23514';
  end if;

  -- The note has to exist before the allocations can point at it, and
  -- both contact columns are not null, so it is seeded from the first
  -- document named and corrected once the loops below have checked
  -- every one of them. The seed is a real contact, not a placeholder:
  -- a nullable column here would let a note survive with no party.
  select d.contact_id into v_cust from public.sales_documents d
   where d.id = (p_invoices->0->>'document')::uuid and d.org_id = p_org
     and d.deleted_at is null;
  if v_cust is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;

  insert into public.contra_notes
    (org_id, contra_no, contra_date, customer_contact_id,
     supplier_contact_id, amount, notes, created_by)
  values (p_org, app.next_document_number_internal(p_org, 'contra'),
          coalesce(p_date, app.today()), v_cust, v_cust, 1, p_notes,
          auth.uid())
  returning id into v_id;

  -- Cleared again so the loop's "all the same customer" check starts
  -- from nothing and actually checks the first document too.
  v_cust := null;

  -- ------------------------------------------------------------------
  -- The receivable side
  -- ------------------------------------------------------------------
  for v_e in select * from jsonb_array_elements(p_invoices) loop
    select d.* into v_doc from public.sales_documents d
     where d.id = (v_e->>'document')::uuid and d.org_id = p_org
       and d.deleted_at is null;
    if v_doc.id is null then
      raise exception 'No such invoice.' using errcode = 'P0002';
    end if;
    if v_doc.doc_type <> 'invoice' or v_doc.status not in ('posted', 'partial') then
      raise exception
        'Invoice % is %, and only an outstanding posted invoice can be '
        'contra''d.', v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.currency <> v_base then
      raise exception
        'Invoice % is in %, and a contra in anything but % would have to '
        'strike an exchange rate that only the two parties can agree. '
        'Settle it and pay the difference instead.',
        v_doc.doc_no, v_doc.currency, v_base using errcode = '23514';
    end if;

    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A contra line has to be for something.'
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception
        'Invoice % has % outstanding and the contra is for %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_cust is null then
      v_cust := v_doc.contact_id;
    elsif v_cust <> v_doc.contact_id then
      raise exception
        'Those invoices are not all the same customer.' using errcode = '23514';
    end if;

    insert into public.payment_allocations
      (org_id, contra_id, invoice_id, amount, allocated_by)
    values (p_org, v_id, v_doc.id, v_amt, auth.uid());
    v_inv_tot := v_inv_tot + v_amt;
  end loop;

  -- ------------------------------------------------------------------
  -- The payable side
  -- ------------------------------------------------------------------
  for v_e in select * from jsonb_array_elements(p_bills) loop
    select d.* into v_doc from public.purchase_documents d
     where d.id = (v_e->>'document')::uuid and d.org_id = p_org
       and d.deleted_at is null;
    if v_doc.id is null then
      raise exception 'No such bill.' using errcode = 'P0002';
    end if;
    if v_doc.doc_type <> 'bill' or v_doc.status not in ('posted', 'partial') then
      raise exception
        'Bill % is %, and only an outstanding posted bill can be '
        'contra''d.', v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.currency <> v_base then
      raise exception
        'Bill % is in %, and a contra in anything but % would have to '
        'strike an exchange rate that only the two parties can agree. '
        'Settle it and pay the difference instead.',
        v_doc.doc_no, v_doc.currency, v_base using errcode = '23514';
    end if;

    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A contra line has to be for something.'
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception
        'Bill % has % outstanding and the contra is for %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_sup is null then
      v_sup := v_doc.contact_id;
    elsif v_sup <> v_doc.contact_id then
      raise exception
        'Those bills are not all the same supplier.' using errcode = '23514';
    end if;

    insert into public.payment_allocations
      (org_id, contra_id, bill_id, amount, allocated_by)
    values (p_org, v_id, v_doc.id, v_amt, auth.uid());
    v_bill_tot := v_bill_tot + v_amt;
  end loop;

  -- ------------------------------------------------------------------
  -- The two things that make it a contra rather than a journal
  -- ------------------------------------------------------------------
  if not app.same_party(v_cust, v_sup) then
    raise exception
      'Those are two different parties. A contra needs the same contact '
      'on both sides, or two contacts carrying the same TIN.'
      using errcode = '23514';
  end if;
  if v_inv_tot <> v_bill_tot then
    raise exception
      'The two sides come to % and %. A contra cancels what is owed both '
      'ways; the difference is what somebody still has to pay.',
      v_inv_tot, v_bill_tot using errcode = '23514';
  end if;

  select coalesce(c.receivable_account_id,
                  (select a.id from public.accounts a
                    where a.org_id = p_org and a.code = '1210'))
    into v_ar from public.contacts c where c.id = v_cust;
  select coalesce(c.payable_account_id,
                  (select a.id from public.accounts a
                    where a.org_id = p_org and a.code = '2110'))
    into v_ap from public.contacts c where c.id = v_sup;
  if v_ar is null or v_ap is null then
    raise exception 'This company has no control accounts.'
      using errcode = 'P0002';
  end if;

  -- What he owed us goes off the receivable; what we owed him goes off
  -- the payable. No cash moves, and none is pretended to.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_ap, 'contact_id', v_sup,
      'description', 'Contra settlement', 'debit', v_inv_tot, 'credit', 0),
    jsonb_build_object('account_id', v_ar, 'contact_id', v_cust,
      'description', 'Contra settlement', 'debit', 0, 'credit', v_inv_tot));

  update public.contra_notes
     set customer_contact_id = v_cust,
         supplier_contact_id = v_sup,
         amount = v_inv_tot
   where id = v_id;

  v_entry := app.create_gl_entry_internal(
    p_org, coalesce(p_date, app.today()), 'contra', v_lines,
    'Contra ' || (select n.contra_no from public.contra_notes n where n.id = v_id),
    'contra_notes', v_id);

  update public.contra_notes set gl_entry_id = v_entry where id = v_id;
  return v_id;
end;
$function$;

-- create_deposit
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
  if not app.can_post(p_org) then
    raise exception
      'A deposit posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
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
$function$;

-- apply_deposit
CREATE OR REPLACE FUNCTION public.apply_deposit(p_deposit uuid, p_document uuid, p_amount numeric, p_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_note   public.deposit_notes;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_ctrl   uuid;
  v_no     text;
  v_bal    numeric(18, 2);
  v_cur    character(3);
  v_status text;
  v_contact uuid;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date;
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
  if not app.can_post(v_note.org_id) then
    raise exception
      'Applying a deposit posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
      using errcode = '42501';
  end if;
  if v_note.status = 'void' then
    raise exception 'That deposit was voided.' using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'An application has to be for something.'
      using errcode = '23514';
  end if;
  if v_amount > v_note.balance_amount then
    raise exception
      'Deposit % has % left and this would take %.',
      v_note.deposit_no, v_note.balance_amount, v_amount using errcode = '23514';
  end if;

  if v_note.kind = 'customer' then
    select d.doc_no, d.balance_amount, d.currency, d.status::text, d.contact_id
      into v_no, v_bal, v_cur, v_status, v_contact
      from public.sales_documents d
     where d.id = p_document and d.org_id = v_note.org_id
       and d.doc_type = 'invoice' and d.deleted_at is null;
  else
    select d.doc_no, d.balance_amount, d.currency, d.status::text, d.contact_id
      into v_no, v_bal, v_cur, v_status, v_contact
      from public.purchase_documents d
     where d.id = p_document and d.org_id = v_note.org_id
       and d.doc_type = 'bill' and d.deleted_at is null;
  end if;

  if v_no is null then
    raise exception
      'No such %.', case when v_note.kind = 'customer' then 'invoice' else 'bill' end
      using errcode = 'P0002';
  end if;
  if v_status not in ('posted', 'partial') then
    raise exception '% is %, and a deposit settles an outstanding document.',
      v_no, v_status using errcode = '23514';
  end if;
  if v_cur <> v_note.currency then
    raise exception
      '% is in % and the deposit is in %. Settle it with a receipt so the '
      'exchange difference is struck where the rest of them are.',
      v_no, v_cur, v_note.currency using errcode = '23514';
  end if;
  if v_contact <> v_note.contact_id then
    raise exception 'That deposit is not %''s.', v_no using errcode = '23514';
  end if;
  if v_amount > v_bal then
    raise exception '% has % outstanding and this would apply %.',
      v_no, v_bal, v_amount using errcode = '23514';
  end if;

  v_on   := coalesce(p_date, app.today());
  v_held := app.deposit_account(v_note.org_id, v_note.kind::text);

  if v_note.kind = 'customer' then
    select coalesce(c.receivable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = v_note.org_id and a.code = '1210'))
      into v_ctrl from public.contacts c where c.id = v_note.contact_id;
    -- The liability is discharged by the invoice it was held against.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_ctrl, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', 0, 'credit', v_amount));
    insert into public.payment_allocations
      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);
  else
    select coalesce(c.payable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = v_note.org_id and a.code = '2110'))
      into v_ctrl from public.contacts c where c.id = v_note.contact_id;
    -- The asset is used up by the bill it was paid against.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_ctrl, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', 0, 'credit', v_amount));
    insert into public.payment_allocations
      (org_id, deposit_id, bill_id, amount, allocated_by, applied_on)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);
  end if;

  v_entry := app.create_gl_entry_internal(
    v_note.org_id, v_on, 'deposit', v_lines,
    'Deposit ' || v_note.deposit_no || ' applied to ' || v_no,
    'deposit_notes', p_deposit);

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$function$;

-- settle_deposit
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
  if not app.can_post(v_note.org_id) then
    raise exception
      'Settling a deposit posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
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
$function$;

-- record_pdc
CREATE OR REPLACE FUNCTION public.record_pdc(p_org uuid, p_direction text, p_contact uuid, p_cheque_no text, p_cheque_date date, p_amount numeric, p_documents jsonb DEFAULT '[]'::jsonb, p_bank uuid DEFAULT NULL::uuid, p_bank_name text DEFAULT NULL::text, p_received date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id     uuid;
  v_no     text;
  v_in     boolean := p_direction = 'incoming';
  v_module text := case when p_direction = 'incoming' then 'sales' else 'purchases' end;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_ctrl   uuid;
  v_e      jsonb;
  v_doc    record;
  v_amt    numeric(18, 2);
  v_alloc  numeric(18, 2) := 0;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date := coalesce(p_received, app.today());
begin
  if p_direction not in ('incoming', 'outgoing') then
    raise exception 'A cheque is either taken in or written out.'
      using errcode = '23514';
  end if;
  if not app.can_write_module(p_org, v_module) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if not app.can_post(p_org) then
    raise exception
      'A post-dated cheque posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
      using errcode = '42501';
  end if;
  if v_amount <= 0 then
    raise exception 'A cheque has to be for something.' using errcode = '23514';
  end if;
  if coalesce(trim(p_cheque_no), '') = '' then
    raise exception 'A cheque has a number on it.' using errcode = '23514';
  end if;
  if p_cheque_date is null then
    raise exception 'A cheque has a date on it.' using errcode = '23514';
  end if;
  -- A cheque dated today or earlier is not post-dated; it is a receipt,
  -- and recording it here would park money in 1140 that could have been
  -- banked this morning.
  if p_cheque_date <= v_on then
    raise exception
      'That cheque is dated % and was received on %. A cheque that can be '
      'banked today is a receipt, not a post-dated cheque.',
      p_cheque_date, v_on using errcode = '23514';
  end if;
  if not exists (select 1 from public.contacts c
                  where c.id = p_contact and c.org_id = p_org) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;

  v_no := app.next_document_number_internal(p_org, 'cheque');

  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date, bank_name,
     amount, received_on, bank_account_id, notes, created_by)
  values (p_org, v_no, p_direction::app.pdc_direction, p_contact,
          trim(p_cheque_no), p_cheque_date, p_bank_name, v_amount, v_on,
          p_bank, p_notes, auth.uid())
  returning id into v_id;

  -- What it settles.
  for v_e in select * from jsonb_array_elements(coalesce(p_documents, '[]'::jsonb))
  loop
    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A settlement has to be for something.'
        using errcode = '23514';
    end if;

    if v_in then
      select d.doc_no, d.balance_amount, d.status::text, d.contact_id, d.currency
        into v_doc
        from public.sales_documents d
       where d.id = (v_e->>'document')::uuid and d.org_id = p_org
         and d.doc_type = 'invoice' and d.deleted_at is null;
    else
      select d.doc_no, d.balance_amount, d.status::text, d.contact_id, d.currency
        into v_doc
        from public.purchase_documents d
       where d.id = (v_e->>'document')::uuid and d.org_id = p_org
         and d.doc_type = 'bill' and d.deleted_at is null;
    end if;

    if v_doc.doc_no is null then
      raise exception 'No such %.',
        case when v_in then 'invoice' else 'bill' end using errcode = 'P0002';
    end if;
    if v_doc.status not in ('posted', 'partial') then
      raise exception '% is %, and a cheque settles an outstanding document.',
        v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.contact_id <> p_contact then
      raise exception 'That cheque is not %''s.', v_doc.doc_no
        using errcode = '23514';
    end if;
    if v_doc.currency <> app.base_currency(p_org) then
      raise exception
        '% is in %, and a cheque held for weeks in another currency has an '
        'exchange difference that only clearing settles. Bank it as a '
        'receipt when it matures.', v_doc.doc_no, v_doc.currency
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception '% has % outstanding and the cheque would settle %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_in then
      insert into public.payment_allocations
        (org_id, pdc_id, invoice_id, amount, allocated_by)
      values (p_org, v_id, (v_e->>'document')::uuid, v_amt, auth.uid());
    else
      insert into public.payment_allocations
        (org_id, pdc_id, bill_id, amount, allocated_by)
      values (p_org, v_id, (v_e->>'document')::uuid, v_amt, auth.uid());
    end if;
    v_alloc := v_alloc + v_amt;
  end loop;

  if v_alloc <> 0 and v_alloc <> v_amount then
    raise exception
      'The cheque is for % and it has been put against %. A cheque that '
      'settles less than its face value is two facts pretending to be one.',
      v_amount, v_alloc using errcode = '23514';
  end if;

  -- Nothing to post when the cheque is not against anything yet: it is
  -- in the register, and the register is the point.
  if v_alloc = 0 then
    return v_id;
  end if;

  v_held := app.cheque_account(p_org, p_direction);
  if v_in then
    select coalesce(c.receivable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = p_org and a.code = '1210'))
      into v_ctrl from public.contacts c where c.id = p_contact;
    -- He has discharged the debt with a negotiable instrument. The
    -- receivable goes; the bank does not move.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', 0, 'credit', v_amount));
  else
    select coalesce(c.payable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = p_org and a.code = '2110'))
      into v_ctrl from public.contacts c where c.id = p_contact;
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    p_org, v_on, 'cheque', v_lines,
    'Post-dated cheque ' || v_no, 'post_dated_cheques', v_id);
  update public.post_dated_cheques set gl_entry_id = v_entry where id = v_id;

  return v_id;
end;
$function$;

-- clear_pdc
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
  if not app.can_post(v_c.org_id) then
    raise exception
      'Clearing a post-dated cheque posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
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
$function$;

-- bounce_pdc
CREATE OR REPLACE FUNCTION public.bounce_pdc(p_id uuid, p_reason text, p_on date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_c     public.post_dated_cheques;
  v_held  uuid;
  v_ctrl  uuid;
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
  if not app.can_post(v_c.org_id) then
    raise exception
      'A bounced cheque posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
      using errcode = '42501';
  end if;
  if v_c.status not in ('held', 'deposited') then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception
      'Say why. "Bounced" is not something anybody can act on, and the '
      'reason decides whether it is re-presented or chased.'
      using errcode = '23514';
  end if;

  v_on   := coalesce(p_on, app.today());
  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);

  if v_c.gl_entry_id is not null then
    if v_c.direction = 'incoming' then
      select coalesce(c.receivable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '1210'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      -- He owes it again.
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', 0, 'credit', v_c.amount));
    else
      select coalesce(c.payable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '2110'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', 0, 'credit', v_c.amount));
    end if;

    v_entry := app.create_gl_entry_internal(
      v_c.org_id, v_on, 'cheque', v_lines,
      'Cheque ' || v_c.pdc_no || ' returned', 'post_dated_cheques', p_id);
  end if;

  delete from public.payment_allocations where pdc_id = p_id;

  update public.post_dated_cheques
     set status = 'bounced', bounced_on = v_on,
         bounce_reason = trim(p_reason), bounce_entry_id = v_entry
   where id = p_id;
  return v_entry;
end;
$function$;

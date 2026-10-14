-- =====================================================================
-- iAkauntan :: 0887 a deposit is used no earlier than it was taken
--
-- `create_deposit` takes any date, and the deposit form offers three
-- years either side of today. `apply_deposit` and `settle_deposit` took
-- any date too, and "Apply" and "Refund" send none, so both post today
-- -- including against a deposit dated next week.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a customer deposit dated 24 October was applied to
-- an invoice and partly refunded on 14 October -- the deposit liability
-- debited ten days before it was credited.
--
-- Production held no deposit on 14 October.
--
-- Answered "not before it was taken": both refuse a day before the
-- deposit's own date, naming it. A deposit may still be dated ahead,
-- and is then used on or after that day. The idempotent overloads call
-- these, so they follow.
--
-- Each body is `pg_get_functiondef` of what was applied, with the block
-- marked 0887 added after the void check.
-- =====================================================================

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
  -- 0887: a deposit is used no earlier than it was taken. Before then
  -- there is nothing held to apply, and the ledger would carry the
  -- liability the wrong way round until it arrived.
  if coalesce(p_date, app.today()) < v_note.deposit_date then
    raise exception
      'Deposit % was taken on %, and cannot be applied before then.',
      v_note.deposit_no, to_char(v_note.deposit_date, 'DD Mon YYYY')
      using errcode = '23514';
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
  -- 0887: a deposit is used no earlier than it was taken. Before then
  -- there is nothing held to settle, and the ledger would carry the
  -- liability the wrong way round until it arrived.
  if v_on < v_note.deposit_date then
    raise exception
      'Deposit % was taken on %, and cannot be given back or kept before then.',
      v_note.deposit_no, to_char(v_note.deposit_date, 'DD Mon YYYY')
      using errcode = '23514';
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

-- =====================================================================
-- 0505 :: a refund cannot reach into another company's bank account
--
-- `settle_deposit` takes an optional bank account to pay a refund out
-- of. It checked that account against the deposit's own organization in
-- exactly one place -- the lookup that resolves which ledger account to
-- credit -- and nowhere else. The `deposit_events` row it writes and
-- the `bank_accounts.current_balance` it decrements both used the raw
-- argument.
--
-- So a member of one company could refund its own deposit while naming
-- another company's bank account, and three things happened: the other
-- company's running balance went down by the refund, the event recorded
-- their account against this deposit, and this company's ledger posted
-- the credit to its own 1120 fallback -- leaving the payer's ledger and
-- balance disagreeing as well. The function is SECURITY DEFINER, so row
-- level security was not in the way of any of it.
--
-- Restated below from the built database with the account resolved once,
-- checked once, and used everywhere. Naming an account that belongs to
-- somebody else is now refused rather than silently redirected.
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
    select a.id into v_bank from public.bank_accounts b
      join public.accounts a on a.id = b.account_id
     where b.id = v_bank_id and b.org_id = v_note.org_id;
    if v_bank is null then
      select id into v_bank from public.accounts
       where org_id = v_note.org_id and code = '1120' and not is_group;
    end if;
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

  if p_kind = 'refund' and v_bank_id is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_note.kind = 'customer' then -v_amount else v_amount end
     where id = v_bank_id;
  end if;

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$function$;

-- =====================================================================
-- 0506 :: the same hole, in the two other functions that had it
--
-- 0505 closed a cross-tenant hole in `settle_deposit`: a bank account
-- passed in by the caller was checked against the caller's company in
-- exactly one place -- the lookup that resolves which ledger account to
-- use -- while the rows written and the running balance updated used
-- the raw argument.
--
-- That was not a one-off. Every SECURITY DEFINER function that writes
-- `bank_accounts.current_balance` was read, and two more had the same
-- shape:
--
--   create_deposit  -- naming another company's account stored THEIR
--                      account on this company's deposit note and put
--                      the money into THEIR balance. Verified: a
--                      deposit of 900 took a second company's balance
--                      from 7,000 to 7,900.
--   clear_pdc       -- clearing a cheque into another company's account
--                      did the same. Verified: 7,900 to 8,400.
--
-- `remit_withholding` already had the guard and an org-scoped update,
-- and `resync_bank_balance` derives the organization from the account
-- it was given, so neither needed changing.
--
-- Both are restated below from the built database with the account
-- checked once, up front, and naming somebody else's refused.
-- =====================================================================

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

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank and b.org_id = p_org;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = p_org and code = '1120' and not is_group;
  end if;
  if v_bank is null then
    raise exception 'This company has no bank account to put it in.'
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

  if p_bank is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when p_kind = 'customer' then v_amount else -v_amount end
     where id = p_bank;
  end if;

  return v_id;
end;
$function$;

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
  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_bid and b.org_id = v_c.org_id;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = v_c.org_id and code = '1120' and not is_group;
  end if;
  if v_bank is null then
    raise exception 'This company has no bank account.' using errcode = 'P0002';
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

  if v_bid is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_c.direction = 'incoming' then v_c.amount
                    else -v_c.amount end
     where id = v_bid;
  end if;

  update public.post_dated_cheques
     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,
         bank_account_id = coalesce(v_bid, bank_account_id)
   where id = p_id;
  return v_entry;
end;
$function$;

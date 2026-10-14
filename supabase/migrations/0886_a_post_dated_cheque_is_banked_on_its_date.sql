-- =====================================================================
-- iAkauntan :: 0886 a post-dated cheque is banked on its date
--
-- The point of holding a post-dated cheque is that the money is not in
-- the bank until it clears ("the money arriving only when it clears",
-- `post_dated_cheques.sql`). `deposit_pdc` and `clear_pdc` took any
-- date, and the cheque list's "Pay it in" and "It cleared" send none,
-- so both default to today -- including for a cheque dated next month.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a cheque dated 13 November was paid in and cleared
-- on 14 October, and the bank journal was dated 14 October -- the money
-- in the bank a month before any bank would pay it.
--
-- Production held no post-dated cheque on 14 October.
--
-- Answered "neither before its date":
--
--   * `deposit_pdc` refuses a day before the cheque's date;
--   * `clear_pdc` refuses a day before the cheque's date, and before
--     the day it was paid in.
--
-- "Nor before it was received" needs no line of its own: `record_pdc`
-- refuses a cheque dated on or before the day it is received, so a day
-- on or after the cheque's date is after it. Bouncing and handing a
-- cheque back stay open on any day -- a cheque presented early comes
-- back for exactly that reason.
--
-- Each body is `pg_get_functiondef` of what was applied, with the block
-- marked 0886 added.
-- =====================================================================

-- deposit_pdc
CREATE OR REPLACE FUNCTION public.deposit_pdc(p_id uuid, p_on date DEFAULT NULL::date)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_c public.post_dated_cheques;
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
  if v_c.status <> 'held' then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;
  -- 0886: a post-dated cheque is post-dated. No bank takes it before
  -- the day written on it, so it cannot have been paid in before then.
  if coalesce(p_on, app.today()) < v_c.cheque_date then
    raise exception
      'Cheque % is dated %, and no bank takes it before then. Pay it in '
      'on or after that day.', v_c.cheque_no,
      to_char(v_c.cheque_date, 'DD Mon YYYY') using errcode = '23514';
  end if;

  -- Deliberately posts nothing. A cheque paid in on Monday is still a
  -- cheque until it clears, and an entry on Monday would put the money
  -- in the bank three days early.
  update public.post_dated_cheques
     set status = 'deposited', deposited_on = coalesce(p_on, app.today())
   where id = p_id;
  return true;
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
  -- 0886: the money arrives when the cheque clears, and it cannot
  -- clear before the day written on it, nor before it was paid in.
  -- That it was received before its date is record_pdc's rule.
  if v_on < v_c.cheque_date then
    raise exception
      'Cheque % is dated %, and no bank pays it before then. Clear it on '
      'or after that day.', v_c.cheque_no,
      to_char(v_c.cheque_date, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if v_on < v_c.deposited_on then
    raise exception
      'Cheque % was paid in on %, and cannot have cleared before it was.',
      v_c.cheque_no, to_char(v_c.deposited_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
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

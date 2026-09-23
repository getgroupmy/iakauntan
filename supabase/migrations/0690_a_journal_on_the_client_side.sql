-- =====================================================================
-- iAkauntan :: 0690 a journal on the client side
--
-- The entry a solicitor's office makes that has no bank movement at
-- all: money already held for one matter becomes money held for
-- another. A deposit paid into the wrong file. A related matter opened
-- for the same client and the balance carried across. A correction.
--
-- `0021` saw it coming. `app.client_txn_type` has carried
-- `transfer_in` -- commented "moved from another matter" -- and
-- `transfer_out` since the day the module was written, and in the five
-- years since, NOTHING HAS EVER WRITTEN EITHER. There was no way to
-- make the entry the enum was built for.
--
-- ---------------------------------------------------------------------
-- Why it is two client rows and not a journal
--
-- The tempting shape is a general journal against `gl_lines` -- `0687`
-- put the matter there and `0688` made every posting path carry it, so
-- it would work.
--
-- It would also route client money around the one control that matters.
-- `app.assert_client_funds` is a deferred constraint trigger on
-- `client_account_transactions`, and it is the rule the Solicitors'
-- Accounts Rules turn on: A MATTER MAY NOT SPEND MONEY IT DOES NOT
-- HOLD, because the alternative is one client's money funding another's.
-- A journal written straight to the ledger is not a
-- `client_account_transactions` row, so that trigger never fires, and
-- the first thing this feature would be used for -- moving money
-- between two clients -- is exactly the thing the trigger exists to
-- refuse.
--
-- So the transfer is written as the two rows it actually is, and the
-- statutory guard applies because it was never avoided. Deferred means
-- both rows land before it looks, so a transfer that leaves the paying
-- matter at zero is fine and one that would overdraw it is refused
-- whole.
--
-- ---------------------------------------------------------------------
-- What posts, and what does not
--
-- Not what `post_client_transaction` would do to each leg separately.
-- That function debits the client bank and credits client monies held
-- for money in, and the reverse for money out -- correct for a receipt
-- or a payment, and wrong here twice over.
--
-- NO MONEY MOVES. It is in the same client bank account before and
-- after; only the ledger attribution changes. Posting a bank leg in
-- each direction would put two cancelling movements through 1150 and
-- leave the reconciliation with two entries the statement has never
-- heard of.
--
-- What DOES change is which matter the firm holds it for. So one entry,
-- two lines, both against 2300 client monies held:
--
--   debit  2300, matter FROM   -- we owe that client less
--   credit 2300, matter TO     -- and that one more
--
-- The account nets to zero, which is right: the firm owes its clients
-- the same total it did a minute ago. Each MATTER's ledger shows the
-- movement, because `0687` put the matter on the line -- so
-- `report_matter_ledger` shows the transfer on both files and
-- `report_matter_trial_balance` moves for both.
--
-- This is the one entry with two different matters on it that `0688`'s
-- assertion was written for.
--
-- ---------------------------------------------------------------------
-- Three refusals, and why each is here rather than assumed
--
-- A DESCRIPTION IS REQUIRED. Every other movement in this module takes
-- one or falls back to a sensible default. This one does not, because a
-- transfer between two clients' money with no explanation is the first
-- thing an auditor asks about and the hardest thing to reconstruct a
-- year later. "Correction" is a poor answer; no answer is worse.
--
-- THE SAME MATTER TWICE IS REFUSED rather than quietly doing nothing.
-- It would post two cancelling rows and read as a completed transfer.
--
-- AND THE TWO MATTERS MUST BE THE SAME FIRM'S. `matters` is per
-- organization and so is everything else here, but the function takes
-- two ids from a caller and nothing else would compare them.
-- =====================================================================

create or replace function public.transfer_between_matters(
  p_from        uuid,
  p_to          uuid,
  p_amount      numeric,
  p_description text,
  p_date        date default null,
  p_reference   text default null)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_org      uuid;
  v_to_org   uuid;
  v_from_no  text;
  v_to_no    text;
  v_held     numeric(18, 2);
  v_bank     uuid;
  v_liab     uuid;
  v_out      uuid;
  v_in       uuid;
  v_entry    uuid;
  v_desc     text := btrim(coalesce(p_description, ''));
  v_on       date := coalesce(p_date, app.today());
begin
  select m.org_id, m.matter_no into v_org, v_from_no
    from public.matters m where m.id = p_from;
  if v_org is null then
    raise exception 'There is no such matter to transfer from'
      using errcode = 'P0002';
  end if;

  select m.org_id, m.matter_no into v_to_org, v_to_no
    from public.matters m where m.id = p_to;
  if v_to_org is null then
    raise exception 'There is no such matter to transfer to'
      using errcode = 'P0002';
  end if;

  -- Two ids from a caller, and nothing else here would compare them.
  if v_to_org <> v_org then
    raise exception 'Those two matters belong to different firms'
      using errcode = '42501';
  end if;

  if not app.has_module(v_org, 'legal') then
    raise exception 'Client accounting is part of the legal module'
      using errcode = '42501';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;

  if p_from = p_to then
    raise exception
      'A transfer needs two different matters. Matter % is both sides '
      'of this one, which would post two cancelling entries and read as '
      'though something had moved.', v_from_no
      using errcode = '23514';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'A transfer between matters has to be a positive amount'
      using errcode = '23514';
  end if;

  if v_desc = '' then
    raise exception
      'Say why this money is moving. A transfer between two clients'' '
      'money is the first thing an audit asks about and the hardest to '
      'reconstruct a year later.'
      using errcode = '23514';
  end if;

  -- Refused here as well as by the deferred trigger, so the message
  -- names the matter and the shortfall while somebody is still looking
  -- at the form. `pay_from_client_account` does the same and for the
  -- same reason.
  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_from and t.status <> 'void';
  if p_amount > v_held then
    raise exception
      'Matter % holds % and cannot transfer %. Money held for one '
      'matter cannot fund another.',
      v_from_no, to_char(v_held, 'FM999999990.00'),
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

  -- Both rows name the same bank account, because the money does not
  -- move between banks -- it does not move at all.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values (v_org, p_from,
          public.next_document_number(v_org, 'client_txn'),
          v_on, 'transfer_out', v_bank, -p_amount,
          v_desc, p_reference, auth.uid())
  returning id into v_out;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values (v_org, p_to,
          public.next_document_number(v_org, 'client_txn'),
          v_on, 'transfer_in', v_bank, p_amount,
          v_desc, p_reference, auth.uid())
  returning id into v_in;

  -- The ledger. NOT `post_client_transaction` on each leg: that debits
  -- the client bank one way and credits it the other, which puts two
  -- cancelling movements through 1150 and hands the reconciliation two
  -- entries the bank statement has never heard of.
  select id into v_liab from public.accounts
   where org_id = v_org and code = '2300';
  if v_liab is null then
    raise exception
      'No client monies held account configured. Run setup_legal_module '
      'first.' using errcode = '23514';
  end if;

  v_entry := app.create_gl_entry_internal(
    v_org, v_on, 'manual',
    jsonb_build_array(
      -- We owe the paying client less.
      jsonb_build_object(
        'account_id', v_liab, 'debit', p_amount, 'credit', 0,
        'matter_id', p_from,
        'description', v_desc),
      -- And the receiving one more.
      jsonb_build_object(
        'account_id', v_liab, 'debit', 0, 'credit', p_amount,
        'matter_id', p_to,
        'description', v_desc)),
    format('Client money moved from %s to %s', v_from_no, v_to_no),
    'client_account_transactions', v_out, p_reference);

  update public.client_account_transactions
     set gl_entry_id = v_entry, posted_at = now(), posted_by = auth.uid(),
         status = 'posted'
   where id in (v_out, v_in);

  return v_out;
end $$;

comment on function public.transfer_between_matters(
  uuid, uuid, numeric, text, date, text) is
  'Moves client money already held from one matter to another. No bank '
  'movement: it is in the same client account before and after, and '
  'only which matter the firm holds it for changes -- so the ledger '
  'entry is one debit and one credit against 2300, on two matters, '
  'netting to zero. Written as two `client_account_transactions` rows '
  'so `app.assert_client_funds` still refuses to overdraw the paying '
  'matter, which a journal straight to `gl_lines` would have bypassed. '
  'Uses `transfer_out` and `transfer_in`, which 0021 defined and '
  'nothing has written until now. 0690.';

revoke all on function public.transfer_between_matters(
  uuid, uuid, numeric, text, date, text) from public, anon;
grant execute on function public.transfer_between_matters(
  uuid, uuid, numeric, text, date, text) to authenticated;

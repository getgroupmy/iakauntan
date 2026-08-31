-- =====================================================================
-- iAkauntan :: 0358 the client's money, moved to their other matter
--
-- `app.client_txn_type` has had `transfer_in` and `transfer_out` since
-- `0021` — "moved from another matter" says the comment — and neither
-- has ever been written. The type dropdown on the matter screen offers
-- four of the six values, `matter_detail_screen.dart` has a
-- `_isMoneyIn` that already knows `transfer_in` counts as money in, and
-- there the design stopped.
--
-- It is an ordinary thing to need. A client finishes a conveyance with
-- a balance still held and starts a tenancy; the deposit follows them.
-- Without this the firm's only route is to refund it out of the client
-- account and take it back in, which is two bank movements to record a
-- transfer that never left the bank, and a Rule 7 withdrawal that did
-- not have to happen.
--
-- ---------------------------------------------------------------------
-- Why an RPC and not two more entries in the dropdown
--
-- A transfer is a pair. One `transfer_out` on its own is money taken
-- off a matter and put nowhere — it looks like a payment, is posted
-- like a payment, and there is no second matter it can be reconciled
-- against. Offering the two halves separately would make that the
-- normal way to get it wrong, and the wrong version is indistinguishable
-- from the right one until somebody adds up the client account.
--
-- So the two legs are written together or not at all. `0021` built the
-- overdraw control as a **deferrable** constraint trigger, which is
-- exactly what a paired write needs: both legs land, then the balances
-- are checked once at commit. That was foresight, and this is the thing
-- it was foreseeing.
--
-- ---------------------------------------------------------------------
-- Same client, and that is the statutory point
--
-- The Legal Profession (Accounts) Rules govern a client account on one
-- principle: money held for one client is that client's, and may not be
-- applied for anybody else. Between two matters of the same client this
-- is bookkeeping. Between two clients it is a breach, and it is the
-- ordinary way a breach happens — a mistyped matter number, both
-- matters open, both in the same list.
--
-- So it is refused, and refused by naming both clients rather than
-- saying "not allowed": somebody who meant the client's other matter
-- and picked the wrong row needs to see which row they picked.
--
-- The ledger is deliberately unmoved. Both legs post through
-- `post_client_transaction`, one negative and one positive, so the
-- client bank account and the client-monies-held liability finish
-- exactly where they started. Nothing left the bank; what moved is
-- which matter the firm says the money is being held against.
-- =====================================================================

create or replace function public.transfer_between_matters(
  p_from        uuid,
  p_to          uuid,
  p_amount      numeric,
  p_date        date default current_date,
  p_description text default null)
returns uuid[]
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_from   public.matters;
  v_to     public.matters;
  v_bank   uuid;
  v_held   numeric;
  v_out    uuid;
  v_in     uuid;
  v_note   text;
  v_from_client text;
  v_to_client   text;
begin
  select * into v_from from public.matters
   where id = p_from and deleted_at is null;
  if not found then
    raise exception 'No such matter to move money from.' using errcode = 'P0002';
  end if;
  select * into v_to from public.matters
   where id = p_to and deleted_at is null and org_id = v_from.org_id;
  if not found then
    raise exception 'No such matter to move money to.' using errcode = 'P0002';
  end if;

  if not app.has_module(v_from.org_id, 'legal') then
    raise exception 'This company does not hold the legal module.'
      using errcode = '42501';
  end if;
  if not app.can_post(v_from.org_id) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;

  if p_from = p_to then
    raise exception 'A matter cannot transfer to itself.' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A transfer needs an amount greater than nothing.'
      using errcode = '22023';
  end if;

  -- The statutory refusal, naming both clients. Somebody who picked the
  -- wrong row from a list of open matters needs to see which row.
  if v_from.client_id <> v_to.client_id then
    select name into v_from_client from public.contacts where id = v_from.client_id;
    select name into v_to_client   from public.contacts where id = v_to.client_id;
    raise exception
      'Matter % is %''s and matter % is %''s. Money held for one client '
      'may not be applied for another, so this transfer is refused.',
      v_from.matter_no, coalesce(v_from_client, 'another client'),
      v_to.matter_no,   coalesce(v_to_client, 'somebody else')
      using errcode = '23514';
  end if;

  -- Checked here as well as by 0021's deferred trigger, and the mutation
  -- run that removed this showed it is not the belt-and-braces it looks
  -- like. `assert_client_funds` is `deferrable initially deferred`, so
  -- inside a transaction that does several things it does not fire until
  -- commit — by which point the caller has done more work on the
  -- strength of a transfer that is about to be rejected. The trigger is
  -- the control and this is the refusal, and it names the matter and the
  -- figure rather than the overdraft that would have resulted.
  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_from and t.status <> 'void';
  if v_held < p_amount then
    raise exception
      'Matter % holds only %. There is not % to move.',
      v_from.matter_no,
      to_char(v_held, 'FM999999990.00'), to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  select id into v_bank from public.bank_accounts
   where org_id = v_from.org_id and is_client_account and is_active
   order by is_default desc limit 1;
  if v_bank is null then
    raise exception
      'No client account configured. Run the legal setup first.'
      using errcode = 'P0002';
  end if;

  v_note := coalesce(nullif(btrim(p_description), ''), 'Transfer between matters');

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values
    (v_from.org_id, p_from,
     app.next_document_number_internal(v_from.org_id, 'client_txn'),
     p_date, 'transfer_out', v_bank, -p_amount,
     v_note || ' — to ' || v_to.matter_no, v_to.matter_no, auth.uid())
  returning id into v_out;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values
    (v_from.org_id, p_to,
     app.next_document_number_internal(v_from.org_id, 'client_txn'),
     p_date, 'transfer_in', v_bank, p_amount,
     v_note || ' — from ' || v_from.matter_no, v_from.matter_no, auth.uid())
  returning id into v_in;

  -- Posted in the order the money moves. Both entries are the same two
  -- accounts with the signs reversed, so the client bank and the
  -- client-monies-held liability finish where they started: nothing
  -- left the bank, and what moved is which matter it is held against.
  perform public.post_client_transaction(v_out);
  perform public.post_client_transaction(v_in);

  return array[v_out, v_in];
end $$;

revoke all on function public.transfer_between_matters(uuid, uuid, numeric, date, text)
  from public, anon;
grant execute on function public.transfer_between_matters(uuid, uuid, numeric, date, text)
  to authenticated;

comment on function public.transfer_between_matters(uuid, uuid, numeric, date, text) is
  'Moves client money from one matter to another matter of the same '
  'client, as a paired transfer_out and transfer_in posted together. '
  'Refuses a transfer between different clients, and one the source '
  'matter does not hold.';

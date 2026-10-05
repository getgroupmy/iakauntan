-- Which client account, when the firm has two and neither is the default.
--
-- `transfer_between_matters` picks the bank account the money moves
-- through with
--
--   select id into v_bank from public.bank_accounts
--    where org_id = ... and is_client_account and is_active
--    order by is_default desc limit 1;
--
-- There is no tiebreak after `is_default desc`, so when no client
-- account is the default the choice is made by physical row order.
-- Demonstrated on a scratch cluster: a firm with two open client
-- accounts and neither marked default returned account A, and after
-- account A's NAME was rewritten -- which moves the row and changes
-- nothing about the ORDER BY -- the same query returned account B.
--
-- That is not a corner case, it is the ordinary configuration. `0741`
-- gives `bank_accounts` a unique index on
-- `(org_id) where is_default and is_active`, so a company has at most
-- ONE default bank account; a firm whose default is its office current
-- account therefore has NO default client account, and every transfer
-- between matters picks whichever of its client accounts the plan
-- reaches first. The money stays inside the client bank either way --
-- both legs are the same two accounts with the signs reversed -- so
-- nothing is lost; what moves is which account the firm's own client
-- ledger says it sits in, and a reconciliation is done per account.
--
-- Found by mutation: `supabase/tests/mutants/transfer_between_matters.py`
-- reversing `is_default desc` to `asc` survived the only file that
-- calls this function, because its fixture had one client account.
--
-- The fix is a total ordering. `created_at` alone is not one -- it
-- defaults to `now()`, the TRANSACTION timestamp, so two accounts
-- created by one statement share it -- which is why `id` follows it.
-- This cannot change an answer that was already determinate: it only
-- orders rows that `is_default desc` left tied.
--
-- The body below is `0739`'s verbatim, with that one line changed.
-- `0739` is the latest of FIVE definitions (0358, 0690, 0696, 0698,
-- 0739) and writes CREATE OR REPLACE in upper case, so a
-- case-sensitive search for the latest finds 0358 and is wrong by five
-- migrations; `latest_defining()` in scripts/mutate_sql.py is the
-- check that refuses to run against anything else.

CREATE OR REPLACE FUNCTION public.transfer_between_matters(p_from uuid, p_to uuid, p_amount numeric, p_date date DEFAULT app.today(), p_description text DEFAULT NULL::text)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
   order by is_default desc, created_at, id limit 1;
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
end $function$;

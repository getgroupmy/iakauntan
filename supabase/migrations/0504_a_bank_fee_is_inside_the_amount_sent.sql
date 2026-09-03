-- =====================================================================
-- 0504 :: a bank fee is inside the amount sent, not beside it
--
-- `bank_accounts.current_balance` is the figure the app puts on the
-- screen; `resync_bank_balance` defines it as the opening balance plus
-- the bank account's own ledger movement. `post_bank_transfer` kept it
-- by hand and took the bank charge off twice -- once inside
-- `amount_sent`, which `create_bank_transfer` requires to equal what
-- arrived plus the fee, and once again as `- v_charges`. The journal it
-- writes credits the bank account `v_sent` and debits the fee to 6300,
-- so after every transfer that carried a fee the balance on the screen
-- was short by that fee while the ledger was right. `void_bank_transfer`
-- put the same wrong amount back, so voiding hid it rather than
-- exposing it, and nothing but a resync would ever have said so.
--
-- Both functions are restated below from the built database with that
-- one term removed from each.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.post_bank_transfer(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r public.bank_transfers;
  f public.bank_accounts;
  t public.bank_accounts;
  v_from_gl uuid;
  v_to_gl uuid;
  v_entries jsonb := '[]'::jsonb;
  v_sent numeric(18, 2);
  v_received numeric(18, 2);
  v_charges numeric(18, 2);
  v_entry uuid;
begin
  select * into r from public.bank_transfers where id = p_id and deleted_at is null;
  if not found then
    raise exception 'Transfer % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if r.gl_entry_id is not null then
    raise exception 'Transfer % is already posted', r.transfer_no;
  end if;

  select * into f from public.bank_accounts where id = r.from_account_id;
  select * into t from public.bank_accounts where id = r.to_account_id;
  v_from_gl := f.account_id;
  v_to_gl := t.account_id;

  v_sent := round(r.amount_sent * r.from_rate, 2);
  v_received := round(r.amount_received * r.to_rate, 2);
  v_charges := round(r.bank_charges * r.from_rate, 2);

  v_entries := v_entries
    || jsonb_build_object(
         'account_id', v_to_gl,
         'description', 'Transfer in ' || r.transfer_no,
         'debit', v_received, 'credit', 0)
    || jsonb_build_object(
         'account_id', v_from_gl,
         'description', 'Transfer out ' || r.transfer_no,
         'debit', 0, 'credit', v_sent);

  if v_charges > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = r.org_id and code = '6300'),
      'description', 'Bank charges ' || r.transfer_no,
      'debit', v_charges, 'credit', 0);
  end if;

  -- Only ever non-zero across currencies: `create_bank_transfer`
  -- refuses a residual when both ends are in the same one.
  if r.fx_difference <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts where org_id = r.org_id
                      and code = case when r.fx_difference > 0
                                      then '6500' else '4920' end),
      'description', 'Exchange difference on ' || r.transfer_no,
      'debit', greatest(r.fx_difference, 0),
      'credit', greatest(-r.fx_difference, 0));
  end if;

  v_entry := public.create_gl_entry(
    r.org_id, r.transfer_date, 'bank_transaction'::app.journal_source,
    v_entries,
    'Transfer ' || r.transfer_no || ': ' || f.name || ' to ' || t.name,
    'bank_transfers', r.id, r.reference);

  -- `current_balance` is carried in the base currency everywhere else
  -- in this schema, so it is carried in the base currency here.
  --
  -- By `v_sent` alone. The fee is already inside the amount sent --
  -- `create_bank_transfer` refuses a same-currency transfer unless
  -- sent = received + charges -- and the journal above credits this
  -- account `v_sent` and debits the fee to 6300, which is a different
  -- account. Subtracting the charge again here took it twice.
  update public.bank_accounts
     set current_balance = current_balance - v_sent
   where id = r.from_account_id;
  update public.bank_accounts
     set current_balance = current_balance + v_received
   where id = r.to_account_id;

  update public.bank_transfers
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  return v_entry;
end; $function$;

CREATE OR REPLACE FUNCTION public.void_bank_transfer(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r public.bank_transfers;
  v_sent numeric(18, 2);
  v_received numeric(18, 2);
  v_reversal uuid;
begin
  select * into r from public.bank_transfers where id = p_id and deleted_at is null;
  if not found then
    raise exception 'Transfer % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if r.status = 'void' then
    raise exception 'Transfer % is already void', r.transfer_no
      using errcode = '22023';
  end if;

  if r.gl_entry_id is not null then
    v_reversal := public.reverse_gl_entry(r.gl_entry_id, r.transfer_date);

    v_sent := round(r.amount_sent * r.from_rate, 2);
    v_received := round(r.amount_received * r.to_rate, 2);

    -- Put back exactly what `post_bank_transfer` took: `v_sent`, which
    -- already includes the fee.
    update public.bank_accounts
       set current_balance = current_balance + v_sent
     where id = r.from_account_id;
    update public.bank_accounts
       set current_balance = current_balance - v_received
     where id = r.to_account_id;
  end if;

  update public.bank_transfers
     set status = 'void',
         notes = trim(both E'\n' from
                      coalesce(notes, '') || E'\n' ||
                      'Voided: ' || coalesce(p_reason, 'no reason given'))
   where id = p_id;

  return v_reversal;
end; $function$;

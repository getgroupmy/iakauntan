-- =====================================================================
-- iAkauntan :: 0282 client money never sits in the office account
--
-- post_client_transaction looks the client bank up like this:
--
--   select a.id into v_bank_acct
--     from public.bank_accounts b join public.accounts a on a.id = b.account_id
--    where b.id = v_txn.bank_account_id and b.is_client_account;
--   if v_bank_acct is null then
--     select id into v_bank_acct from public.accounts
--      where org_id = v_txn.org_id and code = '1150';
--   end if;
--
-- The `is_client_account` test is right and the fallback is what
-- undoes it. When the transaction names a bank account that is not a
-- client account, the join returns nothing, the fallback quietly puts
-- 1150 into the journal, and the last statement in the function then
-- updates the balance of whatever account the transaction named:
--
--   update public.bank_accounts
--      set current_balance = current_balance + v_amount
--    where id = v_txn.bank_account_id;
--
-- So a receipt of client money entered against the firm's own current
-- account debits 1150 Client Account (Bank) in the ledger and adds the
-- money to the office account in the bank register. The two records
-- disagree, and each of them is wrong in a different direction: the
-- client account reconciles to a balance that is not there, and the
-- office account carries money that is not the firm's.
--
-- That is the failure the Solicitors' Accounts Rules 1990 exist to
-- prevent, and it is worse than an inconsistency, because the register
-- is what a firm reconciles against a bank statement.
--
-- The Flutter client never causes it: recordClientTransaction selects
-- the bank account with is_client_account true and refuses to write
-- anything when there is none. But client_account_transactions is a
-- table an accounts clerk can insert into through the API, and the
-- database accepts a bank_account_id pointing anywhere -- so the rule
-- belongs here rather than in the app.
--
-- The transaction is now refused rather than redirected. Redirecting
-- would post the money somewhere the person did not name, which is its
-- own kind of surprise; a refusal that says what is wrong leaves the
-- entry to be corrected.
--
-- The fallback stays for a null bank_account_id -- the column is
-- nullable and a firm with no bank register still has to be able to
-- post -- and the 2300 liability account is now checked the way the
-- bank account already was. Without that check a missing 2300 reached
-- create_gl_entry as a null account_id and came back as a not-null
-- violation on gl_lines, which tells the reader nothing about what to
-- go and fix.
-- =====================================================================

create or replace function public.post_client_transaction(p_id uuid)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_txn public.client_account_transactions;
  v_bank_acct uuid; v_liab_acct uuid; v_entry uuid;
  v_bank_name text;
  v_entries jsonb; v_amount numeric(18,2);
begin
  select * into v_txn from public.client_account_transactions where id = p_id;
  if not found then raise exception 'Transaction % not found', p_id; end if;
  if not app.can_post(v_txn.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_txn.gl_entry_id is not null then
    raise exception 'Transaction % is already posted', v_txn.transaction_no;
  end if;

  if v_txn.bank_account_id is not null then
    select a.id into v_bank_acct
      from public.bank_accounts b join public.accounts a on a.id = b.account_id
     where b.id = v_txn.bank_account_id and b.is_client_account;

    -- Named a bank account that is not a client account. Refused rather
    -- than redirected: the ledger and the bank register have to name the
    -- same account, and the money is not the firm's to hold.
    if v_bank_acct is null then
      select name into v_bank_name from public.bank_accounts
       where id = v_txn.bank_account_id;
      raise exception
        'Bank account "%" is not a client account. Client money is held in '
        'a client account and never in the firm''s own, so % cannot be '
        'posted against it.',
        coalesce(v_bank_name, v_txn.bank_account_id::text), v_txn.transaction_no
        using errcode = '23514';
    end if;
  else
    select id into v_bank_acct from public.accounts
     where org_id = v_txn.org_id and code = '1150';
    if v_bank_acct is null then
      raise exception 'No client account configured. Run setup_legal_module first.';
    end if;
  end if;

  select id into v_liab_acct from public.accounts
   where org_id = v_txn.org_id and code = '2300';
  if v_liab_acct is null then
    raise exception
      'No client monies held account configured. Run setup_legal_module first.';
  end if;

  v_amount := v_txn.amount;

  -- Money in debits the client bank and credits what we owe the client;
  -- money out does the reverse.
  v_entries := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_bank_acct,
      'description', coalesce(v_txn.description, v_txn.transaction_no),
      'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0)),
    jsonb_build_object(
      'account_id', v_liab_acct,
      'description', 'Client monies held',
      'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0))
  );

  v_entry := public.create_gl_entry(
    v_txn.org_id, v_txn.transaction_date, 'manual'::app.journal_source,
    v_entries, 'Client account ' || v_txn.transaction_no,
    'client_account_transactions', v_txn.id, v_txn.reference,
    v_txn.currency, 1);

  update public.client_account_transactions
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  if v_txn.bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance + v_amount
     where id = v_txn.bank_account_id;
  end if;

  return v_entry;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.post_client_transaction(uuid)
  to authenticated;

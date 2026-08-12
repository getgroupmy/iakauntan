-- Bank reconciliation: the tables were designed and nothing was ever
-- built on them.
--
-- `bank_transactions` has carried `import_batch_id`, `matched_table`,
-- `matched_id`, `gl_entry_id`, `is_reconciled` and `reconciliation_id`
-- since 0006, and `bank_reconciliations` has carried the statement
-- balance, the book balance and the difference between them. Both have
-- had RLS since 0010. There was no import, no matching and no way to
-- close a reconciliation — the design was complete and unreachable.
--
-- What reconciling actually asks
-- ------------------------------
-- Not "do the two balances agree", because they never do. The bank does
-- not know about a cheque that has not been presented, and the books do
-- not know about a charge until the statement arrives. The question is
-- whether every difference is accounted for:
--
--   book balance − items the bank has not seen = statement balance
--
-- So a reconciliation is finished when that identity holds, and the
-- difference reported here is what is left over when it does not. A
-- reconciliation completed with a difference is an error somebody has
-- decided to stop looking for, which is why completing refuses one.

-- ---------------------------------------------------------------------
-- Import
--
-- Rows are [{"transaction_date": "2026-01-31", "description": "...",
--            "reference": "...", "amount": -1250.00}, ...] with amount
-- signed: positive is money in.
--
-- Re-importing a statement that overlaps one already imported is the
-- ordinary mistake, not an exotic one — the months overlap by a few days
-- and every shared line would be counted twice, which then has to be
-- found and deleted by hand. So a line identical to one already on the
-- account is skipped and counted rather than inserted.
-- ---------------------------------------------------------------------
create or replace function public.import_bank_transactions(
  p_bank_account_id uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org      uuid;
  v_batch    uuid := gen_random_uuid();
  v_imported integer := 0;
  v_skipped  integer := 0;
  v_row      jsonb;
  v_date     date;
  v_amount   numeric(18, 2);
  v_desc     text;
  v_ref      text;
begin
  select org_id into v_org from public.bank_accounts where id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_date := (v_row ->> 'transaction_date')::date;
    v_amount := round((v_row ->> 'amount')::numeric, 2);
    v_desc := nullif(trim(coalesce(v_row ->> 'description', '')), '');
    v_ref := nullif(trim(coalesce(v_row ->> 'reference', '')), '');

    if v_date is null or v_amount is null then
      raise exception 'Every line needs a date and an amount; got %', v_row
        using errcode = '23514';
    end if;

    if exists (
      select 1 from public.bank_transactions t
       where t.bank_account_id = p_bank_account_id
         and t.transaction_date = v_date
         and t.amount = v_amount
         and coalesce(t.description, '') = coalesce(v_desc, '')
         and coalesce(t.reference, '') = coalesce(v_ref, ''))
    then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.bank_transactions (
      org_id, bank_account_id, transaction_date, description, reference,
      amount, transaction_type, import_batch_id, raw_data, created_by)
    values (
      v_org, p_bank_account_id, v_date, v_desc, v_ref, v_amount,
      case when v_amount >= 0 then 'deposit' else 'withdrawal' end,
      v_batch, v_row, auth.uid());

    v_imported := v_imported + 1;
  end loop;

  return jsonb_build_object(
    'batch_id', v_batch, 'imported', v_imported, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------
-- What each statement line might be
--
-- Candidates by amount and nearness of date, best first. Deliberately
-- suggestive rather than automatic: matching the wrong receipt to the
-- wrong deposit produces a reconciliation that balances and a customer
-- whose account is wrong, and nothing downstream would catch it.
-- ---------------------------------------------------------------------
create or replace function public.suggest_bank_matches(
  p_transaction_id uuid, p_within_days integer default 7)
returns table (
  source_table text, source_id uuid, doc_no text, doc_date date,
  amount numeric, contact_name text, day_gap integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare t public.bank_transactions;
begin
  select * into t from public.bank_transactions where id = p_transaction_id;
  if not found then
    raise exception 'Statement line % not found', p_transaction_id
      using errcode = 'P0002';
  end if;
  if not app.is_org_member(t.org_id) then
    raise exception 'Not a member of organization %', t.org_id
      using errcode = '42501';
  end if;

  return query
  select * from (
    -- Money in is a receipt.
    select 'receipts'::text, r.id, r.receipt_no, r.receipt_date,
           r.amount, c.name,
           abs(r.receipt_date - t.transaction_date)::integer
      from public.receipts r
      left join public.contacts c on c.id = r.contact_id
     where t.amount > 0 and r.org_id = t.org_id
       and r.gl_entry_id is not null
       and round(r.amount - coalesce(r.bank_charges, 0), 2) = round(t.amount, 2)
       and abs(r.receipt_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'receipts' and b.matched_id = r.id)
    union all
    -- Money out is a supplier payment or an expense.
    select 'purchase_payments', p.id, p.payment_no, p.payment_date,
           p.amount, c.name,
           abs(p.payment_date - t.transaction_date)::integer
      from public.purchase_payments p
      left join public.contacts c on c.id = p.contact_id
     where t.amount < 0 and p.org_id = t.org_id
       and p.gl_entry_id is not null
       and round(p.amount + coalesce(p.bank_charges, 0), 2) = round(-t.amount, 2)
       and abs(p.payment_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'purchase_payments'
                          and b.matched_id = p.id)
    union all
    select 'expenses', e.id, e.expense_no, e.expense_date,
           e.total_amount, c.name,
           abs(e.expense_date - t.transaction_date)::integer
      from public.expenses e
      left join public.contacts c on c.id = e.contact_id
     where t.amount < 0 and e.org_id = t.org_id
       and e.gl_entry_id is not null
       and round(e.total_amount, 2) = round(-t.amount, 2)
       and abs(e.expense_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'expenses' and b.matched_id = e.id)
  ) s(source_table, source_id, doc_no, doc_date, amount, contact_name, day_gap)
  order by s.day_gap, s.doc_date
  limit 20;
end;
$$;

create or replace function public.match_bank_transaction(
  p_transaction_id uuid, p_source_table text, p_source_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  t public.bank_transactions;
  v_entry uuid;
begin
  select * into t from public.bank_transactions where id = p_transaction_id;
  if not found then
    raise exception 'Statement line % not found', p_transaction_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(t.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if t.reconciliation_id is not null then
    raise exception
      'That line belongs to a reconciliation that has been completed.'
      using errcode = '23514';
  end if;

  -- The journal behind the document, so completing the reconciliation
  -- can tell which ledger entries the bank has already seen.
  v_entry := case p_source_table
    when 'receipts' then
      (select gl_entry_id from public.receipts where id = p_source_id and org_id = t.org_id)
    when 'purchase_payments' then
      (select gl_entry_id from public.purchase_payments where id = p_source_id and org_id = t.org_id)
    when 'expenses' then
      (select gl_entry_id from public.expenses where id = p_source_id and org_id = t.org_id)
    when 'gl_entries' then
      (select id from public.gl_entries where id = p_source_id and org_id = t.org_id)
    else null end;

  if v_entry is null then
    raise exception
      'Nothing posted found in % with id % for this organization.',
      p_source_table, p_source_id using errcode = 'P0002';
  end if;

  -- One book item, one statement line. Matching the same receipt to two
  -- deposits would reconcile both and leave the account short.
  if exists (select 1 from public.bank_transactions b
              where b.matched_table = p_source_table
                and b.matched_id = p_source_id
                and b.id <> p_transaction_id) then
    raise exception 'That document is already matched to another line.'
      using errcode = '23514';
  end if;

  update public.bank_transactions
     set matched_table = p_source_table, matched_id = p_source_id,
         gl_entry_id = v_entry, is_reconciled = true,
         reconciled_at = now(), updated_at = now()
   where id = p_transaction_id;
end;
$$;

create or replace function public.unmatch_bank_transaction(p_transaction_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare t public.bank_transactions;
begin
  select * into t from public.bank_transactions where id = p_transaction_id;
  if not found then
    raise exception 'Statement line % not found', p_transaction_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(t.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if t.reconciliation_id is not null then
    raise exception
      'That line belongs to a reconciliation that has been completed.'
      using errcode = '23514';
  end if;

  update public.bank_transactions
     set matched_table = null, matched_id = null, gl_entry_id = null,
         is_reconciled = false, reconciled_at = null, updated_at = now()
   where id = p_transaction_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Where the reconciliation stands
--
--   book balance          what the ledger says the account holds
--   unpresented           posted to the ledger, not yet on the statement
--   expected statement    book balance less those
--   difference            expected less the statement actually given
--
-- A difference is not a rounding artefact. It is a statement line nobody
-- has matched, a payment entered twice, or a charge the books have never
-- heard of, and it is the only number on this that matters.
-- ---------------------------------------------------------------------
create or replace function public.bank_reconciliation_status(
  p_bank_account_id uuid,
  p_as_at date,
  p_statement_balance numeric default 0)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_org        uuid;
  v_account    uuid;
  v_book       numeric(18, 2);
  v_unpresented numeric(18, 2);
  v_unmatched  integer;
begin
  select b.org_id, b.account_id into v_org, v_account
    from public.bank_accounts b where b.id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org
      using errcode = '42501';
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_book
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted';

  -- Ledger movements the bank has not shown yet: unpresented cheques and
  -- deposits in transit, which is to say every posting on this account
  -- that no statement line has been matched to.
  select coalesce(sum(l.debit - l.credit), 0) into v_unpresented
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted'
     and not exists (
       select 1 from public.bank_transactions t
        where t.gl_entry_id = e.id
          and t.bank_account_id = p_bank_account_id
          and t.is_reconciled);

  select count(*) into v_unmatched
    from public.bank_transactions t
   where t.bank_account_id = p_bank_account_id
     and t.transaction_date <= p_as_at
     and not t.is_reconciled;

  return jsonb_build_object(
    'book_balance', v_book,
    'unpresented', v_unpresented,
    'expected_statement', v_book - v_unpresented,
    'statement_balance', round(coalesce(p_statement_balance, 0), 2),
    'difference', round(v_book - v_unpresented
                        - coalesce(p_statement_balance, 0), 2),
    'unmatched_lines', v_unmatched);
end;
$$;

-- Closes it, and refuses to close one that does not balance.
create or replace function public.complete_bank_reconciliation(
  p_bank_account_id uuid,
  p_statement_date date,
  p_statement_balance numeric)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org    uuid;
  v_status jsonb;
  v_diff   numeric(18, 2);
  v_id     uuid;
begin
  select org_id into v_org from public.bank_accounts where id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_status := public.bank_reconciliation_status(
    p_bank_account_id, p_statement_date, p_statement_balance);
  v_diff := (v_status ->> 'difference')::numeric;

  if v_diff <> 0 then
    raise exception
      'The reconciliation is out by %. There are % statement lines still '
      'unmatched. Completing it now would bury the difference.',
      v_diff, v_status ->> 'unmatched_lines' using errcode = '23514';
  end if;

  insert into public.bank_reconciliations (
    org_id, bank_account_id, statement_date, statement_balance,
    book_balance, difference, status, completed_at, completed_by)
  values (
    v_org, p_bank_account_id, p_statement_date,
    round(p_statement_balance, 2),
    (v_status ->> 'book_balance')::numeric, 0,
    'completed', now(), auth.uid())
  returning id into v_id;

  -- Stamped so the lines cannot be unmatched afterwards: a completed
  -- reconciliation that can still be edited underneath is not a record
  -- of anything.
  update public.bank_transactions
     set reconciliation_id = v_id, updated_at = now()
   where bank_account_id = p_bank_account_id
     and transaction_date <= p_statement_date
     and is_reconciled and reconciliation_id is null;

  return v_id;
end;
$$;

revoke all on function public.import_bank_transactions(uuid, jsonb) from public, anon;
grant execute on function public.import_bank_transactions(uuid, jsonb) to authenticated;

revoke all on function public.suggest_bank_matches(uuid, integer) from public, anon;
grant execute on function public.suggest_bank_matches(uuid, integer) to authenticated;

revoke all on function public.match_bank_transaction(uuid, text, uuid) from public, anon;
grant execute on function public.match_bank_transaction(uuid, text, uuid) to authenticated;

revoke all on function public.unmatch_bank_transaction(uuid) from public, anon;
grant execute on function public.unmatch_bank_transaction(uuid) to authenticated;

revoke all on function public.bank_reconciliation_status(uuid, date, numeric)
  from public, anon;
grant execute on function public.bank_reconciliation_status(uuid, date, numeric)
  to authenticated;

revoke all on function public.complete_bank_reconciliation(uuid, date, numeric)
  from public, anon;
grant execute on function public.complete_bank_reconciliation(uuid, date, numeric)
  to authenticated;

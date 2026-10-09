-- =====================================================================
-- 0772 :: a statement line is matched to its own account
--
-- Answered on 9 October: "refuse + filter".
--
-- Measured locally: a company with a Maybank and a CIMB account banks a
-- RM1,000 receipt into Maybank and imports a CIMB statement line for
-- RM1,000. `match_bank_transaction` accepted the match. CIMB then read
-- no unmatched lines and a RM1,000 difference; Maybank's own line for
-- that receipt could no longer be matched to it ("That document is
-- already matched to another line"), so Maybank could not reconcile it
-- until somebody found the CIMB match and undid it.
-- `suggest_bank_matches` proposed exactly that match: it chose by
-- company, amount and date, never by account.
--
-- Now the match is refused unless the document's journal has a line on
-- the statement line's bank ledger account, naming where it went; and
-- the suggestions offer only documents that went through that account.
-- One rule for all four kinds of document, asked of the journal.
--
-- Existing matches are left as they are.
--
-- Restated from `0085`. Production's text is `0085`'s with its comment
-- lines removed -- the same code: with them stripped, the local
-- definitions hash to what production's `pg_get_functiondef` hashes to
-- (ff801512..., 67be1a64...). The comment on `match_bank_transaction`
-- is EXTENDED; `suggest_bank_matches` had none and is given one.
-- =====================================================================

create or replace function public.suggest_bank_matches(
  p_transaction_id uuid, p_within_days integer default 7)
returns table (
  source_table text, source_id uuid, doc_no text, doc_date date,
  amount numeric, contact_name text, day_gap integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare t public.bank_transactions; v_bank_gl uuid;
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

  -- `0772`: only what went through THIS account. Every branch below
  -- matched on company, amount and date alone, so a company with two
  -- banks was offered the Maybank receipt for a CIMB line whenever the
  -- figures fitted -- and `match_bank_transaction` took it.
  select b.account_id into v_bank_gl
    from public.bank_accounts b where b.id = t.bank_account_id;

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
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = r.gl_entry_id and l.account_id = v_bank_gl)
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
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = p.gl_entry_id and l.account_id = v_bank_gl)
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
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = e.gl_entry_id and l.account_id = v_bank_gl)
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
  v_bank  public.bank_accounts;
  v_doc   text;
  v_went  text;
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

  -- `0772`: and through THIS account. A statement line is the bank's
  -- record of one account; a document whose journal never touched that
  -- account's ledger is not what the bank is showing. Measured before
  -- this: a CIMB line matched to a receipt banked into Maybank was
  -- accepted, CIMB read "nothing unmatched" with a difference it could
  -- not explain, and Maybank's own line could no longer be matched to
  -- the receipt at all -- the check below said it was already taken.
  -- Asked of the journal rather than of each document's own bank
  -- column, so it is one rule for receipts, payments, expenses and
  -- journals alike.
  select * into v_bank from public.bank_accounts where id = t.bank_account_id;
  if not exists (select 1 from public.gl_lines l
                  where l.entry_id = v_entry and l.account_id = v_bank.account_id) then
    v_doc := case p_source_table
      when 'receipts' then
        (select receipt_no from public.receipts where id = p_source_id)
      when 'purchase_payments' then
        (select payment_no from public.purchase_payments where id = p_source_id)
      when 'expenses' then
        (select expense_no from public.expenses where id = p_source_id)
      else (select entry_no from public.gl_entries where id = v_entry) end;
    select string_agg(distinct b.name, ', ' order by b.name) into v_went
      from public.gl_lines l
      join public.bank_accounts b
        on b.account_id = l.account_id and b.org_id = t.org_id
     where l.entry_id = v_entry;
    raise exception
      '% went through %, not %. A statement line is matched to what passed through its own account.',
      coalesce(v_doc, 'That document'), coalesce(v_went, 'no bank account'),
      v_bank.name
      using errcode = '23514';
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

comment on function public.match_bank_transaction(uuid, text, uuid) is
  'Ties a statement line to the thing in the books that caused it, '
  'posting a journal where the match implies one. Refuses a line '
  'belonging to a reconciliation that has been completed: a closed '
  'reconciliation balanced against the lines it had, and changing one '
  'afterwards would silently unbalance it. Since `0772` it also refuses '
  'a document whose journal never touched this line''s bank account, '
  'naming the account it did go through. Needs `can_post`.';

comment on function public.suggest_bank_matches(uuid, integer) is
  'Candidates for one statement line, best first: receipts for money in, '
  'supplier payments and expenses for money out, of the same amount '
  'within p_within_days, not already matched -- and, since `0772`, only '
  'those whose journal went through this line''s bank account. '
  'Suggestive rather than automatic. Needs membership.';

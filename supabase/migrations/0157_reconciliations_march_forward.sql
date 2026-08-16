-- =====================================================================
-- iAkauntan :: 0157 a reconciliation carries on from the last one
--
-- `docs/unreachable.md` has carried this line:
--
--   **Reconciliation history.** `bank_reconciliations` rows are written
--   and never listed.
--
-- Going to list them is what showed why it matters. `complete_bank_
-- reconciliation` refuses a difference — 0085 was careful about that,
-- and right to be — but nothing stopped it being run twice, or run at a
-- date behind one already closed. One statement line, matched once,
-- produced this:
--
--   2026-03-10  1,000.00  completed   stamped nothing
--   2026-03-31  1,000.00  completed   stamped the line
--   2026-03-31  1,000.00  completed   stamped nothing
--
-- Two of the three are records of a reconciliation that agreed nothing.
-- The lines up to that date already belonged to the first one — the
-- stamping is `where reconciliation_id is null`, so a repeat finds
-- nothing left to claim — and the difference check passes trivially
-- because everything was already reconciled. The result is a history
-- that reads as three months of diligence and is one.
--
-- That is worse than no history at all. A reconciliation register is
-- audit evidence that the bank was agreed at each period end, and an
-- auditor ticking against a phantom row is being told something untrue
-- by the system rather than by a person.
--
-- ---------------------------------------------------------------------
-- Forward only, and a way back
--
-- The rule is that a reconciliation carries on from the last one: the
-- statement date must be after the latest completed date on that
-- account. Refusing alone would be a trap, though — one wrong date and
-- the account is closed past the point anybody wanted, permanently. So
-- `reopen_bank_reconciliation` unstamps the lines and deletes the row,
-- and only for the most recent one, because reopening behind a later
-- reconciliation would leave that later one resting on lines it no
-- longer holds.
--
-- Deleted rather than marked reopened, deliberately. 0085's own comment
-- says a completed reconciliation that can still be edited underneath is
-- not a record of anything; a reopened one is in exactly that state, and
-- keeping it would put back the phantom row this migration removes. What
-- happened is that the reconciliation was undone, and the honest record
-- of that is its absence.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Completing, once and forward
-- ---------------------------------------------------------------------
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
  v_last   date;
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

  -- Checked before the difference, because a repeat of a closed period
  -- passes the difference test for the wrong reason: every line up to
  -- that date is already reconciled, so there is nothing left to be out
  -- by. A nil difference means agreement only the first time.
  select max(statement_date) into v_last
    from public.bank_reconciliations
   where bank_account_id = p_bank_account_id and status = 'completed';

  if v_last is not null and p_statement_date <= v_last then
    raise exception
      'This account is reconciled to %. A reconciliation carries on from '
      'the last one, so the statement date has to be after it — closing '
      'again here would record an agreement that agreed nothing, because '
      'every line up to % already belongs to the earlier one. If that one '
      'was wrong, reopen it.', v_last, v_last
      using errcode = '23514';
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

revoke all on function public.complete_bank_reconciliation(uuid, date, numeric)
  from public, anon;
grant execute on function public.complete_bank_reconciliation(uuid, date, numeric)
  to authenticated;

-- ---------------------------------------------------------------------
-- Undoing the last one
--
-- Only the last one. Reopening an earlier reconciliation would release
-- lines that a later one was closed over, leaving that later one
-- claiming an agreement it can no longer show the working for.
-- ---------------------------------------------------------------------
create or replace function public.reopen_bank_reconciliation(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r      public.bank_reconciliations;
  v_next date;
begin
  select * into r from public.bank_reconciliations where id = p_id;
  if not found then
    raise exception 'Reconciliation % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select min(statement_date) into v_next
    from public.bank_reconciliations
   where bank_account_id = r.bank_account_id and status = 'completed'
     and statement_date > r.statement_date;

  if v_next is not null then
    raise exception
      'This account has been reconciled again since, to %. Reopening an '
      'earlier reconciliation would release lines the later one was '
      'closed over. Reopen that one first.', v_next
      using errcode = '23514';
  end if;

  -- The lines go back to being matched but unclosed, which is what they
  -- were a moment before it was completed. Nothing about the matching
  -- itself is undone.
  update public.bank_transactions
     set reconciliation_id = null, updated_at = now()
   where reconciliation_id = p_id;

  delete from public.bank_reconciliations where id = p_id;
end;
$$;

revoke all on function public.reopen_bank_reconciliation(uuid) from public, anon;
grant execute on function public.reopen_bank_reconciliation(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The register
--
-- What was agreed, when, by whom, and over how many lines. The line
-- count is the part that would have exposed the phantom rows above: a
-- completed reconciliation holding nothing is one that agreed nothing,
-- and it is now impossible to create and visible if one ever existed.
--
-- `can_read_ledger` rather than membership: this is the evidence that
-- the bank balance in the accounts is right.
-- ---------------------------------------------------------------------
create or replace function public.report_bank_reconciliations(
  p_org_id uuid, p_bank_account_id uuid default null)
returns table (
  id                uuid,
  bank_account      text,
  statement_date    date,
  statement_balance numeric,
  book_balance      numeric,
  difference        numeric,
  lines             integer,
  completed_at      timestamptz,
  completed_by      text,
  can_reopen        boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  select br.id, b.name, br.statement_date, br.statement_balance,
         br.book_balance, br.difference,
         (select count(*) from public.bank_transactions bt
           where bt.reconciliation_id = br.id)::integer,
         br.completed_at,
         coalesce(p.full_name, p.email),
         -- Only the most recent on its own account, which is the only
         -- one `reopen_bank_reconciliation` will accept.
         br.statement_date = (
           select max(x.statement_date) from public.bank_reconciliations x
            where x.bank_account_id = br.bank_account_id
              and x.status = 'completed')
    from public.bank_reconciliations br
    join public.bank_accounts b on b.id = br.bank_account_id
    left join public.profiles p on p.id = br.completed_by
   where br.org_id = p_org_id
     and (p_bank_account_id is null or br.bank_account_id = p_bank_account_id)
   order by b.name, br.statement_date desc;
end;
$$;

revoke all on function public.report_bank_reconciliations(uuid, uuid)
  from public, anon;
grant execute on function public.report_bank_reconciliations(uuid, uuid)
  to authenticated;

comment on function public.report_bank_reconciliations(uuid, uuid) is
  'Every completed reconciliation on an account, newest first, with the '
  'number of statement lines it closed over and whether it is the one '
  'that may still be reopened.';

-- =====================================================================
-- iAkauntan :: 0716 nothing in the books is not a difference
--
-- Reported with a screenshot of the bank reconciliation screen:
--
--     Book balance                             RM 0.00
--     Less what the bank has not seen         RM -0.00
--     Statement should read                    RM 0.00
--     Statement says                      RM 11,008.23
--     Out by                             RM -11,008.23
--
--     24 statement lines are still unmatched. A difference is a line
--     nobody has matched, a payment entered twice, or a charge the
--     books have not heard of.
--
-- The arithmetic is right and the explanation is wrong. It offers
-- three causes and the real one is not among them.
--
-- ---------------------------------------------------------------------
-- What had actually happened
--
-- A Maybank statement for OCTOBER 2025 was scanned, read and imported
-- into an account whose ledger begins in JANUARY 2026. Twenty-four
-- lines, 09/10/2025 to 31/10/2025, every one carrying a running
-- balance that chains without a break from 974.74 to 11,008.23. The
-- scan was perfect. The closing figure in the box is the bank's own.
--
-- `bank_reconciliation_status` sums posted ledger lines `where
-- e.entry_date <= p_as_at`. On 31/10/2025 there were none -- not a few,
-- not netting to zero: NONE, anywhere in that company. So the book
-- balance is 0, what the bank has not seen is 0, and the difference is
-- the statement balance itself, to the sen.
--
-- Every one of the three causes the screen offers is a discrepancy
-- between two sets of records. There is only one set of records here.
--
-- ---------------------------------------------------------------------
-- A difference that equals the statement is a different thing
--
-- And it is worth separating, because what to DO about it is not the
-- same. A real difference is hunted line by line. This one is not a
-- difference at all: the books have not been written yet, and no amount
-- of matching will close it, because `suggest_bank_matches` can only
-- offer documents that are already posted and there are none.
--
-- Somebody hunting the first when they have the second looks for a
-- missing RM 11,008.23 that was never there.
--
-- ---------------------------------------------------------------------
-- Facts here, wording in the app
--
-- Two figures go onto the status, and neither of them is a sentence:
--
--   posted_entries  how many posted ledger lines this account has on
--                   or before the statement date. Zero is the state
--                   above, and it is the one the screen cannot
--                   currently see -- a book balance of zero can mean
--                   "nothing posted" or "posted and netted off", and
--                   those want different sentences.
--
--   books_start     the earliest posted entry on the account, at any
--                   date. With `posted_entries` at zero this says
--                   which side of the ledger the statement fell on:
--                   BEFORE the books begin (this case, and the app can
--                   name the date), or after an account that has
--                   nothing in it at all.
--
-- The screen writes the sentence. A database function composing
-- English for one screen is a rule with nowhere to be tested and no way
-- to be translated.
--
-- ---------------------------------------------------------------------
-- And the refusal says which of the two it is
--
-- `complete_bank_reconciliation` is what the person actually hit, and
-- its message is the one that reached the phone. It refuses correctly
-- -- closing would have recorded an agreement that agreed nothing and
-- buried RM 11,008.23 -- but it too described a difference that does
-- not exist.
--
-- It now says which case it is in, because the sentence a refusal
-- carries is the only explanation somebody gets at the moment they are
-- stopped.
--
-- `bank_reconciliation_status` is restated whole from `0085`, which is
-- what last defined it; `complete_bank_reconciliation` from `0157`,
-- which added the march-forward check. Both keep everything else.
-- =====================================================================

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
  v_posted     integer;
  v_start      date;
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

  -- How many, not how much. A book balance of zero is ambiguous --
  -- nothing posted, or posted and netted off -- and only the count
  -- separates them.
  select count(*) into v_posted
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted';

  -- Deliberately NOT bounded by `p_as_at`: the whole use of it is to
  -- say that the books start AFTER the statement, which a figure cut
  -- off at the statement date could never show.
  select min(e.entry_date) into v_start
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.status = 'posted';

  return jsonb_build_object(
    'book_balance', v_book,
    'unpresented', v_unpresented,
    'expected_statement', v_book - v_unpresented,
    'statement_balance', round(coalesce(p_statement_balance, 0), 2),
    'difference', round(v_book - v_unpresented
                        - coalesce(p_statement_balance, 0), 2),
    'unmatched_lines', v_unmatched,
    'posted_entries', v_posted,
    'books_start', v_start);
end;
$$;

comment on function public.bank_reconciliation_status(uuid, date, numeric) is
  'Where a reconciliation stands, as figures. `posted_entries` at zero '
  'means the books hold nothing on this account by the statement date, '
  'which is not a difference to hunt; `books_start` says whether the '
  'statement simply predates them. `0716`.';

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
  v_posted integer;
  v_start  date;
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
  v_posted := (v_status ->> 'posted_entries')::integer;
  v_start := nullif(v_status ->> 'books_start', '')::date;

  if v_diff <> 0 then
    -- `0716`: which of the two this is. A difference between two sets
    -- of records is hunted line by line; an empty set of records is
    -- not, and nothing on this screen will close it.
    if v_posted = 0 then
      if v_start is not null and v_start > p_statement_date then
        raise exception
          'Nothing is posted to this account on or before %, so there is '
          'nothing for the statement to agree with — its books start on '
          '%, after the statement. The % unmatched lines have to be '
          'entered into the ledger before this can close.',
          p_statement_date, v_start,
          (v_status ->> 'unmatched_lines')
          using errcode = '23514';
      end if;
      raise exception
        'Nothing is posted to this account on or before %, so there is '
        'nothing for the statement to agree with. The % unmatched lines '
        'have to be entered into the ledger before this can close.',
        p_statement_date, (v_status ->> 'unmatched_lines')
        using errcode = '23514';
    end if;

    raise exception
      'The reconciliation is out by %. There are % statement lines still '
      'unmatched. Completing it now would bury the difference.',
      v_diff, (v_status ->> 'unmatched_lines')
      using errcode = '23514';
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

comment on function public.complete_bank_reconciliation(uuid, date, numeric) is
  'Closes a reconciliation, and refuses one that does not balance — '
  'naming, since `0716`, whether the difference is a discrepancy to '
  'hunt or an account with nothing posted to it at all.';

-- =====================================================================
-- iAkauntan :: 0717 a statement line can become a posting
--
-- The other half of the screenshot behind `0716`, and the larger half.
--
-- A bank statement was scanned, read, imported, and every one of its
-- twenty-four lines then sat on the reconciliation screen with nothing
-- that could be done to it. `suggest_bank_matches` only offers
-- documents that are ALREADY POSTED — receipts, supplier payments,
-- expenses, journals — so against a ledger with nothing in it, every
-- line answered
--
--     Nothing posted matches that amount and date. Record the receipt
--     or payment first.
--
-- twenty-four times, and the screen offered no way to record one.
--
-- Import brought the lines in. Nothing turned a line into a posting.
-- That is not a gap in the matching; it is a missing verb.
--
-- ---------------------------------------------------------------------
-- What a line posts as
--
-- Two sides. The bank's own GL account, and one account somebody
-- chooses for the other side.
--
-- `bank_transactions.amount` is already a GL-SIGNED movement on the
-- bank's account — `0085` fixed the meaning (positive is money in) and
-- `0712` made a credit card obey it by storing the card's figures
-- negated, precisely so that every reader of the column means one
-- thing by it. So the rule needs no account-type branch of its own:
--
--     amount > 0   debit  the bank account, credit the other one
--     amount < 0   credit the bank account, debit  the other one
--
-- and a card purchase, stored negative, credits the card — raising a
-- liability — which is what a purchase on a card does.
--
-- Posting goes through `app.create_gl_entry_internal` like every other
-- route in this product. It is the only thing that inserts into
-- `gl_lines`, and it is what enforces the fiscal period, the open
-- period, the balance and the document numbering. A second way to
-- write a journal would be a second set of rules to drift.
--
-- `source` is `bank_transaction`, which `0004` has held in the
-- `journal_source` enum since the beginning and nothing has ever
-- written.
--
-- ---------------------------------------------------------------------
-- Undoing it, which is the part that would have rotted
--
-- `unmatch_bank_transaction` clears `gl_entry_id` and lets the line be
-- matched again. For a line matched to a receipt that is right: the
-- receipt is a document in its own right and goes on existing.
--
-- For a line POSTED FROM ITSELF it would be wrong twice. The journal
-- is left in the ledger with nothing pointing at it, and the line is
-- free to be posted a second time — so an undo followed by a redo
-- doubles the figure, silently, in the books.
--
-- So unmatching now REVERSES an entry that came from the line it is
-- detaching. Reversed rather than deleted, because a posted journal
-- that disappears is not something a set of books should be able to
-- do; `reverse_gl_entry` writes the contra and leaves the original
-- standing, which is `0102`'s rule and it is not being relitigated
-- here.
--
-- An entry already reversed by hand does not stop the unmatch. It is
-- detached and left alone, because the thing the reversal exists to
-- prevent has already happened.
--
-- ---------------------------------------------------------------------
-- What is refused, and why each one
--
--   a completed reconciliation     `0085`'s rule, unchanged: a closed
--                                  period cannot be edited underneath.
--   a line already matched         two postings for one line is the
--                                  doubling this is meant to prevent.
--   a zero amount                  a journal of two zeroes balances
--                                  and says nothing.
--   a group account                headers cannot receive postings.
--   the bank's own account         both sides the same account nets to
--                                  nothing and reconciles nothing; it
--                                  is always a mis-click.
--   another company's account      the composite key would catch it at
--                                  the table, but the message would be
--                                  about a constraint.
-- =====================================================================

create or replace function public.post_bank_transaction(
  p_transaction_id uuid,
  p_account_id uuid,
  p_description text default null,
  p_contact_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  t         public.bank_transactions;
  v_bank    public.bank_accounts;
  v_acct    public.accounts;
  v_entry   uuid;
  v_desc    text;
  v_amount  numeric(18, 2);
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
  if t.matched_table is not null then
    raise exception
      'That line is already matched to something. Unmatch it first if it '
      'should be posted instead.'
      using errcode = '23514';
  end if;

  v_amount := round(t.amount, 2);
  if v_amount = 0 then
    raise exception
      'That line is for nothing, so there is nothing to post.'
      using errcode = '23514';
  end if;

  select * into v_bank from public.bank_accounts where id = t.bank_account_id;

  select * into v_acct from public.accounts
   where id = p_account_id and org_id = t.org_id and deleted_at is null;
  if not found then
    raise exception 'No such account in this company.' using errcode = 'P0002';
  end if;
  if v_acct.is_group then
    raise exception
      '% is a heading, not an account postings can go to. Choose one of '
      'the accounts under it.', v_acct.name
      using errcode = '23514';
  end if;
  if v_acct.id = v_bank.account_id then
    raise exception
      'Both sides of that posting would be the same account, which would '
      'record no movement at all. Choose the account the money came from '
      'or went to.'
      using errcode = '23514';
  end if;

  v_desc := nullif(trim(coalesce(p_description, '')), '');
  v_desc := coalesce(v_desc, nullif(trim(coalesce(t.description, '')), ''),
                     'Bank statement line');

  -- The bank's side takes the sign the column already carries; the
  -- chosen account takes the other one.
  v_entry := app.create_gl_entry_internal(
    p_org_id => t.org_id,
    p_entry_date => t.transaction_date,
    p_source => 'bank_transaction'::app.journal_source,
    p_lines => jsonb_build_array(
      jsonb_build_object(
        'account_id', v_bank.account_id,
        'description', v_desc,
        'debit', case when v_amount > 0 then v_amount else 0 end,
        'credit', case when v_amount < 0 then -v_amount else 0 end),
      jsonb_build_object(
        'account_id', v_acct.id,
        'description', v_desc,
        'contact_id', p_contact_id,
        'debit', case when v_amount < 0 then -v_amount else 0 end,
        'credit', case when v_amount > 0 then v_amount else 0 end)),
    p_description => v_desc,
    p_source_table => 'bank_transactions',
    p_source_id => t.id,
    p_reference => t.reference);

  -- Matched to the journal it just became, through the same columns a
  -- match to a receipt uses -- so `unmatch_bank_transaction`,
  -- `bank_reconciliation_status` and the completion stamp all go on
  -- reading one thing.
  update public.bank_transactions
     set matched_table = 'gl_entries', matched_id = v_entry,
         gl_entry_id = v_entry, is_reconciled = true,
         reconciled_at = now(), updated_at = now()
   where id = p_transaction_id;

  return v_entry;
end;
$$;

revoke all on function
  public.post_bank_transaction(uuid, uuid, text, uuid) from public, anon;
grant execute on function
  public.post_bank_transaction(uuid, uuid, text, uuid) to authenticated;

comment on function public.post_bank_transaction(uuid, uuid, text, uuid) is
  'Turns an unmatched statement line into a journal against one chosen '
  'account, and matches the line to it. The other half of bank import: '
  'before `0717` a line could only be matched to something already '
  'posted, so an empty ledger had no way forward at all.';

-- ---------------------------------------------------------------------
-- Unmatching, which now has two cases
-- ---------------------------------------------------------------------
create or replace function public.unmatch_bank_transaction(p_transaction_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  t       public.bank_transactions;
  v_mine  boolean := false;
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

  -- `0717`: an entry this line CREATED has nothing else pointing at
  -- it, so detaching alone would leave it in the ledger unreachable
  -- and leave the line free to post a second one on top.
  if t.gl_entry_id is not null then
    select true into v_mine from public.gl_entries e
     where e.id = t.gl_entry_id
       and e.source_table = 'bank_transactions'
       and e.source_id = t.id
       and e.status = 'posted'
       -- Already reversed by hand: detach and leave it be, rather than
       -- refuse the unmatch over something already put right.
       and not exists (select 1 from public.gl_entries r
                        where r.reversed_entry_id = e.id
                          and r.status = 'posted');
    if coalesce(v_mine, false) then
      perform public.reverse_gl_entry(t.gl_entry_id, t.transaction_date);
    end if;
  end if;

  update public.bank_transactions
     set matched_table = null, matched_id = null, gl_entry_id = null,
         is_reconciled = false, reconciled_at = null, updated_at = now()
   where id = p_transaction_id;
end;
$$;

comment on function public.unmatch_bank_transaction(uuid) is
  'Detaches a statement line from what it was matched to — reversing '
  'the journal first where that journal was posted FROM this line, so '
  'that an undo and a redo cannot double the figure. `0717`.';

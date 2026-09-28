-- =====================================================================
-- iAkauntan :: 0723 the matter a reconciled line belongs to
--
-- The last of the three places `0688` left. Its own note said:
--
--   The Flutter picker is ON THE JOURNAL EDITOR; the bill editor,
--   expense form and bank reconciliation still need it.
--
-- Two of those three turned out to be done already -- `0692` did the
-- expense form and the bill editor carries `matterId` on its header --
-- and reading the code was the only way to find that out. The bank
-- reconciliation is the one that is genuinely missing: the screen has
-- no idea matters exist, and `post_bank_transaction` has no argument to
-- carry one.
--
-- So a solicitor who reconciles a bank statement -- a disbursement paid
-- to a searcher, a court fee, a payment in from a client -- posts a
-- journal that reaches `gl_lines` with `matter_id` null, and the line
-- is invisible to `report_matter_ledger` and `report_matter_trial_balance`.
-- Those two reports are the whole point of `0687`, and the route most
-- likely to feed them was the one route that could not.
--
-- ---------------------------------------------------------------------
-- A parameter, not a column
--
-- `0692` put `matter_id` on `expenses` because an expense is a document
-- somebody fills in, saves as a draft and posts later -- the matter is
-- part of what was entered. A statement line is not that. It arrives
-- from an import with a date, an amount and a description, and
-- everything else about the posting -- which account, which contact --
-- is chosen at the moment of posting, in the dialog, as an argument to
-- this function. The matter is the same kind of thing and travels the
-- same way.
--
-- ---------------------------------------------------------------------
-- WHICH LEG CARRIES IT, which is the decision worth reading
--
-- The chosen account's leg only. NOT the bank's.
--
-- That is `0692`'s convention and this follows it rather than inventing
-- a second one: `post_expense` tags every cost line with the matter and
-- leaves the bank credit untagged, and the SST leg untagged too. Which
-- means a matter's ledger is a record of what was spent and earned ON
-- that matter, and is deliberately NOT a self-balancing set of books --
-- `report_matter_trial_balance` does not foot to zero for one matter
-- and was never meant to.
--
-- Tagging both legs would have made it foot, and would have been wrong:
-- the firm's bank account does not belong to a matter, and a matter
-- ledger showing a negative bank balance for every disbursement is a
-- report nobody asked for and no solicitor would recognise.
--
-- ---------------------------------------------------------------------
-- Dropped and recreated, not overloaded
--
-- `create or replace function` with a different argument count creates a
-- SECOND function rather than replacing the first, and this schema has a
-- gate against exactly that -- `check_ambiguous_overloads.py`, "no two
-- functions answer to one named call". A four-argument call would then
-- resolve to the old body and silently post without the matter, which is
-- the bug this migration exists to fix, still present under a name that
-- looks fixed.
--
-- So the old signature is dropped first. Nothing else in the schema
-- calls it -- the only caller is `Repo.postBankTransaction` -- and the
-- new argument is defaulted, so an app build that has not shipped yet
-- keeps working against it unchanged.
-- =====================================================================

drop function if exists public.post_bank_transaction(uuid, uuid, text, uuid);

create or replace function public.post_bank_transaction(
  p_transaction_id uuid,
  p_account_id uuid,
  p_description text default null,
  p_contact_id uuid default null,
  p_matter_id uuid default null)
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

  -- A matter belonging to another firm is refused by
  -- `gl_lines_matter_same_org` at the table whatever route built the
  -- line -- `0688` -- but the message would be about a composite foreign
  -- key. Said here instead, while there is still a person to tell.
  if p_matter_id is not null
     and not exists (select 1 from public.matters m
                      where m.id = p_matter_id and m.org_id = t.org_id) then
    raise exception 'No such matter in this company.' using errcode = 'P0002';
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
      -- No `matter_id` on the bank's leg, deliberately. See the header:
      -- `post_expense` leaves its bank credit untagged too, and a matter
      -- ledger is what was spent on the matter rather than a balanced
      -- set of books for it.
      jsonb_build_object(
        'account_id', v_bank.account_id,
        'description', v_desc,
        'debit', case when v_amount > 0 then v_amount else 0 end,
        'credit', case when v_amount < 0 then -v_amount else 0 end),
      jsonb_build_object(
        'account_id', v_acct.id,
        'description', v_desc,
        'contact_id', p_contact_id,
        'matter_id', p_matter_id,
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
  public.post_bank_transaction(uuid, uuid, text, uuid, uuid)
  from public, anon;
grant execute on function
  public.post_bank_transaction(uuid, uuid, text, uuid, uuid) to authenticated;

comment on function
  public.post_bank_transaction(uuid, uuid, text, uuid, uuid) is
  'Turns an unmatched statement line into a journal against one chosen '
  'account, and matches the line to it. `p_matter_id` (0723) tags the '
  'CHOSEN account''s leg only, not the bank''s, which is the convention '
  'post_expense set: a matter ledger records what was spent on the '
  'matter and is not a balanced set of books for it.';

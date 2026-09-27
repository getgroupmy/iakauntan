-- =====================================================================
-- iAkauntan :: 0712 a card owes what an account holds
--
-- `bank_accounts.account_type` has permitted `credit_card` since `0003`
-- and nothing has ever read it. A card has therefore been imported as
-- though it were a current account, and the arithmetic of a card runs
-- the other way.
--
-- ---------------------------------------------------------------------
-- What the paper says and what the books mean
--
-- The balance column on a card statement is what you OWE. A purchase
-- raises it; paying the bill lowers it. The balance column on a current
-- account is what you HOLD, and the two move in opposite directions for
-- the same event.
--
-- `bank_transactions.amount` has one meaning across this whole system,
-- fixed by `0085` and relied on in three places:
--
--     amount > 0  -- money in, offer a receipt
--     amount < 0  -- money out, offer a supplier payment or an expense
--
-- Import a card statement as printed and every purchase arrives
-- positive. `suggest_bank_matches` then offers RECEIPTS for the
-- petrol, and the one thing a bookkeeper cannot do is notice that a
-- month of card spending has been filed as income -- the figures are
-- all correct, the account reconciles against itself, and the profit
-- is wrong by the whole of it.
--
-- ---------------------------------------------------------------------
-- The ledger had already decided this
--
-- This is not a convention invented here. `bank_reconciliation_status`
-- computes the book balance as
--
--     sum(debit - credit)
--
-- over the GL account behind the bank account. A card is a LIABILITY,
-- so a card with RM 9,397.28 owing already comes out of that sum as
-- -9,397.28. The books have signed a card negative since `0085`; it is
-- only the importer that has been signing it positive, and a
-- reconciliation between the two could never close.
--
-- So: for an account of type `credit_card`, both figures are stored
-- NEGATED -- the amount and the running balance together. Negating
-- both is what keeps the chain intact (`b = p + a` survives multiplying
-- through by -1), and it is what lets every reader of these two columns
-- go on meaning one thing by them. Negating only the amount would leave
-- `running_balance` saying the opposite of `amount` on the same row,
-- which is the sign bug reintroduced somewhere else in six months.
--
-- ---------------------------------------------------------------------
-- And the message still quotes the paper
--
-- The chain is checked on the figures AS PRINTED, before anything is
-- negated. `0369`'s refusal names three numbers and a person holds the
-- statement while reading it:
--
--     line 3 ... 10088.29 moves by -840.84 and should come to 9247.45,
--     but the statement says ...
--
-- Every one of those has to be findable on the page. A message quoting
-- -10088.29 against a statement printing 10088.29 is a message that
-- sends somebody looking for a line that does not exist.
--
-- `closing_balance` comes back negated, because it is fed straight to
-- `bank_reconciliation_status` as the statement balance to measure the
-- difference against -- and that function's own book balance is already
-- the negative one.
--
-- The `deposit`/`withdrawal` tag follows the stored amount, so a card
-- purchase is a withdrawal. It is money leaving, and it is the word the
-- rest of the system already uses for that.
--
-- Nothing changes for a current, savings, cash or ewallet account: the
-- flag is false and every line of the body below it runs as it did.
--
-- ---------------------------------------------------------------------
-- And nothing is backfilled, because there is nothing to backfill
--
-- Checked before this was written rather than assumed: the live
-- database holds fifteen `current` accounts, two `cash` accounts and
-- sixty-eight statement lines between them. Not one account of type
-- `credit_card` exists, so no row anywhere was imported under the old
-- reading and there is no history to correct.
--
-- Had there been, this migration would still not have touched it. A
-- stored line may already be matched to a posted GL entry and marked
-- reconciled; flipping its sign underneath that would move money in
-- somebody's closed books without a journal, which is a worse failure
-- than the one being fixed. The repair for a card imported before this
-- is to delete the batch and import it again.
-- =====================================================================

create or replace function public.import_bank_transactions(
  p_bank_account_id uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org        uuid;
  v_batch      uuid := gen_random_uuid();
  v_imported   integer := 0;
  v_skipped    integer := 0;
  v_checked    integer := 0;
  v_row        jsonb;
  v_no         integer := 0;
  v_date       date;
  v_amount     numeric(18, 2);
  v_desc       text;
  v_ref        text;
  v_bal        numeric(18, 2);
  v_prev       numeric(18, 2);
  v_prev_no    integer;
  v_prev_amt   numeric(18, 2);
  v_step       numeric(18, 2);
  v_expect     numeric(18, 2);
  v_first      date;
  v_last       date;
  v_newest_first boolean := false;
  v_closing    numeric(18, 2);
  v_close_date date;
  -- A card owes where an account holds. Read once, off the account,
  -- rather than passed in: a caller that had to say so is a caller that
  -- could say the wrong thing.
  v_card       boolean := false;
  v_sign       integer := 1;
  v_store_amt  numeric(18, 2);
  v_store_bal  numeric(18, 2);
begin
  select org_id, account_type = 'credit_card'
    into v_org, v_card
    from public.bank_accounts where id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_card then v_sign := -1; end if;

  -- Which way this statement runs, read off its own dates rather than
  -- assumed. Both orders are ordinary exports.
  select (e.value ->> 'transaction_date')::date into v_first
    from jsonb_array_elements(p_rows) with ordinality e(value, ord)
   where nullif(e.value ->> 'transaction_date', '') is not null
   order by e.ord limit 1;
  select (e.value ->> 'transaction_date')::date into v_last
    from jsonb_array_elements(p_rows) with ordinality e(value, ord)
   where nullif(e.value ->> 'transaction_date', '') is not null
   order by e.ord desc limit 1;
  v_newest_first := v_first is not null and v_last is not null and v_last < v_first;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_no := v_no + 1;
    v_date := nullif(v_row ->> 'transaction_date', '')::date;
    v_amount := round((v_row ->> 'amount')::numeric, 2);
    v_desc := nullif(trim(coalesce(v_row ->> 'description', '')), '');
    v_ref := nullif(trim(coalesce(v_row ->> 'reference', '')), '');
    v_bal := round(nullif(v_row ->> 'running_balance', '')::numeric, 2);

    if v_date is null or v_amount is null then
      raise exception 'Every line needs a date and an amount; got %', v_row
        using errcode = '23514';
    end if;

    -- The arithmetic the statement has to satisfy. Walked the way the
    -- statement runs: forwards the movement is this line's amount,
    -- backwards it is the previous line's, undone.
    if v_bal is not null and v_prev is not null then
      v_step := case when v_newest_first then -v_prev_amt else v_amount end;
      v_expect := round(v_prev + v_step, 2);
      if v_expect <> v_bal then
        raise exception
          'The running balance on line % does not follow line %: % moves '
          'by % and should come to %, but the statement says %. A line is '
          'missing, or one of these figures is wrong.',
          v_no, v_prev_no, v_prev, v_step, v_expect, v_bal
          using errcode = '23514';
      end if;
      v_checked := v_checked + 1;
    end if;
    v_prev := v_bal;
    v_prev_no := v_no;
    v_prev_amt := v_amount;

    -- Checked as printed, stored as the books mean it. Below this line
    -- nothing looks at `v_amount` or `v_bal` again.
    v_store_amt := v_sign * v_amount;
    v_store_bal := v_sign * v_bal;

    -- The balance at the latest date on the statement: the last such
    -- line going forwards, the first going backwards.
    if v_bal is not null
       and (v_close_date is null or v_date > v_close_date
            or (v_date = v_close_date and not v_newest_first)) then
      v_close_date := v_date;
      v_closing := v_bal;
    end if;

    -- Already here. The balance is part of the key when both sides have
    -- one, which is what lets two identical withdrawals on one day both
    -- be imported while the same line pasted twice is still skipped. A
    -- line stored before this migration has no balance to compare, and
    -- is treated as the same line arriving again with more detail —
    -- skipping is the conservative half of that guess.
    if exists (
      select 1 from public.bank_transactions t
       where t.bank_account_id = p_bank_account_id
         and t.transaction_date = v_date
         and t.amount = v_store_amt
         and coalesce(t.description, '') = coalesce(v_desc, '')
         and coalesce(t.reference, '') = coalesce(v_ref, '')
         and (v_store_bal is null or t.running_balance is null
              or t.running_balance = v_store_bal))
    then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.bank_transactions (
      org_id, bank_account_id, transaction_date, description, reference,
      amount, running_balance, transaction_type, import_batch_id, raw_data,
      created_by)
    values (
      v_org, p_bank_account_id, v_date, v_desc, v_ref,
      v_store_amt, v_store_bal,
      case when v_store_amt >= 0 then 'deposit' else 'withdrawal' end,
      v_batch, v_row, auth.uid());

    v_imported := v_imported + 1;
  end loop;

  return jsonb_build_object(
    'batch_id', v_batch, 'imported', v_imported, 'skipped', v_skipped,
    'balance_checks', v_checked,
    'closing_balance', v_sign * v_closing,
    'closing_date', v_close_date);
end;
$$;


revoke all on function public.import_bank_transactions(uuid, jsonb) from public, anon;
grant execute on function public.import_bank_transactions(uuid, jsonb) to authenticated;

comment on function public.import_bank_transactions(uuid, jsonb) is
  'Imports statement lines and checks them against their own running '
  'balance. The balance is the only figure on a statement that can be '
  'checked against the rest of it: a missing line fails the chain on the '
  'line after the hole, and it is what tells two identical withdrawals '
  'from the same line pasted twice. On an account of type credit_card '
  'both the amount and the balance are stored negated, because the '
  'column on a card prints what is owed and the books sign a liability '
  'the other way. 0712.';

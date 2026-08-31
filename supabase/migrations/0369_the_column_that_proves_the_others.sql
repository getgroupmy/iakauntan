-- =====================================================================
-- iAkauntan :: 0369 the column that proves the others
--
-- `bank_transactions.running_balance` has been on the table since 0006
-- and nothing has ever written it. The import in 0085 reads a date, an
-- amount, a description and a reference out of each row and drops the
-- balance the bank printed beside them.
--
-- That column is not decoration. It is the only thing on a statement
-- that can be checked against the rest of the statement. Every other
-- figure is a claim; the running balance is the arithmetic those claims
-- have to satisfy, and a statement with a line missing fails it on the
-- line after the hole.
--
-- ---------------------------------------------------------------------
-- What goes wrong without it
--
-- Two things, and both are silent.
--
-- The first is a line that never arrives. A paste that clips the last
-- rows, a bank export that pages at fifty lines, a row the parser could
-- not read: the import reports what it took and says nothing about what
-- it did not, because it has no way to know. The account is then short
-- by that transaction and the reconciliation is out by its amount, with
-- the difference appearing weeks later as a number nobody can explain.
-- `complete_bank_reconciliation` refuses to close it, correctly, and the
-- person holding it has no idea which line to go and look for.
--
-- The second is the opposite, and it is caused by the fix for the first.
-- 0085 skips a row identical to one already on the account, so that
-- re-importing an overlapping month does not double the shared days.
-- But two identical lines on one day are ordinary — two RM 50 cash
-- withdrawals, two RM 300 standing orders to the same payee — and the
-- importer cannot tell those from a re-import. It drops the second one
-- every time, and the account is short by exactly the amount that looked
-- like a duplicate.
--
-- The running balance separates them. Two genuine withdrawals have two
-- different balances after them; the same line imported twice has the
-- same balance both times. So the balance goes into the key, and both
-- failures stop at once.
--
-- ---------------------------------------------------------------------
-- The chain
--
-- Consecutive lines that both carry a balance must satisfy it:
--
--     balance of this line = balance of the one before + this amount
--
-- and the import refuses the whole statement when they do not, naming
-- the two lines and the figure that does not bridge them. Refusing the
-- whole thing rather than the line is deliberate: a statement with a
-- hole in it is not partly usable, and half of one imported is the same
-- silent shortfall in a different disguise.
--
-- Statements come both ways round. A newest-first export checked
-- forwards fails on its very first pair, and the message would say a
-- line is missing when the only thing wrong is the order — so the
-- direction is read off the dates and the chain is walked the way the
-- statement runs.
--
-- A line with no balance breaks the chain rather than failing it. Half a
-- statement checked is worth more than none, and a bank that prints no
-- balance column is not an error.
--
-- ---------------------------------------------------------------------
-- And the closing figure
--
-- The balance on the last line, returned. `bank_reconciliation_status`
-- measures its difference against a statement balance somebody types,
-- which is one keystroke away from reconciling against a number that is
-- not on the statement at all. Handing it back means the figure the
-- difference is measured against comes from the bank.
--
-- `value_date` is deliberately still unwritten, and this is the place to
-- say why. It is the day the funds become good, which differs from the
-- transaction date on a cheque deposit — and nothing here would read it:
-- the ledger dates the receipt, the matcher measures nearness to the
-- transaction date, and the statement balance already reflects the
-- bank's own treatment. Recording it to no consequence is the failure
-- this migration exists to fix, not a smaller version of the fix.
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
begin
  select org_id into v_org from public.bank_accounts where id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

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
         and t.amount = v_amount
         and coalesce(t.description, '') = coalesce(v_desc, '')
         and coalesce(t.reference, '') = coalesce(v_ref, '')
         and (v_bal is null or t.running_balance is null
              or t.running_balance = v_bal))
    then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.bank_transactions (
      org_id, bank_account_id, transaction_date, description, reference,
      amount, running_balance, transaction_type, import_batch_id, raw_data,
      created_by)
    values (
      v_org, p_bank_account_id, v_date, v_desc, v_ref, v_amount, v_bal,
      case when v_amount >= 0 then 'deposit' else 'withdrawal' end,
      v_batch, v_row, auth.uid());

    v_imported := v_imported + 1;
  end loop;

  return jsonb_build_object(
    'batch_id', v_batch, 'imported', v_imported, 'skipped', v_skipped,
    'balance_checks', v_checked,
    'closing_balance', v_closing,
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
  'from the same line pasted twice.';

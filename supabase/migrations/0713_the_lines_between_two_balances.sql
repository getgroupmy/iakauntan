-- =====================================================================
-- iAkauntan :: 0713 the lines between two balances
--
-- `0369` built the only defence there is against a statement that
-- arrived with a line missing: consecutive lines that both carry a
-- running balance must bridge.
--
--     balance of this line = balance of the one before + this amount
--
-- It is the right check. It is also, on the statements people actually
-- upload, almost never performed.
--
-- ---------------------------------------------------------------------
-- Measured, on a real one
--
-- Hong Leong prints a running balance only where a day's activity
-- closes -- not on every line. On a nine-page current account statement
-- from that bank:
--
--     95 transaction lines
--     21 carry a balance
--     74 do not
--
-- `0369` reads a line with no balance as BREAKING the chain rather than
-- failing it, and said why: "Half a statement checked is worth more
-- than none, and a bank that prints no balance column is not an error."
-- True, and the consequence was not noticed -- on this bank it is not
-- half a statement that goes unchecked but seventy-eight per cent of
-- it, and the lines most likely to be dropped by a reader (the middle
-- of a long page, the run without a balance beside it) are exactly the
-- ones nothing looks at.
--
-- ---------------------------------------------------------------------
-- The span, which is the same arithmetic applied across the gap
--
-- Two printed balances with any number of unbalanced lines between them
-- still have to satisfy the statement:
--
--     later balance = earlier balance + sum of every amount between
--
-- That is not a new rule. It is `0369`'s rule with the restriction to
-- ADJACENT lines removed, and a span of one line is the old check
-- exactly. Nothing that passed before fails now for a different reason;
-- what changes is that the seventy-four lines Hong Leong prints without
-- a balance are now inside a span that is checked, instead of outside
-- every check there is.
--
-- A dropped line in the middle of a run now fails at the end of that
-- run. It used to fail nowhere.
--
-- ---------------------------------------------------------------------
-- Both directions, still read off the dates
--
-- `0369` reads the statement's direction from its own dates because
-- both orders are ordinary exports, and the span has to run the same
-- way. Forwards, the balance printed on a line is the one before it
-- plus everything from the line after that balance down to this one.
-- Backwards, going down the page is going back in time, so the balance
-- printed on a line is the previous balance MINUS everything from that
-- previous line down to the one above this.
--
-- A span of one collapses to `+ this amount` and `- the previous
-- amount`, which is what `0369` wrote.
--
-- ---------------------------------------------------------------------
-- And the message has to name a range now
--
-- `0369`'s refusal named two lines because there were only ever two.
-- A span covers a run, and a person holding the statement needs to know
-- where to start looking:
--
--     The running balance on line 12 does not follow line 4: 39088.45
--     moves by -33712.01 over lines 5 to 12 and should come to 5376.44,
--     but the statement says 5000.00. A line is missing, or one of
--     these figures is wrong.
--
-- Still the whole statement refused rather than the line, for `0369`'s
-- reason unchanged: a statement with a hole in it is not partly usable.
--
-- `0712`'s card handling is untouched -- the check runs on the figures
-- as printed, before anything is negated, and the span is computed from
-- the same figures.
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
  v_step       numeric(18, 2);
  v_expect     numeric(18, 2);
  -- What the lines since the last printed balance add up to, and which
  -- line that balance was on. `0369` could hold one amount because a
  -- span was always one line long.
  v_span       numeric(18, 2) := 0;
  -- How many LINES sit inside a span that closed and held. `checked`
  -- counts spans, and on a bank that prints one balance a day the two
  -- numbers are nothing like each other: a screen reporting spans would
  -- tell somebody 20 where 95 lines were proved.
  v_proved     integer := 0;
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

    -- The arithmetic the statement has to satisfy, across the whole run
    -- of lines since the last balance was printed rather than across
    -- one pair. A span of one line is `0369`'s check unchanged.
    --
    -- Backwards, the span is closed BEFORE this line's amount joins it:
    -- going down a newest-first page is going back in time, so the
    -- balance printed here is the previous balance with everything from
    -- that line down to the one above this taken back off.
    if v_newest_first then
      if v_bal is not null then
        if v_prev is not null then
          v_step := -v_span;
          v_expect := round(v_prev + v_step, 2);
          if v_expect <> v_bal then
            raise exception
              'The running balance on line % does not follow line %: % '
              'moves by % over lines % to % and should come to %, but the '
              'statement says %. A line is missing, or one of these '
              'figures is wrong.',
              v_no, v_prev_no, v_prev, v_step, v_prev_no, v_no - 1,
              v_expect, v_bal
              using errcode = '23514';
          end if;
          v_checked := v_checked + 1;
          v_proved := v_proved + (v_no - v_prev_no);
        end if;
        v_prev := v_bal;
        v_prev_no := v_no;
        v_span := 0;
      end if;
      v_span := round(v_span + v_amount, 2);
    else
      v_span := round(v_span + v_amount, 2);
      if v_bal is not null then
        if v_prev is not null then
          v_step := v_span;
          v_expect := round(v_prev + v_step, 2);
          if v_expect <> v_bal then
            raise exception
              'The running balance on line % does not follow line %: % '
              'moves by % over lines % to % and should come to %, but the '
              'statement says %. A line is missing, or one of these '
              'figures is wrong.',
              v_no, v_prev_no, v_prev, v_step, v_prev_no + 1, v_no,
              v_expect, v_bal
              using errcode = '23514';
          end if;
          v_checked := v_checked + 1;
          v_proved := v_proved + (v_no - v_prev_no);
        end if;
        v_prev := v_bal;
        v_prev_no := v_no;
        v_span := 0;
      end if;
    end if;

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
    'lines_proved', v_proved,
    'closing_balance', v_sign * v_closing,
    'closing_date', v_close_date);
end;
$$;


revoke all on function public.import_bank_transactions(uuid, jsonb) from public, anon;
grant execute on function public.import_bank_transactions(uuid, jsonb) to authenticated;

comment on function public.import_bank_transactions(uuid, jsonb) is
  'Imports statement lines and checks them against their own running '
  'balance. Two printed balances must bridge across every line between '
  'them, not only where the bank prints one on each line -- Hong Leong '
  'prints 21 on a 95-line statement, and under the adjacent-pairs rule '
  'the other 74 were checked by nothing at all. On an account of type '
  'credit_card both the amount and the balance are stored negated, '
  'because the column on a card prints what is owed and the books sign '
  'a liability the other way. 0369, 0712, 0713.';

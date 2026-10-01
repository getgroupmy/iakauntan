-- =====================================================================
-- iAkauntan :: 0727 an expense says which account it was paid from
--
-- Asked for: "make the paid from required when recording an expense".
--
-- ---------------------------------------------------------------------
-- What it was doing instead
--
-- `post_expense` fell back to account code `1120` when
-- `expenses.bank_account_id` was null. `1120` is "Bank Accounts" -- the
-- CONTROL account, the parent, not any particular bank. So an expense
-- saved with the "Paid from" box left blank was posted like this:
--
--     Dr  6250 Transport and Travelling   22.50
--     Cr  1120 Bank Accounts              22.50
--
-- which says the money left the bank, names no bank, and therefore
-- appears on NO bank reconciliation -- because a reconciliation is run
-- per account and that credit belongs to none of them. The balance of
-- 1120 then grows by every such expense and is reconcilable against
-- nothing at all.
--
-- It was invisible as well as wrong. Until `1eafa71b` the expense
-- dialog did not show the bank account at all, so the one screen
-- somebody would look at to check could not have told them.
--
-- ---------------------------------------------------------------------
-- Why the database and not only the form
--
-- `app/lib/.../expenses_screen.dart` now refuses to save without one,
-- and that is where somebody finds out. It is not where the rule lives:
-- `expenses` is an ordinary table that the client inserts into directly
-- under RLS, so a rule enforced only in Dart is enforced only for
-- whoever uses the app as written. This function is the one place every
-- expense must pass through to reach the ledger.
--
-- ---------------------------------------------------------------------
-- What it does NOT do
--
-- It does not touch a single existing row. The guard runs when an
-- expense is POSTED, and an expense already posted is refused before it
-- by `gl_entry_id is not null` -- so nothing already in the books is
-- re-examined, re-posted or repaired. Production holds exactly one
-- expense with no bank account (EXP-2026-00001, posted, RM22.50 against
-- 1120) and this migration leaves it exactly where it is. Correcting it
-- is a reversal and a re-entry, which is somebody's decision and a
-- different verb.
--
-- It also does not make the COLUMN `not null`. An expense is a row
-- before it is a posting -- a draft, a scan half way through being
-- read -- and a column constraint would refuse the draft, which is the
-- wrong moment to ask. The question belongs at the point the money is
-- claimed to have moved.
--
-- ---------------------------------------------------------------------
-- And a second lookup tightened on the way past
--
-- The bank account is now found by `id AND org_id`. It was found by
-- `id` alone, so a bank account belonging to another company would
-- have resolved and been credited. Nothing in production does this --
-- checked, zero rows -- and `0160` is where a bank account stopped
-- being shared between companies; this is the posting side of the same
-- rule, which had been left out.
--
-- Restated whole because PostgreSQL has no way to amend a function.
-- The base is byte-identical to what was live: `0692`'s text hashes to
-- aca7cba9ca5124c86c1e6b247e0532fe, which is
-- md5(pg_get_functiondef('public.post_expense(uuid)')) on production,
-- so what follows is that text and these two changes and nothing else.
-- =====================================================================

create or replace function public.post_expense(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$

declare
  v_exp       public.expenses;
  v_entries   jsonb := '[]'::jsonb;
  v_bank_acct uuid;
  v_entry_id  uuid;
  v_rate      numeric(18, 8);
  v_total     numeric(18, 2);
  v_tax       numeric(18, 2);
  v_net       numeric(18, 2);
  v_run       numeric(18, 2) := 0;
  v_big       uuid;
  v_share     numeric(18, 2);
  r           record;
begin
  select * into v_exp from public.expenses where id = p_id;
  if not found then raise exception 'Expense % not found', p_id; end if;

  -- A deleted expense is not a document. `post_sales_document`,
  -- `post_receipt_internal` and `post_purchase_document` all refuse one;
  -- this was the only posting function in the schema that did not, so an
  -- expense somebody had removed from the list could still be put in the
  -- accounts, where no screen would ever show it to them again.
  if v_exp.deleted_at is not null then
    raise exception 'Expense % has been deleted', v_exp.expense_no
      using errcode = 'P0002';
  end if;

  if not app.can_post(v_exp.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_exp.gl_entry_id is not null then
    raise exception 'Expense % is already posted', v_exp.expense_no;
  end if;

  -- Said plainly, and before the conversion, so the person who saved it
  -- is told which number is wrong rather than what the ledger thought of
  -- the result.
  if v_exp.total_amount is distinct from v_exp.amount + v_exp.tax_amount then
    raise exception
      'Expense % totals %, but its cost and tax come to %',
      v_exp.expense_no, v_exp.total_amount, v_exp.amount + v_exp.tax_amount
      using errcode = '23514';
  end if;

  v_rate := coalesce(v_exp.exchange_rate, 1);

  -- Once, into a variable. The credit leg and the balance adjustment
  -- have to be the same number, and computing `round(total * rate, 2)`
  -- twice is how they stop being.
  v_total := round(v_exp.total_amount * v_rate, 2);
  v_tax   := round(coalesce(v_exp.tax_amount, 0) * v_rate, 2);

  -- 0727. Which account the money left is not optional any more.
  --
  -- What this replaces is a fallback to account `1120`, the BANK
  -- CONTROL account -- so an expense saved without a bank account was
  -- posted as though the money had left the bank, against no bank in
  -- particular, and appeared on no reconciliation anywhere. A
  -- reconciliation is per account, and that posting belonged to none.
  if v_exp.bank_account_id is null then
    raise exception
      'Expense % does not say which account it was paid from. Every '
      'payment leaves an account, and one that names none cannot be '
      'reconciled against any statement. Choose the bank account, card '
      'or petty cash float the money came out of.', v_exp.expense_no
      using errcode = '23514';
  end if;

  -- `b.org_id` as well as `b.id`, so a bank account belonging to
  -- another company cannot be credited by this one. `0160` is where a
  -- bank account stopped being shared; this is the posting side of it.
  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_exp.bank_account_id and b.org_id = v_exp.org_id;
  if v_bank_acct is null then
    raise exception
      'The account expense % was paid from is not one of this '
      'company''s, or has no line in the chart of accounts yet.',
      v_exp.expense_no
      using errcode = 'P0002';
  end if;

  -- The total less the tax, not the cost converted on its own. See the
  -- header of 0009: this is the leg that absorbs the conversion, because
  -- the other two answer to a bank statement and to a tax return.
  v_net := v_total - v_tax;

  select id into v_big from public.expense_lines
   where expense_id = p_id
   order by amount desc, line_no
   limit 1;

  if v_big is null then
    -- No split. Exactly what this function has always done.
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_exp.account_id,
      'description', coalesce(v_exp.description,
                              'Expense ' || v_exp.expense_no),
      'debit', v_net, 'credit', 0,
      'contact_id', v_exp.contact_id, 'project_code', v_exp.project_code,
      'department_code', v_exp.department_code,
      'matter_id', v_exp.matter_id);
  else
    -- Every line but the largest converted on its own; see the header
    -- for why the largest takes what is left rather than the first.
    for r in select * from public.expense_lines
              where expense_id = p_id and id <> v_big
    loop
      v_run := v_run + round(r.amount * v_rate, 2);
    end loop;

    for r in select * from public.expense_lines
              where expense_id = p_id
              order by line_no
    loop
      if r.id = v_big then
        v_share := v_net - v_run;
      else
        v_share := round(r.amount * v_rate, 2);
      end if;
      v_entries := v_entries || jsonb_build_object(
        'account_id', r.account_id,
        'description', coalesce(r.description, v_exp.description,
                                'Expense ' || v_exp.expense_no),
        'debit', v_share, 'credit', 0,
        'contact_id', v_exp.contact_id,
        'project_code', coalesce(r.project_code, v_exp.project_code),
        'department_code', coalesce(r.department_code,
                                    v_exp.department_code),
        'matter_id', coalesce(r.matter_id, v_exp.matter_id));
    end loop;
  end if;

  if coalesce(v_exp.tax_amount, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = v_exp.org_id and code = '1410'),
      'description', 'SST input tax',
      'debit', v_tax, 'credit', 0,
      'tax_code_id', v_exp.tax_code_id,
      'tax_amount', v_tax);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Expense ' || v_exp.expense_no,
    'debit', 0, 'credit', v_total);

  v_entry_id := public.create_gl_entry(
    v_exp.org_id, v_exp.expense_date, 'manual'::app.journal_source, v_entries,
    'Expense ' || v_exp.expense_no, 'expenses', v_exp.id, v_exp.reference,
    v_exp.currency, v_rate);

  update public.expenses
     set gl_entry_id = v_entry_id, status = 'posted', posted_at = now()
   where id = p_id;

  -- Keep the cached bank balance in step with the journal.
  --
  -- Unconditional now. It used to be wrapped in `if bank_account_id is
  -- not null`, because an expense without one was posted to the control
  -- account and had no `bank_accounts` row to adjust. There is no such
  -- expense any more -- the guard at the top refuses it -- so the
  -- condition could only ever be true, and a conditional that cannot be
  -- false reads as a case somebody still has to think about.
  update public.bank_accounts
     set current_balance = current_balance - v_total
   where id = v_exp.bank_account_id;

  return v_entry_id;
end;

$$;

comment on function public.post_expense(uuid) is
  'Posts an expense to the ledger. Refuses one that does not say which '
  'account it was paid from: the fallback to the 1120 control account '
  'put money on no reconciliation at all. 0727.';

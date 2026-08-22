-- =====================================================================
-- iAkauntan :: 0286 the expense that could not be posted
--
-- `post_expense` converts a foreign-currency expense one leg at a time
-- and the credit all at once, and those are not the same arithmetic:
--
--   debit  cost   round(amount     * rate, 2)
--   debit  tax    round(tax_amount * rate, 2)
--   credit bank   round(total      * rate, 2)
--
-- Where the cost and the tax each round up and the total does not, the
-- debits come to a cent more than the credit and `create_gl_entry`
-- refuses the journal. 10.05 with 0.85 tax at 1.5 is the smallest
-- realistic case: 15.075 and 1.275 each round up to make 16.36, against
-- a total of 10.90 at 1.5 which is exactly 16.35.
--
-- The expense cannot be posted at all — not wrongly, not at half the
-- value, simply not — and the message is "Journal does not balance:
-- debits 16.36, credits 16.35", which is about the ledger and gives
-- nobody a reason to look at the exchange rate. Nothing is left in a
-- half state, because the whole thing is one transaction; the expense
-- just stays a draft and the person who raised it is told the accounts
-- are broken.
--
-- ---------------------------------------------------------------------
-- Which leg absorbs it
--
-- Not an arbitrary choice. Two of the three figures are answerable to
-- somebody outside the company:
--
--   * the credit is what left the bank, and it is reconciled line by
--     line against a statement. It has to stay the total converted once;
--   * the tax is what the SST-02 return is built from, so it has to
--     stay the tax converted at the rate on the document.
--
-- That leaves the cost, which is answerable to nobody in particular at
-- the level of a cent, so the cost is derived — the total less the tax
-- — rather than converted independently. The three legs then sum by
-- construction, at every rate, without a rounding rule anywhere.
--
-- ---------------------------------------------------------------------
-- The guard this replaces
--
-- `total_amount` is an ordinary column with a default of zero. Nothing
-- in the schema keeps it equal to `amount + tax_amount` — the app
-- computes it — so an expense saved with a total that disagrees with
-- its own parts was until now refused by accident, by the same balance
-- check, with the same unhelpful message.
--
-- Deriving the cost leg would swallow that instead, and a cost silently
-- adjusted to make a wrong total balance is worse than a refusal. So the
-- disagreement is now refused deliberately, in the expense's own words,
-- before any of the arithmetic happens. What the derivation absorbs is
-- only ever the sub-cent difference between converting twice and
-- converting once, which cannot exceed a cent.
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

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_exp.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_exp.org_id and code = '1120';
  end if;

  -- The total less the tax, not the cost converted on its own. See the
  -- header: this is the leg that absorbs the conversion, because the
  -- other two answer to a bank statement and to a tax return.
  v_entries := v_entries || jsonb_build_object(
    'account_id', v_exp.account_id,
    'description', coalesce(v_exp.description, 'Expense ' || v_exp.expense_no),
    'debit', v_total - v_tax, 'credit', 0,
    'contact_id', v_exp.contact_id, 'project_code', v_exp.project_code);

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

  -- Keep the cached bank balance in step with the journal. Only when the
  -- expense actually names a bank account: one paid in cash falls back
  -- to account 1120 above for the ledger leg, and there is no
  -- `bank_accounts` row to adjust.
  if v_exp.bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance - v_total
     where id = v_exp.bank_account_id;
  end if;

  return v_entry_id;
end;
$$;

revoke all on function public.post_expense(uuid) from public, anon;
grant execute on function public.post_expense(uuid) to authenticated;

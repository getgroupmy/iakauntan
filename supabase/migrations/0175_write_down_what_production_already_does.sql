-- Two things the hosted project has that no migration ever wrote down.
--
-- Found by `scripts/schema_drift.py` on its first live run. Both are the
-- same failure as `0174`, in the same direction: **production is
-- correct and the repository is stale**, so the damage is confined to
-- deployments built from these files — of which there are none yet.
--
-- ## `post_expense` did not keep the bank balance in step
--
-- `bank_accounts.current_balance` is a cached figure. Every other
-- posting routine that touches a bank account maintains it — receipts,
-- purchase payments, transfers, withholding remittance all adjust it in
-- the same statement that writes the journal.
--
-- `post_expense` in `0013_posting.sql` does not. It writes a balanced
-- entry crediting the bank's GL account and returns, leaving the cached
-- balance untouched. So on a deployment built from these files, paying
-- an expense from a bank account moves the ledger and not the number the
-- banking screen shows, and the two drift apart by the whole value of
-- every expense ever paid.
--
-- The hosted project has the fix. Somebody applied it there and never
-- wrote the migration.
--
-- ## `resync_bank_balance` is its companion, and also unwritten
--
-- Rebuilds the cached balance from posted ledger lines. It is what
-- somebody reaches for when the cache has already drifted — which,
-- given the above, it had. It exists on the hosted project and in no
-- file.
--
-- It assumes one bank account maps to its own GL account, which is the
-- normal setup here and is what the hosted project's own comment on the
-- function says. That assumption is why this is a repair tool rather
-- than something called automatically.
--
-- ## Not included: `rls_auto_enable`
--
-- The drift run also reported `public.rls_auto_enable` as present on the
-- hosted project and absent from the migrations. It is deliberately not
-- reproduced here. It is Supabase's own — the platform's automatic
-- row-level-security toggle, recognisable by its `RAISE LOG
-- 'rls_auto_enable: ...'` messages and its hardcoded schema allow-list —
-- and writing a copy of somebody else's platform function into this
-- repository would mean maintaining a fork of it forever. It is
-- excluded from the comparison instead, in `scripts/schema_drift.py`,
-- alongside the default privileges it keeps company with.

-- ---------------------------------------------------------------------
-- The expense posting, as the hosted project has run it all along
-- ---------------------------------------------------------------------
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
begin
  select * into v_exp from public.expenses where id = p_id;
  if not found then raise exception 'Expense % not found', p_id; end if;
  if not app.can_post(v_exp.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_exp.gl_entry_id is not null then
    raise exception 'Expense % is already posted', v_exp.expense_no;
  end if;

  v_rate := coalesce(v_exp.exchange_rate, 1);

  -- Once, into a variable. The credit leg and the balance adjustment
  -- have to be the same number, and computing `round(total * rate, 2)`
  -- twice is how they stop being.
  v_total := round(v_exp.total_amount * v_rate, 2);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_exp.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_exp.org_id and code = '1120';
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_exp.account_id,
    'description', coalesce(v_exp.description, 'Expense ' || v_exp.expense_no),
    'debit', round(v_exp.amount * v_rate, 2), 'credit', 0,
    'contact_id', v_exp.contact_id, 'project_code', v_exp.project_code);

  if coalesce(v_exp.tax_amount, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = v_exp.org_id and code = '1410'),
      'description', 'SST input tax',
      'debit', round(v_exp.tax_amount * v_rate, 2), 'credit', 0,
      'tax_code_id', v_exp.tax_code_id,
      'tax_amount', round(v_exp.tax_amount * v_rate, 2));
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

-- ---------------------------------------------------------------------
-- Putting the cache back when it has already slipped
-- ---------------------------------------------------------------------
create or replace function public.resync_bank_balance(p_bank_account_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bank    public.bank_accounts;
  v_balance numeric(18, 2);
begin
  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if not found then
    raise exception 'Bank account % not found', p_bank_account_id;
  end if;
  if not app.can_post(v_bank.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_balance
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_bank.account_id
     and e.status = 'posted';

  update public.bank_accounts
     set current_balance = v_bank.opening_balance + v_balance
   where id = p_bank_account_id;

  return v_bank.opening_balance + v_balance;
end;
$$;

comment on function public.resync_bank_balance(uuid) is
  'Rebuilds bank_accounts.current_balance from posted ledger lines. '
  'Assumes each bank account maps to its own GL account, which is the '
  'normal setup.';

-- `0165`'s event trigger has already stripped PUBLIC and anon from both.
grant execute on function public.post_expense(uuid) to authenticated;
grant execute on function public.resync_bank_balance(uuid) to authenticated;

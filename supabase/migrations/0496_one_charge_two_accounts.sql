-- ---------------------------------------------------------------------
-- 0496  One charge, two accounts
-- ---------------------------------------------------------------------
-- An expense names one account. A card statement does not: the RM 500
-- on the 14th was RM 320 of flights and RM 180 of client entertainment,
-- and the only way to record that here has been to type two expenses,
-- give them two numbers, split the receipt between them by hand and
-- hope nobody reconciling the card statement later wonders why RM 500
-- left the bank as two payments.
--
-- `docs/gaps-against-akaunting.md` has listed this as "split
-- transaction" since the register was written.
--
-- ### What changes
--
-- `expense_lines`: an account, an amount, its own tax and its own
-- project code, as many as the charge needs. An expense with no lines
-- behaves exactly as it always has -- the header account takes the
-- whole debit -- so nothing already recorded moves.
--
-- The split *is* the expense, so `set_expense_split` writes the header
-- from the lines rather than validating one against the other. There is
-- no state in which the parts and the total disagree, because the total
-- is not separately typed once a split exists. The header's
-- `account_id` follows the largest line, which is what a one-line
-- report of the expense should say it was for.
--
-- ### The cent
--
-- A split expense in a foreign currency is the place this goes wrong.
-- The credit leg answers to a bank statement and the tax leg answers to
-- a tax return, so neither may be adjusted; the debits are what must
-- add up. Converting each line on its own and adding them can miss the
-- converted total by a cent, so every line but the largest is converted
-- on its own and the largest takes what is left. The largest, because
-- a cent lands least visibly on the biggest number.
--
-- ### Mutants
--
-- Run against `supabase/tests/expense_split.sql`. Nine, and only four
-- die on the assertion that was written for them; the rest die on
-- something older, which is worth saying plainly rather than tidying
-- away:
--   * the lines not posted at all -- "each account is debited its own
--     share";
--   * the residual put on the first line rather than the largest --
--     "the two smaller lines convert on their own";
--   * the header not written from the lines -- "the header follows the
--     split";
--   * the guard dropped from the setter -- "a reader cannot split an
--     expense";
--   * splitting a posted expense allowed -- "a posted expense cannot be
--     re-split";
--   * the residual dropped, every line converted on its own -- killed
--     by the ledger itself, which refuses the entry with "Journal does
--     not balance: debits 377.74, credits 377.75". That is exactly the
--     failure the residual exists to prevent, so the ledger is the
--     right thing to be caught by; what the assertion "a split in a
--     foreign currency still balances" adds is that the file names the
--     currency block when it happens;
--   * the old single-account path lost -- also the ledger's balance
--     check, in the block asserting "an expense with no split posts as
--     it always did": an expense with no lines would post its tax and
--     its credit and no debit at all;
--   * the split not scoped to its own expense -- killed by
--     `gl_lines_account_same_org`, the foreign key that keeps one
--     company's journal out of another company's chart. An unscoped
--     read reaches every split in the database, so it trips that
--     before it reaches "and not another expense's share", which is
--     what would catch it within one company;
--   * an account from another company accepted -- refused by this
--     migration's own self-check, which will not install a setter that
--     has lost `org_id = v_exp.org_id`, so it never reaches the suite.
--     "a company cannot split an expense into somebody else's account"
--     would have caught it had it got that far.
-- ---------------------------------------------------------------------

create table if not exists public.expense_lines (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  expense_id    uuid not null references public.expenses(id)
                  on delete cascade,
  line_no       integer not null,
  account_id    uuid not null references public.accounts(id),
  description   text,
  amount        numeric(18, 2) not null check (amount > 0),
  tax_code_id   uuid references public.tax_codes(id),
  tax_amount    numeric(18, 2) not null default 0 check (tax_amount >= 0),
  project_code  text,
  created_at    timestamptz not null default now(),
  unique (expense_id, line_no)
);

create index if not exists expense_lines_expense_idx
  on public.expense_lines (org_id, expense_id);

comment on table public.expense_lines is
  'One charge divided across several accounts. No rows means the '
  'expense''s own account_id takes the whole debit, which is how every '
  'expense before 0496 behaves.';

-- ---------------------------------------------------------------------
-- Row level security
--
-- The same standard as `expenses` itself, which is `can_write` and not
-- `can_post`: whoever may record the expense may say what it was for.
-- ---------------------------------------------------------------------
alter table public.expense_lines enable row level security;

create policy expense_lines_select on public.expense_lines
  for select to authenticated using (app.is_org_member(org_id));
create policy expense_lines_write on public.expense_lines
  for all to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));

create policy module_gate_select on public.expense_lines
  as restrictive for select to authenticated
  using (app.can_read_module(org_id, 'purchases'));
create policy module_gate_insert on public.expense_lines
  as restrictive for insert to authenticated
  with check (app.can_write_module(org_id, 'purchases'));
create policy module_gate_update on public.expense_lines
  as restrictive for update to authenticated
  using (app.can_write_module(org_id, 'purchases'))
  with check (app.can_write_module(org_id, 'purchases'));
create policy module_gate_delete on public.expense_lines
  as restrictive for delete to authenticated
  using (app.can_write_module(org_id, 'purchases'));


-- Supabase's own default privileges hand `anon` every new table in
-- `public`. 0165's event trigger strips that from functions and not
-- from tables, so a new table is readable by a stranger from the moment
-- it exists unless this line is here. Taken away before anything is
-- granted -- and see 0413, which does the same for
-- `sales_gateway_payments`.
revoke all on public.expense_lines from anon, authenticated, public;
grant select, insert, update, delete on public.expense_lines
  to authenticated;

-- ---------------------------------------------------------------------
-- Setting the split
--
-- Replaces the whole split in one call, because a split is one thought:
-- editing it line by line from a screen would leave the header
-- disagreeing with the parts in between calls.
-- ---------------------------------------------------------------------
create or replace function public.set_expense_split(
  p_expense_id uuid, p_lines jsonb)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_exp    public.expenses;
  v_line   jsonb;
  v_no     integer := 0;
  v_acct   uuid;
  v_amount numeric(18, 2);
  v_tax    numeric(18, 2);
  v_big    uuid;
begin
  select * into v_exp from public.expenses where id = p_expense_id;
  if not found then
    raise exception 'Expense % not found', p_expense_id
      using errcode = 'P0002';
  end if;
  if v_exp.deleted_at is not null then
    raise exception 'Expense % has been deleted', v_exp.expense_no
      using errcode = 'P0002';
  end if;
  if not app.can_write(v_exp.org_id) then
    raise exception 'Insufficient privileges to edit an expense'
      using errcode = '42501';
  end if;
  -- Posted is posted. Changing what an expense was for after it is in
  -- the ledger is a journal, not an edit.
  if v_exp.gl_entry_id is not null then
    raise exception 'Expense % is already posted', v_exp.expense_no
      using errcode = '23514';
  end if;

  delete from public.expense_lines where expense_id = p_expense_id;

  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    return 0;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_no := v_no + 1;
    v_acct := nullif(v_line ->> 'account_id', '')::uuid;
    v_amount := round(coalesce((v_line ->> 'amount')::numeric, 0), 2);
    v_tax := round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2);

    if v_amount <= 0 then
      raise exception 'Line % of expense % has no amount',
        v_no, v_exp.expense_no using errcode = '23514';
    end if;
    -- The account has to be this company's. Without this an id typed
    -- into a request body posts one company's spending into another
    -- company's ledger, and both would look right on their own screen.
    if v_acct is null or not exists (
         select 1 from public.accounts
          where id = v_acct and org_id = v_exp.org_id) then
      raise exception 'Line % of expense % names an unknown account',
        v_no, v_exp.expense_no using errcode = '23503';
    end if;

    insert into public.expense_lines
      (org_id, expense_id, line_no, account_id, description, amount,
       tax_code_id, tax_amount, project_code)
    values (v_exp.org_id, p_expense_id, v_no, v_acct,
            nullif(v_line ->> 'description', ''), v_amount,
            nullif(v_line ->> 'tax_code_id', '')::uuid, v_tax,
            nullif(v_line ->> 'project_code', ''));
  end loop;

  -- The header follows the split, not the other way round.
  select account_id into v_big from public.expense_lines
   where expense_id = p_expense_id
   order by amount desc, line_no
   limit 1;

  update public.expenses e
     set amount = s.base,
         tax_amount = s.tax,
         total_amount = s.base + s.tax,
         account_id = v_big,
         updated_at = now()
    from (select sum(amount) as base, sum(tax_amount) as tax
            from public.expense_lines where expense_id = p_expense_id) s
   where e.id = p_expense_id;

  return v_no;
end;
$$;

comment on function public.set_expense_split(uuid, jsonb) is
  'Replace an expense''s split. The header amount, tax and account are '
  'written from the lines. See 0496.';

revoke all on function public.set_expense_split(uuid, jsonb)
  from public, anon;
grant execute on function public.set_expense_split(uuid, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Reading it back
--
-- Security invoker on purpose: the rows are behind RLS already and this
-- is only here to save the caller a join for the account's name.
-- ---------------------------------------------------------------------
create or replace function public.expense_split(p_expense_id uuid)
returns table(id uuid, line_no integer, account_id uuid,
              account_code text, account_name text, description text,
              amount numeric, tax_code_id uuid, tax_amount numeric,
              project_code text)
language sql stable
set search_path = public, app, pg_temp as $$
  select l.id, l.line_no, l.account_id, a.code::text, a.name::text,
         l.description, l.amount, l.tax_code_id, l.tax_amount,
         l.project_code
    from public.expense_lines l
    left join public.accounts a on a.id = l.account_id
   where l.expense_id = p_expense_id
   order by l.line_no;
$$;

revoke all on function public.expense_split(uuid) from public, anon;
grant execute on function public.expense_split(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Posting it
--
-- Restated from the built definition. 0009 wrote it and later
-- migrations added the deleted-expense refusal, the totals check and
-- the single-conversion rule; rebuilding from any one of those would
-- drop the others.
-- ---------------------------------------------------------------------
create or replace function public.post_expense(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_exp.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_exp.org_id and code = '1120';
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
      'contact_id', v_exp.contact_id, 'project_code', v_exp.project_code);
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
        'project_code', coalesce(r.project_code, v_exp.project_code));
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
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_post text := pg_get_functiondef('public.post_expense(uuid)'::regprocedure);
  v_set  text := pg_get_functiondef(
    'public.set_expense_split(uuid, jsonb)'::regprocedure);
begin
  if position('expense_lines' in v_post) = 0 then
    raise exception '0496: posting still ignores the split';
  end if;
  -- The three rules the restatement inherited and must not have lost.
  if position('deleted_at is not null' in v_post) = 0
     or position('can_post' in v_post) = 0
     or position('gl_entry_id is not null' in v_post) = 0 then
    raise exception '0496: posting lost a rule it already had';
  end if;
  if position('can_write' in v_set) = 0 then
    raise exception '0496: anybody who can read can split an expense';
  end if;
  if position('org_id = v_exp.org_id' in v_set) = 0 then
    raise exception '0496: the split does not check whose account it is';
  end if;
  if not exists (select 1 from pg_policies
                  where tablename = 'expense_lines'
                    and policyname = 'module_gate_select') then
    raise exception '0496: the split is outside the purchases module gate';
  end if;
  if has_table_privilege('anon', 'public.expense_lines', 'select')
     or has_function_privilege('anon',
          'public.set_expense_split(uuid, jsonb)', 'execute') then
    raise exception '0496: a stranger can read or write a split';
  end if;
end $do$;

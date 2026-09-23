-- =====================================================================
-- iAkauntan :: 0692 the matter a claimed cost belongs to
--
-- `0691` put the matter on what a firm bills and buys. The third way a
-- cost reaches the ledger is an expense claim, and that is the one a
-- law firm uses most: a fee earner pays a filing fee at the counter, a
-- courier, a commissioner for oaths, and claims it back.
--
-- `0639` is this migration's twin, written for the department and for
-- the same reason -- a dimension the ledger could hold and expenses had
-- no column to put anything in, so every claimed cost reached the books
-- with it null however carefully the claim was coded. Its header says
-- why that shape of hole is the worst one: a matter whose disbursements
-- came in through expenses reads as a matter that SPENT LESS, and a
-- missing figure that looks like a small figure is one nobody queries.
--
-- On a solicitor's books it is worse than a reporting hole. A
-- disbursement that never reaches the matter is a disbursement that
-- never gets billed to the client, and the firm absorbs it.
--
-- ---------------------------------------------------------------------
-- Both levels, coalesced the same way
--
-- `expenses.matter_id` is the header's and `expense_lines.matter_id` is
-- the line's, and `post_expense` coalesces the line over the header --
-- exactly what it already does for the project and the department. The
-- reason is the same and it is stronger here: a claim for a day at
-- court is one matter, and a claim with four lines can be four files.
--
-- Nothing is invented. Both functions were pulled out of the applied
-- database, where `0639` left them, and restated with the dimension
-- added. Everything else in them is what is already live, which is the
-- only way to be sure a restatement does not revert something.
--
-- ---------------------------------------------------------------------
-- Not the tax leg and not the bank leg
--
-- `0639`'s line, for `0639`'s reason and `0691`'s. An input tax
-- reclaimed from the Customs Department and a payment out of the firm's
-- bank account are not matter costs; putting the matter on them would
-- make every file's disbursements include the SST the FIRM reclaims and
-- the cash it paid, double-counting against the expense line that is
-- the actual cost.
--
-- ---------------------------------------------------------------------
-- Nullable, with the composite key and nothing else
--
-- Nullable for `0639`'s reason: most expenses have no matter at all, and
-- a required dimension is a dimension people type anything into.
--
-- The foreign key is composite and names its column on delete, which is
-- not the shape `project_code` has -- that is plain text with no key at
-- all. A matter is a row rather than a code, and `0160`'s rule is that
-- an id crossing between two companies is refused by the key rather than
-- by RLS, which scopes a row by its own `org_id` and says nothing about
-- the ids it carries.
-- =====================================================================

alter table public.expenses
  add column if not exists matter_id uuid;

alter table public.expense_lines
  add column if not exists matter_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'expenses_matter_same_org') then
    alter table public.expenses
      add constraint expenses_matter_same_org
      foreign key (org_id, matter_id)
      references public.matters (org_id, id)
      -- The column named, because a bare `on delete set null` on a
      -- composite key nulls `org_id` too and `org_id` is NOT NULL, so
      -- deleting a matter would raise rather than detach the claim.
      -- `tenant_foreign_keys.sql` refuses the bare form.
      on delete set null (matter_id);
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'expense_lines_matter_same_org') then
    alter table public.expense_lines
      add constraint expense_lines_matter_same_org
      foreign key (org_id, matter_id)
      references public.matters (org_id, id)
      on delete set null (matter_id);
  end if;
end $$;

comment on column public.expenses.matter_id is
  'Which matter this whole claim was incurred on, or null for the '
  'firm''s own costs. The line''s own overrides it in `post_expense`, '
  'the same way the project and the department do. 0692.';

comment on column public.expense_lines.matter_id is
  'Which matter this one claimed cost was incurred on -- a filing fee, '
  'a courier, a commissioner for oaths. Falls back to the claim''s when '
  'null. Reaches `gl_lines.matter_id` through `post_expense`. 0692.';

create index if not exists expenses_matter_idx
  on public.expenses (org_id, matter_id)
  where matter_id is not null;

create index if not exists expense_lines_matter_idx
  on public.expense_lines (org_id, matter_id)
  where matter_id is not null;

-- ---------------------------------------------------------------------
-- The split takes a matter per line
-- ---------------------------------------------------------------------
create or replace function public.set_expense_split(
  p_expense_id uuid, p_lines jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$

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
       tax_code_id, tax_amount, project_code, department_code, matter_id)
    values (v_exp.org_id, p_expense_id, v_no, v_acct,
            nullif(v_line ->> 'description', ''), v_amount,
            nullif(v_line ->> 'tax_code_id', '')::uuid, v_tax,
            nullif(v_line ->> 'project_code', ''),
            nullif(v_line ->> 'department_code', ''),
            nullif(v_line ->> 'matter_id', '')::uuid);
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

$function$;

-- ---------------------------------------------------------------------
-- And posting carries it to the ledger
-- ---------------------------------------------------------------------
create or replace function public.post_expense(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$

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

$function$;

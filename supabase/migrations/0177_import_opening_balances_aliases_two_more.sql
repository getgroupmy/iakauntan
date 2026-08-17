-- `import_opening_balances`: two subqueries the aliasing rule missed.
--
-- Second of the three functions the drift check flagged and `0175` left
-- open. As with `0176`, **production is the correct side** — and here it
-- is correcting something this file already knew about.
--
-- ## The rule, which `0151` states itself
--
-- The function is declared `returns table (row_no integer, code text,
-- status text, message text)`, and in plpgsql those four output columns
-- are *variables*. An unqualified reference to a table column of the
-- same name is not wrong, it is **ambiguous** — which means it does not
-- fail when the function is created, or when it is read, but at run
-- time, on the line that touches it. `0151` says exactly this, at the
-- top of the commit branch:
--
--     -- Aliased throughout: this function returns a column called
--     -- `status`, which makes `status` a plpgsql variable, and an
--     -- unqualified reference to `gl_entries.status` is ambiguous rather
--     -- than wrong — it fails at run time, inside the commit branch,
--     -- which is the worst place to find it.
--
-- The rule is right. It was applied to `gl_entries` and to `accounts`,
-- and missed on two subqueries elsewhere in the same function:
--
--     select exists (select 1 from public.items
--                     where org_id = p_org_id and track_inventory ...
--
--     (select base_currency from public.organizations where id = p_org_id)
--
-- ## Latent, not live — and worth fixing anyway
--
-- Neither is broken today, and this migration does not change what the
-- function does. The ambiguity only fires on an identifier that is both
-- a variable and a column, and these two subqueries happen to reference
-- only `org_id`, `track_inventory`, `deleted_at`, `base_currency` and
-- `id` — none of which is one of the four.
--
-- What makes it worth closing rather than leaving is that **both tables
-- carry a colliding column already**:
--
--     public.items          has `code`
--     public.organizations  has `status`
--
-- So the trap is loaded. Narrowing the stock probe with `and code = ...`
-- or the currency lookup with `and status = ...` — both entirely
-- reasonable edits — turns a working function into one that raises
-- `column reference is ambiguous` inside `if p_commit then`, after the
-- validation has passed and while the operator is watching an import
-- they believe is running. That is the failure `0151`'s own comment
-- describes, and the alias is what prevents it.
--
-- ## Nothing else differs
--
-- Verified rather than assumed: with these two edits applied, the body
-- normalises byte-for-byte to the hosted project's, under the same
-- `code()` normalisation `scripts/schema_drift.py` uses to compare them
-- (`3ad6dff9d774a91e74440bc73a935549`). The remaining textual
-- differences between the two are line breaks inside adjacent string
-- literals, which that normalisation joins, and which the check has
-- always treated as cosmetic.
--
-- One of the three remains after this: `transfer_document`, in `0178`.

create or replace function public.import_opening_balances(
  p_org_id uuid,
  p_rows jsonb,
  p_as_at date,
  p_commit boolean default false)
returns table (row_no integer, code text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_code text; v_debit numeric; v_credit numeric; v_problem text;
  v_kind text;
  -- Scalars rather than a record, because a record variable that no
  -- SELECT has reached yet cannot be referenced at all — and the first
  -- thing this loop does with a blank code is ask whether the account
  -- was found.
  v_acct_id uuid; v_acct_type app.account_type;
  v_acct_subtype app.account_subtype; v_acct_group boolean;
  v_file_debit numeric := 0; v_file_credit numeric := 0;
  v_post_debit numeric := 0; v_post_credit numeric := 0;
  v_residual numeric;
  v_equity uuid; v_entry_id uuid; v_lines jsonb := '[]'::jsonb;
  v_ledger numeric; v_stock boolean;
  v_bank record;
begin
  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);

  -- Whether anything is stock-tracked at all, for the inventory warning.
  select exists (select 1 from public.items it
                  where it.org_id = p_org_id and it.track_inventory
                    and it.deleted_at is null)
    into v_stock;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;
    v_kind := 'ok';

    v_code   := app.import_text(r, 'account_code');
    v_debit  := app.import_number(app.import_text(r, 'debit'), 0);
    v_credit := app.import_number(app.import_text(r, 'credit'), 0);

    v_acct_id := null; v_acct_type := null;
    v_acct_subtype := null; v_acct_group := null;
    if v_code is not null then
      select a.id, a.account_type, a.account_subtype, a.is_group
        into v_acct_id, v_acct_type, v_acct_subtype, v_acct_group
        from public.accounts a
       where a.org_id = p_org_id and lower(a.code) = lower(v_code)
         and a.deleted_at is null;
    end if;

    if v_code is null then
      v_problem := 'No account code.';
    elsif lower(v_code) = any (v_seen) then
      v_problem := format('%s is in this file more than once.', v_code);
    -- Before the existence check, not after: 3900 is created on demand,
    -- so in a company that has imported nothing yet it does not exist,
    -- and the wrong branch answers "3900 is not an account in this
    -- company's chart" — true, unhelpful, and not the reason it is
    -- being refused.
    elsif v_code = '3900' then
      v_problem :=
        'Opening Balance Equity is what this import balances *to*. Leave '
        'it out; if it does not come to zero afterwards, the report will '
        'say by how much.';
    elsif v_acct_id is null then
      v_problem := format(
        '%s is not an account in this company''s chart. Add it first, or '
        'map the old code to one that is here.', v_code);
    elsif v_acct_group then
      v_problem := format(
        '%s is a heading, not an account. Its total is the accounts under '
        'it, and posting to it would double them.', v_code);
    elsif v_debit is null then
      v_problem := format('"%s" is not an amount.', app.import_text(r, 'debit'));
    elsif v_credit is null then
      v_problem := format('"%s" is not an amount.', app.import_text(r, 'credit'));
    elsif v_debit < 0 or v_credit < 0 then
      -- A negative debit is a credit, and letting somebody write it the
      -- other way means two spellings of the same line.
      v_problem := 'A negative amount belongs in the other column.';
    elsif v_debit <> 0 and v_credit <> 0 then
      v_problem := 'A trial balance line is on one side or the other, '
                || 'not both.';
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_code);
      v_file_debit  := v_file_debit + v_debit;
      v_file_credit := v_file_credit + v_credit;

      if v_acct_subtype in ('accounts_receivable', 'accounts_payable') then
        v_ledger := app.control_account_balance(
                      p_org_id, v_acct_subtype, p_as_at);
        -- The comparison, which is the reason the row is allowed in the
        -- file at all.
        if round(v_ledger, 2)
           = round(case when v_acct_type = 'asset'
                        then v_debit - v_credit
                        else v_credit - v_debit end, 2)
        then
          v_kind := 'ok';
          v_problem := format(
            'Not posted — the open %s already did, and they agree at %s.',
            case when v_acct_subtype = 'accounts_receivable'
                 then 'invoices' else 'bills' end,
            to_char(v_ledger, 'FM999999999990.00'));
        else
          v_kind := 'warning';
          v_problem := format(
            'Not posted. This file says %s and the open %s brought across '
            'come to %s. Opening Balance Equity will be out by the '
            'difference until one of them is corrected.',
            to_char(case when v_acct_type = 'asset'
                         then v_debit - v_credit
                         else v_credit - v_debit end,
                    'FM999999999990.00'),
            case when v_acct_subtype = 'accounts_receivable'
                 then 'invoices' else 'bills' end,
            to_char(v_ledger, 'FM999999999990.00'));
        end if;
      elsif v_debit = 0 and v_credit = 0 then
        v_problem := 'Nothing on this line.';
      else
        v_post_debit  := v_post_debit + v_debit;
        v_post_credit := v_post_credit + v_credit;

        if v_acct_subtype = 'inventory' and not v_stock then
          v_kind := 'warning';
          v_problem :=
            'Brought in as a figure. Nothing in this company is '
            'stock-tracked, so there are no quantities behind it and the '
            'stock valuation report will not agree with the balance '
            'sheet.';
        elsif v_acct_subtype = 'inventory' then
          v_kind := 'warning';
          v_problem :=
            'Brought in as a figure. Opening stock quantities are a '
            'separate import that is not built, so until they are entered '
            'this balance has nothing behind it and cost of sales will '
            'take an average of nothing.';
        end if;
      end if;
    else
      v_kind := 'error';
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', v_kind,
      'message', coalesce(v_problem, ''));
  end loop;

  -- A trial balance that does not balance is not one. Checked whether or
  -- not this is a commit, because it is the first thing somebody wants
  -- to know and the preview is where they will look.
  if round(v_file_debit - v_file_credit, 2) <> 0 then
    if p_commit then
      raise exception
        'Nothing was imported: the file does not balance. Debits come to '
        '%, credits to %, a difference of %.',
        to_char(v_file_debit, 'FM999999999990.00'),
        to_char(v_file_credit, 'FM999999999990.00'),
        to_char(v_file_debit - v_file_credit, 'FM999999999990.00')
        using errcode = '22023';
    end if;
    v_results := v_results || jsonb_build_object(
      'row_no', i + 1,
      'code', '',
      'status', 'error',
      'message', format(
        'The file does not balance. Debits %s against credits %s, a '
        'difference of %s.',
        to_char(v_file_debit, 'FM999999999990.00'),
        to_char(v_file_credit, 'FM999999999990.00'),
        to_char(v_file_debit - v_file_credit, 'FM999999999990.00')));
  end if;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  if p_commit then
    -- Refused rather than added to. An opening balance is brought in
    -- once; a second run would double every account in the file, and
    -- unlike the open items there is no document number to catch it.
    -- Aliased throughout: this function returns a column called
    -- `status`, which makes `status` a plpgsql variable, and an
    -- unqualified reference to `gl_entries.status` is ambiguous rather
    -- than wrong — it fails at run time, inside the commit branch, which
    -- is the worst place to find it.
    if exists (select 1 from public.gl_entries ge
                where ge.org_id = p_org_id
                  and ge.source = 'opening_balance'
                  and ge.source_table = 'opening_trial_balance'
                  and ge.status = 'posted')
    then
      raise exception
        'An opening trial balance has already been brought into this '
        'company. Reverse that entry before bringing in another, or the '
        'balances would be counted twice.' using errcode = '22023';
    end if;

    v_equity := app.opening_balance_account(p_org_id);

    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_code   := app.import_text(r, 'account_code');
      v_debit  := app.import_number(app.import_text(r, 'debit'), 0);
      v_credit := app.import_number(app.import_text(r, 'credit'), 0);

      select a.id, a.account_subtype into v_acct_id, v_acct_subtype
        from public.accounts a
       where a.org_id = p_org_id and lower(a.code) = lower(v_code)
         and a.deleted_at is null;

      continue when v_acct_subtype in ('accounts_receivable',
                                       'accounts_payable');
      continue when v_debit = 0 and v_credit = 0;

      v_lines := v_lines || jsonb_build_object(
        'account_id', v_acct_id,
        'description', coalesce(app.import_text(r, 'description'),
                                'Opening balance'),
        'debit', v_debit,
        'credit', v_credit);
    end loop;

    -- What the control accounts would have contributed, which is what
    -- 0150 parked in 3900.
    v_residual := round(v_post_debit - v_post_credit, 2);
    if v_residual <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_equity,
        'description', 'Opening balances brought forward',
        'debit', greatest(-v_residual, 0),
        'credit', greatest(v_residual, 0));
    end if;

    if jsonb_array_length(v_lines) = 0 then
      raise exception 'There is nothing to post.' using errcode = '22023';
    end if;

    v_entry_id := app.create_gl_entry_internal(
      p_org_id, p_as_at, 'opening_balance'::app.journal_source,
      v_lines,
      'Opening trial balance at ' || p_as_at,
      'opening_trial_balance', null, null,
      (select o.base_currency from public.organizations o where o.id = p_org_id), 1);

    -- A bank account carries its own running balance for the
    -- reconciliation screen, and it is derived rather than posted, so it
    -- has to be told.
    for v_bank in
      select b.id from public.bank_accounts b
       join public.accounts a on a.id = b.account_id
      where b.org_id = p_org_id
        and a.account_subtype in ('bank', 'cash')
    loop
      perform public.resync_bank_balance(v_bank.id);
    end loop;

    v_results := (
      select jsonb_agg(
               case when x ->> 'status' = 'ok'
                    then jsonb_set(x, '{status}', '"imported"')
                    else x end)
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status',
           x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end $$;

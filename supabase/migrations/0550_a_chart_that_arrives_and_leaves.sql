-- ---------------------------------------------------------------------
-- 0550  A chart that arrives, and leaves
-- ---------------------------------------------------------------------
-- 0103 imports contacts and items. 0451 lets a company edit its chart
-- of accounts one account at a time. Between them is the thing every
-- company migrating from another system actually has: a chart of two
-- hundred accounts in a spreadsheet, and one dialog to type it into.
--
-- ### What this adds
--
-- `import_accounts`, in the shape 0103 established: preview or commit,
-- one row per line with a verdict, and nothing written at all unless
-- every row is good. A file with one bad line imports nothing, which is
-- the only sane rule for a chart -- half a chart is worse than none,
-- because the postings that follow will find some accounts and invent
-- nothing for the rest.
--
-- ### The pairing nobody was checking
--
-- `accounts` carries `account_type` (asset, liability, equity, revenue,
-- expense) and `account_subtype` (twenty-six of them), and NOTHING in
-- this schema has ever said which subtype belongs to which type. There
-- is no check constraint, no trigger, and `upsert_account` takes both
-- as arguments and writes them as given. An asset account with the
-- subtype `sales` has always been one dialog away, and it would sit in
-- the balance sheet by type while every report that groups by subtype
-- put it in the income statement.
--
-- It never happened because the seeded template is consistent and the
-- dialog offers the subtypes of the chosen type. That is two courtesies
-- and no rule. An import is where it would have happened first: a file
-- from another system carries whatever that system called things.
--
-- `app.account_subtype_type` is the mapping, stated once, and both
-- doors ask it now.
--
-- ### What it does not do
--
-- It creates accounts and does not change existing ones. A code already
-- in the chart is reported and the file is refused, rather than
-- silently renaming an account the ledger posts to by number. Editing
-- stays where 0451 put it, one account at a time, where the refusals
-- about postings and renumbering can be explained.
--
-- Nor does it import balances. `import_opening_balances` (0103) does
-- that, against a chart that already exists, which is the order the two
-- have to happen in.
--
-- ### Mutants
--
-- Run against `supabase/tests/chart_import.sql`, each named with the
-- assertion that kills it:
--   * a bad row not stopping the file -- "one bad row imports nothing";
--   * a duplicate code inside the file accepted -- "a code twice in one
--     file is refused";
--   * an existing code overwritten -- "a code already in the chart is
--     refused";
--   * the subtype pairing dropped -- "an asset cannot be a sales
--     account";
--   * a parent named after its child accepted -- "a parent has to come
--     before the account that uses it";
--   * a parent that is not a heading accepted -- "a parent has to be a
--     heading";
--   * preview writing -- "a preview writes nothing";
--   * `can_write` dropped -- "a clerk who may not post cannot import a
--     chart".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Which type a subtype belongs to
-- ---------------------------------------------------------------------
-- Stated once, here, because it was previously stated nowhere and
-- implied in three places: the seed template, the account dialog's
-- filtered list, and every report that groups by one and totals by the
-- other.
create or replace function app.account_subtype_type(
  p_subtype app.account_subtype)
returns app.account_type
language sql immutable
set search_path = pg_catalog, public, app, pg_temp as $$
  select case p_subtype
    when 'current_asset'            then 'asset'
    when 'bank'                     then 'asset'
    when 'cash'                     then 'asset'
    when 'accounts_receivable'      then 'asset'
    when 'inventory'                then 'asset'
    when 'fixed_asset'              then 'asset'
    when 'accumulated_depreciation' then 'asset'
    when 'other_asset'              then 'asset'
    when 'current_liability'        then 'liability'
    when 'accounts_payable'         then 'liability'
    when 'tax_payable'              then 'liability'
    when 'long_term_liability'      then 'liability'
    when 'other_liability'          then 'liability'
    when 'share_capital'            then 'equity'
    when 'retained_earnings'        then 'equity'
    when 'reserves'                 then 'equity'
    when 'drawings'                 then 'equity'
    when 'sales'                    then 'revenue'
    when 'other_income'             then 'revenue'
    when 'cost_of_sales'            then 'expense'
    when 'operating_expense'        then 'expense'
    when 'payroll_expense'          then 'expense'
    when 'depreciation_expense'     then 'expense'
    when 'finance_cost'             then 'expense'
    when 'tax_expense'              then 'expense'
    when 'other_expense'            then 'expense'
  end::app.account_type;
$$;

comment on function app.account_subtype_type(app.account_subtype) is
  'The account type a subtype belongs to. Stated once so the chart '
  'cannot hold an asset that reports as revenue. See 0550.';

grant execute on function app.account_subtype_type(app.account_subtype)
  to authenticated;

-- ---------------------------------------------------------------------
-- The chart, from a file
-- ---------------------------------------------------------------------
create or replace function public.import_accounts(
  p_org_id uuid,
  p_rows jsonb,
  p_commit boolean default false)
returns table (row_no integer, code text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_groups text[] := '{}';
  v_bad integer := 0;
  v_code text; v_name text; v_type text; v_subtype text;
  v_parent text; v_is_group boolean; v_problem text;
  v_parent_id uuid;
begin
  -- `can_post` and not `can_write`: the chart decides what every future
  -- posting lands on, which is the same authority 0451 requires to add
  -- one account.
  if not app.can_post(p_org_id) then
    raise exception 'Only somebody who may post the books may import a chart'
      using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There is nothing in the file' using errcode = '22023';
  end if;

  -- The headings already in the chart, so a file may hang new accounts
  -- under an existing one without listing it.
  select coalesce(array_agg(lower(a.code)), '{}') into v_groups
    from public.accounts a
   where a.org_id = p_org_id and a.is_group and a.deleted_at is null;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_code := app.import_text(r, 'code');
    v_name := app.import_text(r, 'name');
    v_type := lower(coalesce(app.import_text(r, 'account_type'), ''));
    v_subtype := lower(coalesce(app.import_text(r, 'account_subtype'), ''));
    v_parent := app.import_text(r, 'parent_code');
    v_is_group := app.import_boolean(app.import_text(r, 'is_group'), false);

    if v_code is null then
      v_problem := 'No account number. Every account needs one, and it is '
                || 'what the ledger finds it by when it posts.';
    elsif v_name is null then
      v_problem := 'No name.';
    elsif lower(v_code) = any (v_seen) then
      v_problem := format('The number %s is in this file more than once.',
                          v_code);
    elsif exists (select 1 from public.accounts a
                   where a.org_id = p_org_id
                     and lower(a.code) = lower(v_code)
                     and a.deleted_at is null) then
      v_problem := format('%s is already in the chart. This brings new '
                       || 'accounts in; it does not change existing ones.',
                          v_code);
    elsif v_subtype = '' then
      v_problem := 'No account_subtype. It decides which statement the '
                || 'account lands on and which line of it.';
    elsif not exists (select 1 from pg_enum e
                       join pg_type t on t.oid = e.enumtypid
                      where t.typname = 'account_subtype'
                        and e.enumlabel = v_subtype) then
      v_problem := format('"%s" is not an account subtype.', v_subtype);
    elsif v_type <> ''
      and not exists (select 1 from pg_enum e
                       join pg_type t on t.oid = e.enumtypid
                      where t.typname = 'account_type'
                        and e.enumlabel = v_type) then
      v_problem := format('"%s" is not an account type. Use asset, '
                       || 'liability, equity, revenue or expense.', v_type);
    elsif v_type <> ''
      and v_type <> app.account_subtype_type(
                      v_subtype::app.account_subtype)::text then
      -- The pairing this migration is mostly about. An account that is
      -- an asset by type and a sales account by subtype sits in the
      -- balance sheet and the income statement at once.
      v_problem := format(
        'A %s account cannot have the subtype "%s" -- that belongs to %s.',
        v_type, v_subtype,
        app.account_subtype_type(v_subtype::app.account_subtype));
    elsif v_parent is not null
      -- `<> all`, not `<> any`. With `any` this is true as soon as the
      -- parent differs from ONE heading in the list, so every parent in
      -- a chart that already has more than one heading was refused --
      -- including the one two lines above it in the same file.
      and lower(v_parent) <> all (v_groups) then
      -- Earlier in the same file, or already a heading in the chart.
      -- Anything else is a parent that does not exist yet, and creating
      -- the child first would leave it hanging.
      v_problem := format(
        '%s is not a heading in this chart. A parent has to be a heading, '
        'and if it is in this file it has to come before the accounts '
        'that use it.', v_parent);
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_code);
      if v_is_group then
        v_groups := v_groups || lower(v_code);
      end if;
    else
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, ''));
  end loop;

  -- Nothing is written unless every row is good, and nothing is written
  -- on a preview.
  if p_commit and v_bad = 0 then
    i := 0;
    for r in select * from jsonb_array_elements(p_rows)
    loop
      i := i + 1;
      v_code := app.import_text(r, 'code');
      v_subtype := lower(app.import_text(r, 'account_subtype'));
      v_parent := app.import_text(r, 'parent_code');

      v_parent_id := null;
      if v_parent is not null then
        select a.id into v_parent_id from public.accounts a
         where a.org_id = p_org_id and lower(a.code) = lower(v_parent)
           and a.deleted_at is null;
      end if;

      -- Through `upsert_account`, not an insert: it is where the rules
      -- about parents, renumbering and posted accounts live, and a
      -- second door into the chart that skipped them would be a way to
      -- write what the first door refuses.
      perform public.upsert_account(
        p_code => v_code,
        p_name => app.import_text(r, 'name'),
        p_type => coalesce(
          nullif(lower(coalesce(app.import_text(r, 'account_type'), '')), ''),
          app.account_subtype_type(v_subtype::app.account_subtype)::text
        )::app.account_type,
        p_subtype => v_subtype::app.account_subtype,
        p_parent_id => v_parent_id,
        p_is_group => app.import_boolean(
          app.import_text(r, 'is_group'), false),
        p_description => app.import_text(r, 'description'),
        p_org_id => p_org_id);
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status',
           x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end; $$;

comment on function public.import_accounts(uuid, jsonb, boolean) is
  'Brings a chart of accounts in from a file. Preview or commit; one '
  'bad row imports nothing. See 0550.';

revoke all on function public.import_accounts(uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.import_accounts(uuid, jsonb, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the other door asks the same question
-- ---------------------------------------------------------------------
-- Restated from the built definition of `upsert_account` with one block
-- added and nothing else touched. The import above would be the only
-- place the pairing was checked otherwise, and the dialog that adds one
-- account at a time would still be able to write what the file cannot.
CREATE OR REPLACE FUNCTION public.upsert_account(p_code text, p_name text, p_type app.account_type, p_subtype app.account_subtype, p_id uuid DEFAULT NULL::uuid, p_parent_id uuid DEFAULT NULL::uuid, p_is_group boolean DEFAULT false, p_description text DEFAULT NULL::text, p_org_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $$
declare
  v_org  uuid;
  v_old  public.accounts;
  v_id   uuid;
  v_code text := upper(btrim(coalesce(p_code, '')));
begin
  if p_id is not null then
    select * into v_old from public.accounts a where a.id = p_id;
    v_org := v_old.org_id;
  else
    v_org := p_org_id;
  end if;

  if v_org is null then
    raise exception 'Which company is this account for?' using errcode = '22023';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'An account needs a number.' using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'An account needs a name.' using errcode = '23514';
  end if;

  -- Renumbering an account the posting paths name by number detaches
  -- them silently. See the header.
  if p_id is not null and v_old.code is distinct from v_code
     and exists (select 1 from app.posting_account_codes() c
                  where c.code = v_old.code) then
    raise exception
      'Account % is one the ledger finds by number when it posts, so its '
      'number cannot change. Its name and description can.', v_old.code
      using errcode = '23514';
  end if;

  if p_parent_id is not null then
    if p_parent_id = p_id then
      raise exception 'An account cannot be its own parent.'
        using errcode = '23514';
    end if;
    if not exists (select 1 from public.accounts a
                    where a.id = p_parent_id and a.org_id = v_org
                      and a.is_group) then
      raise exception 'A parent has to be a heading in the same company.'
        using errcode = '23514';
    end if;
  end if;

  -- 0550. The type and the subtype have to agree. Nothing said so
  -- until now: an asset with the subtype `sales` sat in the balance
  -- sheet by type and in the income statement by subtype, and the
  -- only reason it never happened is that the dialog offers the
  -- subtypes of the chosen type and the seeded chart is consistent.
  -- That is two courtesies and no rule.
  --
  -- Checked on insert, and on update only when one of the two is
  -- actually moving. A row that already holds a bad pairing -- there
  -- should be none, but this cannot know that of every company -- can
  -- still be renamed by somebody trying to tidy it up.
  if p_id is null
     or v_old.account_type is distinct from p_type
     or v_old.account_subtype is distinct from p_subtype then
    if p_type is distinct from app.account_subtype_type(p_subtype) then
      -- `%` and not `%s`: RAISE's placeholder is a bare percent, and
      -- `%s` interpolates the value and then prints a literal s -- "A
      -- assets account cannot have the subtype saless". `format()`
      -- three lines up in the importer is the one that takes %s, which
      -- is exactly why this reads wrong.
      raise exception
        'A % account cannot have the subtype "%" -- that belongs to %.',
        p_type, p_subtype, app.account_subtype_type(p_subtype)
        using errcode = '23514';
    end if;
  end if;

  -- Changing what kind of account it is flips its sign in every report
  -- that has ever been run against it, so it is refused once anything
  -- has been posted.
  if p_id is not null and v_old.account_type is distinct from p_type
     and exists (select 1 from public.gl_lines l where l.account_id = p_id)
  then
    raise exception
      'Account % has postings, so what kind of account it is cannot '
      'change. Retire it and open a new one.', v_old.code
      using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.accounts
      (org_id, code, name, description, account_type, account_subtype,
       parent_id, is_group)
    values (v_org, v_code, btrim(p_name), nullif(btrim(p_description), ''),
            p_type, p_subtype, p_parent_id, coalesce(p_is_group, false))
    returning id into v_id;
  else
    update public.accounts
       set code = v_code,
           name = btrim(p_name),
           description = nullif(btrim(p_description), ''),
           account_type = p_type,
           account_subtype = p_subtype,
           parent_id = p_parent_id,
           is_group = coalesce(p_is_group, v_old.is_group)
     where id = p_id
    returning id into v_id;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
-- The mapping has to cover every subtype the enum holds. A subtype
-- added later and not added here would come back null, and null is not
-- distinct from nothing -- the pairing check would pass for it whatever
-- type it was given.
do $do$
declare v_missing text;
begin
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
    into v_missing
    from pg_enum e join pg_type t on t.oid = e.enumtypid
   where t.typname = 'account_subtype'
     and app.account_subtype_type(e.enumlabel::app.account_subtype) is null;
  if v_missing is not null then
    raise exception
      '0550: these subtypes have no type: %', v_missing;
  end if;
end $do$;

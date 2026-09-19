-- =====================================================================
-- iAkauntan :: 0655 a sub-account under one that never posted
--
-- Asked for as:
--
--     1120            Bank accounts
--     1120-1000       Maybank
--     1120-1000-1000  Multi Currency
--     1120-1000-1000-1000        USD
--     1120-1000-1000-1000-1000   Cash
--     1120-2000       CIMB
--
-- with any depth allowed, and a sub-account allowed under a parent only
-- while that parent has no transactions.
--
-- ---------------------------------------------------------------------
-- The rule is not arbitrary, and it is the whole migration
--
-- `accounts` has had `parent_id` and `is_group` since `0003`, and
-- `upsert_account` has always accepted a parent -- but only a parent
-- that is ALREADY a heading. There was no way to put something under an
-- account that posts, which is every account somebody actually wants to
-- break up. Maybank is where the money went; Multi Currency underneath
-- it is the refinement.
--
-- Putting a child under a posting account means promoting that account
-- to a heading, and a heading is not postable:
--
--   * `0089`'s manual journal refuses `a.is_group`;
--   * `0013`'s `resolve_account` and every `code = '5350' and not
--     is_group` lookup skip headings;
--   * `0014`, `0016` and `0100` sum LEAVES -- `and not a.is_group` --
--     so a promoted account's own balance leaves the trial balance,
--     the profit and loss, and the cash flow statement at once.
--
-- With no transactions that balance is zero, so nothing moves and no
-- report changes by a cent. With transactions it is a figure silently
-- dropping out of the accounts. That is what the requested rule is
-- protecting, and it is why the refusal is worth its own message rather
-- than a constraint violation.
--
-- ---------------------------------------------------------------------
-- Three things count as "has transactions"
--
--   1. A posted line -- `gl_lines.account_id` -- which is the obvious
--      one.
--   2. A NON-ZERO OPENING BALANCE, which is not a posted line and is
--      still a figure on the trial balance. `0003` keeps it on the
--      account row.
--   3. The code being one the LEDGER ITSELF posts to. `2120`, `5350`
--      and their siblings are resolved by number inside the posting
--      functions, every one of them with `and not is_group`, so
--      promoting one turns a working posting path into "no account
--      found" at the moment somebody runs payroll. `upsert_account`
--      already refuses to RENUMBER those, by the same test, for the
--      same reason; this refuses to promote them.
--
-- The third is the one nobody would think of, and it is the one whose
-- failure arrives a month later in somebody else's screen.
--
-- ---------------------------------------------------------------------
-- The numbering
--
-- `1120-1000`, then `1120-2000`, and a child of `1120-1000` starts at
-- `1120-1000-1000` again. Steps of a thousand, so there is room to slot
-- one in between without renumbering anything -- which is what a chart
-- of accounts is numbered in thousands FOR.
--
-- A hyphen and no spaces. The request wrote `1120 - 1000` and that is
-- how a chart is read out rather than how it is stored; `accounts.code`
-- is what reports sort by and what somebody types into a picker, and
-- ' - ' is three characters of which two are invisible.
--
-- A code can still be given explicitly. The generator is what happens
-- when nobody has an opinion, which is most of the time.
--
-- ---------------------------------------------------------------------
-- What a sub-account inherits
--
-- Its TYPE, always and not optionally: a sub-account of an expense
-- account is an expense account, and an asset filed under an expense
-- heading would appear on one statement by type and another by
-- position. The subtype defaults to the parent's and may be given --
-- `1120-1000-1000-1000` USD under a bank is still a bank account, but a
-- company that wants it filed as cash may say so, and
-- `app.account_subtype_type` still refuses a pairing that crosses
-- statements.
--
-- Currency may be given, because the example asks for it by name: a USD
-- account under a multi-currency bank.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The next number under a parent
-- ---------------------------------------------------------------------
create or replace function app.next_sub_account_code(p_parent_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_org uuid;
  v_parent text;
  v_step int := 1000;
  v_next int;
  v_code text;
begin
  select org_id, code into v_org, v_parent
    from public.accounts where id = p_parent_id;
  if v_parent is null then
    raise exception 'There is no account to put this under'
      using errcode = 'P0002';
  end if;

  -- The highest number already used directly under this parent, read
  -- off the codes rather than from a counter. A counter would be a
  -- second place the answer lives, and it would drift the first time
  -- somebody types a code by hand -- which they may.
  --
  -- Only the segment IMMEDIATELY under the parent: `1120-1000-1000` is
  -- a grandchild and must not push `1120`'s next child to 2000.
  select max(seg) into v_next
    from (
      select (regexp_match(a.code,
                '^' || regexp_replace(v_parent, '([^a-zA-Z0-9])', '\\\1', 'g')
                    || '-([0-9]+)$'))[1]::int as seg
        from public.accounts a
       where a.org_id = v_org
         and a.code like v_parent || '-%'
    ) q
   where seg is not null;

  v_code := v_parent || '-' || lpad((coalesce(v_next, 0) + v_step)::text, 4, '0');

  -- Deleted rows keep their code -- the unique index does not exclude
  -- them -- and a hand-typed code can sit anywhere, so the generated
  -- one is walked forward until it is free rather than assumed.
  while exists (select 1 from public.accounts a
                 where a.org_id = v_org and a.code = v_code)
  loop
    v_step := v_step + 1000;
    v_code := v_parent || '-'
              || lpad((coalesce(v_next, 0) + v_step)::text, 4, '0');
  end loop;

  return v_code;
end;
$function$;

comment on function app.next_sub_account_code(uuid) is
  'The next code under a parent: parent code, a hyphen, and the next '
  'thousand not already used by a direct child. See 0655.';


-- ---------------------------------------------------------------------
-- Why a parent cannot take one
-- ---------------------------------------------------------------------
--
-- Split out from the insert so the app can ask BEFORE it offers the
-- button, and so the sentence is written once. Null means it can.
create or replace function app.sub_account_refusal(p_parent_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v public.accounts;
  v_lines bigint;
begin
  select * into v from public.accounts a where a.id = p_parent_id;
  if v.id is null then
    return 'There is no account to put this under.';
  end if;
  if v.deleted_at is not null then
    return format('Account %s has been retired, so nothing can be filed '
                  'under it.', v.code);
  end if;

  -- Already a heading: it posts nothing today and putting another
  -- child under it changes nothing at all.
  if v.is_group then
    return null;
  end if;

  select count(*) into v_lines
    from public.gl_lines l where l.account_id = p_parent_id;
  if v_lines > 0 then
    return format(
      'Account %s (%s) has %s posted %s, so it cannot become a heading. '
      'A heading holds no balance of its own -- its figure would leave '
      'the trial balance. Open a new account beside it instead.',
      v.code, v.name, v_lines,
      case when v_lines = 1 then 'entry' else 'entries' end);
  end if;

  -- Not a posted line, and still a figure on the balance sheet.
  if coalesce(v.opening_balance, 0) <> 0 then
    return format(
      'Account %s (%s) carries an opening balance, so it cannot become '
      'a heading -- that balance would stop being reported. Open a new '
      'account beside it instead.', v.code, v.name);
  end if;

  -- The one nobody thinks of. These codes are resolved by number
  -- inside the posting functions, every one with `and not is_group`.
  if exists (select 1 from app.posting_account_codes() c
              where c.code = v.code) then
    return format(
      'Account %s is one the ledger finds by number when it posts, so '
      'it has to stay postable and cannot become a heading.', v.code);
  end if;

  return null;
end;
$function$;

comment on function app.sub_account_refusal(uuid) is
  'Why a sub-account cannot go under this parent, or null if one can. '
  'Split out so the app can ask before offering the button. See 0655.';


-- ---------------------------------------------------------------------
-- Adding one
-- ---------------------------------------------------------------------
create or replace function public.add_sub_account(
  p_parent_id uuid,
  p_name text,
  p_code text default null,
  p_subtype app.account_subtype default null,
  p_description text default null,
  p_currency text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
declare
  v_parent public.accounts;
  v_refusal text;
  v_subtype app.account_subtype;
  v_code text;
  v_currency char(3);
  v_promoted boolean := false;
  v_id uuid;
begin
  select * into v_parent from public.accounts a where a.id = p_parent_id;
  if v_parent.id is null then
    raise exception 'There is no account to put this under'
      using errcode = 'P0002';
  end if;

  -- The same guard `upsert_account` uses, and asked here because this
  -- function is its own definer: the table's policies do not apply to
  -- the insert below.
  if not app.can_post(v_parent.org_id) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'An account needs a name.' using errcode = '23514';
  end if;

  v_refusal := app.sub_account_refusal(p_parent_id);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = '23514';
  end if;

  -- The type is the parent's, full stop. The subtype defaults to it
  -- and may be overridden, and `0550`'s rule still applies: the two
  -- have to belong to the same statement.
  v_subtype := coalesce(p_subtype, v_parent.account_subtype);
  if v_parent.account_type is distinct from app.account_subtype_type(v_subtype)
  then
    raise exception
      'A % account cannot have the subtype "%" -- that belongs to %.',
      v_parent.account_type, v_subtype,
      app.account_subtype_type(v_subtype)
      using errcode = '23514';
  end if;

  v_code := upper(nullif(btrim(coalesce(p_code, '')), ''));
  if v_code is null then
    v_code := app.next_sub_account_code(p_parent_id);
  end if;
  if exists (select 1 from public.accounts a
              where a.org_id = v_parent.org_id and a.code = v_code) then
    raise exception 'Account % already exists in this company.', v_code
      using errcode = '23505';
  end if;

  v_currency := upper(nullif(btrim(coalesce(p_currency, '')), ''))::char(3);

  -- Promote the parent, having established that promoting it costs
  -- nothing. A heading that was already a heading is left alone, so
  -- `promoted` in the answer means "this changed under you" rather
  -- than "this is a heading".
  if not v_parent.is_group then
    update public.accounts set is_group = true where id = p_parent_id;
    v_promoted := true;
  end if;

  insert into public.accounts
    (org_id, code, name, description, account_type, account_subtype,
     parent_id, is_group, currency, sort_order)
  values (v_parent.org_id, v_code, btrim(p_name),
          nullif(btrim(p_description), ''),
          v_parent.account_type, v_subtype, p_parent_id, false,
          coalesce(v_currency, v_parent.currency),
          v_parent.sort_order)
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id,
    'code', v_code,
    'parent_code', v_parent.code,
    -- So the app can say "1120 Bank accounts is now a heading" once,
    -- rather than leaving somebody to notice that the account they
    -- were posting to has stopped being offered.
    'parent_promoted', v_promoted);
end;
$function$;

revoke all on function public.add_sub_account(
  uuid, text, text, app.account_subtype, text, text) from public;
grant execute on function public.add_sub_account(
  uuid, text, text, app.account_subtype, text, text) to authenticated;

comment on function public.add_sub_account(
  uuid, text, text, app.account_subtype, text, text) is
  'Files a new account under an existing one, promoting the parent to a '
  'heading -- which is only allowed while the parent has nothing posted '
  'to it, no opening balance, and is not a code the ledger posts to by '
  'number. See 0655.';


-- ---------------------------------------------------------------------
-- And the same question, answerable from the app
-- ---------------------------------------------------------------------
--
-- So a row in the chart can offer "Add sub-account" or say why not,
-- without a failed write being the way somebody finds out.
create or replace function public.sub_account_refusal(p_parent_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $function$
declare v_org uuid;
begin
  select org_id into v_org from public.accounts where id = p_parent_id;
  if v_org is null then
    return 'There is no account to put this under.';
  end if;
  -- Read rather than written, so membership is the test rather than
  -- the posting right. The write itself still asks `can_post`.
  if not app.is_org_member(v_org) then
    raise exception 'That account belongs to another company'
      using errcode = '42501';
  end if;
  return app.sub_account_refusal(p_parent_id);
end;
$function$;

revoke all on function public.sub_account_refusal(uuid) from public;
grant execute on function public.sub_account_refusal(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
begin
  -- The refusal has to name all three reasons, because the third is the
  -- one nobody would think to test by hand.
  if (select prosrc from pg_proc
       where oid = 'app.sub_account_refusal(uuid)'::regprocedure)
     not like '%posting_account_codes%' then
    raise exception 'the refusal does not protect the codes the ledger '
                    'posts to by number';
  end if;
  if (select prosrc from pg_proc
       where oid = 'app.sub_account_refusal(uuid)'::regprocedure)
     not like '%opening_balance%' then
    raise exception 'the refusal ignores an opening balance';
  end if;
  if (select prosrc from pg_proc
       where oid = 'app.sub_account_refusal(uuid)'::regprocedure)
     not like '%gl_lines%' then
    raise exception 'the refusal ignores posted entries';
  end if;

  -- And the writer has to ask it. A version that checked `gl_lines`
  -- itself would be a second copy of the rule, which is the shape this
  -- repository keeps having to undo.
  if (select prosrc from pg_proc
       where oid = 'public.add_sub_account(uuid, text, text, '
                   'app.account_subtype, text, text)'::regprocedure)
     not like '%app.sub_account_refusal%' then
    raise exception 'add_sub_account does not ask why not';
  end if;
  if (select prosrc from pg_proc
       where oid = 'public.add_sub_account(uuid, text, text, '
                   'app.account_subtype, text, text)'::regprocedure)
     not like '%can_post%' then
    raise exception 'add_sub_account does not check who is asking';
  end if;

  if has_function_privilege('anon',
       'public.add_sub_account(uuid, text, text, app.account_subtype, '
       'text, text)', 'execute') then
    raise exception 'add_sub_account is callable without signing in';
  end if;
end $do$;

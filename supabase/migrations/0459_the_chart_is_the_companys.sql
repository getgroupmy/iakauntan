-- ---------------------------------------------------------------------
-- 0459  The chart is the company's
-- ---------------------------------------------------------------------
-- Measured: `accounts` has had insert, update and delete policies for
-- `app.can_post` since the schema was laid down, and `authenticated`
-- holds all four grants. The screen is a card that counts accounts by
-- type and offers nothing. So a company that wanted an account for a
-- new line of business had a permission it could not reach -- the same
-- shape 0-something fixed for `tax_codes`, which is the card directly
-- underneath.
--
-- ### What has to be refused, and why it cannot be a flag
--
-- `accounts.is_system` exists. **Nothing sets it** -- measured, zero
-- rows in a freshly seeded company -- so it protects nothing.
--
-- What actually matters is narrower and stranger: posting resolves
-- accounts **by code**. `app.resolve_account` ends with
--
--   select id from public.accounts
--    where org_id = p_org_id and code = p_default_code and not is_group;
--
-- and fifty-odd posting functions pass a literal code into it or fall
-- back to one directly. Renumbering 2110 does not break anything
-- loudly: it detaches a posting path, and the next invoice posts its
-- receivable somewhere else or fails at the ledger with a message about
-- a null account.
--
-- So the protected set is **derived, not declared**: every four-digit
-- literal named by a function in `public` or `app`, excluding
-- `seed_chart_of_accounts` and the demo seeds, which name the whole
-- chart and would protect everything. Measured today that is 64 codes,
-- from a chart of about a hundred.
--
-- Deriving it means a posting path added next year protects its own
-- account without anybody remembering. A false positive -- a four-digit
-- string that is not an account code -- would only over-protect one
-- account, which is the safe direction to be wrong in.
--
-- **A protected code can still be renamed, described, re-parented and
-- deactivated.** What it cannot be is renumbered or deleted. The number
-- is the part the machinery holds.
--
-- ### Deleting versus retiring
--
-- `gl_lines.account_id` is `on delete restrict`, so an account that has
-- been posted to cannot be deleted and never could -- the database
-- would answer with a constraint name. `retire_account` says which
-- happened instead: an account nothing has ever touched is deleted, and
-- one with history is deactivated and keeps its postings. An accounting
-- system that let somebody delete an account with a balance would be
-- one whose trial balance stopped balancing.
--
-- ### Mutants
--
-- Seven, restated into a built database and run against
-- `supabase/tests/chart_of_accounts.sql`. **Two survived the assertions
-- as first written**, and both survivors passed for a reason that had
-- nothing to do with the guard being tested:
--
--   * the seed no longer excluded, so the protected set is the whole
--     chart -- killed by "the protected set is a part of the chart,
--     not all of it";
--   * the renumbering guard dropped -- killed by "an account the ledger
--     posts to by number cannot be renumbered";
--   * the type-change guard dropped -- killed by "an account with
--     postings cannot change what it is";
--   * an account with history deleted rather than deactivated --
--     **survived**. `gl_lines.account_id` is `on delete restrict`, so
--     the delete raises anyway and the function's own foreign-key
--     handler turns it into a deactivation: the guard is redundant for
--     that case. It is not redundant for an account carrying an
--     `opening_balance` and no postings, which no foreign key protects
--     at all -- that one really would be deleted, and the trial balance
--     would stop balancing. The assertion added for it reads `deleted`
--     against `deactivated`;
--   * a protected account may be retired -- **survived**, and this is
--     the more instructive one. The assertion asked about **1200**,
--     which is a *heading with accounts under it*: retiring it is
--     refused by the children guard, with the same SQLSTATE, whether
--     the protection exists or not. Only a protected *leaf* tests the
--     protection, so the assertion now asks about 1310 and first
--     checks that 1310 is a leaf;
--   * a heading with accounts under it retired anyway -- killed by "a
--     heading with accounts under it stays";
--   * the chart open to anybody in the company -- killed by "a viewer
--     cannot open an account".
--
-- The lesson from the second survivor is worth carrying: **an
-- assertion that expects a refusal proves nothing until you know which
-- refusal it got.** Two guards raising the same SQLSTATE are
-- indistinguishable to an exception handler, and the wrong one was
-- answering.
-- ---------------------------------------------------------------------

create or replace function app.posting_account_codes()
returns table (code text)
language sql stable
set search_path = public, app, pg_temp
as $$
  -- The seed names every account in the chart, and the demo seeds name
  -- most of them, so both are excluded: including them would protect
  -- the whole chart and leave the company with an editor that edits
  -- nothing.
  select distinct m[1]
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, '''([0-9]{4})''', 'g') m
   where n.nspname in ('public', 'app')
     and p.proname not like 'demo%'
     and p.proname <> 'seed_chart_of_accounts'
     and p.proname <> 'posting_account_codes';
$$;

-- ---------------------------------------------------------------------
-- Adding one, and changing one
-- ---------------------------------------------------------------------
create or replace function public.upsert_account(
  p_code        text,
  p_name        text,
  p_type        app.account_type,
  p_subtype     app.account_subtype,
  p_id          uuid default null,
  p_parent_id   uuid default null,
  p_is_group    boolean default false,
  p_description text default null,
  p_org_id      uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
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
-- Taking one out of use
-- ---------------------------------------------------------------------
create or replace function public.retire_account(p_id uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a public.accounts;
begin
  select * into v_a from public.accounts a where a.id = p_id;
  if v_a.id is null then
    raise exception 'No such account.' using errcode = '22023';
  end if;
  if not app.can_post(v_a.org_id) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;

  if exists (select 1 from app.posting_account_codes() c
              where c.code = v_a.code) then
    raise exception
      'Account % is one the ledger posts to by number. It can be renamed '
      'but not removed.', v_a.code
      using errcode = '23514';
  end if;

  if exists (select 1 from public.accounts a
              where a.parent_id = p_id and a.deleted_at is null) then
    raise exception
      'Account % still has accounts under it.', v_a.code
      using errcode = '23514';
  end if;

  -- Anything ever posted to it, or anything still naming it. Deleting
  -- either would be answered by a constraint name rather than a
  -- sentence, and in the first case would take a balance out of the
  -- trial balance.
  if exists (select 1 from public.gl_lines l where l.account_id = p_id)
     or v_a.opening_balance <> 0 then
    update public.accounts
       set is_active = false, deleted_at = now()
     where id = p_id;
    return 'deactivated';
  end if;

  delete from public.accounts where id = p_id;
  return 'deleted';
exception
  -- Something else still names it -- a bank account, a budget line, an
  -- item's posting account. Keeping it, switched off, is the only
  -- answer that leaves those rows pointing at something.
  when foreign_key_violation then
    update public.accounts
       set is_active = false, deleted_at = now()
     where id = p_id;
    return 'deactivated';
end;
$$;

revoke all on function public.upsert_account(
  text, text, app.account_type, app.account_subtype, uuid, uuid, boolean,
  text, uuid) from public;
revoke all on function public.retire_account(uuid) from public;

grant execute on function public.upsert_account(
  text, text, app.account_type, app.account_subtype, uuid, uuid, boolean,
  text, uuid) to authenticated;
grant execute on function public.retire_account(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_codes text := pg_get_functiondef(
    to_regprocedure('app.posting_account_codes()'));
  v_n integer;
begin
  -- Derived, not declared: the seed is excluded or the set is the whole
  -- chart and the editor edits nothing.
  if position('seed_chart_of_accounts' in v_codes) = 0 then
    raise exception '0459: the protected set is the whole chart';
  end if;

  select count(*) into v_n from app.posting_account_codes();
  if v_n < 20 then
    raise exception
      '0459: only % codes are protected, which cannot be right', v_n;
  end if;

  -- The receivable and payable control accounts are the two whose
  -- renumbering breaks the most, so they are checked by name.
  if not exists (select 1 from app.posting_account_codes() where code = '1200')
     or not exists (select 1 from app.posting_account_codes()
                     where code = '2100') then
    raise exception '0459: the control accounts are not protected';
  end if;
end
$do$;

comment on function public.upsert_account(
  text, text, app.account_type, app.account_subtype, uuid, uuid, boolean,
  text, uuid) is
  'Add or change an account. Refuses renumbering one the ledger finds '
  'by number when it posts, and refuses changing the type of one that '
  'has postings. See 0459.';

-- =====================================================================
-- 0766 :: a rename leaves the chart as it was
--
-- Answered on 9 October: "guard + app fix", production's rows left as
-- they are.
--
-- `upsert_account` writes `is_group` and `parent_id` from whatever it is
-- handed. The app's edit dialog handed it `p_is_group => false` and no
-- parent for every account it saved, so:
--
--   * renaming a HEADING made it a postable leaf, its children still
--     filed under it. Production, 9 October: DEVINDER & CO's 1200 Trade
--     and Other Receivables and GESWANT & CO's 1300 Inventories;
--   * renaming ANY account took it out from under its parent. Seven
--     accounts across three companies.
--
-- Nothing had been posted to the two demoted headings and no report
-- reads `parent_id`, so no figure moved. They stay as they are: that
-- was the answer. The app now sends what the account already is
-- (`chart_of_accounts_card.dart`), and this makes the function refuse
-- the two changes that are never what a rename means:
--
--   1. BECOMING A HEADING when `app.sub_account_refusal` says it may
--      not -- posted entries, an opening balance, or a number the
--      ledger posts to. A heading holds no balance of its own, so its
--      figure would leave the trial balance: reproduced by RPC, 25 / 25
--      became 0 / 25. `0655` asks this before a sub-account promotes its
--      parent; this path never did.
--   2. STOPPING BEING ONE while accounts are filed under it.
--
-- And it stops re-examining a parent the account already HAS. `0693`
-- files a child under an account that still posts -- GESWANT's 1120
-- has two -- and "a parent has to be a heading" would otherwise refuse
-- the fixed dialog re-saving that child's name with its own parent.
--
-- Restated from `0550`, whose text is the live one: replayed into a
-- rolled-back transaction it hashes to a6e8d692..., which is what
-- production's `pg_get_functiondef` hashes to. NOT from `0459` -- the
-- first draft of this was, because `0550` spells it `CREATE OR REPLACE
-- FUNCTION` and a case-sensitive search for the definition found only
-- `0459`. That draft dropped `0550`'s rule that an account's type and
-- subtype agree, and `chart_import.sql` is what caught it. Grants
-- survive a replace. The comment is EXTENDED, not rewritten, because it
-- is published in `docs/api`.
-- =====================================================================

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
  v_refusal text;
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
    -- A parent the account already has is not examined again (0766).
    -- `0693` files a child under an account that still posts, so
    -- re-saving that child's name with the parent it has must not be
    -- refused for an arrangement the product made.
    if (p_id is null or p_parent_id is distinct from v_old.parent_id)
       and not exists (select 1 from public.accounts a
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

  -- Becoming a heading (0766). A heading holds no balance of its own,
  -- so promoting an account with postings, an opening balance or a
  -- number the ledger posts to drops a figure out of every report.
  -- `app.sub_account_refusal` is the question `0655` asks before a
  -- sub-account promotes its parent; this path never asked it.
  if p_id is not null and coalesce(p_is_group, v_old.is_group)
     and not v_old.is_group then
    v_refusal := app.sub_account_refusal(p_id);
    if v_refusal is not null then
      raise exception '%', v_refusal using errcode = '23514';
    end if;
  end if;

  -- Stopping being one (0766). The app's edit dialog sent `false` for
  -- every account it saved, so renaming a heading made it postable with
  -- its children still filed under it.
  if p_id is not null and v_old.is_group
     and not coalesce(p_is_group, v_old.is_group)
     and exists (select 1 from public.accounts a
                  where a.parent_id = p_id and a.deleted_at is null) then
    raise exception
      'Account % (%) has accounts under it, so it stays a heading.',
      v_old.code, v_old.name
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

comment on function public.upsert_account(
  text, text, app.account_type, app.account_subtype, uuid, uuid, boolean,
  text, uuid) is
  'Add or change an account. Refuses renumbering one the ledger finds '
  'by number when it posts, and refuses changing the type of one that '
  'has postings. See 0459. Also refuses making an account with postings, '
  'an opening balance or a number the ledger posts to into a heading, '
  'and turning a heading with accounts under it back into one that '
  'posts; a parent the account already has is kept without being '
  'examined again (0766).';

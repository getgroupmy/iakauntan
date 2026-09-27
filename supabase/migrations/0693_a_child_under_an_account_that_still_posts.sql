-- =====================================================================
-- iAkauntan :: 0693 a child under an account that still posts
--
-- Reported from the chart of accounts: adding a sub-account under
-- `1120 Bank Accounts` is refused with
--
--     Nothing can be filed under this
--     Account 1120 is one the ledger finds by number when it posts, so
--     it has to stay postable and cannot become a heading.
--
-- and the company already has `1120-M001 mbb` sitting under it. The
-- product both permits the arrangement and refuses to create it.
--
-- ---------------------------------------------------------------------
-- Two questions that `0655` treated as one
--
-- `0655` reasoned, correctly, that a heading is not postable: `0089`'s
-- journal refuses `is_group`, `resolve_account` skips headings, and
-- `0014`, `0016` and `0100` sum LEAVES -- so promoting an account with
-- a balance drops that balance out of the trial balance, the profit and
-- loss and the cash flow statement at once. It then refused three
-- things for that reason: a parent with posted entries, a parent with
-- an opening balance, and a parent whose CODE the ledger resolves by
-- number.
--
-- All three are reasons THE PARENT MUST NOT BECOME A HEADING. `0655`
-- read them as reasons a child cannot go under it, because it promoted
-- the parent as a matter of course. That is the step this removes.
--
-- A parent that was not promoted is still a leaf. It keeps its own
-- balance, every report goes on counting it exactly once, and it goes
-- on being found by number -- `1120` is the bank leg `post_expense`
-- falls back to when an expense names no bank account, which is the
-- reason its refusal exists and is entirely unaffected by something
-- being nested under it.
--
-- Nothing is double counted by this. A parent's figure is its OWN
-- balance and never the sum of its children; the tree is how the chart
-- is read, not how it is added up.
--
-- ---------------------------------------------------------------------
-- What the caller is told
--
-- `parent_promoted` already existed, so that the app could say "1120 is
-- now a heading" once rather than leave somebody to discover that the
-- account they were posting to has stopped being offered. The opposite
-- now needs saying too, and for the same reason: somebody who has just
-- nested Maybank under Bank Accounts should know that Bank Accounts is
-- still a place money can land. Hence `parent_stays_postable` and the
-- refusal that explains it.
--
-- `app.sub_account_refusal` is unchanged -- it always answered "may
-- this become a heading?" and that is still exactly what it answers.
-- Only its comment moves, because the name reads like the other
-- question and that is what led here.
--
-- Restated from the applied database, where `0655` left it.
-- =====================================================================

comment on function app.sub_account_refusal(uuid) is
  'Why this parent cannot be PROMOTED TO A HEADING, or null if it can. '
  'Not a reason a child cannot go under it: since 0693 a sub-account '
  'may be added under an account that goes on posting, and this is '
  'what decides which of the two happens. Split out so the app can say '
  'which it will be before somebody presses the button. 0655, 0693.';

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

  -- Asked, and no longer raised on. `0693`.
  --
  -- This answers "may the PARENT become a heading?", which `0655` took
  -- to be the same question as "may a child go under it?" -- and it is
  -- not. A child under a parent that goes on posting is a perfectly
  -- ordinary chart: `1120 Bank Accounts` keeps its own balance and its
  -- role as the cash fallback, and `1120-M001 Maybank` sits under it.
  -- Every report sums LEAVES, and a parent that was not promoted is
  -- still a leaf, so nothing is double counted and nothing drops out.
  --
  -- So a refusal now decides whether to PROMOTE, and the answer comes
  -- back with the row.
  v_refusal := app.sub_account_refusal(p_parent_id);

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

  -- Promote the parent only where promoting it costs nothing. A
  -- heading that was already a heading is left alone, so `promoted` in
  -- the answer means "this changed under you" rather than "this is a
  -- heading".
  --
  -- Where it would cost something the child still goes in and the
  -- parent goes on posting. That is the whole of `0693`: the three
  -- things `sub_account_refusal` objects to -- posted entries, an
  -- opening balance, a code the ledger resolves by number -- are all
  -- reasons the parent's own FIGURE must not leave the reports. None
  -- of them is a reason the child cannot exist.
  if not v_parent.is_group and v_refusal is null then
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
    'parent_promoted', v_promoted,
    -- And the other way round, which is the case `0693` added: the
    -- parent kept its balance and goes on being posted to. Said for
    -- the same reason -- somebody who has just nested an account under
    -- it should know it is still a place money can land.
    'parent_stays_postable', (not v_promoted) and not v_parent.is_group,
    'not_promoted_because', case
      when v_promoted or v_parent.is_group then null
      else v_refusal
    end);
end;
$function$;

comment on function public.add_sub_account(
  uuid, text, text, app.account_subtype, text, text) is
  'Adds an account under another. Refuses a caller who may not post, a '
  'nameless account, a code already in use and a subtype from another '
  'statement. Promotes the parent to a heading where that costs '
  'nothing; where it would cost something -- posted entries, an '
  'opening balance, or a code the ledger resolves by number -- the '
  'child still goes in and the parent goes on posting. Answers the new '
  'account with `parent_promoted`, `parent_stays_postable` and, when '
  'it stays postable, `not_promoted_because`. 0655, 0693.';

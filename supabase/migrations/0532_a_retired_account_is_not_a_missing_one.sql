-- =====================================================================
-- 0532  A retired account is not a missing one
--
-- Found by a mutation sweep of `dispose_fixed_asset`. The fixture set
-- out to prove that a soft-deleted 6510 is not reused for this year's
-- loss on disposal, and the disposal did not post at all:
--
--     ERROR: duplicate key value violates unique constraint
--            "accounts_org_id_code_key"
--
-- `app.disposal_account` looks for its account with
--
--     where org_id = p_org_id and code = v_code and deleted_at is null
--
-- and inserts one when it finds none. But `accounts_org_id_code_key` is
-- a plain UNIQUE (org_id, code) — it does not know about `deleted_at` —
-- so once a company retires its 6510, the lookup can never find it and
-- the insert can never succeed. THE COMPANY CANNOT RECORD SELLING
-- ANYTHING AT A LOSS AGAIN, and what it gets is a constraint violation
-- rather than anything it could act on.
--
-- Retiring an account is an ordinary thing to do: `Settings › Chart of
-- accounts` offers it, and 6510 and 3900 are exactly the sort of
-- account a tidy-minded bookkeeper removes because nothing has ever
-- been posted to it.
--
-- THE RULE, WRITTEN ONCE. A retired account with the code we need is
-- the account we need. It is revived rather than duplicated — the code
-- IS the identity in a chart of accounts, the unique key says so, and a
-- second 6510 would be worse than the error. `app.revive_account` does
-- that and nothing else, so the five callers below each gain one line
-- rather than five.
--
-- WHAT THIS DOES NOT TOUCH. Eight further helpers create accounts the
-- same way — `absorption_account`, `cheque_account`,
-- `deferred_revenue_account`, `deposit_account`,
-- `goods_in_transit_account`, `landed_cost_account`,
-- `stall_purchases_account`, `withholding_account` — but their lookups
-- do NOT filter `deleted_at`, so they find the retired row and return
-- it. That is a quieter fault of its own: postings land on an account
-- the chart says is gone, and it does not stop anybody working. It is
-- recorded rather than fixed here, because the five below are the ones
-- that raise.
-- =====================================================================

-- Revive a retired account, and say whether there was one.
--
-- SECURITY DEFINER because every caller is, and because the point is to
-- repair a chart from inside a posting routine that has already decided
-- what it needs. It changes nothing when there is no retired row: the
-- update matches nothing and the function returns null, which is what
-- the caller's `if v_id is not null` reads.
create or replace function app.revive_account(p_org_id uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  update public.accounts
     set deleted_at = null, is_active = true, updated_at = now()
   where org_id = p_org_id and code = p_code and deleted_at is not null
  returning id into v_id;
  return v_id;
end $$;

comment on function app.revive_account(uuid, text) is
  'Bring a soft-deleted account of this code back. The chart holds one '
  'account per code — accounts_org_id_code_key — so a helper that needs '
  '6510 and finds only a retired 6510 must revive it: inserting raises, '
  'and posting to a retired account hides the entry.';

revoke all on function app.revive_account(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The five that raised
-- ---------------------------------------------------------------------
create or replace function app.disposal_account(p_org_id uuid, p_gain boolean)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_code   text := case when p_gain then '4930' else '6510' end;
  v_parent text := case when p_gain then '4000' else '6000' end;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  v_id := app.revive_account(p_org_id, v_code);
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code,
    case when p_gain then 'Gain on Disposal of Assets'
         else 'Loss on Disposal of Assets' end,
    'What an asset fetched, against what the books still carried it at. '
    'Separate from foreign exchange, which is where this used to land.',
    case when p_gain then 'revenue' else 'expense' end::app.account_type,
    case when p_gain then 'other_income' else 'other_expense' end::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = v_parent and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

create or replace function app.opening_balance_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '3900' and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  v_id := app.revive_account(p_org_id, '3900');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, '3900', 'Opening Balance Equity',
    'The other side of balances brought in from a previous system. '
    'Once everything has been carried across this account is zero; '
    'whatever is left in it has not been brought over yet.',
    'equity', 'retained_earnings',
    (select id from public.accounts
      where org_id = p_org_id and code = '3000' and deleted_at is null),
    false, true, true, 3900)
  returning id into v_id;

  return v_id;
end $$;

create or replace function app.property_expense_account(
  p_org_id uuid, p_kind app.statutory_property_charge)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id   uuid;
  v_code text := case p_kind
    when 'quit_rent'  then '6296'
    when 'assessment' then '6297'
    end;
  v_name text := case p_kind
    when 'quit_rent'  then 'Quit Rent'
    when 'assessment' then 'Assessment'
    end;
  v_note text := case p_kind
    when 'quit_rent' then
      'Rent reserved to the State on alienated land under the National '
      'Land Code, payable to the land office for the year.'
    when 'assessment' then
      'Rates levied on the holding by the local authority under the '
      'Local Government Act 1976, usually in two half-yearly bills.'
    end;
begin
  if v_code is null then
    raise exception 'Unknown statutory property charge "%"', p_kind
      using errcode = '22023';
  end if;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  v_id := app.revive_account(p_org_id, v_code);
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code, v_name, v_note,
    'expense'::app.account_type, 'operating_expense'::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = '6000' and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

create or replace function app.property_income_account(
  p_org_id uuid, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id   uuid;
  v_code text := case p_kind
    when 'maintenance' then '4810'
    when 'sinking'     then '4820'
    when 'rent'        then '4830'
    end;
  v_name text := case p_kind
    when 'maintenance' then 'Maintenance Charges'
    when 'sinking'     then 'Sinking Fund Contributions'
    when 'rent'        then 'Rental Income'
    end;
  v_note text := case p_kind
    when 'maintenance' then
      'Charges levied under the SMA 2013 in proportion to allocated share '
      'units.'
    when 'sinking' then
      'Contributions to the sinking fund, at least ten per cent of the '
      'Charges. Held for capital expenditure and not for running costs.'
    when 'rent' then 'Rent receivable under a tenancy.'
    end;
begin
  if v_code is null then
    raise exception 'Unknown property income account "%"', p_kind
      using errcode = '22023';
  end if;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  v_id := app.revive_account(p_org_id, v_code);
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code, v_name, v_note,
    'revenue'::app.account_type, 'sales'::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = '4000' and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

create or replace function app.time_income_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '4840' and deleted_at is null;
  if v_id is not null then return v_id; end if;

  v_id := app.revive_account(p_org_id, '4840');
  if v_id is not null then return v_id; end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, '4840', 'Professional Fees',
    'Chargeable time billed to clients.',
    'revenue'::app.account_type, 'sales'::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = '4000' and deleted_at is null),
    false, true, true, 4840)
  returning id into v_id;
  return v_id;
end $$;

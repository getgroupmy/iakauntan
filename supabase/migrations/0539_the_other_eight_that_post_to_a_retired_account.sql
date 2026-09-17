-- =====================================================================
-- The other eight helpers that post to a retired account
--
-- 0532 fixed five of these — `disposal_account`,
-- `opening_balance_account`, `property_expense_account`,
-- `property_income_account`, `time_income_account` — and recorded that
-- eight more had the same shape and were left for a follow-up. This is
-- the follow-up.
--
-- THE EIGHT FAIL DIFFERENTLY FROM THE FIVE, AND WORSE.
--
-- The five looked for an account `where deleted_at is null`, found
-- none, and went on to INSERT. With a retired account of that code
-- already on file the insert hit `accounts_org_id_code_key` and the
-- whole posting crashed. Loud, traceable, and it stopped.
--
-- These eight have no `deleted_at` filter at all. They FIND the retired
-- account and return it, and the entry is posted to an account the
-- chart no longer shows. Nothing raises. Nothing in the app says so.
-- The trial balance still balances, because the entry is really there —
-- it is on a row that every screen filters out.
--
-- A company that tidied its chart last year and retired an account it
-- was not using is the whole population at risk, and 2145 (Withholding
-- Tax Payable), 2127 (Deferred Revenue) and 1140 (Cheques on Hand) are
-- exactly the accounts a company that has not needed them yet would
-- retire.
--
-- The fix is 0532's, unchanged: look for a live account of the code,
-- REVIVE a retired one, and only then insert. The chart holds one
-- account per code, so there is no third option — inserting raises, and
-- returning the retired row hides the entry.
--
-- Nothing else about the eight changes. `withholding_account` is
-- restructured from `if v_id is null then insert` to the early-return
-- shape the other seven use, so that all thirteen helpers now read the
-- same way; that is a rewrite of the same logic, not a change to it.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.absorption_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5350' and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '5350');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5350', 'Manufacturing Cost Absorbed', 'expense',
          'cost_of_sales', false, true, 5350,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end; $function$
;

CREATE OR REPLACE FUNCTION app.cheque_account(p_org_id uuid, p_direction text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id uuid;
  v_in boolean := p_direction = 'incoming';
  v_code text := case when v_in then '1140' else '2115' end;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, v_code);
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, v_code,
          case when v_in then 'Cheques on Hand' else 'Cheques Issued' end,
          (case when v_in then 'asset' else 'liability' end)::app.account_type,
          (case when v_in then 'current_asset' else 'current_liability' end)
            ::app.account_subtype,
          false, true, v_code::integer,
          (select id from public.accounts
            where org_id = p_org_id
              and code = case when v_in then '1100' else '2100' end))
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.deferred_revenue_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid; v_parent uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '2127'
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '2127');
  if v_id is not null then
    return v_id;
  end if;

  select id into v_parent from public.accounts
   where org_id = p_org_id and code = '2100';

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, parent_id,
     is_group, is_system, is_active)
  values (p_org_id, '2127', 'Deferred Revenue', 'liability',
          'current_liability', v_parent, false, true, true)
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.deposit_account(p_org_id uuid, p_kind text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id     uuid;
  v_code   text;
  v_name   text;
  v_type   text;
  v_sub    text;
  v_parent text;
begin
  select case p_kind
    when 'customer' then '2125' when 'supplier' then '1235'
    when 'income'   then '4930' else '6610' end into v_code;
  select case p_kind
    when 'customer' then 'Customer Deposits'
    when 'supplier' then 'Deposits Paid to Suppliers'
    else 'Deposits Forfeited' end into v_name;
  select case p_kind
    when 'customer' then 'liability' when 'supplier' then 'asset'
    when 'income'   then 'revenue'   else 'expense' end into v_type;
  select case p_kind
    when 'customer' then 'current_liability' when 'supplier' then 'current_asset'
    when 'income'   then 'other_income'      else 'other_expense' end into v_sub;
  select case p_kind
    when 'customer' then '2100' when 'supplier' then '1200'
    when 'income'   then '4900' else '6000' end into v_parent;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, v_code);
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, v_code, v_name, v_type::app.account_type,
          v_sub::app.account_subtype, false, true, v_code::integer,
          (select id from public.accounts
            where org_id = p_org_id and code = v_parent))
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.goods_in_transit_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '1320' and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '1320');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '1320', 'Goods in Transit', 'asset', 'inventory',
          false, true, 1320,
          (select id from public.accounts
            where org_id = p_org_id and code = '1300'))
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.landed_cost_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5400' and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '5400');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5400', 'Freight and Import Duty', 'expense',
          'cost_of_sales', false, true, 5400,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.stall_purchases_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5150' and not is_group
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '5150');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5150', 'Stall Purchases', 'expense', 'cost_of_sales',
          false, true, 5150,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION app.withholding_account(p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '2145'
     and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape: a retired account of this code is brought back
  -- rather than posted to. The chart holds one account per code,
  -- so there is no third option -- inserting raises on the unique
  -- key, and returning the retired row hides every entry made.
  v_id := app.revive_account(p_org_id, '2145');
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (p_org_id, '2145', 'Withholding Tax Payable', 'liability',
          'tax_payable', false,
          (select id from public.accounts
            where org_id = p_org_id and code = '2100'), 2145)
  returning id into v_id;
  return v_id;
end; $function$

;

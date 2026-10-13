-- =====================================================================
-- iAkauntan :: 0856 an account's balance is the ledger's to show
--
-- `0855` gave the reports built from the ledger the question the
-- journals ask of their reader, `app.can_read_ledger`. One column was
-- left: `accounts.current_balance`, the running total
-- `app.apply_account_balance` keeps of every posted line (`0009`,
-- `0844`). `accounts_select` admits every member, as it must -- a
-- salesman picks a revenue account on an invoice line -- so every
-- member read every account's balance: the trial balance, one column
-- away from the reports they had just been refused.
--
-- Measured on 13 October 2026, locally, with `0855` applied, as a
-- `sales` member with the role `authenticated`: `report_general_ledger`
-- gave nothing, and `accounts` gave 3100 Share Capital 4,321.09 and
-- 5100 Purchases 4,321.09.
--
-- Answered "withhold the running balance". Row level security cannot
-- hide a column, and `authenticated` is one database role for the
-- accountant and the salesman alike, so the column is withheld from
-- everybody's direct reads and served to the ledger's readers through
-- a function:
--
--   * `authenticated` keeps select on every column of `accounts` but
--     `current_balance`. Insert and update are untouched (`0643` and
--     `0844` already refuse a client's own balance), and nothing a
--     client runs reads the column: `apply_account_balance` fires on
--     `gl_lines`, which only definers write, and no invoker function,
--     view, policy, edge function or realtime feed names it.
--   * `account_balances(org)`, a definer, answers it -- for a reader
--     `can_read_ledger` admits, and with nothing for anybody else, as
--     the reports in SQL answer since `0855`.
--
-- A `select *` on `accounts` is now refused to every client role, the
-- accountant's included. The app names its columns.
--
-- `opening_balance` stays readable: the chart editor shows and types
-- it, and it was not part of the answer.
--
-- Production on 13 October: every member is an owner, admin,
-- accountant, accounts clerk or auditor, and none of them reads the
-- column any longer except through the function.
-- =====================================================================

revoke select on public.accounts from authenticated;
grant select (id, org_id, code, name, description, account_type,
              account_subtype, parent_id, is_group, is_system, is_active,
              currency, tax_code_id, opening_balance, opening_balance_date,
              sort_order, created_at, updated_at, deleted_at, import_source,
              import_ref, import_batch_id, imported_at, tax_treatment)
  on public.accounts to authenticated;

create or replace function public.account_balances(p_org_id uuid)
returns table (account_id uuid, current_balance numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select a.id, a.current_balance
    from public.accounts a
   where a.org_id = p_org_id
     and a.deleted_at is null
     and app.can_read_ledger(p_org_id)
   order by a.code;
$$;

comment on function public.account_balances(uuid) is
  'Each live account''s running balance, for a reader app.can_read_ledger '
  'admits, and nothing for anybody else. The column itself is withheld '
  'from authenticated. 0856.';

revoke all on function public.account_balances(uuid) from public, anon;
grant execute on function public.account_balances(uuid)
  to authenticated, service_role;

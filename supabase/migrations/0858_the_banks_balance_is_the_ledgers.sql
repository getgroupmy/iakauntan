-- =====================================================================
-- iAkauntan :: 0858 the bank's balance is the ledger's
--
-- `0855` gave the reports built from the ledger `app.can_read_ledger`,
-- `bank_reconciliation_status` among them, and `0856` withheld the
-- running balance on `accounts`. The bank's own running balance,
-- `bank_accounts.current_balance` (`resync_bank_balance`, `0175`,
-- rebuilds it from the bank's GL account), was still every member's:
--
--   * `bank_accounts_select` admits every member -- a salesman picks the
--     account a receipt lands in -- and with it the column;
--   * `dashboard_summary` gives every member `bank_balance`;
--   * `report_cash_forecast` asks the accounting module, which
--     `app.module_access` grants every member without a custom access
--     type, and opens its weeks at the bank's balance.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated`, after a journal of 98,765.43 into the bank's GL
-- account and `resync_bank_balance`: the table gave 98,765.43, the
-- dashboard 98,765.43, and the forecast opened at 98,765.43.
--
-- Answered "bank balances need ledger access", as `0856` did for
-- accounts:
--
--   * `authenticated` holds select on every column of `bank_accounts`
--     but `current_balance` -- select is all it ever held (`0823`). No
--     invoker function, view, policy, edge function or realtime feed
--     reads the column; the one invoker trigger on the table reads
--     `accounts`.
--   * `bank_balances(org)`, a definer, gives each bank account's
--     balance to a reader `can_read_ledger` admits and nothing to
--     anybody else.
--   * `dashboard_summary` gives `bank_balance` only to such a reader,
--     and nothing -- not nought -- to anybody else.
--   * `report_cash_forecast` keeps its module check and adds
--     "Insufficient privileges to read the ledger", as in `0855`.
--
-- Each function is restated from the migration named above it, its text
-- unchanged but for that. `opening_balance` stays readable, as on
-- `accounts`.
--
-- Production on 13 October: every member is an owner, admin,
-- accountant, accounts clerk or auditor.
-- =====================================================================

revoke select on public.bank_accounts from authenticated;
grant select (id, org_id, account_id, name, bank_name, bank_code,
              account_number, account_type, currency, opening_balance,
              is_default, is_active, created_at, updated_at,
              is_client_account, import_source, import_ref,
              import_batch_id, imported_at)
  on public.bank_accounts to authenticated;

create or replace function public.bank_balances(p_org_id uuid)
returns table (bank_account_id uuid, current_balance numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select b.id, b.current_balance
    from public.bank_accounts b
   where b.org_id = p_org_id
     and app.can_read_ledger(p_org_id)
   order by b.name;
$$;

comment on function public.bank_balances(uuid) is
  'Each bank account''s running balance, for a reader app.can_read_ledger '
  'admits, and nothing for anybody else. The column itself is withheld '
  'from authenticated. 0858.';

revoke all on function public.bank_balances(uuid) from public, anon;
grant execute on function public.bank_balances(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- public.dashboard_summary, from `0419`
-- ---------------------------------------------------------------------
create or replace function public.dashboard_summary(
  p_org_id uuid, p_from date default null, p_to date default app.today())
returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_from date := coalesce(p_from, date_trunc('month', app.today())::date);
  v_result jsonb;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'revenue', (
      select coalesce(sum(base_total_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'expenses', (
      select coalesce(sum(base_total_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null),
    'payables', (
      select coalesce(sum(balance_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null),
    'overdue_receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and due_date < app.today() and balance_amount > 0),
    -- `0858`. The bank's balance is the ledger's, and only a reader of
    -- the ledger is given it; anybody else is given nothing, not nought.
    'bank_balance', case when app.can_read_ledger(p_org_id) then (
      select coalesce(sum(current_balance), 0) from public.bank_accounts
       where org_id = p_org_id and is_active) end,
    'draft_invoices', (
      select count(*) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status = 'draft' and deleted_at is null),
    'einvoice_pending', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('draft', 'queued', 'submitted')),
    'einvoice_invalid', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('invalid', 'failed')),
    'open_opportunities', (
      select coalesce(sum(amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'weighted_pipeline', (
      select coalesce(sum(weighted_amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'activities_due', (
      select count(*) from public.activities
       where org_id = p_org_id and status = 'pending'
         and due_date <= app.today() + interval '1 day'),
    'low_stock', (
      select count(*) from public.items
       where org_id = p_org_id and deleted_at is null and track_inventory
         and reorder_level > 0 and quantity_on_hand <= reorder_level)
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- public.report_cash_forecast, from `0419`
-- ---------------------------------------------------------------------
create or replace function public.report_cash_forecast(
  p_org uuid,
  p_weeks integer default 13,
  p_use_history boolean default true)
returns table (
  week_no     integer,
  week_start  date,
  week_end    date,
  opening     numeric,
  money_in    numeric,
  money_out   numeric,
  net         numeric,
  closing     numeric,
  overdrawn   boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_weeks integer := least(greatest(coalesce(p_weeks, 13), 1), 104);
  v_from  date := app.today();
  v_to    date;
  v_open  numeric(18, 2);
begin
  if not app.can_read_module(p_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;
  v_to := v_from + (v_weeks * 7 - 1);

  select coalesce(sum(b.current_balance), 0) into v_open
    from public.bank_accounts b
   where b.org_id = p_org and b.is_active;

  return query
  with weeks as (
    select generate_series(1, v_weeks) as n
  ),
  bounded as (
    select w.n,
           v_from + ((w.n - 1) * 7) as w_start,
           v_from + (w.n * 7 - 1)   as w_end
      from weeks w
  ),
  moved as (
    select b.n,
           coalesce(sum(m.amount) filter (where m.direction = 'in'), 0) as inflow,
           coalesce(sum(m.amount) filter (where m.direction = 'out'), 0) as outflow
      from bounded b
      left join app.cash_forecast_movements(p_org, v_from, v_to, p_use_history) m
        on m.expected_on between b.w_start and b.w_end
     group by b.n
  ),
  running as (
    select b.n, b.w_start, b.w_end, m.inflow, m.outflow,
           v_open + coalesce(sum(m.inflow - m.outflow)
             over (order by b.n rows between unbounded preceding
                                         and 1 preceding), 0) as opening,
           v_open + sum(m.inflow - m.outflow)
             over (order by b.n rows unbounded preceding) as closing
      from bounded b join moved m on m.n = b.n
  )
  select r.n, r.w_start, r.w_end,
         round(r.opening, 2), round(r.inflow, 2), round(r.outflow, 2),
         round(r.inflow - r.outflow, 2), round(r.closing, 2),
         r.closing < 0
    from running r
   order by r.n;
end;
$$;

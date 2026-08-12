-- =====================================================================
-- iAkauntan :: 0100 statement of cash flows, statement of changes in equity
--
-- MFRS 101 and MPERS Section 3 both require a *complete* set of
-- financial statements. A balance sheet, a profit and loss and a trial
-- balance is not one: the cash flow statement (MFRS 107, MPERS Section
-- 7) and the statement of changes in equity (MFRS 101, MPERS Section 6)
-- are missing, and a corporate secretarial module that cannot produce
-- the accounts it exists to file is only half a module.
--
-- The cash flow statement is built the indirect way, which is what
-- every Malaysian company files, and it is derived rather than
-- classified by hand. The whole thing rests on one identity:
--
--   every journal balances, so across all accounts the debits and the
--   credits cancel. Therefore the movement in cash equals the *negative*
--   of the movement in everything else.
--
-- So each non-cash account contributes `-(debits - credits)` to cash —
-- a debit absorbs cash, a credit releases it — and the sections are
-- nothing more than a grouping of those contributions. The statement
-- cannot fail to reconcile to the cash accounts, because reconciling is
-- the only thing it does. What is a judgement is which section a
-- movement belongs in, and that comes from the account's subtype, so
-- correcting a misclassified statement means correcting the chart of
-- accounts — which is where it was wrong in the first place.
--
-- Two consequences of the identity worth writing down:
--
-- **A year-end close is left out.** It moves a year of profit from the
-- profit and loss into retained earnings and touches no cash. It nets
-- to zero across every account, so dropping it changes no total — but
-- leaving it in would drag the year's profit out of operating and into
-- financing on any statement that spans the close.
--
-- **Depreciation is classified operating, not investing.** The expense
-- and the accumulated depreciation it credits then fall in the same
-- section and cancel, which is exactly what "add back depreciation"
-- means. Putting accumulated depreciation in investing would show a
-- cash outflow from operating and an equal inflow from investing, for a
-- transaction where no money moved.
--
-- `supabase/tests/financial_statements.sql` asserts the reconciliation
-- of both statements — the cash flow to the movement in the bank
-- accounts, and the closing equity to net assets on the balance sheet.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Statement of cash flows, indirect method
-- ---------------------------------------------------------------------
create or replace function public.report_cash_flow(
  p_org_id uuid,
  p_from date,
  p_to date)
returns table (
  section text, label text, amount numeric, sort_order integer)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with movements as (
    select a.id, a.code, a.name, a.account_type, a.account_subtype,
           -- What this account did to cash. A debit used cash up, a
           -- credit freed it, so the sign is the other way round from
           -- the ledger.
           round(-sum(l.debit - l.credit), 2) as contributed
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date between p_from and p_to
       and e.source <> 'year_end_close'
     group by a.id, a.code, a.name, a.account_type, a.account_subtype
  ),
  classified as (
    select m.*,
           case
             when m.account_subtype in ('bank', 'cash') then 'cash'
             when m.account_type in ('revenue', 'expense') then 'profit'
             -- The add-back. Sitting in operating alongside the
             -- depreciation charge is what makes the two cancel.
             when m.account_subtype = 'accumulated_depreciation' then 'noncash'
             when m.account_subtype in ('fixed_asset', 'other_asset')
               then 'investing'
             when m.account_subtype in ('long_term_liability', 'share_capital',
                                        'retained_earnings', 'reserves',
                                        'drawings') then 'financing'
             -- Receivables, inventory, payables, accruals, tax: the
             -- working capital the business turns over.
             else 'working_capital'
           end as bucket
      from movements m
  ),
  cash_now as (
    select
      coalesce((select sum(l.debit - l.credit)
                  from public.gl_lines l
                  join public.gl_entries e on e.id = l.entry_id
                  join public.accounts a on a.id = l.account_id
                 where l.org_id = p_org_id and e.status = 'posted'
                   and a.account_subtype in ('bank', 'cash')
                   and e.entry_date < p_from), 0)
    + coalesce((select sum(a.opening_balance) from public.accounts a
                 where a.org_id = p_org_id and a.deleted_at is null
                   and not a.is_group
                   and a.account_subtype in ('bank', 'cash')), 0) as opening,
      coalesce((select sum(l.debit - l.credit)
                  from public.gl_lines l
                  join public.gl_entries e on e.id = l.entry_id
                  join public.accounts a on a.id = l.account_id
                 where l.org_id = p_org_id and e.status = 'posted'
                   and a.account_subtype in ('bank', 'cash')
                   and e.entry_date <= p_to), 0)
    + coalesce((select sum(a.opening_balance) from public.accounts a
                 where a.org_id = p_org_id and a.deleted_at is null
                   and not a.is_group
                   and a.account_subtype in ('bank', 'cash')), 0) as closing
  ),
  lines as (
    -- Operating: the result for the period, then what did not move cash,
    -- then what working capital did with it.
    select 'operating'::text as section,
           'Profit for the period'::text as label,
           coalesce(sum(c.contributed), 0) as amount,
           10 as sort_order
      from classified c where c.bucket = 'profit'
    union all
    select 'operating', 'Depreciation and amortisation',
           coalesce(sum(c.contributed), 0), 20
      from classified c where c.bucket = 'noncash'
      having coalesce(sum(c.contributed), 0) <> 0
    union all
    select 'operating', c.name, c.contributed, 30
      from classified c
     where c.bucket = 'working_capital' and c.contributed <> 0
    union all
    select 'investing', c.name, c.contributed, 10
      from classified c
     where c.bucket = 'investing' and c.contributed <> 0
    union all
    select 'financing', c.name, c.contributed, 10
      from classified c
     where c.bucket = 'financing' and c.contributed <> 0
    union all
    -- The reconciliation. `Net movement` is the sum of every
    -- contribution above, and the two cash figures come straight from
    -- the bank and cash accounts, so the statement proves itself.
    select 'reconciliation', 'Net movement in cash',
           coalesce((select sum(c.contributed) from classified c
                      where c.bucket <> 'cash'), 0), 10
    union all
    select 'reconciliation', 'Cash and cash equivalents brought forward',
           (select round(opening, 2) from cash_now), 20
    union all
    select 'reconciliation', 'Cash and cash equivalents carried forward',
           (select round(closing, 2) from cash_now), 30
  )
  select l.section, l.label, l.amount, l.sort_order
    from lines l
   where app.is_org_member(p_org_id)
   order by
     case l.section when 'operating' then 1 when 'investing' then 2
                    when 'financing' then 3 else 4 end,
     l.sort_order, l.label;
$$;

-- ---------------------------------------------------------------------
-- Statement of changes in equity
--
-- One row per equity component, plus the result for the period, which
-- is not in any of them until the year is closed. That row is what
-- makes the statement agree with the balance sheet: net assets include
-- this year's profit, and the equity accounts do not until the closing
-- journal moves it.
--
-- Which also means the row goes to zero of its own accord once the year
-- *is* closed — the profit and loss nets to nothing over a period
-- containing the close, and retained earnings has moved instead. No
-- special case, and no double count either way.
-- ---------------------------------------------------------------------
create or replace function public.report_changes_in_equity(
  p_org_id uuid,
  p_from date,
  p_to date)
returns table (
  account_id uuid, code text, name text,
  opening_balance numeric, movement numeric, closing_balance numeric,
  sort_order integer)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with equity as (
    select a.id, a.code, a.name, a.sort_order,
           -- Credit side positive, the way the balance sheet shows it.
           a.opening_balance
         + coalesce((select sum(l.credit - l.debit)
                       from public.gl_lines l
                       join public.gl_entries e on e.id = l.entry_id
                      where l.account_id = a.id and e.status = 'posted'
                        and e.entry_date < p_from), 0) as opening,
           coalesce((select sum(l.credit - l.debit)
                       from public.gl_lines l
                       join public.gl_entries e on e.id = l.entry_id
                      where l.account_id = a.id and e.status = 'posted'
                        and e.entry_date between p_from and p_to), 0) as moved
      from public.accounts a
     where a.org_id = p_org_id
       and a.account_type = 'equity'
       and a.deleted_at is null
       and not a.is_group
  ),
  result_for_period as (
    select coalesce(sum(l.credit - l.debit), 0) as profit
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and a.account_type in ('revenue', 'expense')
       and e.entry_date between p_from and p_to
  )
  select e.id, e.code, e.name,
         round(e.opening, 2), round(e.moved, 2), round(e.opening + e.moved, 2),
         e.sort_order
    from equity e
   where app.is_org_member(p_org_id)
     and (e.opening <> 0 or e.moved <> 0)
  union all
  select null::uuid, null::text, 'Profit for the financial period',
         0, round(r.profit, 2), round(r.profit, 2), 999999
    from result_for_period r
   where app.is_org_member(p_org_id)
     and round(r.profit, 2) <> 0
   order by 7, 2;
$$;

revoke all on function public.report_cash_flow(uuid, date, date) from public, anon;
revoke all on function public.report_changes_in_equity(uuid, date, date)
  from public, anon;
grant execute on function public.report_cash_flow(uuid, date, date) to authenticated;
grant execute on function public.report_changes_in_equity(uuid, date, date)
  to authenticated;

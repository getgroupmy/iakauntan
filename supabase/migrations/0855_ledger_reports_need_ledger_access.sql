-- =====================================================================
-- iAkauntan :: 0855 ledger reports need ledger access
--
-- The journals are read by the roles `app.can_read_ledger` names --
-- owner, admin, accountant, accounts clerk and auditor -- and by nobody
-- else: `0019` put that on `gl_entries` and `gl_lines` ("sales and
-- purchasing staff have no business reading the journals"), and the
-- role picker says it to whoever assigns one: sales, purchasing and
-- view-only "not the ledger", HR manager "cannot open the ledger", an
-- employee their own payslips, leave and claims.
--
-- The reports built from the journals are SECURITY DEFINER, so the
-- policies on those tables do not apply inside them, and they asked
-- only `app.is_org_member`. Measured on 13 October 2026, locally, as
-- an `employee` and as a `sales` member with the role `authenticated`:
-- `gl_lines` gave 0 rows, and `report_general_ledger` gave every line
-- -- JV-2026-00001, its date, its accounts, 4,321.09 -- with the trial
-- balance showing the same. The reports screen is offered to every
-- role.
--
-- Answered "ledger reports need ledger access". Two shapes here:
--
--   * A report written in SQL carries its guard in the WHERE clause and
--     answers a reader it does not serve with no rows, as it has always
--     answered a stranger. In the nine of those -- trial balance,
--     profit and loss, balance sheet, general ledger, cash flow,
--     changes in equity, profit and loss by dimension, the ledger's
--     dimensions, and `app.group_orgs` -- `is_org_member` becomes
--     `can_read_ledger` and nothing else moves.
--
--   * One written in PL/pgSQL refuses. Its membership check stays as it
--     was, wording and all (tests assert on it, and a stranger is still
--     told they are one), and a second refusal follows it:
--     "Insufficient privileges to read the ledger", 42501, the wording
--     `report_matter_ledger` and its neighbours already use.
--
-- Seventeen of the second kind, and why each:
--
--   * `report_with_layout`, the four `report_group_*`,
--     `report_deferred_revenue`, `suggest_bank_matches` and
--     `bank_reconciliation_status` read the ledger themselves.
--   * `tax_computation_lines`, `tax_estimate_exposure`, `fs_prepare` and
--     `fs_audit_exemption` are built on `report_profit_loss` and
--     `report_balance_sheet`. Those now give such a reader nothing, so
--     without a refusal of their own a sales member would be handed a
--     tax computation and a set of financial statements of zeros -- a
--     wrong answer, not a refusal.
--   * `fs_export` answers a frozen filing from `fs_figures`, without
--     `fs_prepare` and so without its refusal.
--   * `tax_computation`, `tax_computation_individual`,
--     `tax_partnership_allocation`, `tax_partnership_summary` and
--     `report_group_consolidated_trial_balance` would refuse through
--     what they are built on, in the same words. Each says it at its
--     top as well, so that the refusal does not depend on how its
--     figures are put together; the mutation sweep records these five
--     as equivalent.
--
-- `app.group_orgs` lists the companies in a group whose ledger the
-- reader may read, as it listed those they belonged to: an accountant
-- here who sells for a sister company sees this company in the group
-- trial balance and not the sister.
--
-- Each function is restated from the migration named above it, its
-- text unchanged but for the guard.
--
-- Not changed, and why:
--
--   * `dashboard_summary`, the aged receivables and payables, the SST
--     summary and the statement of account read documents, not the
--     journals.
--   * `report_budget_vs_actual`, `build_budget_from_actual` and
--     `report_project_budget` read the ledger's actuals behind a module
--     or membership check. Whether a budget holder is a ledger reader
--     is a question of its own, raised separately.
--   * `app.tax_business_income` cannot be called by a client, and
--     everything that calls it now refuses first. `close_fiscal_year`
--     asks `can_admin`.
--   * `accounts.current_balance` is readable by every member through
--     `accounts_select`. `authenticated` is one database role for the
--     accountant and the salesman alike, so a column grant cannot tell
--     them apart; that is the next question, not this migration's.
--
-- Production on 13 October: every active member is an owner, admin,
-- accountant, accounts clerk or auditor, so nobody loses a report they
-- had.
-- =====================================================================

-- ---------------------------------------------------------------------
-- public.report_trial_balance, from `0828`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with movements as (
    select l.account_id,
           -- With no start date every posted line is inside the period,
           -- so there is nothing to carry forward as an opening balance.
           sum(case when p_from is not null and e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0) + case when a.account_type in ('asset','expense')
               then a.opening_balance else -a.opening_balance end, 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0) - coalesce(m.cr, 0)
               + case when a.account_type in ('asset','expense')
                      then a.opening_balance else -a.opening_balance end, 2)
    from public.accounts a
    left join movements m on m.account_id = a.id
   where a.org_id = p_org_id
     -- Open, or closed with posted lines in it (0828). A closed account
     -- carrying lines is still part of the books, and leaving it out
     -- leaves the trial balance out by it. One with only a typed
     -- opening balance stays out, as `0458`'s ledger has it.
     and (a.deleted_at is null or m.account_id is not null)
     and not a.is_group
     and app.can_read_ledger(p_org_id)
   order by a.code;
$function$;

-- ---------------------------------------------------------------------
-- public.report_profit_loss, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_profit_loss(p_org_id uuid, p_from date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) as amount
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and e.status = 'posted'
     and e.entry_date between p_from and p_to
     and a.account_type in ('revenue', 'expense')
     and app.can_read_ledger(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$function$;

-- ---------------------------------------------------------------------
-- public.report_balance_sheet, from `0828`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_balance_sheet(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(sum(
           -- e.id is null when the journal did not satisfy the join
           -- conditions (draft, void, or after the cut-off date).
           case when e.id is null then 0
                when a.account_type in ('asset', 'expense')
                then l.debit - l.credit
                else l.credit - l.debit end), 0) + a.opening_balance, 2) as balance
    from public.accounts a
    left join public.gl_lines l on l.account_id = a.id
    left join public.gl_entries e on e.id = l.entry_id
         and e.status = 'posted' and e.entry_date <= p_as_at
   where a.org_id = p_org_id
     and not a.is_group
     and a.account_type in ('asset', 'liability', 'equity')
     and app.can_read_ledger(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance
  -- Open, or closed with posted lines by the date (0828): what a closed
  -- account still holds is still an asset, a liability or equity.
  having a.deleted_at is null or count(e.id) > 0
   order by a.code;
$function$;

-- ---------------------------------------------------------------------
-- public.report_general_ledger, from `0828`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_general_ledger(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_account_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, entry_date date, entry_no text, line_no integer, source text, description text, reference text, contact_name text, debit numeric, credit numeric, balance numeric, is_opening boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with bounds as (
    select coalesce(p_to, app.today()) as upto
  ),
  wanted as (
    select a.id, a.code, a.name, a.account_type, a.opening_balance
      from public.accounts a
     where a.org_id = p_org_id
       -- Open, or closed with posted lines (0828): a closed account
       -- with lines is part of the ledger. One with only a typed opening
       -- balance is still not.
       and (a.deleted_at is null
            or exists (select 1 from public.gl_lines pl
                          join public.gl_entries pe on pe.id = pl.entry_id
                         where pl.account_id = a.id and pe.status = 'posted'))
       and not a.is_group
       and (p_account_id is null or a.id = p_account_id)
  ),
  -- What the account stood at before the period began. The same sum
  -- `report_trial_balance` makes, including the account's own recorded
  -- opening balance signed by its type.
  opening as (
    select w.id as account_id,
           coalesce((
             select sum(l.debit - l.credit)
               from public.gl_lines l
               join public.gl_entries e on e.id = l.entry_id
              where l.account_id = w.id
                and l.org_id = p_org_id
                and e.status = 'posted'
                and p_from is not null
                and e.entry_date < p_from), 0)
           + case when w.account_type in ('asset', 'expense')
                  then w.opening_balance else -w.opening_balance end
             as amount
      from wanted w
  ),
  lines as (
    select w.id as account_id, w.code, w.name, w.account_type,
           e.entry_date, e.entry_no, e.source::text, l.description,
           e.reference, c.name as contact_name,
           l.debit, l.credit, l.line_no, e.created_at
      from wanted w
      join public.gl_lines l on l.account_id = w.id
      join public.gl_entries e on e.id = l.entry_id
      left join public.contacts c on c.id = l.contact_id
      cross join bounds b
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= b.upto
       and (p_from is null or e.entry_date >= p_from)
  ),
  running as (
    select l.*,
           o.amount + sum(l.debit - l.credit) over (
             partition by l.account_id
             order by l.entry_date, l.entry_no, l.line_no, l.created_at
             rows between unbounded preceding and current row) as balance
      from lines l
      join opening o on o.account_id = l.account_id
  )
  -- The line the balance is carried forward on, and then the account's
  -- movements under it.
  select w.id, w.code, w.name, w.account_type,
         p_from, null::text, null::integer, null::text,
         'Balance brought forward'::text, null::text, null::text,
         0::numeric, 0::numeric, round(o.amount, 2), true
    from wanted w
    join opening o on o.account_id = w.id
   where app.can_read_ledger(p_org_id)
     -- An account with nothing in it and nothing brought forward is not
     -- part of anybody's ledger.
     and (o.amount <> 0
          or exists (select 1 from lines l where l.account_id = w.id))
  union all
  select r.account_id, r.code, r.name, r.account_type,
         r.entry_date, r.entry_no, r.line_no, r.source, r.description,
         r.reference, r.contact_name, round(r.debit, 2), round(r.credit, 2),
         round(r.balance, 2), false
    from running r
   where app.can_read_ledger(p_org_id)
  -- The same order the running balance was computed in. Printing the
  -- rows any other way would show balances that do not follow from the
  -- lines above them, which is the one thing a ledger may not do.
   order by 2, 15 desc, 5, 6, 7;
$function$;

-- ---------------------------------------------------------------------
-- public.report_cash_flow, from `0828`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_cash_flow(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(section text, label text, amount numeric, sort_order integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
    -- And a closed account's opening balance where it has posted lines
    -- (0828), as the trial balance counts it; the lines beside this sum
    -- never asked whether an account was open.
    + coalesce((select sum(a.opening_balance) from public.accounts a
                 where a.org_id = p_org_id
                   and (a.deleted_at is null
                        or exists (select 1 from public.gl_lines ol
                                    join public.gl_entries oe on oe.id = ol.entry_id
                                   where ol.account_id = a.id and oe.status = 'posted'))
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
                 where a.org_id = p_org_id
                   and (a.deleted_at is null
                        or exists (select 1 from public.gl_lines cl
                                    join public.gl_entries ce2 on ce2.id = cl.entry_id
                                   where cl.account_id = a.id and ce2.status = 'posted'))
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
   where app.can_read_ledger(p_org_id)
   order by
     case l.section when 'operating' then 1 when 'investing' then 2
                    when 'financing' then 3 else 4 end,
     l.sort_order, l.label;
$function$;

-- ---------------------------------------------------------------------
-- public.report_changes_in_equity, from `0828`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_changes_in_equity(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(account_id uuid, code text, name text, opening_balance numeric, movement numeric, closing_balance numeric, sort_order integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
       -- Open, or closed with posted lines (0828).
       and (a.deleted_at is null
            or exists (select 1 from public.gl_lines pl
                           join public.gl_entries pe on pe.id = pl.entry_id
                          where pl.account_id = a.id and pe.status = 'posted'))
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
   where app.can_read_ledger(p_org_id)
     and (e.opening <> 0 or e.moved <> 0)
  union all
  select null::uuid, null::text, 'Profit for the financial period',
         0, round(r.profit, 2), round(r.profit, 2), 999999
    from result_for_period r
   where app.can_read_ledger(p_org_id)
     and round(r.profit, 2) <> 0
   order by 7, 2;
$function$;

-- ---------------------------------------------------------------------
-- public.report_profit_loss_by_dimension, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_profit_loss_by_dimension(p_org_id uuid, p_from date, p_to date DEFAULT app.today(), p_project_code text DEFAULT NULL::text, p_department_code text DEFAULT NULL::text)
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) as amount
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and e.status = 'posted'
     and e.entry_date between p_from and p_to
     and a.account_type in ('revenue', 'expense')
     and (p_project_code is null or l.project_code = p_project_code)
     and (p_department_code is null or l.department_code = p_department_code)
     and app.can_read_ledger(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$function$;

-- ---------------------------------------------------------------------
-- public.ledger_dimensions, from `0088`
-- ---------------------------------------------------------------------
create or replace function public.ledger_dimensions(p_org_id uuid)
returns table (kind text, code text, entries bigint)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select 'project', l.project_code, count(*)
    from public.gl_lines l
   where l.org_id = p_org_id and l.project_code is not null
     and app.can_read_ledger(p_org_id)
   group by l.project_code
  union all
  select 'department', l.department_code, count(*)
    from public.gl_lines l
   where l.org_id = p_org_id and l.department_code is not null
     and app.can_read_ledger(p_org_id)
   group by l.department_code
   order by 1, 2;
$$;

-- ---------------------------------------------------------------------
-- app.group_orgs, from `0142`
-- ---------------------------------------------------------------------
create or replace function app.group_orgs(p_org_id uuid)
returns table (org_id uuid, base_currency text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.id, o.base_currency
    from public.organizations o
   where app.can_read_ledger(p_org_id)
     and app.can_read_ledger(o.id)
     and o.group_id is not null
     and o.group_id = (select group_id from public.organizations
                        where id = p_org_id);
$$;

-- ---------------------------------------------------------------------
-- public.report_with_layout, from `0637`
-- ---------------------------------------------------------------------
create or replace function public.report_with_layout(
  p_org_id uuid,
  p_kind app.report_kind,
  p_from date default null,
  p_to date default null,
  p_layout_id uuid default null,
  p_project_code text default null,
  p_department_code text default null)
returns table (
  row_key text,
  kind app.layout_row_kind,
  label text,
  depth smallint,
  emphasise boolean,
  amount numeric,
  account_code text,
  account_name text,
  sort_order integer,
  line_no integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_layout uuid;
  v_row    record;
  v_acct   record;
  v_total  numeric(18, 2);
  v_ref    jsonb;
  v_seen   jsonb := '{}'::jsonb;
  v_line   integer;
  v_balances app.account_balance[];
  -- `current_date` is UTC, and a Malaysian business day is eight hours
  -- ahead of it: at 7am in Kuala Lumpur on the 1st, `current_date` is
  -- still the 31st and the report would stop a day short. `utc_is_not_
  -- today.sql` refuses the default outright, which is how this was
  -- caught rather than reasoned about.
  v_to     date := coalesce(p_to, app.today());
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  -- A balance sheet for one project is not a thing this schema can
  -- answer: a cumulative position needs every line ever posted, and
  -- the opening balances carry no dimension. Refusing says so;
  -- ignoring it would return a figure that balances and is wrong,
  -- which is the worst way to be wrong.
  if p_kind = 'balance_sheet'
     and (p_project_code is not null or p_department_code is not null) then
    raise exception
      'A balance sheet cannot be filtered by project or department: '
      'opening balances carry neither.' using errcode = '0A000';
  end if;

  if p_layout_id is not null then
    select l.id into v_layout from public.report_layouts l
     where l.id = p_layout_id and l.org_id = p_org_id
       and l.deleted_at is null;
    if v_layout is null then
      raise exception 'Layout % not found', p_layout_id using errcode = 'P0002';
    end if;
  else
    select l.id into v_layout from public.report_layouts l
     where l.org_id = p_org_id and l.kind = p_kind
       and l.is_active and l.deleted_at is null;
  end if;

  -- The balances every row is drawn from, gathered ONCE into an array.
  -- Not a temporary table: this function is STABLE, PostgREST runs a
  -- STABLE function in a READ ONLY transaction, and `create temporary
  -- table` there fails with 25006 -- so the report would not have run
  -- from the app at all.
  if p_kind = 'profit_loss' then
    select array_agg(b::app.account_balance) into v_balances from (
      select a.id, a.code, a.name, a.account_type, a.account_subtype,
             round(sum(case when a.account_type = 'revenue'
                            then l.credit - l.debit
                            else l.debit - l.credit end), 2)
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and (p_from is null or e.entry_date >= p_from)
         and e.entry_date <= v_to
         and (p_project_code is null or l.project_code = p_project_code)
         and (p_department_code is null
              or l.department_code = p_department_code)
       group by a.id, a.code, a.name, a.account_type, a.account_subtype
    ) b;
  else
    -- A balance sheet is cumulative to a date, so `p_from` is ignored
    -- rather than applied: a balance sheet "from March" is not a
    -- thing, and silently honouring it would produce a figure that
    -- balances and is wrong.
    select array_agg(b::app.account_balance) into v_balances from (
      select a.id, a.code, a.name, a.account_type, a.account_subtype,
             round(sum(case when a.account_type in ('asset', 'expense')
                            then l.debit - l.credit
                            else l.credit - l.debit end), 2)
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and e.entry_date <= v_to
       group by a.id, a.code, a.name, a.account_type, a.account_subtype
    ) b;
  end if;

  -- A company with no posted entries aggregates to NULL, and `unnest`
  -- of a null array is not an empty set -- it is an error waiting in
  -- the first section. Every layout row still renders, at zero.
  v_balances := coalesce(v_balances, array[]::app.account_balance[]);

  for v_row in
    -- Stored rows where the company has a layout, the standard ones
    -- where it has not. One loop, one set of arithmetic, and opening a
    -- report writes nothing.
    select r.row_key, r.kind, r.label, r.sort_order, r.depth, r.emphasise,
           r.show_accounts, r.account_types, r.account_subtypes,
           r.account_ids, r.formula
      from public.report_layout_rows r
     where v_layout is not null and r.layout_id = v_layout
    union all
    select b.row_key, b.kind, b.label, b.sort_order, b.depth, b.emphasise,
           b.show_accounts, b.account_types, b.account_subtypes,
           b.account_ids, b.formula
      from app.builtin_layout_rows(p_kind) b
     where v_layout is null
     order by 4
  loop
    if v_row.kind = 'formula' then
      v_total := 0;
      for v_ref in select * from jsonb_array_elements(v_row.formula) loop
        if not (v_seen ? (v_ref ->> 'row')) then
          raise exception
            'Row "%" refers to "%", which is not above it. A formula may '
            'only use rows already computed.',
            v_row.row_key, v_ref ->> 'row' using errcode = '23514';
        end if;
        v_total := v_total
                 + coalesce((v_ref ->> 'sign')::numeric, 1)
                   * (v_seen ->> (v_ref ->> 'row'))::numeric;
      end loop;
    elsif v_row.kind = 'heading' then
      v_total := null;
    else
      select coalesce(sum(b.amount), 0) into v_total
        from unnest(v_balances) b
       where (v_row.account_types is null
              or b.account_type = any(v_row.account_types))
         and (v_row.account_subtypes is null
              or b.account_subtype = any(v_row.account_subtypes))
         and (v_row.account_ids is null
              or b.account_id = any(v_row.account_ids));
    end if;

    if v_row.kind <> 'heading' then
      v_seen := v_seen || jsonb_build_object(v_row.row_key, v_total);
    end if;

    row_key := v_row.row_key; kind := v_row.kind; label := v_row.label;
    depth := v_row.depth; emphasise := v_row.emphasise; amount := v_total;
    account_code := null; account_name := null;
    sort_order := v_row.sort_order; line_no := 0;
    return next;

    -- The accounts under a section, after its total, numbered so a
    -- renderer keeps them together without re-sorting. A zero balance
    -- is left out: a P&L listing every account a company has ever
    -- opened is a list nobody reads.
    if v_row.kind = 'section' and v_row.show_accounts then
      v_line := 0;
      for v_acct in
        select b.amount, b.code, b.name from unnest(v_balances) b
         where (v_row.account_types is null
                or b.account_type = any(v_row.account_types))
           and (v_row.account_subtypes is null
                or b.account_subtype = any(v_row.account_subtypes))
           and (v_row.account_ids is null
                or b.account_id = any(v_row.account_ids))
           and b.amount <> 0
         order by b.code
      loop
        v_line := v_line + 1;
        row_key := v_row.row_key; kind := v_row.kind; label := v_acct.name;
        depth := (v_row.depth + 1)::smallint; emphasise := false;
        amount := v_acct.amount; account_code := v_acct.code;
        account_name := v_acct.name;
        sort_order := v_row.sort_order; line_no := v_line;
        return next;
      end loop;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- public.report_group_trial_balance, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_group_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(code text, name text, account_type app.account_type, account_subtype app.account_subtype, companies integer, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_currencies text[];
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select array_agg(distinct g.base_currency)
    into v_currencies
    from app.group_orgs(p_org_id) g;

  if v_currencies is null then
    raise exception 'This company is not in a group'
      using errcode = '42501';
  end if;

  if array_length(v_currencies, 1) > 1 then
    raise exception
      'The companies in this group keep their books in different '
      'currencies (%). Adding them together would produce a number that '
      'is not money. Translating them properly is not built yet.',
      array_to_string(v_currencies, ', ')
      using errcode = '22000';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  per_company as (
    select t.code, t.name, t.account_type, t.account_subtype,
           t.opening_balance, t.debit, t.credit, t.closing_balance
      from orgs o
      cross join lateral public.report_trial_balance(o.org_id, p_from, p_to) t)
  select p.code,
         -- The name from whichever company uses that code; they are the
         -- same seeded chart, and where they are not, one of them has to
         -- win and it may as well be the first alphabetically.
         min(p.name),
         min(p.account_type),
         min(p.account_subtype),
         count(*)::integer,
         round(sum(p.opening_balance), 2),
         round(sum(p.debit), 2),
         round(sum(p.credit), 2),
         round(sum(p.closing_balance), 2)
    from per_company p
   group by p.code
  having sum(abs(p.opening_balance)) + sum(p.debit) + sum(p.credit) <> 0
   order by p.code;
end; $function$;

-- ---------------------------------------------------------------------
-- public.report_group_intercompany, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_group_intercompany(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(from_org_id uuid, from_org text, to_org_id uuid, to_org text, contact_id uuid, contact_name text, receivable numeric, payable numeric, revenue numeric, expense numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  lines as (
    select l.org_id, c.linked_org_id, c.id as contact_id, c.name as contact_name,
           a.account_type, a.account_subtype, l.debit, l.credit
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.contacts c on c.id = l.contact_id
      join public.accounts a on a.id = l.account_id
     where l.org_id in (select org_id from orgs)
       and c.linked_org_id in (select org_id from orgs)
       and e.status = 'posted'
       and e.entry_date <= p_to
       and (p_from is null or e.entry_date >= p_from))
  select l.org_id, mine.name, l.linked_org_id, theirs.name,
         l.contact_id, l.contact_name,
         round(sum(case when l.account_subtype = 'accounts_receivable'
                        then l.debit - l.credit else 0 end), 2),
         round(sum(case when l.account_subtype = 'accounts_payable'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'revenue'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'expense'
                        then l.debit - l.credit else 0 end), 2)
    from lines l
    join public.organizations mine on mine.id = l.org_id
    join public.organizations theirs on theirs.id = l.linked_org_id
   group by l.org_id, mine.name, l.linked_org_id, theirs.name,
            l.contact_id, l.contact_name
  having sum(abs(l.debit)) + sum(abs(l.credit)) <> 0
   order by mine.name, theirs.name;
end; $function$;

-- ---------------------------------------------------------------------
-- public.report_group_consolidated_trial_balance, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_group_consolidated_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(code text, name text, account_type app.account_type, account_subtype app.account_subtype, companies integer, combined_balance numeric, elimination numeric, consolidated_balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_partial text;
  v_unowned text;
  v_parent  text;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  -- Anything short of wholly owned needs minority interest, and this
  -- does not compute one. Named rather than refused in general, because
  -- "cannot consolidate" is not an answer somebody can act on.
  select string_agg(o.name || ' (' || o.owned_percent || '%)', ', ')
    into v_partial
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.owned_percent is not null
     and o.owned_percent < 100;

  if v_partial is not null then
    raise exception
      'These companies are not wholly owned: %. Consolidating them needs '
      'minority interest, which is not built — the group''s share of '
      'their profit and net assets would have to be split out, and this '
      'report would understate it silently.', v_partial
      using errcode = '22000';
  end if;

  -- Standing in a subsidiary. Answered before the unowned test below,
  -- which would otherwise report the parent as having no owner — true,
  -- and not a problem, and not something anybody can fix.
  select p.name into v_parent
    from public.organizations o
    join public.organizations p on p.id = o.parent_org_id
   where o.id = p_org_id;

  if v_parent is not null then
    raise exception
      'Consolidated accounts are prepared by the parent, and this company '
      'is owned by %. Switch to it and run the report there. The combined '
      'trial balance and the inter-company check work from here.', v_parent
      using errcode = '22000';
  end if;

  select string_agg(o.name, ', ') into v_unowned
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.parent_org_id is null;

  if v_unowned is not null then
    raise exception
      'Nobody has recorded who owns %. A consolidation cannot be produced '
      'without it: whether the whole of a subsidiary belongs to the group '
      'is the question minority interest turns on. Record it in Settings.',
      v_unowned
      using errcode = '22000';
  end if;

  return query
  with e as (
    select g.code, sum(g.adjustment) as adjustment
      from app.group_eliminations(p_org_id, p_from, p_to) g
     group by g.code)
  select t.code, t.name, t.account_type, t.account_subtype, t.companies,
         t.closing_balance,
         coalesce(e.adjustment, 0),
         round(t.closing_balance + coalesce(e.adjustment, 0), 2)
    from public.report_group_trial_balance(p_org_id, p_from, p_to) t
    left join e on e.code = t.code
   order by t.code;
end; $function$;

-- ---------------------------------------------------------------------
-- public.report_group_elimination_check, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_group_elimination_check(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(from_org text, to_org text, what text, their_side numeric, our_side numeric, difference numeric, eliminated boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  with lines as (select * from app.group_intercompany_lines(p_org_id, p_from, p_to)),
  totals as (
    select l.org_id, l.counterparty, l.category, sum(l.amount) as amount
      from lines l group by l.org_id, l.counterparty, l.category),
  pairs as (
    select r.org_id as a, r.counterparty as b,
           'Balances owed'::text as what,
           r.amount as a_side,
           coalesce(p.amount, 0) as b_side
      from totals r
      left join totals p
        on p.org_id = r.counterparty and p.counterparty = r.org_id
       and p.category = 'payable'
     where r.category = 'receivable'
    union all
    select s.org_id, s.counterparty, 'Trading'::text,
           s.amount, coalesce(x.amount, 0)
      from totals s
      left join totals x
        on x.org_id = s.counterparty and x.counterparty = s.org_id
       and x.category = 'expense'
     where s.category = 'revenue')
  select seller.name, buyer.name, pairs.what,
         pairs.a_side, pairs.b_side,
         round(pairs.a_side - pairs.b_side, 2),
         round(pairs.a_side - pairs.b_side, 2) = 0
    from pairs
    join public.organizations seller on seller.id = pairs.a
    join public.organizations buyer  on buyer.id  = pairs.b
   order by seller.name, buyer.name, pairs.what;
end; $function$;

-- ---------------------------------------------------------------------
-- public.report_deferred_revenue, from `0313`
-- ---------------------------------------------------------------------
create or replace function public.report_deferred_revenue(
  p_org_id uuid, p_as_at date default null)
returns table (
  contact_name   text,
  doc_no         text,
  doc_date       date,
  description    text,
  service_start  date,
  service_end    date,
  deferred       numeric,
  recognised     numeric,
  cancelled      numeric,
  balance        numeric,
  ledger_balance numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_as_at  date := coalesce(p_as_at,
                            (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_acct   uuid;
  v_ledger numeric := 0;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select a.id into v_acct
    from public.accounts a
   where a.org_id = p_org_id and a.code = '2127';

  if v_acct is not null then
    select coalesce(sum(l.credit - l.debit), 0) into v_ledger
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and l.account_id = v_acct
       and e.entry_date <= v_as_at
       and e.status = 'posted';
  end if;

  return query
  with movement as (
    select p.line_id,
           p.amount,
           case when re.id is not null and re.entry_date <= v_as_at
                then p.amount - p.cancelled_amount else 0 end as released,
           case when cn.id is not null and cn.doc_date <= v_as_at
                then p.cancelled_amount else 0 end as taken
      from public.revenue_schedule_periods p
      left join public.gl_entries re on re.id = p.gl_entry_id
      left join public.sales_documents cn on cn.id = p.cancelled_by_id
     where p.org_id = p_org_id
  )
  select c.name,
         d.doc_no,
         d.doc_date,
         l.description,
         l.service_start,
         l.service_end,
         round(sum(m.amount), 2),
         round(sum(m.released), 2),
         round(sum(m.taken), 2),
         round(sum(m.amount - m.released - m.taken), 2),
         v_ledger
    from movement m
    join public.sales_document_lines l on l.id = m.line_id
    join public.sales_documents d on d.id = l.document_id
    join public.gl_entries de on de.id = d.gl_entry_id
    left join public.contacts c on c.id = d.contact_id
   where de.entry_date <= v_as_at
     and de.status = 'posted'
     and d.status <> 'void'
   group by c.name, d.doc_no, d.doc_date, l.description,
            l.service_start, l.service_end, l.id
  having round(sum(m.amount - m.released - m.taken), 2) <> 0
   order by c.name, d.doc_no, l.service_start;
end;
$$;

-- ---------------------------------------------------------------------
-- public.suggest_bank_matches, from `0772`
-- ---------------------------------------------------------------------
create or replace function public.suggest_bank_matches(
  p_transaction_id uuid, p_within_days integer default 7)
returns table (
  source_table text, source_id uuid, doc_no text, doc_date date,
  amount numeric, contact_name text, day_gap integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare t public.bank_transactions; v_bank_gl uuid;
begin
  select * into t from public.bank_transactions where id = p_transaction_id;
  if not found then
    raise exception 'Statement line % not found', p_transaction_id
      using errcode = 'P0002';
  end if;
  if not app.is_org_member(t.org_id) then
    raise exception 'Not a member of organization %', t.org_id
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(t.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  -- `0772`: only what went through THIS account. Every branch below
  -- matched on company, amount and date alone, so a company with two
  -- banks was offered the Maybank receipt for a CIMB line whenever the
  -- figures fitted -- and `match_bank_transaction` took it.
  select b.account_id into v_bank_gl
    from public.bank_accounts b where b.id = t.bank_account_id;

  return query
  select * from (
    -- Money in is a receipt.
    select 'receipts'::text, r.id, r.receipt_no, r.receipt_date,
           r.amount, c.name,
           abs(r.receipt_date - t.transaction_date)::integer
      from public.receipts r
      left join public.contacts c on c.id = r.contact_id
     where t.amount > 0 and r.org_id = t.org_id
       and r.gl_entry_id is not null
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = r.gl_entry_id and l.account_id = v_bank_gl)
       and round(r.amount - coalesce(r.bank_charges, 0), 2) = round(t.amount, 2)
       and abs(r.receipt_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'receipts' and b.matched_id = r.id)
    union all
    -- Money out is a supplier payment or an expense.
    select 'purchase_payments', p.id, p.payment_no, p.payment_date,
           p.amount, c.name,
           abs(p.payment_date - t.transaction_date)::integer
      from public.purchase_payments p
      left join public.contacts c on c.id = p.contact_id
     where t.amount < 0 and p.org_id = t.org_id
       and p.gl_entry_id is not null
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = p.gl_entry_id and l.account_id = v_bank_gl)
       and round(p.amount + coalesce(p.bank_charges, 0), 2) = round(-t.amount, 2)
       and abs(p.payment_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'purchase_payments'
                          and b.matched_id = p.id)
    union all
    select 'expenses', e.id, e.expense_no, e.expense_date,
           e.total_amount, c.name,
           abs(e.expense_date - t.transaction_date)::integer
      from public.expenses e
      left join public.contacts c on c.id = e.contact_id
     where t.amount < 0 and e.org_id = t.org_id
       and e.gl_entry_id is not null
       and exists (select 1 from public.gl_lines l
                    where l.entry_id = e.gl_entry_id and l.account_id = v_bank_gl)
       and round(e.total_amount, 2) = round(-t.amount, 2)
       and abs(e.expense_date - t.transaction_date) <= p_within_days
       and not exists (select 1 from public.bank_transactions b
                        where b.matched_table = 'expenses' and b.matched_id = e.id)
  ) s(source_table, source_id, doc_no, doc_date, amount, contact_name, day_gap)
  order by s.day_gap, s.doc_date
  limit 20;
end;
$$;

-- ---------------------------------------------------------------------
-- public.bank_reconciliation_status, from `0716`
-- ---------------------------------------------------------------------
create or replace function public.bank_reconciliation_status(
  p_bank_account_id uuid,
  p_as_at date,
  p_statement_balance numeric default 0)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_org        uuid;
  v_account    uuid;
  v_book       numeric(18, 2);
  v_unpresented numeric(18, 2);
  v_unmatched  integer;
  v_posted     integer;
  v_start      date;
begin
  select b.org_id, b.account_id into v_org, v_account
    from public.bank_accounts b where b.id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(v_org) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_book
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted';

  -- Ledger movements the bank has not shown yet: unpresented cheques and
  -- deposits in transit, which is to say every posting on this account
  -- that no statement line has been matched to.
  select coalesce(sum(l.debit - l.credit), 0) into v_unpresented
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted'
     and not exists (
       select 1 from public.bank_transactions t
        where t.gl_entry_id = e.id
          and t.bank_account_id = p_bank_account_id
          and t.is_reconciled);

  select count(*) into v_unmatched
    from public.bank_transactions t
   where t.bank_account_id = p_bank_account_id
     and t.transaction_date <= p_as_at
     and not t.is_reconciled;

  -- How many, not how much. A book balance of zero is ambiguous --
  -- nothing posted, or posted and netted off -- and only the count
  -- separates them.
  select count(*) into v_posted
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.entry_date <= p_as_at
     and e.status = 'posted';

  -- Deliberately NOT bounded by `p_as_at`: the whole use of it is to
  -- say that the books start AFTER the statement, which a figure cut
  -- off at the statement date could never show.
  select min(e.entry_date) into v_start
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = v_account and e.status = 'posted';

  return jsonb_build_object(
    'book_balance', v_book,
    'unpresented', v_unpresented,
    'expected_statement', v_book - v_unpresented,
    'statement_balance', round(coalesce(p_statement_balance, 0), 2),
    'difference', round(v_book - v_unpresented
                        - coalesce(p_statement_balance, 0), 2),
    'unmatched_lines', v_unmatched,
    'posted_entries', v_posted,
    'books_start', v_start);
end;
$$;

-- ---------------------------------------------------------------------
-- public.tax_computation_lines, from `0665`
-- ---------------------------------------------------------------------
create or replace function public.tax_computation_lines(
  p_computation_id uuid)
returns table (
  kind       text,
  code       text,
  label      text,
  source     text,
  gross      numeric,
  fraction   numeric,
  amount     numeric,
  reference  text)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c record;
  v_from date;
  v_to   date;
begin
  select tc.*, fy.start_date, fy.end_date into c
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(c.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  v_from := c.start_date;
  v_to   := c.end_date;

  return query
  -- Tagged accounts, from the profit and loss of the basis period.
  select t.kind,
         pl.code,
         t.label,
         'Account ' || pl.code || ' ' || pl.name,
         pl.amount,
         t.fraction,
         round(pl.amount * t.fraction, 2),
         t.reference
    from public.report_profit_loss(c.org_id, v_from, v_to) pl
    join public.accounts a on a.id = pl.account_id
    join public.tax_treatments t on t.code = a.tax_treatment
   -- A treatment meant for an expense account, sitting on a revenue
   -- one, would still produce a figure that adds up. It is dropped
   -- rather than applied, and `tax_computation_misfiled` is what says
   -- so on the screen.
   where t.applies_to = pl.account_type::text
     and round(pl.amount * t.fraction, 2) <> 0

  union all

  -- Typed adjustments.
  select adj.kind, null, adj.label,
         coalesce(nullif(btrim(adj.reason), ''), 'No reason given'),
         adj.amount, 1::numeric, adj.amount, null
    from public.tax_adjustments adj
   where adj.computation_id = p_computation_id

  order by 1, 2 nulls last, 3;
end; $$;

-- ---------------------------------------------------------------------
-- public.tax_computation, from `0666`
-- ---------------------------------------------------------------------
create or replace function public.tax_computation(p_computation_id uuid)
returns table (
  year_of_assessment   integer,
  period_from          date,
  period_to            date,
  profit_before_tax    numeric,
  add_backs            numeric,
  deductions           numeric,
  balancing_charge     numeric,
  adjusted_income      numeric,
  adjusted_loss        numeric,
  ca_current           numeric,
  ca_brought_forward   numeric,
  ca_used              numeric,
  ca_carried_forward   numeric,
  statutory_income     numeric,
  loss_brought_forward numeric,
  loss_used            numeric,
  loss_carried_forward numeric,
  chargeable_income    numeric,
  is_sme               boolean,
  sme_known            boolean,
  tax_charged          numeric,
  zakat_rebate         numeric,
  s110_tax_deducted    numeric,
  cp204_paid           numeric,
  tax_payable          numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c       record;
  b       record;
  r       record;
  v_lu    numeric;
  v_ci    numeric;
  v_sme   boolean;
  v_known boolean;
  v_tax   numeric;
  v_zakat numeric;
begin
  select tc.*, fy.start_date, fy.end_date into c
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(c.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  v_lu := least(c.loss_bf, b.statutory_income);
  v_ci := round(b.statutory_income - v_lu, 2);

  v_known := c.paid_up_capital is not null
             and c.gross_business_income is not null;

  select r2.* into r
    from public.company_tax_rates r2
   where r2.year_of_assessment = c.year_of_assessment;

  if r is null then
    raise exception
      'No company tax rates for year of assessment %', c.year_of_assessment
      using errcode = 'P0002';
  end if;

  v_sme := v_known
           and c.paid_up_capital <= r.sme_capital_limit
           and c.gross_business_income <= r.sme_turnover_limit;

  if v_sme then
    v_tax := round(least(v_ci, r.sme_band_limit) * r.sme_rate, 2)
             + round(greatest(v_ci - r.sme_band_limit, 0)
                       * r.standard_rate, 2);
  else
    v_tax := round(v_ci * r.standard_rate, 2);
  end if;

  v_zakat := least(c.zakat_paid, v_tax);

  return query select
    c.year_of_assessment, c.start_date, c.end_date,
    b.profit_before_tax, b.add_backs, b.deductions, b.balancing_charge,
    b.adjusted_income, b.adjusted_loss,
    b.ca_current, b.ca_brought_forward, b.ca_used, b.ca_carried_forward,
    b.statutory_income,
    round(c.loss_bf, 2), round(v_lu, 2),
    round(c.loss_bf - v_lu + b.adjusted_loss, 2),
    v_ci, v_sme, v_known, v_tax, v_zakat,
    round(c.s110_tax_deducted, 2), round(c.cp204_paid, 2),
    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);
end; $$;

-- ---------------------------------------------------------------------
-- public.tax_computation_individual, from `0666`
-- ---------------------------------------------------------------------
create or replace function public.tax_computation_individual(
  p_computation_id uuid)
returns table (
  year_of_assessment   integer,
  period_from          date,
  period_to            date,
  profit_before_tax    numeric,
  add_backs            numeric,
  deductions           numeric,
  balancing_charge     numeric,
  adjusted_income      numeric,
  adjusted_loss        numeric,
  ca_current           numeric,
  ca_used              numeric,
  ca_carried_forward   numeric,
  statutory_business   numeric,
  other_income         numeric,
  aggregate_income     numeric,
  approved_donations   numeric,
  donations_allowed    numeric,
  total_income         numeric,
  reliefs_claimed      numeric,
  chargeable_income    numeric,
  tax_charged          numeric,
  rebate               numeric,
  zakat_rebate         numeric,
  s110_tax_deducted    numeric,
  instalments_paid     numeric,
  tax_payable          numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  b        record;
  v_other  numeric := 0;
  v_agg    numeric;
  v_don    numeric;
  v_total  numeric;
  v_rel    numeric := 0;
  v_ci     numeric;
  v_tax    numeric;
  v_reb    numeric := 0;
  v_zakat  numeric;
  v_thr    record;
begin
  select tc.*, fy.start_date, fy.end_date into c
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(c.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  select coalesce(sum(oi.amount), 0) into v_other
    from public.tax_other_income oi
   where oi.computation_id = p_computation_id;

  v_agg := round(b.statutory_income + v_other, 2);

  -- s.44(6): a deduction from AGGREGATE income, and it cannot take it
  -- below nothing. A donation larger than the income is not a loss to
  -- carry anywhere; the excess is simply lost.
  v_don := least(c.approved_donations, v_agg);
  v_total := round(v_agg - v_don, 2);

  select coalesce(sum(rc.amount), 0) into v_rel
    from public.tax_relief_claims rc
   where rc.computation_id = p_computation_id;

  -- Reliefs come off TOTAL income and stop at nothing. More relief
  -- than income is not a refund and not a carry-forward.
  v_ci := round(greatest(v_total - v_rel, 0), 2);

  v_tax := app.individual_tax_on(v_ci, c.end_date);

  select ir.* into v_thr
    from public.individual_tax_rebates ir
   where ir.year_of_assessment = c.year_of_assessment;

  if v_thr is not null and v_ci > 0 and v_ci <= v_thr.threshold then
    v_reb := least(v_thr.amount, v_tax);
  end if;

  -- Zakat after the rebate, and capped at what is left. Two reliefs
  -- against the same tax cannot between them exceed it.
  v_zakat := least(c.zakat_paid, greatest(v_tax - v_reb, 0));

  return query select
    c.year_of_assessment, c.start_date, c.end_date,
    b.profit_before_tax, b.add_backs, b.deductions, b.balancing_charge,
    b.adjusted_income, b.adjusted_loss,
    b.ca_current, b.ca_used, b.ca_carried_forward, b.statutory_income,
    round(v_other, 2), v_agg,
    round(c.approved_donations, 2), round(v_don, 2), v_total,
    round(v_rel, 2), v_ci,
    v_tax, round(v_reb, 2), round(v_zakat, 2),
    round(c.s110_tax_deducted, 2), round(c.cp204_paid, 2),
    round(v_tax - v_reb - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);
end; $$;

-- ---------------------------------------------------------------------
-- public.tax_partnership_allocation, from `0666`
-- ---------------------------------------------------------------------
create or replace function public.tax_partnership_allocation(
  p_computation_id uuid)
returns table (
  partner_id       uuid,
  name             text,
  tax_reference    text,
  share_percent    numeric,
  salary           numeric,
  interest_on_capital numeric,
  share_of_divisible  numeric,
  capital_allowances  numeric,
  statutory_income    numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c            record;
  b            record;
  v_divisible  numeric;
begin
  select tc.* into c from public.tax_computations tc
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(c.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  -- THE ASSUMPTION, stated because it decides every figure below: the
  -- accounts EXPENSED the partners' salaries and interest, which is
  -- what a partnership's books almost always do.
  --
  -- On that assumption the arithmetic collapses, and it is worth
  -- following once. The partnership's true adjusted income is what the
  -- accounts show PLUS the appropriations added back -- a partner
  -- cannot employ themselves. The divisible income is then that, LESS
  -- the appropriations handed to the partners who earned them. The two
  -- cancel, so:
  --
  --     divisible income = adjusted income, as the accounts computed it
  --
  -- and each partner takes their share of it plus their own salary and
  -- interest. The total allocated comes to the adjusted income plus the
  -- appropriations, which is the partnership's real figure --
  -- `tax_computation.sql` asserts exactly that.
  --
  -- Where a partnership does NOT expense them -- showing them below the
  -- line as an appropriation of profit -- this over-allocates by the
  -- appropriations. That case is not modelled, and the screen says so
  -- beside the total rather than leaving it to be discovered.
  --
  -- Left negative where it is negative. A divisible LOSS is shared in
  -- the same ratio and each partner sets their share against their own
  -- other income; clamping it at nothing would hand every partner a
  -- share of zero and lose the relief entirely.
  v_divisible := b.adjusted_income;

  return query
  select p.id, p.name, p.tax_reference, p.share_percent,
         p.salary, p.interest_on_capital,
         round(v_divisible * p.share_percent / 100, 2),
         -- Allowances follow the same ratio. They belong to the
         -- partners, not to the partnership, because the partnership
         -- has no income to set them against.
         round(b.ca_current * p.share_percent / 100, 2),
         round(p.salary + p.interest_on_capital
               + v_divisible * p.share_percent / 100
               - b.ca_current * p.share_percent / 100, 2)
    from public.tax_partners p
   where p.computation_id = p_computation_id
   order by p.sort_order, p.name;
end; $$;

-- ---------------------------------------------------------------------
-- public.tax_partnership_summary, from `0666`
-- ---------------------------------------------------------------------
create or replace function public.tax_partnership_summary(
  p_computation_id uuid)
returns table (
  adjusted_income   numeric,
  appropriations    numeric,
  divisible_income  numeric,
  partnership_adjusted numeric,
  total_allocated   numeric,
  shares_total      numeric,
  partner_count     integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  b        record;
  v_approp numeric := 0;
  v_shares numeric := 0;
  v_count  integer := 0;
  v_total  numeric := 0;
begin
  select tc.* into c from public.tax_computations tc
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(c.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  select coalesce(sum(p.salary + p.interest_on_capital), 0),
         coalesce(sum(p.share_percent), 0),
         count(*)
    into v_approp, v_shares, v_count
    from public.tax_partners p
   where p.computation_id = p_computation_id;

  select coalesce(sum(a.statutory_income), 0) into v_total
    from public.tax_partnership_allocation(p_computation_id) a;

  return query select
    b.adjusted_income,
    round(v_approp, 2),
    -- The divisible income IS the adjusted income the accounts
    -- produced; see the allocation function for why the add-back and
    -- the hand-out cancel.
    b.adjusted_income,
    round(b.adjusted_income + v_approp, 2),
    round(v_total, 2),
    round(v_shares, 4),
    v_count;
end; $$;

-- ---------------------------------------------------------------------
-- public.tax_estimate_exposure, from `0670`
-- ---------------------------------------------------------------------
create or replace function public.tax_estimate_exposure(
  p_estimate_id uuid,
  p_computation_id uuid default null)
returns table (
  form              text,
  estimated_tax     numeric,
  prior_estimate    numeric,
  floor_required    numeric,
  meets_floor       boolean,
  floor_known       boolean,
  floor_applies     boolean,
  actual_tax        numeric,
  actual_known      boolean,
  shortfall         numeric,
  tolerance_amount  numeric,
  excess_over_tolerance numeric,
  penalty           numeric,
  revision_open     boolean,
  revision_months   integer[])
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  r        record;
  v_actual numeric;
  v_known  boolean := false;
  v_floor  numeric;
  v_short  numeric := 0;
  v_tol    numeric := 0;
  v_excess numeric := 0;
  v_month  integer;
  v_has_floor boolean;
begin
  select te.*, fy.start_date, fy.end_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(e.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  -- Aliased, because this function now has an OUT parameter called
  -- `form` and an unqualified `form` in the where clause is ambiguous
  -- between it and the column. Postgres refuses it rather than
  -- guessing, which is the good outcome: the guess would have
  -- compared the rules to an uninitialised output.
  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  v_has_floor := r.has_floor;

  -- The floor, where there is one and last year's figure is known.
  -- Null prior estimate means unknown rather than nothing: a floor of
  -- zero would pass any estimate at all and say so confidently, which
  -- is worse than admitting the question cannot be answered.
  v_floor := round(coalesce(e.prior_estimate, 0)
                   * r.floor_percent_of_prior / 100, 2);

  if p_computation_id is not null then
    select tc.tax_charged - tc.zakat_rebate into v_actual
      from public.tax_computation(p_computation_id) tc;
    v_known := v_actual is not null;
  end if;

  if v_known then
    v_actual := greatest(v_actual, 0);
    v_short := greatest(v_actual - e.estimated_tax, 0);
    -- The tolerance is a share of what was ACTUALLY owed, not of the
    -- estimate. Measuring it against the estimate would let a taxpayer
    -- who estimated nothing be penalised on nothing.
    v_tol := round(v_actual * r.under_tolerance_percent / 100, 2);
    v_excess := greatest(v_short - v_tol, 0);
  end if;

  -- Which month of the basis period today falls in, and whether a
  -- revision is still allowed in it.
  -- `app.today()` rather than the server's idea of today. Malaysia is
  -- eight hours ahead of UTC, so for a third of every day the server
  -- is a day behind it -- and the month a revision falls in decides
  -- whether the revision is allowed at all.
  v_month := 1 + (extract(year from app.today())::integer
                    - extract(year from e.start_date)::integer) * 12
               + (extract(month from app.today())::integer
                    - extract(month from e.start_date)::integer);

  return query select
    e.form,
    round(e.estimated_tax, 2),
    case when not v_has_floor or e.prior_estimate is null then null
         else round(e.prior_estimate, 2) end,
    case when not v_has_floor or e.prior_estimate is null then null
         else v_floor end,
    -- Unknown reads as NOT meeting the floor. The generous answer
    -- would be a tick beside a figure nobody has checked.
    --
    -- Where there is NO floor, this is FALSE as well -- and
    -- `floor_applies` below is what keeps the screen from reporting
    -- that as a failure. A CP500 does not pass a floor; it has none.
    (v_has_floor and e.prior_estimate is not null
       and e.estimated_tax >= v_floor),
    (v_has_floor and e.prior_estimate is not null),
    v_has_floor,
    case when v_known then round(v_actual, 2) else null end,
    v_known,
    case when v_known then round(v_short, 2) else null end,
    case when v_known then round(v_tol, 2) else null end,
    case when v_known then round(v_excess, 2) else null end,
    case when v_known
         then round(v_excess * r.under_penalty_percent / 100, 2)
         else null end,
    (v_month = any (r.revision_months)),
    r.revision_months;
end; $$;

-- ---------------------------------------------------------------------
-- public.fs_prepare, from `0172`
-- ---------------------------------------------------------------------
create or replace function public.fs_prepare(p_filing_id uuid)
returns table (
  element_code text, statement app.fs_statement, section text,
  label text, sort_order integer,
  current_amount numeric, prior_amount numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not app.can_read_ledger(f.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
    select e.code, e.statement, e.section, e.label, e.sort_order,
           round(coalesce(c.amount, 0), 2),
           round(coalesce(p.amount, 0), 2)
      from public.mbrs_elements e
      left join app.fs_figures_at(f.org_id, f.fy_start, f.fy_end) c
             on c.element_code = e.code
      -- The comparative: the twelve months ending the day before this
      -- year began. Not "last calendar year" — a company with a June
      -- year end compares against the June before.
      left join app.fs_figures_at(f.org_id,
                  (f.fy_start - interval '1 year')::date,
                  (f.fy_start - interval '1 day')::date) p
             on p.element_code = e.code
     where e.is_active
       and (e.framework is null or e.framework = f.framework)
       and (c.amount is not null or p.amount is not null)
     order by e.sort_order;
end $$;

-- ---------------------------------------------------------------------
-- public.fs_export, from `0172`
-- ---------------------------------------------------------------------
create or replace function public.fs_export(p_filing_id uuid)
returns table (
  statement app.fs_statement, section text, element_code text,
  label text, current_amount numeric, prior_amount numeric, is_frozen boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not app.can_read_ledger(f.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  if f.status = 'draft' then
    return query
      select r.statement, r.section, r.element_code, r.label,
             r.current_amount, r.prior_amount, false
        from public.fs_prepare(p_filing_id) r
       order by r.sort_order;
  else
    return query
      select e.statement, e.section, g.element_code, e.label,
             g.current_amount, g.prior_amount, true
        from public.fs_figures g
        join public.mbrs_elements e on e.code = g.element_code
       where g.filing_id = p_filing_id
       order by e.sort_order;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- public.fs_audit_exemption, from `0751`
-- ---------------------------------------------------------------------
create or replace function public.fs_audit_exemption(p_filing_id uuid)
returns table (ground text, qualifies boolean, reason text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_start date; v_end date;
  v_rev numeric; v_assets numeric; v_staff integer;
  v_max_rev numeric := 0; v_max_assets numeric := 0; v_max_staff integer := 0;
  v_any_movement boolean := false;
  v_staff_known boolean := true;
  i integer;
  t record;
  v_rev_ok boolean; v_assets_ok boolean; v_staff_ok boolean;
  v_met integer;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not app.can_read_ledger(f.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  -- This year and the two before it.
  for i in 0..2 loop
    v_start := (f.fy_start - (i || ' years')::interval)::date;
    v_end := (f.fy_end - (i || ' years')::interval)::date;

    select coalesce(sum(p.amount), 0) into v_rev
      from public.report_profit_loss(f.org_id, v_start, v_end) p
     where p.account_type = 'revenue';

    select coalesce(sum(b.balance), 0) into v_assets
      from public.report_balance_sheet(f.org_id, v_end) b
     where b.account_type = 'asset';

    -- Dormancy is about *any* accounting transaction, not about revenue.
    -- A company that paid a filing fee out of its bank account had a
    -- transaction and is not dormant.
    if exists (select 1 from public.gl_entries e
                where e.org_id = f.org_id and e.status = 'posted'
                  and e.entry_date between v_start and v_end) then
      v_any_movement := true;
    end if;

    -- Headcount comes off each year's own filing row. Guessing it from
    -- today's employee list would answer a question about 2023 with a
    -- fact about 2026.
    select g.employee_count into v_staff
      from public.fs_filings g
     where g.org_id = f.org_id and g.fy_end = v_end;
    if v_staff is null then v_staff_known := false;
                       else v_max_staff := greatest(v_max_staff, v_staff);
    end if;

    v_max_rev := greatest(v_max_rev, v_rev);
    v_max_assets := greatest(v_max_assets, v_assets);
  end loop;

  -- 0751. Which directive governs is decided by when the financial year
  -- being filed COMMENCED, and the same limits are applied to all three
  -- years: the test is whether the company stayed within them for the
  -- current year and the two before it.
  select * into t from app.audit_exemption_thresholds(f.fy_start);
  v_rev_ok    := v_max_rev <= t.revenue;
  v_assets_ok := v_max_assets <= t.assets;
  v_staff_ok  := v_staff_known and v_max_staff <= t.staff;
  v_met := v_rev_ok::integer + v_assets_ok::integer + v_staff_ok::integer;

  return query values
    ('dormant',
     not v_any_movement,
     case when not v_any_movement
       then 'No accounting transaction in this financial year or the two '
            'before it.'
       else 'There were accounting transactions in the three years to '
            || f.fy_end || '.' end),

    ('zero_revenue',
     v_max_rev = 0 and v_max_assets <= 300000,
     case when v_max_rev = 0 and v_max_assets <= 300000
       then 'No revenue in any of the three years, and total assets never '
            'above RM300,000.'
       when v_max_rev > 0
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ' in one of the three years.'
       else 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.' end),

    ('threshold_qualified',
     case when t.any_two then v_met >= 2
          else v_staff_known and v_rev_ok and v_assets_ok and v_staff_ok end,
     case
       -- Practice Directive 10/2024: any two of the three.
       when t.any_two and v_met >= 2
       then 'Within ' || v_met || ' of the three limits of ' || t.directive
            || ' in each of the three years -- '
            || array_to_string(array_remove(array[
                 case when v_rev_ok then 'revenue under '
                      || app.ringgit(t.revenue) end,
                 case when v_assets_ok then 'total assets under '
                      || app.ringgit(t.assets) end,
                 case when v_staff_ok then 'headcount under '
                      || (t.staff + 1) end], null), ', ')
            || '. Two are enough.'
       -- The headcount is missing and it is the one that would decide.
       when t.any_two and not v_staff_known and v_met = 1
       then 'Cannot tell -- one of revenue and total assets is within '
            || t.directive || '''s limits, and the headcount at the year '
            'end, which would decide it, is missing on one of the three '
            'years. Record it on each filing.'
       when t.any_two
       then 'Within ' || v_met || ' of the three limits of ' || t.directive
            || ', and it takes two -- '
            || array_to_string(array_remove(array[
                 case when not v_rev_ok then 'revenue reached '
                      || app.ringgit(v_max_rev) || ' against '
                      || app.ringgit(t.revenue) end,
                 case when not v_assets_ok then 'total assets reached '
                      || app.ringgit(v_max_assets) || ' against '
                      || app.ringgit(t.assets) end,
                 case when not v_staff_known then 'the headcount is missing '
                      'on one of the three years'
                      when not v_staff_ok then 'headcount reached '
                      || v_max_staff || ' against ' || t.staff end], null), '; ')
            || '.'
       -- Practice Directive 3/2018: all three, as before 0751 -- except
       -- that a ceiling already crossed is said before "cannot tell".
       -- Under an all-three rule a revenue over RM100,000 decides it
       -- whatever the headcount was, and 0172 answered "cannot tell" to
       -- a question it could answer.
       when v_max_rev > t.revenue
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ', above the RM100,000 ceiling.'
       when v_max_assets > t.assets
       then 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.'
       when not v_staff_known
       then 'Cannot tell — the headcount at the year end is missing on '
            'one of the three years. Record it on each filing.'
       when v_max_staff > t.staff
       then 'Headcount reached ' || v_max_staff || ', above the five '
            'employee ceiling.'
       else 'Revenue, total assets and headcount were all within the '
            'thresholds in each of the three years.' end);
end $$;

-- =====================================================================
-- iAkauntan :: 0857 a budget's actuals are the ledger's
--
-- `0855` gave every report built from the ledger the question the
-- journals ask of their reader, `app.can_read_ledger`. Three readers of
-- the ledger's actuals asked something else:
--
--   * `report_budget_vs_actual` and `build_budget_from_actual` (`0274`)
--     ask the accounting module -- `app.can_read_module`,
--     `app.can_write_module`. `app.module_access` answers 'write' for
--     every member without a custom access type (`0232`), a salesman
--     included, so the module question is no question about the ledger.
--   * `report_project_budget` (`0389`) asks only membership.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated`: `can_read_ledger` false, `gl_lines` 0 rows, and
-- `report_budget_vs_actual` gave 5100 Purchases with an actual of
-- 4,321.09 -- the profit and loss, by month, beside a budget.
-- `build_budget_from_actual` would copy last year's actuals into a
-- budget the same salesman reads.
--
-- Answered "actuals need ledger access", in two shapes:
--
--   * The two budget functions keep the check each had, in its own
--     words, and a second refusal follows it -- "Insufficient privileges
--     to read the ledger", 42501, as in `0855`.
--   * The project budget is also the projects' front door: the panel it
--     feeds lists, makes and closes them. Asked again, the answer was
--     "answer everyone, blank the actuals" -- every member is given
--     every project, its budget, dates, status and unbilled time (from
--     the timesheets, not the ledger), and cost to date, revenue to
--     date, variance and percent spent come back empty unless
--     `can_read_ledger`.
--
-- Each function is restated from the migration named above it, its text
-- unchanged but for that.
--
-- The budgets themselves -- the amounts people typed -- stay with the
-- module: `budgets`, `budget_lines`, `upsert_budget`, `set_budget_lines`
-- and `budgets_list` are untouched. A salesman may still keep a plan;
-- what they may not see is the ledger's figure beside it.
--
-- Production on 13 October: every member is an owner, admin,
-- accountant, accounts clerk or auditor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- public.report_budget_vs_actual, from `0274`
-- ---------------------------------------------------------------------
create or replace function public.report_budget_vs_actual(
  p_budget uuid,
  p_from_period integer default null,
  p_to_period integer default null)
returns table (
  account_id     uuid,
  code           text,
  name           text,
  account_type   app.account_type,
  account_subtype app.account_subtype,
  budget         numeric,
  actual         numeric,
  variance       numeric,
  variance_pct   numeric,
  favourable     boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b    public.budgets;
  v_from integer := coalesce(p_from_period, 1);
  v_to   integer := coalesce(p_to_period, 12);
  v_s    date;
  v_e    date;
begin
  select * into v_b from public.budgets where id = p_budget;
  if v_b.id is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_b.org_id, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(v_b.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  select min(p.start_date), max(p.end_date) into v_s, v_e
    from public.fiscal_periods p
   where p.fiscal_year_id = v_b.fiscal_year_id
     and p.period_no between v_from and v_to;
  if v_s is null then
    raise exception 'That financial year has no such periods.'
      using errcode = '23514';
  end if;

  return query
  with budgeted as (
    select l.account_id, sum(l.amount) as amount
      from public.budget_lines l
      join public.fiscal_periods p on p.id = l.period_id
     where l.budget_id = p_budget
       and p.period_no between v_from and v_to
     group by l.account_id
  ),
  actuals as (
    select l.account_id,
           sum(case when a.account_type = 'revenue'
                    then l.credit - l.debit
                    else l.debit - l.credit end) as amount
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where l.org_id = v_b.org_id
       and e.status = 'posted'
       and e.entry_date between v_s and v_e
       and not a.is_group
       and (v_b.department_code is null
            or l.department_code = v_b.department_code)
     group by l.account_id
  )
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(b.amount, 0), 2),
         round(coalesce(x.amount, 0), 2),
         round(coalesce(x.amount, 0) - coalesce(b.amount, 0), 2),
         case when coalesce(b.amount, 0) = 0 then null
              else round((coalesce(x.amount, 0) - b.amount)
                         / abs(b.amount) * 100, 2) end,
         -- Spending less than budgeted is good news; earning less is
         -- not, and both are a negative variance. Answered once here so
         -- no screen has to work it out from the account type.
         case when coalesce(x.amount, 0) - coalesce(b.amount, 0) = 0 then true
              when a.account_type = 'revenue'
                then coalesce(x.amount, 0) > coalesce(b.amount, 0)
              when a.account_type = 'expense'
                then coalesce(x.amount, 0) < coalesce(b.amount, 0)
              else null end
    from public.accounts a
    left join budgeted b on b.account_id = a.id
    left join actuals  x on x.account_id = a.id
   where a.org_id = v_b.org_id
     and (b.account_id is not null or x.account_id is not null)
     and a.account_type in ('revenue', 'expense')
   order by a.code;
end;
$$;

-- ---------------------------------------------------------------------
-- public.build_budget_from_actual, from `0274`
-- ---------------------------------------------------------------------
create or replace function public.build_budget_from_actual(
  p_budget uuid,
  p_from_year uuid,
  p_uplift_percent numeric default 0)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b public.budgets;
  v_n integer := 0;
  v_f numeric := 1 + coalesce(p_uplift_percent, 0) / 100;
begin
  select * into v_b from public.budgets where id = p_budget;
  if v_b.id is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(v_b.org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;
  if v_b.status <> 'draft' then
    raise exception 'That budget is %, and is not rebuilt.', v_b.status
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.fiscal_years y
                  where y.id = p_from_year and y.org_id = v_b.org_id) then
    raise exception 'No such financial year.' using errcode = 'P0002';
  end if;

  delete from public.budget_lines where budget_id = p_budget;

  insert into public.budget_lines
    (org_id, budget_id, account_id, period_id, amount)
  select v_b.org_id, p_budget, a.id, np.id,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end) * v_f, 2)
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
    join public.fiscal_periods op on op.org_id = v_b.org_id
      and op.fiscal_year_id = p_from_year
      and e.entry_date between op.start_date and op.end_date
    join public.fiscal_periods np on np.org_id = v_b.org_id
      and np.fiscal_year_id = v_b.fiscal_year_id
      and np.period_no = op.period_no
   where l.org_id = v_b.org_id
     and e.status = 'posted'
     and a.account_type in ('revenue', 'expense')
     and not a.is_group
     and (v_b.department_code is null
          or l.department_code = v_b.department_code)
   group by a.id, a.account_type, np.id
  having round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end) * v_f, 2) <> 0;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- public.report_project_budget, from `0389`
-- ---------------------------------------------------------------------
create or replace function public.report_project_budget(
  p_org_id uuid,
  p_include_closed boolean default false)
returns table (
  project_id uuid,
  code text,
  name text,
  customer text,
  start_date date,
  end_date date,
  is_active boolean,
  budget_amount numeric,
  cost_to_date numeric,
  revenue_to_date numeric,
  unbilled_time numeric,
  variance numeric,
  percent_spent numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  -- `0857`. Every member is answered with every project, and only a
  -- reader of the ledger with what the ledger has against it.
  v_ledger constant boolean := app.can_read_ledger(p_org_id);
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    with ledger as (
      select l.project_code,
             sum(case when a.account_type = 'expense'
                      then l.debit - l.credit else 0 end) as cost,
             sum(case when a.account_type = 'revenue'
                      then l.credit - l.debit else 0 end) as revenue
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and l.project_code is not null
       group by l.project_code
    ),
    unbilled as (
      select t.project_id, sum(t.amount) as amount
        from public.time_entries t
       where t.org_id = p_org_id
         and t.project_id is not null
         and t.is_billable
         and not t.is_billed
       group by t.project_id
    )
    select p.id, p.code, p.name, c.name, p.start_date, p.end_date,
           p.is_active,
           p.budget_amount,
           case when v_ledger then round(coalesce(g.cost, 0), 2) end,
           case when v_ledger then round(coalesce(g.revenue, 0), 2) end,
           round(coalesce(u.amount, 0), 2),
           -- Null when there is no budget, rather than zero. A job with
           -- no budget is not a job exactly on budget, and a report
           -- that says nought either way is answering a question it was
           -- never asked.
           case when not v_ledger or p.budget_amount is null then null
                else round(p.budget_amount - coalesce(g.cost, 0), 2) end,
           case when not v_ledger or coalesce(p.budget_amount, 0) = 0 then null
                else round(coalesce(g.cost, 0) * 100 / p.budget_amount, 1)
           end
      from public.projects p
      left join public.contacts c on c.id = p.contact_id
      left join ledger g on g.project_code = p.code
      left join unbilled u on u.project_id = p.id
     where p.org_id = p_org_id
       and (p_include_closed or p.is_active)
     order by p.code;
end $$;

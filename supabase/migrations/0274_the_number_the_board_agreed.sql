-- =====================================================================
-- The number the board agreed
--
-- Every management account anybody has ever presented has three columns:
-- what happened, what was supposed to happen, and the difference. This
-- system has had the first one since 0014 and nothing at all for the
-- other two. There is no budget table, no budget column, no budget
-- anywhere -- so the report that a director actually reads cannot be
-- produced, and the answer to "are we ahead or behind" is somebody's
-- spreadsheet.
--
-- ---------------------------------------------------------------------
-- Per account, per period
--
-- Not one annual figure per account. A business that budgets RM 240,000
-- of rent and pays RM 20,000 a month is on plan in March; the same
-- business budgeting RM 240,000 of sales against a Raya spike is
-- nowhere near it, and an annual figure divided by twelve would say it
-- was. The period is the unit the variance is read at, so it is the
-- unit the budget is stored at.
--
-- `budget_lines` therefore points at a `fiscal_periods` row rather than
-- carrying a month number. The period already knows its dates, its year
-- and whether it is closed, and a budget that named "period 3" would
-- have to be re-read against the calendar every time it was reported.
--
-- ---------------------------------------------------------------------
-- Favourable is not the same as positive
--
-- Spending RM 5,000 less than budgeted is good; earning RM 5,000 less
-- is not, and both are a variance of minus five thousand. Every screen
-- that shows a variance has to know which, so `report_budget_vs_actual`
-- answers it once -- `favourable` is on the row -- rather than leaving
-- each caller to work out the sign convention from the account type and
-- get it wrong somewhere.
--
-- ---------------------------------------------------------------------
-- Built from last year, because that is how budgets are actually made
--
-- Nobody types a hundred and forty numbers. They take last year's
-- actuals, add a percentage, and argue about the six lines that matter.
-- `build_budget_from_actual` does exactly that and stops: it fills a
-- draft, and a draft is meant to be edited.
--
-- ---------------------------------------------------------------------
-- An approved budget stops moving
--
-- The whole value of a variance report is that the budget is what was
-- agreed, not what somebody adjusted after seeing the actuals. So the
-- lines are editable while it is a draft and refused once it is
-- approved. Changing an agreed budget means superseding it with another
-- one, which is a thing the list can show and a silent edit is not.
-- =====================================================================

create type app.budget_status as enum ('draft', 'approved', 'archived');

-- ---------------------------------------------------------------------
-- The budget
-- ---------------------------------------------------------------------
create table public.budgets (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id)
                    on delete cascade,
  fiscal_year_id  uuid not null references public.fiscal_years(id)
                    on delete cascade,
  name            text not null,
  status          app.budget_status not null default 'draft',

  -- A budget for one part of the business, or for all of it. Null means
  -- the whole company, and a departmental budget is compared only
  -- against ledger lines carrying that department -- the rule 0088 set
  -- for the dimension P&L, kept here so the two reports agree.
  department_code text,

  notes           text,
  approved_at     timestamptz,
  approved_by     uuid references auth.users(id),
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (org_id, fiscal_year_id, name)
);

create table public.budget_lines (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations(id) on delete cascade,
  budget_id  uuid not null references public.budgets(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  period_id  uuid not null references public.fiscal_periods(id) on delete cascade,

  -- Signed in the account's own direction: what a reader would write
  -- down. RM 20,000 of rent is 20000, and RM 240,000 of sales is
  -- 240000 -- not a credit of minus something. `report_budget_vs_actual`
  -- normalises the actual the same way so the two are comparable
  -- without either of them being negated.
  amount     numeric(18, 2) not null,

  created_at timestamptz not null default now(),
  unique (budget_id, account_id, period_id)
);

create index budgets_org_idx on public.budgets (org_id, fiscal_year_id);
create index budget_lines_budget_idx on public.budget_lines (budget_id);
create index budget_lines_account_idx on public.budget_lines (account_id);

create trigger budgets_touch before update on public.budgets
  for each row execute function app.set_updated_at();

comment on table public.budgets is
  'What was supposed to happen, per account per period, so a management account can have its second and third columns.';
comment on column public.budget_lines.amount is
  'Signed in the account''s own direction — sales positive, expenses positive — which is what somebody writing a budget down actually types.';

-- ---------------------------------------------------------------------
-- Writing one down
-- ---------------------------------------------------------------------
create or replace function public.upsert_budget(
  p_id         uuid,
  p_org        uuid,
  p_year       uuid,
  p_name       text,
  p_department text default null,
  p_notes      text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id  uuid := p_id;
  v_row public.budgets;
begin
  if not app.can_write_module(p_org, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'A budget needs a name.' using errcode = '23514';
  end if;
  if not exists (select 1 from public.fiscal_years y
                  where y.id = p_year and y.org_id = p_org) then
    raise exception 'No such financial year.' using errcode = 'P0002';
  end if;

  if v_id is null then
    insert into public.budgets
      (org_id, fiscal_year_id, name, department_code, notes, created_by)
    values (p_org, p_year, trim(p_name),
            nullif(trim(coalesce(p_department, '')), ''), p_notes, auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  select * into v_row from public.budgets where id = v_id;
  if v_row.id is null or v_row.org_id <> p_org then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if v_row.status = 'approved' then
    raise exception
      'That budget is approved. Supersede it with another one rather '
      'than editing what was agreed.' using errcode = '23514';
  end if;

  update public.budgets
     set name = trim(p_name),
         fiscal_year_id = p_year,
         department_code = nullif(trim(coalesce(p_department, '')), ''),
         notes = p_notes
   where id = v_id;
  return v_id;
end;
$$;

revoke all on function public.upsert_budget(uuid, uuid, uuid, text, text, text)
  from public, anon;
grant execute on function public.upsert_budget(uuid, uuid, uuid, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- The numbers in it
-- ---------------------------------------------------------------------
--
-- Each entry of p_lines is `{account, period, amount}`. Sent whole and
-- replacing what was there, the way document lines are: a budget is
-- edited as a grid and a partial update would leave rows nobody deleted
-- from a screen that no longer shows them.
create or replace function public.set_budget_lines(
  p_budget uuid, p_lines jsonb)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b   public.budgets;
  v_e   jsonb;
  v_n   integer := 0;
  v_acc uuid;
  v_per uuid;
  v_amt numeric(18, 2);
begin
  select * into v_b from public.budgets where id = p_budget;
  if v_b.id is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_b.status <> 'draft' then
    raise exception
      'That budget is %. Its numbers are what was agreed and are not '
      'edited afterwards.', v_b.status using errcode = '23514';
  end if;

  delete from public.budget_lines where budget_id = p_budget;

  for v_e in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_acc := (v_e->>'account')::uuid;
    v_per := (v_e->>'period')::uuid;
    v_amt := round(coalesce((v_e->>'amount')::numeric, 0), 2);

    -- A zero is not a budget line. Storing it would fill the grid with
    -- rows that say nothing and make "which accounts are budgeted"
    -- unanswerable.
    if v_amt = 0 then
      continue;
    end if;

    if not exists (select 1 from public.accounts a
                    where a.id = v_acc and a.org_id = v_b.org_id
                      and not a.is_group) then
      raise exception 'No such account, or it is a heading.'
        using errcode = 'P0002';
    end if;
    if not exists (select 1 from public.fiscal_periods p
                    where p.id = v_per and p.org_id = v_b.org_id
                      and p.fiscal_year_id = v_b.fiscal_year_id) then
      raise exception
        'That period is not in the budget''s financial year.'
        using errcode = '23514';
    end if;

    insert into public.budget_lines
      (org_id, budget_id, account_id, period_id, amount)
    values (v_b.org_id, p_budget, v_acc, v_per, v_amt)
    on conflict (budget_id, account_id, period_id) do update
      set amount = excluded.amount;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.set_budget_lines(uuid, jsonb) from public, anon;
grant execute on function public.set_budget_lines(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Built from last year, plus a percentage
-- ---------------------------------------------------------------------
--
-- What people actually do. It fills a draft period by period from what
-- the ledger says happened, so the shape of the year comes with it --
-- the December that is always quiet stays quiet -- and then stops,
-- because the six lines that matter are the ones somebody argues about
-- by hand.
--
-- Periods are matched by their number in the year, not by date: a
-- company that moved its year end still means "the first month against
-- the first month".
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

revoke all on function public.build_budget_from_actual(uuid, uuid, numeric)
  from public, anon;
grant execute on function public.build_budget_from_actual(uuid, uuid, numeric)
  to authenticated;

comment on function public.build_budget_from_actual(uuid, uuid, numeric) is
  'Fills a draft budget from a previous year''s actuals, period by period, with an optional uplift. The shape of the year comes with it; the arguing is still done by hand.';

-- ---------------------------------------------------------------------
-- Agreeing it, and putting it away
-- ---------------------------------------------------------------------
create or replace function public.approve_budget(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_b public.budgets;
begin
  select * into v_b from public.budgets where id = p_id;
  if v_b.id is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  -- Approving is the act that makes a budget the thing variances are
  -- measured against, so it takes the same privilege as posting rather
  -- than merely being able to edit.
  if not app.can_post(v_b.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_b.status <> 'draft' then
    raise exception 'That budget is already %.', v_b.status
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.budget_lines l where l.budget_id = p_id) then
    raise exception 'An empty budget is not something to agree to.'
      using errcode = '23514';
  end if;

  update public.budgets
     set status = 'approved', approved_at = now(), approved_by = auth.uid()
   where id = p_id;
  return true;
end;
$$;

revoke all on function public.approve_budget(uuid) from public, anon;
grant execute on function public.approve_budget(uuid) to authenticated;

create or replace function public.archive_budget(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_b public.budgets;
begin
  select * into v_b from public.budgets where id = p_id;
  if v_b.id is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_b.status = 'archived' then
    raise exception 'That budget is already archived.' using errcode = '23514';
  end if;
  -- Archived rather than deleted. Last year's budget is what last
  -- year's variance report was run against, and deleting it would make
  -- a report somebody has already circulated impossible to reproduce.
  update public.budgets set status = 'archived' where id = p_id;
  return true;
end;
$$;

revoke all on function public.archive_budget(uuid) from public, anon;
grant execute on function public.archive_budget(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The third column
-- ---------------------------------------------------------------------
--
-- Budget, actual, variance, and whether the variance is good news.
-- Bounded by period rather than by date so it lines up exactly with the
-- rows the budget is stored in: "the first quarter" is periods one to
-- three, not a date range that might cut a month in half.
--
-- Accounts with a budget and no actual appear, and so do accounts with
-- an actual and no budget. Both are the point: the first is money not
-- yet spent and the second is money nobody planned to spend.
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

revoke all on function public.report_budget_vs_actual(uuid, integer, integer)
  from public, anon;
grant execute on function public.report_budget_vs_actual(uuid, integer, integer)
  to authenticated;

comment on function public.report_budget_vs_actual(uuid, integer, integer) is
  'What happened, what was supposed to, and whether the difference is good news. Accounts budgeted with no spend and accounts spent with no budget both appear, because both are the point.';

-- ---------------------------------------------------------------------
-- The lists
-- ---------------------------------------------------------------------
create or replace function public.budgets_list(p_org uuid)
returns table (
  id          uuid,
  name        text,
  status      text,
  year_name   text,
  year_id     uuid,
  department_code text,
  lines       bigint,
  total       numeric,
  notes       text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select b.id, b.name, b.status::text, y.name, y.id, b.department_code,
           (select count(*) from public.budget_lines l where l.budget_id = b.id),
           (select coalesce(sum(l.amount), 0) from public.budget_lines l
              join public.accounts a on a.id = l.account_id
             where l.budget_id = b.id and a.account_type = 'revenue'),
           b.notes
      from public.budgets b
      join public.fiscal_years y on y.id = b.fiscal_year_id
     where b.org_id = p_org
     order by y.start_date desc, b.name;
end;
$$;

revoke all on function public.budgets_list(uuid) from public, anon;
grant execute on function public.budgets_list(uuid) to authenticated;

-- The grid: every line of one budget, with the period and account named
-- so the screen does not have to join three tables to draw a row.
create or replace function public.budget_lines_for(p_budget uuid)
returns table (
  account_id uuid,
  code       text,
  name       text,
  account_type app.account_type,
  period_id  uuid,
  period_no  smallint,
  period_name text,
  amount     numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select b.org_id into v_org from public.budgets b where b.id = p_budget;
  if v_org is null then
    raise exception 'No such budget.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select a.id, a.code, a.name, a.account_type, p.id, p.period_no, p.name,
           l.amount
      from public.budget_lines l
      join public.accounts a on a.id = l.account_id
      join public.fiscal_periods p on p.id = l.period_id
     where l.budget_id = p_budget
     order by a.code, p.period_no;
end;
$$;

revoke all on function public.budget_lines_for(uuid) from public, anon;
grant execute on function public.budget_lines_for(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.budgets      enable row level security;
alter table public.budget_lines enable row level security;

create policy budgets_read on public.budgets for select
  to authenticated using (app.can_read_module(org_id, 'accounting'));
create policy budget_lines_read on public.budget_lines for select
  to authenticated using (app.can_read_module(org_id, 'accounting'));

-- No write policies. A client that could update `status` directly could
-- approve its own budget, and one that could write lines could change
-- an agreed number after seeing the actuals — which is the single thing
-- a variance report exists to prevent.
revoke all on public.budgets      from anon, authenticated;
revoke all on public.budget_lines from anon, authenticated;

grant select on public.budgets      to authenticated;
grant select on public.budget_lines to authenticated;

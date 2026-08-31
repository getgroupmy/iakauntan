-- =====================================================================
-- iAkauntan :: the project budget nobody could overrun
--
-- `projects.budget_amount` has been a column since `0088` and the word
-- appears nowhere else — not in another migration, not in the client,
-- not in a report. Nothing writes it and nothing reads it.
--
-- The reason is one step further back. Nothing writes *any* column of
-- `projects`. `projectsProvider` reads the table, four screens offer
-- the list, and the timesheet screen's own empty state says "No
-- projects yet — a project is what hours are recorded against and what
-- they are billed to" while offering no way to make one. A project has
-- to be inserted by hand, straight into the table, by somebody with a
-- database connection.
--
-- So `budget_amount` is not an unused column. It is the visible end of
-- a table with no front door.
--
-- Three things, then, and the third is the one that matters.
--
-- A project can be created and amended, with its rules where they hold:
-- a budget is not negative, and a job does not end before it starts.
--
-- `report_project_budget` puts the budget beside what has been spent
-- against it. The ledger side already works — `0088` tags `gl_lines`
-- with `project_code` and `report_profit_loss_by_dimension` reads it —
-- so what was missing was only the comparison. A budget nothing is
-- compared against is a number somebody typed once.
--
-- And closing a project refuses while billable time on it has not been
-- invoiced. `0176` made exactly this refusal for a legal matter holding
-- client money, and the reasoning carries: hours recorded, billable,
-- never invoiced, on a job nobody will open again are revenue the
-- company earned and threw away. The difference between a matter and a
-- project here is only which pot the forgotten money sits in.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What a project is allowed to say about itself
-- ---------------------------------------------------------------------
alter table public.projects
  drop constraint if exists projects_budget_ck;
alter table public.projects
  add constraint projects_budget_ck
  check (budget_amount is null or budget_amount >= 0);

alter table public.projects
  drop constraint if exists projects_dates_ck;
alter table public.projects
  add constraint projects_dates_ck
  check (end_date is null or start_date is null or end_date >= start_date);

-- ---------------------------------------------------------------------
-- What a project has cost, and what it has earned
--
-- Cost is read from the ledger rather than from the documents, because
-- the ledger is where everything lands: a bill line tagged to the
-- project, an expense claim, a journal somebody posted by hand. Reading
-- the documents would count the ones this module knows about and
-- silently miss the rest.
--
-- Unbilled time is counted separately and *not* added to cost. It is
-- neither — it is revenue not yet raised, and adding it to either side
-- would flatter one of them. It is here because it is the number that
-- decides whether the job may be closed.
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
           round(coalesce(g.cost, 0), 2),
           round(coalesce(g.revenue, 0), 2),
           round(coalesce(u.amount, 0), 2),
           -- Null when there is no budget, rather than zero. A job with
           -- no budget is not a job exactly on budget, and a report
           -- that says nought either way is answering a question it was
           -- never asked.
           case when p.budget_amount is null then null
                else round(p.budget_amount - coalesce(g.cost, 0), 2) end,
           case when coalesce(p.budget_amount, 0) = 0 then null
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

-- ---------------------------------------------------------------------
-- Closing a job
--
-- `0176`'s refusal, one table over. A closed project drops out of every
-- picker in the client, so time on it can never afterwards be selected,
-- invoiced or even found without going looking — and the hours were
-- billable, which is to say somebody meant to charge for them.
--
-- Writing the time off is a decision, not an oversight, so there is a
-- way to say it: `p_write_off` marks the outstanding entries
-- non-billable, which is the honest record of having decided not to
-- charge, and then closes. What is refused is closing while the
-- question is still open.
-- ---------------------------------------------------------------------
create or replace function public.close_project(
  p_project uuid,
  p_write_off boolean default false)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_p    public.projects;
  v_time numeric(18, 2);
  v_n    integer;
begin
  select * into v_p from public.projects where id = p_project;
  if v_p.id is null then
    raise exception 'No such project.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_p.org_id) then
    raise exception 'not permitted to close a project' using errcode = '42501';
  end if;
  if not v_p.is_active then
    raise exception 'That project is already closed.' using errcode = '23514';
  end if;

  select coalesce(sum(t.amount), 0), count(*)
    into v_time, v_n
    from public.time_entries t
   where t.project_id = p_project
     and t.is_billable
     and not t.is_billed;

  if v_n > 0 and not p_write_off then
    raise exception
      'This project still has % of billable time nobody has invoiced, '
      'across % entries. Bill it, or close the project writing the time '
      'off, which says the decision was taken. Hours left on a closed '
      'job are hours nobody is looking at.',
      to_char(round(v_time, 2), 'FM999G999G990D00'), v_n
      using errcode = '23514';
  end if;

  if p_write_off and v_n > 0 then
    -- Marked non-billable rather than deleted. The hours were worked,
    -- and the utilisation report that counts what people did must go on
    -- counting them; what changes is that nobody is going to be charged.
    update public.time_entries
       set is_billable = false, updated_at = now()
     where project_id = p_project
       and is_billable
       and not is_billed;
  end if;

  update public.projects
     set is_active = false, updated_at = now()
   where id = p_project;
end $$;

-- ---------------------------------------------------------------------
-- And reopening one
--
-- A job closed by mistake, or one the customer comes back about. The
-- write-off is not undone: those hours were decided about, and quietly
-- making them billable again on reopening would put a decision back on
-- the books that somebody took deliberately.
-- ---------------------------------------------------------------------
create or replace function public.reopen_project(p_project uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_p public.projects;
begin
  select * into v_p from public.projects where id = p_project;
  if v_p.id is null then
    raise exception 'No such project.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_p.org_id) then
    raise exception 'not permitted to reopen a project'
      using errcode = '42501';
  end if;
  if v_p.is_active then
    raise exception 'That project is already open.' using errcode = '23514';
  end if;

  update public.projects
     set is_active = true, updated_at = now()
   where id = p_project;
end $$;

grant execute on function public.report_project_budget(uuid, boolean)
  to authenticated;
grant execute on function public.close_project(uuid, boolean)
  to authenticated;
grant execute on function public.reopen_project(uuid) to authenticated;

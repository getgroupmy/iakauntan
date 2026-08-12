-- Three capabilities that were built and never wired to anything:
-- price levels, analysis dimensions, and recurring journals.
--
-- `price_levels` and `item_prices` have been in the schema since 0003
-- and `contacts.price_level_id` since the same migration, with zero
-- references in the app — the line editor reads `items.unit_price` and
-- nothing else, so a customer on Wholesale is quoted the retail price.
--
-- `gl_lines.project_code` and `.department_code` have been on every line
-- table since 0004 with nothing to put in them and nothing that reads
-- them out, so job costing is impossible even though the ledger has room
-- for it.
--
-- `recurring_journals` is run nightly by `app.run_recurring_journals`
-- through the `iakauntan-daily` cron and there has never been a way to
-- create one. The runner has been working perfectly on an empty table.

-- ---------------------------------------------------------------------
-- Projects
--
-- `department_code` already has a home — the HR `departments` table —
-- so only projects need one. Codes rather than ids on the ledger lines,
-- because that is what the columns are: renaming a project must not
-- silently restate last year's job costing.
-- ---------------------------------------------------------------------
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  code        text not null,
  name        text not null,
  description text,
  contact_id  uuid references public.contacts (id) on delete set null,
  start_date  date,
  end_date    date,
  budget_amount numeric(18, 2),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

alter table public.projects enable row level security;

drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects
  for insert to authenticated with check (app.can_write(org_id));
drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects
  for delete to authenticated using (app.can_admin(org_id));

-- ---------------------------------------------------------------------
-- What to charge this customer for this item
--
-- Two ways a price level can work, and both are in the schema:
-- `item_prices` names a price outright for an item at a level, and
-- `price_levels.adjustment_percent` moves every price by a percentage.
-- The named price wins, because somebody typed it deliberately.
--
-- Quantity breaks come from `item_prices.min_quantity`: the row with the
-- highest minimum that the quantity reaches.
-- ---------------------------------------------------------------------
create or replace function public.item_price(
  p_item_id uuid,
  p_contact_id uuid default null,
  p_quantity numeric default 1)
returns numeric
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_org      uuid;
  v_base     numeric(18, 4);
  v_level    uuid;
  v_named    numeric(18, 4);
  v_percent  numeric(9, 4);
begin
  select org_id, unit_price into v_org, v_base
    from public.items where id = p_item_id;
  if v_org is null then
    raise exception 'Item % not found', p_item_id using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  if p_contact_id is not null then
    select price_level_id into v_level
      from public.contacts where id = p_contact_id and org_id = v_org;
  end if;

  -- No level, or a contact from another organization: list price.
  if v_level is null then
    select id into v_level from public.price_levels
     where org_id = v_org and is_default and is_active limit 1;
  end if;
  if v_level is null then return v_base; end if;

  select p.unit_price into v_named
    from public.item_prices p
   where p.item_id = p_item_id and p.price_level_id = v_level
     and coalesce(p.min_quantity, 0) <= coalesce(p_quantity, 1)
   order by coalesce(p.min_quantity, 0) desc
   limit 1;

  if v_named is not null then return v_named; end if;

  select adjustment_percent into v_percent
    from public.price_levels where id = v_level;

  if coalesce(v_percent, 0) = 0 then return v_base; end if;
  return round(v_base * (1 + v_percent / 100.0), 4);
end;
$$;

-- ---------------------------------------------------------------------
-- Profit and loss for one project or one department
--
-- A new function rather than more arguments on `report_profit_loss`:
-- that one is called from the reports screen with three arguments and
-- adding optional ones would change the shape of a function every
-- report already depends on.
--
-- Lines with no dimension are excluded when a dimension is asked for.
-- Including them would show the whole company's overheads against every
-- project, which is worse than showing none of them.
-- ---------------------------------------------------------------------
create or replace function public.report_profit_loss_by_dimension(
  p_org_id uuid,
  p_from date,
  p_to date default current_date,
  p_project_code text default null,
  p_department_code text default null)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype,
  amount numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
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
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$$;

-- Which dimensions actually appear in the ledger, so the report can
-- offer the ones with something behind them rather than every project
-- ever created.
create or replace function public.ledger_dimensions(p_org_id uuid)
returns table (kind text, code text, entries bigint)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select 'project', l.project_code, count(*)
    from public.gl_lines l
   where l.org_id = p_org_id and l.project_code is not null
     and app.is_org_member(p_org_id)
   group by l.project_code
  union all
  select 'department', l.department_code, count(*)
    from public.gl_lines l
   where l.org_id = p_org_id and l.department_code is not null
     and app.is_org_member(p_org_id)
   group by l.department_code
   order by 1, 2;
$$;

-- ---------------------------------------------------------------------
-- Run the recurring journals now, for one organization
--
-- The nightly cron is the normal route. This exists for what the cron
-- cannot help with: a template just created and dated last week, or a
-- run that failed on a closed period and has been fixed at four in the
-- afternoon.
--
-- Deliberately not a wrapper around `app.run_recurring_journals`: that
-- one walks every organization in the database, and a signed-in user may
-- only post in their own. Same body, one org, one permission check.
-- ---------------------------------------------------------------------
create or replace function public.run_recurring_journals_for(
  p_org_id uuid, p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.recurring_journals;
  v_n integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  -- Deliberately not `app.run_recurring_journals`: that one walks every
  -- organization in the database, and a signed-in user may only post in
  -- their own. Same body, one org.
  for r in
    select * from public.recurring_journals
     where org_id = p_org_id and is_active
       and next_run_date is not null and next_run_date <= p_on
       and (end_date is null or next_run_date <= end_date)
  loop
    begin
      if r.auto_post then
        perform app.create_gl_entry_internal(
          p_org_id       => r.org_id,
          p_entry_date   => r.next_run_date,
          p_source       => 'recurring'::app.journal_source,
          p_lines        => r.template -> 'lines',
          p_description  => coalesce(r.description, r.name),
          p_source_table => 'recurring_journals',
          p_source_id    => r.id,
          p_reference    => r.name);
      end if;

      update public.recurring_journals
         set last_run_date = r.next_run_date,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count),
             last_error = null, last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
    end;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.item_price(uuid, uuid, numeric) from public, anon;
grant execute on function public.item_price(uuid, uuid, numeric) to authenticated;

revoke all on function public.report_profit_loss_by_dimension(uuid, date, date, text, text)
  from public, anon;
grant execute on function public.report_profit_loss_by_dimension(uuid, date, date, text, text)
  to authenticated;

revoke all on function public.ledger_dimensions(uuid) from public, anon;
grant execute on function public.ledger_dimensions(uuid) to authenticated;

revoke all on function public.run_recurring_journals_for(uuid, date) from public, anon;
grant execute on function public.run_recurring_journals_for(uuid, date) to authenticated;

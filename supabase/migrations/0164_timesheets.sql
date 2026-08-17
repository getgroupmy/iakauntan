-- Timesheets: record time, and be able to bill it.
--
-- Two things are wrong with time recording as it stands.
--
-- **It is welded to law firms.** `time_entries.matter_id` is NOT NULL and
-- the table is gated on the `legal` module, so a consultant, an
-- engineer, an architect or an agency — everyone else who sells hours —
-- cannot record a minute. `public.projects` has been sitting there since
-- the dimensions work with a code, a name, a client and a budget, and
-- nothing has ever written to it. It is the anchor this needs.
--
-- **Nothing can bill it.** `time_entries.is_billed` and `invoice_id`
-- exist, and the only function in the database that mentions either is
-- `report_matter_summary`, which *reads* them. There is no code path
-- anywhere that sets them. A law firm using this today can record a
-- year of chargeable time and has no way to turn any of it into an
-- invoice. That is the gap worth closing first, and it is closed here
-- for matters and projects alike.

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('timesheets', 'Timesheets',
   'Chargeable time against projects and clients, billing rates per '
   'person, and turning unbilled hours into an invoice',
   false, 49, 14)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Time can hang off a project as well as a matter
-- ---------------------------------------------------------------------
alter table public.time_entries alter column matter_id drop not null;

alter table public.time_entries
  add column project_id uuid references public.projects(id) on delete restrict;

create index time_entries_project_idx
  on public.time_entries (project_id) where project_id is not null;
create index time_entries_unbilled_idx
  on public.time_entries (org_id, entry_date)
  where is_billable and not is_billed;

-- The cross-tenant rule, applied to both anchors.
alter table public.projects add constraint projects_org_id_id_key
  unique (org_id, id);
alter table public.matters add constraint matters_org_id_id_key
  unique (org_id, id);
alter table public.time_entries
  add constraint time_entries_project_same_org
  foreign key (org_id, project_id) references public.projects (org_id, id);
alter table public.time_entries
  add constraint time_entries_matter_same_org
  foreign key (org_id, matter_id) references public.matters (org_id, id);

-- An hour is worked on one thing. Both at once is not a richer record,
-- it is two answers to "who is being billed for this".
alter table public.time_entries
  add constraint time_entries_one_anchor
  check (matter_id is null or project_id is null);

-- Chargeable time has to be chargeable *to* somebody. Unbillable time —
-- training, admin, writing this — is allowed to float free, which is the
-- only way a timesheet tells you anything about utilisation.
create or replace function app.time_entry_is_chargeable_to_something()
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp as $$
begin
  if new.is_billable
     and new.matter_id is null and new.project_id is null then
    raise exception
      'Billable time has to be against a matter or a project — there is '
      'otherwise nobody to invoice for it. Mark it non-billable if that is '
      'what it is.'
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger chargeable_to_something
  before insert or update on public.time_entries
  for each row execute function app.time_entry_is_chargeable_to_something();

-- ---------------------------------------------------------------------
-- Row level security, widened
--
-- The existing policies say `has_module(org_id, 'legal')`. A firm that
-- bought timesheets and not legal has to be able to record time, so both
-- open the table; which anchor an entry uses is what actually separates
-- them, and the FKs above are what enforce that.
-- ---------------------------------------------------------------------
drop policy if exists time_entries_insert on public.time_entries;
drop policy if exists time_entries_update on public.time_entries;
drop policy if exists time_entries_delete on public.time_entries;
drop policy if exists time_entries_write on public.time_entries;

create or replace function app.has_time_module(p_org_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select app.has_module(p_org_id, 'legal')
      or app.has_module(p_org_id, 'timesheets');
$$;

create policy time_entries_write on public.time_entries
  for all to authenticated
  using (app.can_write(org_id) and app.has_time_module(org_id))
  with check (app.can_write(org_id) and app.has_time_module(org_id));

-- `projects` was created with the dimensions work and never gated. It is
-- the timesheet anchor now, so it gets the same treatment as everything
-- else that belongs to a module.
alter table public.projects enable row level security;
drop policy if exists projects_select on public.projects;
drop policy if exists projects_write on public.projects;
create policy projects_select on public.projects
  for select to authenticated using (app.is_org_member(org_id));
create policy projects_write on public.projects
  for all to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
grant select, insert, update, delete on public.projects to authenticated;

-- ---------------------------------------------------------------------
-- What an hour is worth
--
-- Three places a rate can come from, most specific first: this person on
-- this project, this person generally, or the engagement's own rate. A
-- senior partner billed at the junior's rate for six months is the kind
-- of error nobody spots by looking at a timesheet, so the resolution is
-- one function and it is asserted.
-- ---------------------------------------------------------------------
create table public.billing_rates (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  -- Null means "this person's default rate". A row with a project is
  -- that person's rate on that project only.
  project_id     uuid references public.projects(id) on delete cascade,
  effective_from date not null,
  hourly_rate    numeric(18, 2) not null check (hourly_rate >= 0),
  notes          text,
  created_at     timestamptz not null default now()
);

alter table public.billing_rates
  add constraint billing_rates_project_same_org
  foreign key (org_id, project_id) references public.projects (org_id, id)
  on delete cascade;

-- Two partial indexes rather than one unique over a nullable column: in
-- Postgres nulls are distinct, so `unique (org_id, user_id, project_id,
-- effective_from)` would happily take the same default rate twice.
create unique index billing_rates_default_idx
  on public.billing_rates (org_id, user_id, effective_from)
  where project_id is null;
create unique index billing_rates_project_idx
  on public.billing_rates (org_id, user_id, project_id, effective_from)
  where project_id is not null;

alter table public.billing_rates enable row level security;
create policy billing_rates_select on public.billing_rates
  for select to authenticated
  using (app.is_org_member(org_id) and app.has_time_module(org_id));
create policy billing_rates_write on public.billing_rates
  for all to authenticated
  using (app.can_admin(org_id) and app.has_time_module(org_id))
  with check (app.can_admin(org_id) and app.has_time_module(org_id));
grant select, insert, update, delete on public.billing_rates to authenticated;

create or replace function app.billing_rate_for(
  p_org_id uuid,
  p_user_id uuid,
  p_project_id uuid,
  p_matter_id uuid,
  p_on date)
returns numeric language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_rate numeric(18, 2);
begin
  -- 1. This person, on this project.
  if p_project_id is not null then
    select hourly_rate into v_rate from public.billing_rates
     where org_id = p_org_id and user_id = p_user_id
       and project_id = p_project_id and effective_from <= p_on
     order by effective_from desc limit 1;
    if v_rate is not null then return v_rate; end if;
  end if;

  -- 2. This person, generally.
  select hourly_rate into v_rate from public.billing_rates
   where org_id = p_org_id and user_id = p_user_id
     and project_id is null and effective_from <= p_on
   order by effective_from desc limit 1;
  if v_rate is not null then return v_rate; end if;

  -- 3. Whatever the engagement itself says. A matter carries its own
  --    agreed rate; a project does not, so this is where a project with
  --    no rate for anybody comes back as nothing.
  if p_matter_id is not null then
    select hourly_rate into v_rate from public.matters where id = p_matter_id;
  end if;

  return v_rate;
end $$;

-- Fill the rate in when the person recording time did not say one, which
-- is almost always: somebody logging two hours should not have to know
-- what they are charged out at.
create or replace function app.time_entry_default_rate()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if new.hourly_rate is null or new.hourly_rate = 0 then
    new.hourly_rate := coalesce(
      app.billing_rate_for(new.org_id, new.user_id, new.project_id,
                           new.matter_id, new.entry_date),
      0);
  end if;
  return new;
end $$;

-- The name is load-bearing. Postgres fires BEFORE triggers in
-- alphabetical order, and the existing one on this table is
-- `calc_amount`, which multiplies the rate by the minutes. A trigger
-- called `default_rate` would sort *after* it and fill in a rate that
-- had already been multiplied by nothing — every entry would come out at
-- zero and the timesheet would look like a lot of free work.
-- `apply_billing_rate` sorts before `calc_amount`, which is the whole
-- reason it is called that.
create trigger apply_billing_rate
  before insert or update on public.time_entries
  for each row execute function app.time_entry_default_rate();

-- ---------------------------------------------------------------------
-- Turning hours into an invoice
--
-- This is the part that was missing entirely. `is_billed` and
-- `invoice_id` have been on `time_entries` since the legal module
-- shipped and nothing in the database has ever written to either.
--
-- One invoice per engagement, one line per person, because that is what
-- a client queries: not "what did you do at 14:20 on the third", but
-- "why is there eleven hours of associate time on this". The entries
-- themselves stay linked to the invoice, so the detail is a click away
-- when the client does ask.
--
-- Entries are filtered on `not is_billed`, so running it twice over the
-- same period bills nothing the second time rather than billing it
-- again. That is the property that matters here — a double-billed client
-- is a lost client.
-- ---------------------------------------------------------------------
create or replace function app.time_income_account(p_org_id uuid)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '4840' and deleted_at is null;
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

create or replace function app.bill_time_internal(
  p_org_id uuid,
  p_project_id uuid,
  p_matter_id uuid,
  p_contact_id uuid,
  p_subject text,
  p_from date,
  p_to date,
  p_due date)
returns uuid language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_invoice uuid;
  v_account uuid;
  v_line record;
  v_no integer := 0;
  v_total numeric(18, 2) := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to raise an invoice'
      using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception
      'There is no client on this engagement, so there is nobody to '
      'invoice.' using errcode = '23502';
  end if;
  if p_to < p_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.time_entries t
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0)
  then
    raise exception
      'No unbilled chargeable time on this engagement between % and %.',
      p_from, p_to using errcode = 'P0002';
  end if;

  v_account := app.time_income_account(p_org_id);

  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id,
    subject, reference, currency, exchange_rate, status)
  values (
    p_org_id, 'invoice',
    app.next_document_number_internal(p_org_id, 'invoice'),
    p_to, coalesce(p_due, p_to), p_contact_id,
    p_subject, format('%s to %s', p_from, p_to),
    app.base_currency(p_org_id), 1, 'draft')
  returning id into v_invoice;

  -- One line per person, with the hours on it. `sum(minutes)/60` is
  -- rounded once at the end rather than per entry, so six ten-minute
  -- calls bill as one hour and not as 0.996 of one.
  for v_line in
    select t.user_id,
           coalesce(p.full_name, p.email, 'Fee earner') as who,
           round(sum(t.minutes)::numeric / 60.0, 2) as hours,
           sum(t.amount) as amount
      from public.time_entries t
      left join public.profiles p on p.id = t.user_id
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0
     group by t.user_id, p.full_name, p.email
     order by 2
  loop
    v_no := v_no + 1;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_rate)
    values (p_org_id, v_invoice, v_no, 'item',
            format('%s — %s hours', v_line.who, v_line.hours),
            1, v_line.amount, v_account, 0);
    v_total := v_total + v_line.amount;
  end loop;

  update public.time_entries t
     set is_billed = true, invoice_id = v_invoice
   where t.org_id = p_org_id
     and t.project_id is not distinct from p_project_id
     and t.matter_id is not distinct from p_matter_id
     and t.entry_date between p_from and p_to
     and t.is_billable and not t.is_billed and t.amount > 0;

  perform app.post_sales_document_internal(v_invoice);
  return v_invoice;
end $$;

create or replace function public.bill_project_time(
  p_project_id uuid,
  p_from date,
  p_to date,
  p_due date default null)
returns uuid language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare pr public.projects;
begin
  select * into pr from public.projects where id = p_project_id;
  if not found then
    raise exception 'No such project' using errcode = 'P0002';
  end if;
  if not app.has_module(pr.org_id, 'timesheets') then
    raise exception 'The timesheets module is not switched on'
      using errcode = '42501';
  end if;
  return app.bill_time_internal(
    pr.org_id, p_project_id, null, pr.contact_id,
    format('Professional fees — %s', pr.name), p_from, p_to, p_due);
end $$;

create or replace function public.bill_matter_time(
  p_matter_id uuid,
  p_from date,
  p_to date,
  p_due date default null)
returns uuid language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare m public.matters;
begin
  select * into m from public.matters where id = p_matter_id;
  if not found then
    raise exception 'No such matter' using errcode = 'P0002';
  end if;
  if not app.has_module(m.org_id, 'legal') then
    raise exception 'The legal module is not switched on'
      using errcode = '42501';
  end if;
  return app.bill_time_internal(
    m.org_id, null, p_matter_id, m.client_id,
    format('Professional fees — %s', m.name), p_from, p_to, p_due);
end $$;

-- ---------------------------------------------------------------------
-- What everyone has been doing
--
-- Hours by person, split billable from not, and what is still sitting
-- unbilled. The last column is the one a partner actually reads.
-- ---------------------------------------------------------------------
create or replace function public.report_timesheet(
  p_org_id uuid,
  p_from date,
  p_to date)
returns table (
  user_id uuid,
  who text,
  billable_hours numeric,
  non_billable_hours numeric,
  utilisation_percent numeric,
  billed_amount numeric,
  unbilled_amount numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) or not app.has_time_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select t.user_id,
           coalesce(p.full_name, p.email, 'Unknown'),
           round(sum(t.minutes) filter (where t.is_billable)::numeric
                 / 60.0, 2),
           round(sum(t.minutes) filter (where not t.is_billable)::numeric
                 / 60.0, 2),
           -- Billable as a share of everything recorded. Nothing
           -- recorded is nothing to divide by, and 0/0 is not 0% — it is
           -- "this person did not fill in a timesheet", which is a
           -- different thing to say.
           case when coalesce(sum(t.minutes), 0) = 0 then null
                else round(100.0
                  * coalesce(sum(t.minutes) filter (where t.is_billable), 0)
                  / sum(t.minutes), 1) end,
           coalesce(sum(t.amount) filter (where t.is_billed), 0),
           coalesce(sum(t.amount) filter
                    (where t.is_billable and not t.is_billed), 0)
      from public.time_entries t
      left join public.profiles p on p.id = t.user_id
     where t.org_id = p_org_id
       and t.entry_date between p_from and p_to
     group by t.user_id, p.full_name, p.email
     order by 2;
end $$;

grant execute on function app.has_time_module(uuid) to authenticated;
grant execute on function app.billing_rate_for(uuid, uuid, uuid, uuid, date)
  to authenticated;
grant execute on function public.bill_project_time(uuid, date, date, date)
  to authenticated;
grant execute on function public.bill_matter_time(uuid, date, date, date)
  to authenticated;
grant execute on function public.report_timesheet(uuid, date, date)
  to authenticated;

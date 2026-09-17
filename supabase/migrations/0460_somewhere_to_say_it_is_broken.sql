-- ---------------------------------------------------------------------
-- 0460  Somewhere to say it is broken
-- ---------------------------------------------------------------------
-- There is nowhere in this product for a user to say "this is wrong".
-- Measured: `tickets` is the *service desk a tenant runs for its own
-- customers* -- org-scoped, SLA'd, and entirely about the tenant's
-- business. Nothing points the other way, at us. A person who finds a
-- fault in the payroll screen has an e-mail address to guess at.
--
-- ### Not an entitlement
--
-- This is asked for as a module and is deliberately **not** one in the
-- `platform_modules` sense. Reporting a fault is not a feature a
-- company buys, and a company that stopped paying for a module is
-- exactly the company most likely to want to tell us why. So the
-- destination carries no module gate, the way Team and Settings do
-- not.
--
-- ### Who reads a report
--
-- The reporter, the administrators of the company they were in, and
-- platform staff. **Not every user of the platform.**
--
-- That is a narrower answer than "a shared board", and it is a
-- judgement rather than a technicality: people paste screenshots into
-- bug reports, and a screenshot of the payroll screen is a list of
-- salaries. `no_tenant_sees_another.sql` is the loudest rule in this
-- schema and a public feature-request board is the obvious way to
-- breach it by accident. If a genuinely public board is wanted, the
-- honest way to build it is a separate opt-in field on each report --
-- "may we quote this" -- and not a widened policy.
--
-- ### The picture
--
-- Through `attachments`, which is already generic -- `entity_table`
-- plus `entity_id` -- and already has tested storage policies. Two of
-- its helpers needed a branch, and both are restated here in full
-- rather than patched:
--
--   * `app.can_attach_to` refuses without the `attachments` **module**
--     and requires `can_write`. Neither can hold here: the person most
--     likely to have a screenshot is the employee who hit the fault,
--     who may hold no write permission at all, and a bug report is not
--     something a company buys.
--   * `app.can_read_attachment` opens with `can_write or
--     can_read_ledger`, which is about a company's own records. A bug
--     report is not one of those, so its branch comes first: whoever
--     may read the report may see the picture on it.
--
-- ### Status is the platform's to set
--
-- An author may correct their own report while it is still `new`. What
-- they may not do is mark it `done`. That is enforced by a trigger
-- rather than by leaving `update` off, because an author who cannot
-- fix a typo in their own report writes a second report.
--
-- ### Mutants
--
-- Eight, restated into a built database and run against
-- `supabase/tests/feedback.sql`. **Two survived the assertions as first
-- written**, and both for the same reason: a fixture that could not
-- tell two things apart.
--
--   * `my_feedback` showing a company's reports to any member rather
--     than to its administrators -- **survived**, because the reader in
--     the test was the fixture's owner, who is both. It now asks a
--     colleague who is a member and not an administrator, and reads 1
--     where 0 is right;
--   * `my_feedback` ignoring who is asking altogether -- killed by "and
--     another company sees none of it", 3 for 0;
--   * the status guard dropped -- killed by "but not mark it done";
--   * the platform note writable by the author -- killed by "nor write
--     the answer to it". A reporter who can write the answer to their
--     own report has a support queue that lies;
--   * the triage list open to anybody -- killed by "nor read every
--     company's reports at once";
--   * a report raised against any company at all -- killed at "anybody
--     can report a fault", though **by the foreign key rather than by
--     the guard**: a random uuid is not an organization. The guard is
--     what stops a report against a company that exists and is not
--     yours, which the foreign key would happily accept;
--   * the feedback branch moved to *after* the module check in
--     `app.can_attach_to` -- killed by "the person who hit it can put a
--     picture on it". The order of the two is the whole point: the
--     company in that block deliberately has no `attachments` module;
--   * the triage list not sorting faults above suggestions --
--     **survived**, because the assertion read the first row and the
--     list spans every company, so the first row was a fault by luck.
--     It now asks the real question -- that no suggestion appears above
--     any fault -- and reads 2 where 0 is right.
--
-- Both survivors are the same shape as the ones in 0459: an assertion
-- pointed at a participant that could not distinguish the two
-- behaviours.
-- ---------------------------------------------------------------------

create type app.feedback_kind as enum ('bug', 'feature', 'suggestion');

create type app.feedback_status as enum (
  'new', 'triaged', 'planned', 'in_progress', 'done', 'declined',
  'duplicate');

create table public.feedback_reports (
  id            uuid primary key default gen_random_uuid(),
  -- The company they were looking at when they hit it. Null for
  -- platform staff, who belong to none, and `on delete set null` so a
  -- closed company does not take its bug reports with it -- the fault
  -- is ours and outlives them.
  org_id        uuid references public.organizations (id) on delete set null,
  reported_by   uuid references auth.users (id) on delete set null,
  kind          app.feedback_kind not null default 'bug',
  title         text not null,
  body          text,
  -- Where in the app, and which build. Both are the difference between
  -- a report somebody can act on and one they cannot.
  screen        text,
  app_version   text,
  status        app.feedback_status not null default 'new',
  -- 1 is "nobody can work", 4 is "it is untidy". Only meaningful on a
  -- bug, and left null on the other two rather than defaulted to a
  -- number that would sort them among the faults.
  severity      smallint,
  platform_note text,
  handled_by    uuid references auth.users (id) on delete set null,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint feedback_needs_a_title
    check (nullif(btrim(title), '') is not null),
  constraint feedback_severity_is_a_severity
    check (severity is null or severity between 1 and 4)
);

create index feedback_reports_org_idx
  on public.feedback_reports (org_id, created_at desc);
create index feedback_reports_status_idx
  on public.feedback_reports (status, created_at desc);

alter table public.feedback_reports enable row level security;

create policy feedback_select on public.feedback_reports
  for select using (
    reported_by = auth.uid()
    or app.is_platform_admin()
    or (org_id is not null and app.can_admin(org_id)));

create policy feedback_insert on public.feedback_reports
  for insert with check (
    reported_by = auth.uid()
    and (org_id is null or app.is_org_member(org_id)));

-- The author while it is still new, and the platform always. The
-- trigger below is what stops an author marking their own report done.
create policy feedback_update on public.feedback_reports
  for update using (
    app.is_platform_admin()
    or (reported_by = auth.uid() and status = 'new'))
  with check (
    app.is_platform_admin()
    or (reported_by = auth.uid() and status = 'new'));

revoke all on public.feedback_reports from public;
grant select, insert, update on public.feedback_reports to authenticated;

create trigger set_updated_at before update on public.feedback_reports
  for each row execute function app.set_updated_at();

create or replace function app.guard_feedback_status()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
begin
  if NEW.status is distinct from OLD.status
     and not app.is_platform_admin() then
    raise exception
      'Only the people who look after this product may change what a '
      'report''s status is. You can still correct what it says.'
      using errcode = '42501';
  end if;
  if (NEW.platform_note is distinct from OLD.platform_note
      or NEW.handled_by is distinct from OLD.handled_by)
     and not app.is_platform_admin() then
    raise exception 'That part of the report is not yours to write.'
      using errcode = '42501';
  end if;
  return NEW;
end;
$$;

create trigger guard_status before update on public.feedback_reports
  for each row execute function app.guard_feedback_status();

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
create or replace function public.report_feedback(
  p_title       text,
  p_kind        app.feedback_kind default 'bug',
  p_body        text default null,
  p_screen      text default null,
  p_app_version text default null,
  p_severity    smallint default null,
  p_org_id      uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'Say in one line what is wrong.' using errcode = '23514';
  end if;
  if p_org_id is not null and not app.is_org_member(p_org_id) then
    raise exception 'That is not your company.' using errcode = '42501';
  end if;

  insert into public.feedback_reports
    (org_id, reported_by, kind, title, body, screen, app_version, severity)
  values (p_org_id, auth.uid(), coalesce(p_kind, 'bug'), btrim(p_title),
          nullif(btrim(p_body), ''), nullif(btrim(p_screen), ''),
          nullif(btrim(p_app_version), ''),
          case when p_kind = 'bug' then p_severity end)
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Reading them
--
-- Through a function rather than off the table, because the reporter's
-- name lives in `profiles`, which only somebody sharing an organization
-- may read -- and a platform administrator shares none.
-- ---------------------------------------------------------------------
create or replace function public.my_feedback(p_org_id uuid default null)
returns table (
  id            uuid,
  kind          app.feedback_kind,
  title         text,
  body          text,
  screen        text,
  status        app.feedback_status,
  severity      smallint,
  platform_note text,
  reported_by   text,
  is_mine       boolean,
  created_at    timestamptz,
  resolved_at   timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select f.id, f.kind, f.title, f.body, f.screen, f.status, f.severity,
         f.platform_note,
         coalesce(p.full_name, p.email, 'somebody who has since left'),
         f.reported_by = auth.uid(),
         f.created_at, f.resolved_at
    from public.feedback_reports f
    left join public.profiles p on p.id = f.reported_by
   where (f.reported_by = auth.uid()
          or (p_org_id is not null
              and f.org_id = p_org_id
              and app.can_admin(p_org_id)))
   order by f.created_at desc;
$$;

create or replace function public.platform_feedback(
  p_status app.feedback_status default null,
  p_limit  integer default 200)
returns table (
  id            uuid,
  kind          app.feedback_kind,
  title         text,
  body          text,
  screen        text,
  app_version   text,
  status        app.feedback_status,
  severity      smallint,
  platform_note text,
  reported_by   text,
  company       text,
  created_at    timestamptz,
  resolved_at   timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  perform app.note_read(null, 'feedback_reports');

  return query
  select f.id, f.kind, f.title, f.body, f.screen, f.app_version, f.status,
         f.severity, f.platform_note,
         coalesce(p.full_name, p.email, 'somebody who has since left'),
         o.name, f.created_at, f.resolved_at
    from public.feedback_reports f
    left join public.profiles p on p.id = f.reported_by
    left join public.organizations o on o.id = f.org_id
   where (p_status is null or f.status = p_status)
   order by
     -- Faults first, worst first, then whatever came in most recently.
     case when f.kind = 'bug' then 0 else 1 end,
     coalesce(f.severity, 9),
     f.created_at desc
   limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

create or replace function public.set_feedback_status(
  p_id     uuid,
  p_status app.feedback_status,
  p_note   text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  update public.feedback_reports
     set status = p_status,
         platform_note = coalesce(nullif(btrim(p_note), ''), platform_note),
         handled_by = auth.uid(),
         resolved_at = case
           when p_status in ('done', 'declined', 'duplicate') then now()
           else null end
   where id = p_id;
end;
$$;

revoke all on function public.report_feedback(
  text, app.feedback_kind, text, text, text, smallint, uuid) from public;
revoke all on function public.my_feedback(uuid) from public;
revoke all on function public.platform_feedback(app.feedback_status, integer)
  from public;
revoke all on function public.set_feedback_status(
  uuid, app.feedback_status, text) from public;

grant execute on function public.report_feedback(
  text, app.feedback_kind, text, text, text, smallint, uuid) to authenticated;
grant execute on function public.my_feedback(uuid) to authenticated;
grant execute on function public.platform_feedback(
  app.feedback_status, integer) to authenticated;
grant execute on function public.set_feedback_status(
  uuid, app.feedback_status, text) to authenticated;

-- ---------------------------------------------------------------------
-- The two attachment helpers, restated so a screenshot can be attached
-- ---------------------------------------------------------------------
create or replace function app.can_read_attachment(p_org_id uuid, p_entity_table text, p_entity_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_employee uuid;
begin
  -- A screenshot on a bug report, before anything else is asked.
  --
  -- Everything below this line is about a company's own records and
  -- asks `can_write` or `can_read_ledger` first; a bug report is not
  -- one of those. Whoever may read the report may see the picture on
  -- it, and nobody else. See 0460.
  if p_entity_table = 'feedback_reports' then
    return exists (
      select 1 from public.feedback_reports f
       where f.id = p_entity_id
         and (f.reported_by = auth.uid()
              or app.is_platform_admin()
              or (f.org_id is not null and app.can_admin(f.org_id))));
  end if;

  if p_org_id is null then return false; end if;

  if app.can_write(p_org_id) or app.can_read_ledger(p_org_id) then
    -- …except the personnel records, which the ledger audience has no
    -- business in. An accounts clerk does not get to read a passport.
    if p_entity_table in ('employees', 'employee_documents', 'payslips',
                          'corp_persons') then
      return app.can_manage_hr(p_org_id) or app.can_admin(p_org_id)
          or app.can_run_payroll(p_org_id);
    end if;
    return true;
  end if;

  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person it is about, and nobody else.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    when 'employees' then p_entity_id = v_employee
    when 'employee_documents' then exists (
      select 1 from public.employee_documents d
       where d.id = p_entity_id and d.employee_id = v_employee)
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id and c.employee_id = v_employee)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id and r.employee_id = v_employee)
    when 'payslips' then exists (
      select 1 from public.payslips p
       where p.id = p_entity_id and p.employee_id = v_employee)
    else false
  end;
end;
$function$

;

create or replace function app.can_attach_to(p_org_id uuid, p_entity_table text, p_entity_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_employee uuid;
begin
  if p_org_id is null or p_entity_id is null then return false; end if;

  -- 0323. The module. Reading is decided by
  -- `app.can_read_attachment`, which does not ask this and is
  -- deliberately left open: a company that stops paying keeps its
  -- documents, it just cannot add more.
  -- A picture on your own bug report, before the module is asked
  -- about. Reporting a fault in the product is not a feature a company
  -- buys, and the person most likely to have a screenshot is the
  -- employee who hit the fault -- who may hold no write permission at
  -- all. See 0460.
  if p_entity_table = 'feedback_reports' then
    return exists (
      select 1 from public.feedback_reports f
       where f.id = p_entity_id and f.reported_by = auth.uid());
  end if;

  if not app.has_module(p_org_id, 'attachments') then return false; end if;

  -- Everybody who could before.
  if app.can_write(p_org_id) then return true; end if;
  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person the record is about, on the records that are
  -- theirs to support.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    -- While it can still matter. Once a claim is in the ledger the
    -- paperwork behind it is the accountant's record, not a document
    -- the claimant can still add to.
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id
         and c.employee_id = v_employee
         and c.posted_at is null)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id
         and r.employee_id = v_employee)
    else false
  end;
end; $function$

;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_read text := pg_get_functiondef(
    to_regprocedure('app.can_read_attachment(uuid, text, uuid)'));
  v_att  text := pg_get_functiondef(
    to_regprocedure('app.can_attach_to(uuid, text, uuid)'));
begin
  if position('feedback_reports' in v_att) = 0 then
    raise exception
      '0460: a screenshot needs a module the reporter has not bought';
  end if;

  -- Before the module check, or an employee who hit the fault cannot
  -- show anybody what they saw.
  if position('feedback_reports' in v_att)
     > position('has_module(p_org_id, ''attachments'')' in v_att) then
    raise exception '0460: the module is asked about first anyway';
  end if;

  if position('feedback_reports' in v_read)
     > position('app.can_write(p_org_id) or app.can_read_ledger' in v_read)
  then
    raise exception
      '0460: a bug report''s picture is read by the ledger''s rules';
  end if;

  -- The two branches must not have cost the helpers their old ones.
  if position('employee_documents' in v_read) = 0
     or position('expense_claims' in v_att) = 0 then
    raise exception '0460: restating the helpers lost what they did before';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgname = 'guard_status'
                    and tgrelid = 'public.feedback_reports'::regclass) then
    raise exception '0460: anybody may mark their own report done';
  end if;
end
$do$;

comment on table public.feedback_reports is
  'Faults, feature requests and suggestions about this product, raised '
  'by anybody using it. Read by the reporter, their company''s '
  'administrators and platform staff -- not by every tenant. See 0460.';

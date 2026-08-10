-- =====================================================================
-- iAkauntan :: 0045 auditor access to payslips, on request and with
-- approval.
--
-- An auditor cannot audit payroll without seeing it, but standing access
-- to everyone's pay is not the answer either. A request names a scope
-- and a reason, a company admin decides, and the grant lapses on its own
-- so nobody has to remember to take it away.
-- =====================================================================

create type app.access_request_status as enum
  ('pending', 'approved', 'rejected', 'revoked');

create table public.payslip_access_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  requested_by uuid not null references auth.users (id) on delete cascade,
  -- Why the access is needed. Required: an audit trail with no reason on
  -- it is not much of an audit trail.
  reason text not null,

  -- Scope. Null means "not narrowed on this axis", so a request with all
  -- four null covers every payslip — which an admin can see and refuse.
  period_from date,
  period_to date,
  run_id uuid references public.payroll_runs (id) on delete cascade,
  employee_id uuid references public.employees (id) on delete cascade,

  status app.access_request_status not null default 'pending',
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users (id),
  decided_at timestamptz,
  decision_note text,
  -- Set on approval. Access stops here whether or not anyone revokes it.
  expires_at timestamptz,
  revoked_by uuid references auth.users (id),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index payslip_access_requests_lookup_idx
  on public.payslip_access_requests (org_id, requested_by, status);
create index payslip_access_requests_pending_idx
  on public.payslip_access_requests (org_id, status)
  where status = 'pending';

comment on table public.payslip_access_requests is
  'Time-boxed, admin-approved access for an auditor to read payslips they would otherwise never see.';

-- A payslip is a frozen document, so it should carry its own pay date
-- rather than making every access check join back to the period.
alter table public.payslips add column if not exists pay_date date;

create or replace function app.set_payslip_pay_date()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.pay_date is null then
    select pp.pay_date into new.pay_date
      from public.payroll_runs r
      join public.pay_periods pp on pp.id = r.period_id
     where r.id = new.run_id;
  end if;
  return new;
end;
$$;

create trigger set_pay_date before insert on public.payslips
  for each row execute function app.set_payslip_pay_date();

update public.payslips p
   set pay_date = pp.pay_date
  from public.payroll_runs r
  join public.pay_periods pp on pp.id = r.period_id
 where r.id = p.run_id and p.pay_date is null;

-- ---------------------------------------------------------------------
-- Does the caller hold a live grant covering this payslip?
-- ---------------------------------------------------------------------
create or replace function app.payslip_access_granted(
  p_org_id uuid,
  p_run_id uuid,
  p_employee_id uuid,
  p_pay_date date
)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.payslip_access_requests r
     where r.org_id = p_org_id
       and r.requested_by = auth.uid()
       and r.status = 'approved'
       and (r.expires_at is null or r.expires_at > now())
       and (r.run_id is null or r.run_id = p_run_id)
       and (r.employee_id is null or r.employee_id = p_employee_id)
       and (r.period_from is null or p_pay_date is null
            or p_pay_date >= r.period_from)
       and (r.period_to is null or p_pay_date is null
            or p_pay_date <= r.period_to)
  );
$$;

comment on function app.payslip_access_granted is
  'True when the caller holds an approved, unexpired, unrevoked grant whose scope covers this payslip.';

-- Whether the caller holds any live grant at all, used to decide whether
-- to show the payroll section rather than to filter rows.
create or replace function public.my_payslip_access(p_org_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.payslip_access_requests r
     where r.org_id = p_org_id
       and r.requested_by = auth.uid()
       and r.status = 'approved'
       and (r.expires_at is null or r.expires_at > now())
  );
$$;

-- ---------------------------------------------------------------------
-- Widen the read policies to honour a grant
-- ---------------------------------------------------------------------
drop policy if exists payslips_select on public.payslips;
create policy payslips_select on public.payslips
  for select to authenticated
  using (app.can_run_payroll(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.payslip_access_granted(org_id, run_id, employee_id, pay_date));

drop policy if exists payslip_lines_select on public.payslip_lines;
create policy payslip_lines_select on public.payslip_lines
  for select to authenticated
  using (exists (
    select 1 from public.payslips p
     where p.id = payslip_id
       and (app.can_run_payroll(p.org_id)
            or p.employee_id = app.my_employee_id(p.org_id)
            or app.payslip_access_granted(
                 p.org_id, p.run_id, p.employee_id, p.pay_date))));

-- A payslip without its run header is hard to make sense of, so a grant
-- opens the runs it covers too — read only, and never the ability to
-- calculate or post one.
drop policy if exists payroll_runs_select on public.payroll_runs;
create policy payroll_runs_select on public.payroll_runs
  for select to authenticated
  using (app.can_run_payroll(org_id)
         or exists (
           select 1 from public.payslip_access_requests r
            where r.org_id = payroll_runs.org_id
              and r.requested_by = auth.uid()
              and r.status = 'approved'
              and (r.expires_at is null or r.expires_at > now())
              and (r.run_id is null or r.run_id = payroll_runs.id)));

-- ---------------------------------------------------------------------
-- The requests themselves
-- ---------------------------------------------------------------------
alter table public.payslip_access_requests enable row level security;

-- Visible to the person who asked, to the admins who decide, and to
-- payroll — who ought to know who has been let into the pay data.
create policy payslip_access_requests_select on public.payslip_access_requests
  for select to authenticated
  using (requested_by = auth.uid()
         or app.can_admin(org_id)
         or app.can_run_payroll(org_id));

-- No write policies: every change goes through the functions in the next
-- migration, so the rules about who may ask and who may decide live in
-- one place.

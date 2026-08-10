-- =====================================================================
-- iAkauntan :: 0047 read-level tracking for granted payslip access
--
-- Postgres cannot fire a trigger on SELECT, so a log that sits beside an
-- open read path is a log you can walk around. Instead the grant stops
-- opening the table: a granted reader gets in only through the functions
-- in the next migration, and those write the log entry before they
-- return the rows. No other route in, no way to read without a trace.
-- =====================================================================

create table public.payslip_access_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  grant_id uuid references public.payslip_access_requests (id) on delete set null,
  actor_id uuid not null references auth.users (id) on delete cascade,

  -- 'list' is a page of payslips; 'view' is one payslip opened in full,
  -- which is the read that actually exposes somebody's pay.
  action text not null check (action in ('list', 'view')),
  payslip_id uuid references public.payslips (id) on delete set null,
  -- Denormalised so the log still reads correctly after the payslip is
  -- gone, and so nobody needs access to payslips to audit the auditor.
  employee_name text,
  period_code text,
  payslip_count integer,

  -- Whatever PostgREST was told about the caller. Both may be null when
  -- the call did not come through the API.
  ip_address text,
  user_agent text,

  viewed_at timestamptz not null default now()
);

create index payslip_access_log_org_idx
  on public.payslip_access_log (org_id, viewed_at desc);
create index payslip_access_log_actor_idx
  on public.payslip_access_log (actor_id, viewed_at desc);

comment on table public.payslip_access_log is
  'Every payslip read made under a granted access. Written by the read functions themselves, so it cannot be sidestepped.';

alter table public.payslip_access_log enable row level security;

-- Admins and payroll can see who looked at what. So can the auditor, at
-- their own entries — being watched is not the same as being watched
-- secretly.
create policy payslip_access_log_select on public.payslip_access_log
  for select to authenticated
  using (app.can_admin(org_id)
         or app.can_run_payroll(org_id)
         or actor_id = auth.uid());

-- No insert, update or delete policy at all: only the read functions
-- write here, and nobody edits it afterwards.

-- ---------------------------------------------------------------------
-- Close the direct read path
--
-- A grant no longer widens the table policies. Payroll and the employee
-- themselves keep their direct access; a granted auditor does not get
-- one, because an unlogged read is exactly what we are removing.
-- ---------------------------------------------------------------------
drop policy if exists payslips_select on public.payslips;
create policy payslips_select on public.payslips
  for select to authenticated
  using (app.can_run_payroll(org_id)
         or employee_id = app.my_employee_id(org_id));

drop policy if exists payslip_lines_select on public.payslip_lines;
create policy payslip_lines_select on public.payslip_lines
  for select to authenticated
  using (exists (
    select 1 from public.payslips p
     where p.id = payslip_id
       and (app.can_run_payroll(p.org_id)
            or p.employee_id = app.my_employee_id(p.org_id))));

-- Run headers stay readable under a grant. They are org-level totals,
-- and the same figures already sit in the payroll journal an auditor can
-- read in the general ledger; the per-person detail is what is tracked.

-- ---------------------------------------------------------------------
-- The grant that covers a payslip, if any
-- ---------------------------------------------------------------------
create or replace function app.covering_grant(
  p_org_id uuid,
  p_run_id uuid,
  p_employee_id uuid,
  p_pay_date date
)
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select r.id from public.payslip_access_requests r
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
   order by r.expires_at desc nulls last
   limit 1;
$$;

-- What PostgREST was told about the caller, when it was PostgREST.
create or replace function app.request_header(p_name text)
returns text language plpgsql stable
set search_path = pg_catalog, pg_temp as $$
begin
  return nullif(
    current_setting('request.headers', true)::json ->> p_name, '');
exception when others then
  return null;
end;
$$;

-- =====================================================================
-- iAkauntan :: 0046 requesting, deciding and revoking payslip access
-- =====================================================================

-- Ask for access. Only an auditor needs this route: everyone else either
-- already has payroll rights or has no business in the pay data.
create or replace function public.request_payslip_access(
  p_org_id uuid,
  p_reason text,
  p_period_from date default null,
  p_period_to date default null,
  p_run_id uuid default null,
  p_employee_id uuid default null
)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this company' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the access is needed' using errcode = '22023';
  end if;
  if app.can_run_payroll(p_org_id) then
    raise exception 'You already have access to payroll' using errcode = '22023';
  end if;
  if not app.has_org_role(p_org_id, array['auditor']::app.member_role[]) then
    raise exception
      'Only an auditor may request access to payslips' using errcode = '42501';
  end if;
  if p_period_from is not null and p_period_to is not null
     and p_period_to < p_period_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  -- One live request at a time keeps the admin's queue honest.
  if exists (
    select 1 from public.payslip_access_requests r
     where r.org_id = p_org_id
       and r.requested_by = auth.uid()
       and r.status = 'pending')
  then
    raise exception 'You already have a request awaiting a decision'
      using errcode = '23505';
  end if;

  insert into public.payslip_access_requests
    (org_id, requested_by, reason, period_from, period_to, run_id, employee_id)
  values (p_org_id, auth.uid(), btrim(p_reason), p_period_from, p_period_to,
          p_run_id, p_employee_id)
  returning id into v_id;

  return v_id;
end;
$$;

-- Decide one. Company admins only, and never your own request — an
-- auditor who could approve themselves would make the whole thing
-- decorative.
create or replace function public.decide_payslip_access(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null,
  p_days integer default 30
)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_req public.payslip_access_requests;
begin
  select * into v_req from public.payslip_access_requests
   where id = p_request_id;
  if v_req.id is null then
    raise exception 'Request not found' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_req.org_id) then
    raise exception 'Only a company admin may decide this request'
      using errcode = '42501';
  end if;
  if v_req.requested_by = auth.uid() then
    raise exception 'You cannot approve your own request for access'
      using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request is already %', v_req.status
      using errcode = '22023';
  end if;
  if p_approve and coalesce(p_days, 0) <= 0 then
    raise exception 'Access has to expire; give it a number of days'
      using errcode = '22023';
  end if;

  update public.payslip_access_requests set
    status = case when p_approve then 'approved'::app.access_request_status
                  else 'rejected'::app.access_request_status end,
    decided_by = auth.uid(),
    decided_at = now(),
    decision_note = p_note,
    expires_at = case when p_approve
                      then now() + make_interval(days => p_days) end
  where id = p_request_id;
end;
$$;

-- Take it back early.
create or replace function public.revoke_payslip_access(
  p_request_id uuid, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_req public.payslip_access_requests;
begin
  select * into v_req from public.payslip_access_requests
   where id = p_request_id;
  if v_req.id is null then
    raise exception 'Request not found' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_req.org_id) then
    raise exception 'Only a company admin may revoke access'
      using errcode = '42501';
  end if;
  if v_req.status <> 'approved' then
    raise exception 'Only approved access can be revoked; this is %',
      v_req.status using errcode = '22023';
  end if;

  update public.payslip_access_requests set
    status = 'revoked',
    revoked_by = auth.uid(),
    revoked_at = now(),
    decision_note = coalesce(p_note, decision_note)
  where id = p_request_id;
end;
$$;

-- Re-run the hardening sweep for the functions just created: a function
-- created after the last pass inherits PUBLIC execute, which hands it to
-- the anon role.
do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;

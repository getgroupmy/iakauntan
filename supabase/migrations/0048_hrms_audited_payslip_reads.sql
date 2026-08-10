-- =====================================================================
-- iAkauntan :: 0048 the only way a granted reader sees a payslip
--
-- Volatile on purpose: each function writes its log entry before it
-- returns anything.
-- =====================================================================

create or replace function public.audit_list_payslips(
  p_org_id uuid, p_run_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_rows jsonb;
  v_grant uuid;
  v_count integer;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this company' using errcode = '42501';
  end if;

  -- Payroll already reads the table directly and is not tracked here;
  -- this route exists for granted access.
  if app.can_run_payroll(p_org_id) then
    raise exception
      'Use the payroll screens; this route is for granted access'
      using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' order by p.employee_no), '[]'::jsonb),
         count(*)
    into v_rows, v_count
    from public.payslips p
   where p.org_id = p_org_id
     and (p_run_id is null or p.run_id = p_run_id)
     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)
         is not null;

  if v_count = 0 then
    return '[]'::jsonb;
  end if;

  select app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)
    into v_grant
    from public.payslips p
   where p.org_id = p_org_id
     and (p_run_id is null or p.run_id = p_run_id)
   limit 1;

  insert into public.payslip_access_log
    (org_id, grant_id, actor_id, action, payslip_count,
     ip_address, user_agent)
  values (p_org_id, v_grant, auth.uid(), 'list', v_count,
          app.request_header('x-forwarded-for'),
          app.request_header('user-agent'));

  return v_rows;
end;
$$;

comment on function public.audit_list_payslips is
  'Payslips a granted reader may see, logged as one list read.';

-- Open one payslip in full. This is the read that actually exposes what
-- a named person is paid, so it is logged individually.
create or replace function public.audit_view_payslip(p_payslip_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_slip public.payslips;
  v_grant uuid;
  v_result jsonb;
begin
  select * into v_slip from public.payslips where id = p_payslip_id;
  if v_slip.id is null then
    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_slip.org_id) then
    raise exception 'Not a member of this company' using errcode = '42501';
  end if;
  if app.can_run_payroll(v_slip.org_id) then
    raise exception
      'Use the payroll screens; this route is for granted access'
      using errcode = '22023';
  end if;

  v_grant := app.covering_grant(
    v_slip.org_id, v_slip.run_id, v_slip.employee_id, v_slip.pay_date);
  if v_grant is null then
    raise exception
      'Your access does not cover this payslip' using errcode = '42501';
  end if;

  select to_jsonb(v_slip) - 'org_id'
       || jsonb_build_object(
            'payslip_lines', coalesce(
              (select jsonb_agg(to_jsonb(l) - 'org_id' order by l.line_no)
                 from public.payslip_lines l
                where l.payslip_id = v_slip.id), '[]'::jsonb),
            'payroll_runs', (
              select jsonb_build_object('run_no', r.run_no,
                       'pay_periods', jsonb_build_object('code', pp.code))
                from public.payroll_runs r
                join public.pay_periods pp on pp.id = r.period_id
               where r.id = v_slip.run_id))
    into v_result;

  insert into public.payslip_access_log
    (org_id, grant_id, actor_id, action, payslip_id, employee_name,
     period_code, ip_address, user_agent)
  values (v_slip.org_id, v_grant, auth.uid(), 'view', v_slip.id,
          v_slip.employee_name,
          (select pp.code from public.payroll_runs r
             join public.pay_periods pp on pp.id = r.period_id
            where r.id = v_slip.run_id),
          app.request_header('x-forwarded-for'),
          app.request_header('user-agent'));

  return v_result;
end;
$$;

comment on function public.audit_view_payslip is
  'One payslip in full for a granted reader, logged against the grant that permitted it.';

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

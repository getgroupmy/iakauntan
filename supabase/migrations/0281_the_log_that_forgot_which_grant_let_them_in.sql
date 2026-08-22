-- =====================================================================
-- iAkauntan :: 0281 the log that forgot which grant let them in
--
-- 0047 closed the direct read path on payslips so that a granted
-- auditor can only get in through audit_list_payslips and
-- audit_view_payslip, and those write the log entry before returning
-- the rows: "no other route in, no way to read without a trace."
--
-- The trace is incomplete. audit_list_payslips selects the rows
-- correctly -- only the payslips a covering grant reaches -- and then
-- looks up the grant to log against with a second query that forgot
-- the filter:
--
--   select app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)
--     into v_grant
--     from public.payslips p
--    where p.org_id = p_org_id
--      and (p_run_id is null or p.run_id = p_run_id)
--    limit 1;
--
-- No `is not null`, and no order. It takes an arbitrary payslip from
-- the whole company rather than from the covered set, so whenever that
-- payslip falls outside the grant's scope, covering_grant returns null
-- and the read is logged with grant_id = null.
--
-- It is not hypothetical and it is not rare: an auditor granted access
-- to one employee, in a company with more than one, hits it whenever
-- the uncovered payslip is the one the scan reaches first -- which,
-- with the rows in insertion order and calculate_payroll_run inserting
-- by employee_no, is most of the time.
--
-- The read itself is still recorded, with the actor, the count and the
-- time, so nothing is invisible. What is lost is attribution: an admin
-- reviewing who has been in the pay data cannot tell which approval
-- authorised the read, and an auditor holding more than one grant
-- cannot be held to the narrower of them.
--
-- The fix is to look the grant up in the same set the rows came from,
-- with the same filter and the same order. Where several grants cover
-- different rows of one page, the entry names the grant covering the
-- first row listed; the per-payslip 'view' entries each carry the exact
-- grant that permitted them, which is the read that matters.
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

  -- The same set the rows came from, in the same order, so the entry
  -- names a grant that actually covered something.
  select app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)
    into v_grant
    from public.payslips p
   where p.org_id = p_org_id
     and (p_run_id is null or p.run_id = p_run_id)
     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)
         is not null
   order by p.employee_no
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
  'Payslips a granted reader may see, logged as one list read against the grant that permitted it.';

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.audit_list_payslips(uuid, uuid)
  to authenticated, service_role;

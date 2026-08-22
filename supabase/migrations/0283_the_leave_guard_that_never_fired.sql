-- =====================================================================
-- iAkauntan :: 0283 the leave guard that never fired
--
-- submit_leave_request lets HR file leave on somebody else's behalf and
-- means to stop anybody else doing it:
--
--   v_emp := coalesce(p_employee_id, app.my_employee_id(p_org_id));
--   ...
--   if v_emp <> app.my_employee_id(p_org_id)
--      and not app.can_manage_hr(p_org_id) then
--     raise exception 'Only HR may file leave for another employee'
--
-- When the caller has no employee record, app.my_employee_id returns
-- null. `v_emp <> null` is null, `null and true` is null, and
-- `if null then raise` does not fire. The guard is skipped for exactly
-- the callers it was written to stop.
--
-- This is the same shape as the hole 0044 closed in the payroll
-- permission check, and statutory.sql still carries the note about it:
-- "app.org_role gives null for someone outside the organization,
-- `null = any (...)` is null, and `if not null then raise` never
-- fires." Three-valued logic does not raise, and a guard that has to
-- raise cannot be written with a comparison that can go null.
--
-- Who is affected: every member whose role is not owner, admin or
-- hr_manager and who has no employee record of their own -- an
-- accountant, an accounts clerk, an auditor, a sales or purchasing
-- member, a viewer. On the harness a member with the `sales` role and
-- no employee record filed five days of unpaid leave against another
-- employee, and the request came back `submitted` against that
-- employee's id.
--
-- The filer cannot then approve it: decide_leave_request wants
-- app.can_manage_hr or app.manages_employee, and somebody with no
-- employee record is nobody's manager. What they can do is put a
-- request in front of HR to approve, and unpaid leave that is approved
-- is not an HR formality -- calculate_payroll_run turns it into a
-- negative earning line that comes off gross pay, off the EPF wage,
-- off the SOCSO and EIS wages and off taxable income. The request is
-- the first move in docking somebody's salary.
--
-- `is distinct from` is the null-safe comparison: it is true when one
-- side is null and the other is not, which is precisely the case that
-- was falling through. app.my_employee_id is also read once into a
-- variable rather than called twice, so the guard and the value it
-- guards cannot disagree.
-- =====================================================================

create or replace function public.submit_leave_request(
  p_org_id uuid,
  p_leave_type_id uuid,
  p_start_date date,
  p_end_date date,
  p_total_days numeric,
  p_reason text default null,
  p_is_half_day boolean default false,
  p_half_day_period text default null,
  p_employee_id uuid default null
)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid;
  v_emp uuid;
  v_type public.leave_types;
  v_year integer := extract(year from p_start_date)::integer;
  v_available numeric;
  v_id uuid;
begin
  v_me := app.my_employee_id(p_org_id);
  v_emp := coalesce(p_employee_id, v_me);
  if v_emp is null then
    raise exception 'No employee record is linked to this login'
      using errcode = 'P0002';
  end if;
  -- `is distinct from`, not `<>`: v_me is null for a member who is not
  -- on the payroll, and `<>` against null is null, which never raises.
  if v_emp is distinct from v_me
     and not app.can_manage_hr(p_org_id) then
    raise exception 'Only HR may file leave for another employee'
      using errcode = '42501';
  end if;
  if p_end_date < p_start_date then
    raise exception 'The last day cannot fall before the first'
      using errcode = '22023';
  end if;

  select * into v_type from public.leave_types where id = p_leave_type_id;
  if v_type.id is null then
    raise exception 'Unknown leave type' using errcode = 'P0002';
  end if;

  -- Paid leave has to be within what the employee actually has left.
  -- Unpaid leave has no balance to check.
  --
  -- No balance row at all leaves v_available null and the check is
  -- skipped, which is deliberate: it means nobody has set an
  -- entitlement for this leave type and this year yet, and refusing
  -- every request until somebody does would stop a company using the
  -- module on the day it starts.
  if v_type.is_paid then
    select coalesce(entitled_days, 0) + coalesce(carried_forward, 0)
         + coalesce(adjustment_days, 0) - coalesce(taken_days, 0)
         - coalesce(pending_days, 0)
      into v_available
      from public.leave_balances
     where employee_id = v_emp and leave_type_id = p_leave_type_id
       and leave_year = v_year;

    if v_available is not null and p_total_days > v_available then
      raise exception
        'Only % day(s) of % remain; this request is for %',
        v_available, v_type.name, p_total_days using errcode = '23514';
    end if;
  end if;

  insert into public.leave_requests (
    org_id, request_no, employee_id, leave_type_id, start_date, end_date,
    is_half_day, half_day_period, total_days, reason, status, submitted_at,
    created_by)
  values (
    p_org_id, public.next_document_number(p_org_id, 'leave_request'), v_emp,
    p_leave_type_id, p_start_date, p_end_date, p_is_half_day,
    p_half_day_period, p_total_days, p_reason, 'submitted', now(), auth.uid())
  returning id into v_id;

  -- Held against the balance while it awaits a decision, so two requests
  -- cannot each pass a check the pair of them would fail.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, pending_days)
  values (p_org_id, v_emp, p_leave_type_id, v_year, p_total_days)
  on conflict (employee_id, leave_type_id, leave_year) do update
    set pending_days = public.leave_balances.pending_days + p_total_days;

  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid)
  to authenticated;

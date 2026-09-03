-- =====================================================================
-- 0507 :: an employee belongs to one company, and leave says so
--
-- The audit that produced 0505 and 0506 asked one question: is an id
-- passed in by the caller checked against the caller's organization
-- everywhere it is used? Asking it of the HR side found
-- `submit_leave_request`.
--
-- `leave_type_id` is held to the organization by a composite foreign
-- key, `leave_requests_leave_type_same_org`. `employee_id` had only a
-- plain reference to `employees(id)`, so HR in one company could file
-- leave naming ANOTHER company's employee: verified against the built
-- database, the request was written with this company's org_id and
-- their employee, and a `leave_balances` row was created for them here
-- too.
--
-- Two changes, because either alone would be half a fix. The function
-- refuses it with a message somebody can read; the composite keys mean
-- no future writer can do it either, which is how `leave_type_id` was
-- already protected.
--
-- `employees` gets the unique key the composite references need. It is
-- the same shape 0502 added to `pay_periods`.
--
-- Checked before writing this: the hosted project has no row that would
-- violate either constraint.
--
-- Not fixed here, and worth naming: twenty-six tables reference
-- `employees` with a plain key while carrying their own `org_id`. This
-- migration adds the unique key those all need, and closes the two that
-- `submit_leave_request` writes. The rest are a separate piece of work
-- and each one needs `scripts/check_embeds.py` run against it, because
-- every added foreign key is an API change.
-- =====================================================================

alter table public.employees
  add constraint employees_org_id_id_key unique (org_id, id);

alter table public.leave_requests
  add constraint leave_requests_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

alter table public.leave_balances
  add constraint leave_balances_employee_same_org
  foreign key (org_id, employee_id)
  references public.employees (org_id, id) on delete cascade;

CREATE OR REPLACE FUNCTION public.submit_leave_request(p_org_id uuid, p_leave_type_id uuid, p_start_date date, p_end_date date, p_total_days numeric, p_reason text DEFAULT NULL::text, p_is_half_day boolean DEFAULT false, p_half_day_period text DEFAULT NULL::text, p_employee_id uuid DEFAULT NULL::uuid, p_contact_while_away text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  -- The employee has to be THIS company's. `leave_type_id` is already
  -- held to the organization by a composite foreign key; `employee_id`
  -- was not, so HR in one company could file leave naming another
  -- company's employee and write both the request and a balance row
  -- against them.
  if not exists (select 1 from public.employees e
                  where e.id = v_emp and e.org_id = p_org_id) then
    raise exception 'That employee belongs to another company.'
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
    is_half_day, half_day_period, total_days, reason, contact_while_away,
    status, submitted_at, created_by)
  values (
    p_org_id, public.next_document_number(p_org_id, 'leave_request'), v_emp,
    p_leave_type_id, p_start_date, p_end_date, p_is_half_day,
    p_half_day_period, p_total_days, p_reason,
    -- A form that posts every field posts the empty ones too, and a
    -- contact of '' reads on a report as a contact that was given.
    nullif(btrim(p_contact_while_away), ''),
    'submitted', now(), auth.uid())
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
$function$;

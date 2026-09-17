-- =====================================================================
-- iAkauntan :: 0395 the number to call while they are away
--
-- `leave_requests.contact_while_away` has been on the table since
-- `0027`. Nothing has ever written it and nothing has ever read it.
--
-- That is a smaller thing than the last few migrations found, and it is
-- worth being honest about which of these gaps deserve SQL. Two other
-- columns from the same sweep — `employees.emergency_contact_*` and
-- `positions.job_description` — are written straight into their tables
-- by the client, so the whole of their fix is a form field, and they
-- got one. This one is different for a reason that is not cosmetic:
-- the write path is a SECURITY DEFINER function, so the column is
-- unreachable from the client no matter what the form offers. There is
-- no form field that fixes it.
--
-- And once you go looking, the column is not merely unwritten. It is
-- the one field on a leave request that cannot be right at the moment
-- it is submitted and must be changeable afterwards, and it is the one
-- field the person it belongs to is locked out of.
--
-- ---------------------------------------------------------------------
-- Three separate faults
--
-- **It cannot be given.** `submit_leave_request` takes nine parameters
-- and none of them is the contact. The insert names ten columns and
-- this is not one of them. Every leave request in every organization
-- has `contact_while_away` null, and will have whatever anyone types.
--
-- **It cannot be corrected.** `0038`'s update policy:
--
--     using (app.can_manage_hr(org_id)
--            or app.manages_employee(employee_id)
--            or (employee_id = app.my_employee_id(org_id)
--                and status = 'draft'))
--
-- A submitted request is out of the employee's hands, and for the
-- decision fields that is exactly right — an employee who could edit
-- their own dates after approval could take three weeks off against an
-- approval for three days. But the contact is not a term of the leave.
-- It is where the person is, and where the person is changes: the
-- number given a fortnight before departure is a hotel they have since
-- left. The field that most needs to stay current for the whole of the
-- absence is frozen at the moment the absence is agreed, and frozen
-- specifically against the only person who knows the new number.
--
-- **It cannot be read.** No function returns it and no screen selects
-- it. A column that is written and never read is a column that will
-- quietly stop being written, and the first person to notice will be
-- whoever needed it.
--
-- So: give it, correct it, read it. A column needs all three or it is
-- not reachable, and this one had none.
--
-- ---------------------------------------------------------------------
-- Dropped rather than overloaded
--
-- `submit_leave_request` gains a parameter, so the old nine-argument
-- function goes. `0351` states the reason and it holds here exactly:
-- a default does not replace a function, it overloads it. With both in
-- place PostgREST resolving a call that omits the new argument would
-- land on the old body and silently discard nothing — but a call that
-- supplies only the six required arguments matches both signatures and
-- gets 42725, ambiguous function, at run time and never in a test.
-- One function, so there is one answer.
--
-- ---------------------------------------------------------------------
-- `is distinct from`, again
--
-- `0283` exists because `v_emp <> app.my_employee_id(p_org_id)` is null
-- for a caller with no employee record, and `if null then raise` does
-- not raise, so the guard was skipped for exactly the callers it was
-- written to stop. `update_leave_contact` decides between "this is my
-- own leave" and "I am HR" on the same comparison against the same
-- nullable function, so it is written the same null-safe way, and the
-- employee id is read once into a variable rather than called twice.
-- The mutation run turns `is distinct from` back into `<>` and the
-- refusal test for a member with no employee record has to fail.
--
-- ---------------------------------------------------------------------
-- Who may read it
--
-- A contact-while-away is a personal number and a private address, not
-- a staff directory entry. `report_who_is_away` returns the same set
-- `0038`'s select policy already allows — HR the organization, anybody
-- else their own reporting line and their own leave — so the report
-- cannot show anyone a row they could not already select. Widening it to every colleague would be a
-- new decision about personal data and is not one this migration is
-- entitled to make on a company's behalf.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Give it
--
-- The old nine-argument version, dropped rather than left beside this
-- one, for the reason `0351` sets out.
drop function if exists public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid);

create or replace function public.submit_leave_request(
  p_org_id uuid,
  p_leave_type_id uuid,
  p_start_date date,
  p_end_date date,
  p_total_days numeric,
  p_reason text default null,
  p_is_half_day boolean default false,
  p_half_day_period text default null,
  p_employee_id uuid default null,
  p_contact_while_away text default null
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
$$;

revoke all on function public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid, text)
  from public, anon;
grant execute on function public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Correct it
--
-- The narrow hole in `0038`'s update policy: this one column, on a
-- request that is still live, changed by the person the leave belongs
-- to or by HR. Nothing else about the request is reachable from here,
-- which is why it is a function and not a widened policy — a policy
-- permissive enough to let the employee change the contact would let
-- them change the dates.
create or replace function public.update_leave_contact(
  p_request_id uuid,
  p_contact    text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_req public.leave_requests;
  v_me  uuid;
begin
  select * into v_req from public.leave_requests where id = p_request_id;
  if v_req.id is null then
    raise exception 'No such leave request.' using errcode = 'P0002';
  end if;

  -- Read once, so the guard and the value it guards cannot disagree,
  -- and compared null-safely, so a caller with no employee record is
  -- refused rather than waved through. `0283` is the whole argument.
  v_me := app.my_employee_id(v_req.org_id);
  if v_req.employee_id is distinct from v_me
     and not app.can_manage_hr(v_req.org_id) then
    raise exception
      'Only the employee on leave or HR may change where to reach them'
      using errcode = '42501';
  end if;

  -- A cancelled or rejected request is not an absence, and a request
  -- whose last day has passed is not one either. Neither has anybody
  -- to reach.
  if v_req.status not in ('draft', 'submitted', 'approved') then
    raise exception
      'Leave % was %; there is nobody away to reach.',
      v_req.request_no, v_req.status using errcode = '23514';
  end if;
  if v_req.end_date < (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception
      'Leave % ended on %. Changing the contact now records where '
      'somebody was, not where they are.',
      v_req.request_no, to_char(v_req.end_date, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  update public.leave_requests
     set contact_while_away = nullif(btrim(p_contact), '')
   where id = p_request_id;
end $$;

revoke all on function public.update_leave_contact(uuid, text)
  from public, anon;
grant execute on function public.update_leave_contact(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Read it
--
-- Everyone whose approved leave touches the window, and how to reach
-- them. The window is inclusive at both ends and the overlap is the
-- ordinary one — leave that starts before the window and ends inside it
-- is somebody who is away, and so is leave that spans the window
-- entirely without either date falling in it.
create or replace function public.report_who_is_away(
  p_org_id uuid,
  p_from   date default null,
  p_to     date default null)
returns table (
  request_id         uuid,
  request_no         text,
  employee_id        uuid,
  employee_no        text,
  employee_name      text,
  leave_type         text,
  start_date         date,
  end_date           date,
  total_days         numeric,
  status             text,
  contact_while_away text,
  has_contact        boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_from date := coalesce(p_from,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_to   date;
  v_hr   boolean;
  v_me   uuid;
begin
  v_to := coalesce(p_to, v_from);
  if v_to < v_from then
    raise exception 'The window ends before it begins.'
      using errcode = '22023';
  end if;
  -- HR reads the organization; anybody else reads their own reporting
  -- line and their own leave, which is exactly the set `0038`'s select
  -- policy on the table already allows. A member of no org at all gets
  -- neither, and is told so rather than handed an empty result — an
  -- empty report and a refused one mean different things to whoever is
  -- looking.
  v_hr := app.can_manage_hr(p_org_id);
  v_me := app.my_employee_id(p_org_id);
  if not v_hr and v_me is null then
    raise exception
      'Only HR or a manager may read who is away and how to reach them'
      using errcode = '42501';
  end if;

  return query
    select r.id, r.request_no, e.id, e.employee_no, e.full_name,
           t.name, r.start_date, r.end_date, r.total_days,
           r.status::text,
           r.contact_while_away,
           r.contact_while_away is not null
      from public.leave_requests r
      join public.employees e on e.id = r.employee_id
      join public.leave_types t on t.id = r.leave_type_id
     where r.org_id = p_org_id
       and r.status = 'approved'
       and r.start_date <= v_to
       and r.end_date >= v_from
       and (v_hr
            or r.employee_id = v_me
            or app.manages_employee(r.employee_id))
     order by r.start_date, e.full_name;
end $$;

revoke all on function public.report_who_is_away(uuid, date, date)
  from public, anon;
grant execute on function public.report_who_is_away(uuid, date, date)
  to authenticated;

comment on function public.report_who_is_away(uuid, date, date) is
  'Approved leave overlapping the window, with the contact `0027` has '
  'had a column for since the beginning and nothing wrote until `0395`. '
  'HR reads the organization and anybody else reads their own reporting '
  'line and their own leave — the same set `0038`''s select policy '
  'already allows, because a contact-while-away is a personal number '
  'and not a directory entry.';

comment on function public.update_leave_contact(uuid, text) is
  'The one field on a live leave request the employee may still change '
  'after submitting it. Where somebody is changes; the dates they '
  'agreed do not, and `0038`''s update policy is right to freeze those.';

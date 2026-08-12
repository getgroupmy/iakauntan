-- Clocking in has never worked.
--
--   column "status" is of type attendance_status but expression is of
--   type text (42804)
--
-- `insert ... values ('present')` is fine, because a bare literal stays
-- `unknown` and takes the column's type. Wrap the same literals in a
-- CASE and PostgreSQL has to resolve the expression before it ever looks
-- at the target column: with every branch unknown, it resolves to text,
-- and there is no implicit cast from text to an enum. The result is a
-- function that compiles, deploys, passes every check that does not
-- actually call it, and then fails on the first punch of the day.
--
-- clock_out casts each branch explicitly. clock_in did not. Recreated
-- here in clock_out's style so the two read the same, since the next
-- person to change one will look at the other.

create or replace function public.clock_in(
  p_org_id uuid,
  p_method app.clock_method default 'web',
  p_lat numeric default null,
  p_lng numeric default null,
  p_address text default null,
  p_device text default null,
  p_terminal text default null,
  p_employee_id uuid default null
)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_emp uuid;
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_shift public.work_shifts;
  v_late integer := 0;
  v_id uuid;
begin
  -- Punching for somebody else is an HR action, not a self-service one.
  if p_employee_id is not null and p_employee_id <> app.my_employee_id(p_org_id) then
    if not app.can_manage_hr(p_org_id) then
      raise exception 'Only HR may clock in on behalf of another employee'
        using errcode = '42501';
    end if;
    v_emp := p_employee_id;
  else
    v_emp := app.my_employee_id(p_org_id);
  end if;

  if v_emp is null then
    raise exception 'No employee record is linked to this login'
      using errcode = 'P0002';
  end if;

  v_shift := app.shift_for(v_emp, v_date);

  if v_shift.id is not null then
    v_late := greatest(0, (extract(epoch from (
        (now() at time zone 'Asia/Kuala_Lumpur')::time - v_shift.start_time
      )) / 60)::integer - coalesce(v_shift.grace_minutes, 0));
  end if;

  insert into public.attendance_records as a (
    org_id, employee_id, work_date, shift_id, clock_in, clock_in_method,
    clock_in_lat, clock_in_lng, clock_in_address, clock_in_device,
    clock_in_terminal, status, late_minutes)
  values (
    p_org_id, v_emp, v_date, v_shift.id, now(), p_method,
    p_lat, p_lng, p_address, p_device, p_terminal,
    case when v_late > 0 then 'late'::app.attendance_status
         else 'present'::app.attendance_status end,
    v_late)
  -- A second punch on the same day does not overwrite the first: the
  -- earliest clock-in is the one that counts.
  on conflict (employee_id, work_date) do update
    set clock_in = coalesce(a.clock_in, excluded.clock_in)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.clock_in(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  from public, anon;
grant execute on function public.clock_in(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  to authenticated;

-- =====================================================================
-- iAkauntan :: 0789 a company clocks its own people
--
-- `clock_in` and `clock_out` let HR punch for somebody else, by naming
-- them: `p_employee_id`. Each asked whether the caller may manage HR in
-- `p_org_id`, and neither asked whether the employee named works
-- there. `clock_out` then finds the day by employee alone. Measured on
-- 9 October 2026, locally: HR of one company, with no part in a second,
-- named the second company's employee -- clocked in that morning -- and
-- `clock_out` closed their day, wrote its own location onto it, and
-- handed back the minutes they had worked. `clock_in` was refused, but
-- only by accident, which is the second thing:
--
-- `clock_in` still compares with `<>`. `0285` found that slip in
-- `clock_out`: `app.my_employee_id` is null for an HR manager who is not
-- on the payroll -- an owner running the company, an outsourced HR
-- administrator -- and `p_employee_id <> null` is null, so the HR branch
-- never runs and the caller is told their own record is missing. It was
-- fixed in `clock_out` and never carried across.
--
-- Answered "fix both". Each now refuses an employee who is not in
-- `p_org_id`, "No such employee in this company.", and `clock_in` reads
-- `app.my_employee_id` once and compares with `is distinct from`, as
-- `clock_out` does. Punching for oneself is unchanged. The app never
-- names an employee; this was the API's road.
--
-- Restated from `0075` (`clock_in`; production runs its text with the
-- two comments stripped -- identical once they are, hash 77c26432...)
-- and `0363` (`clock_out`; identical, c6e1aa59...). Production held no
-- attendance record.
-- =====================================================================

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
  v_me uuid;
  v_emp uuid;
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_shift public.work_shifts;
  v_late integer := 0;
  v_id uuid;
begin
  v_me := app.my_employee_id(p_org_id);

  -- Punching for somebody else is an HR action, not a self-service one.
  -- `is distinct from`, not `<>`: v_me is null for an HR manager who is
  -- not on the payroll, and `<>` against null neither raises nor
  -- branches. `0285` fixed `clock_out`; `0789` this.
  if p_employee_id is not null and p_employee_id is distinct from v_me then
    if not app.can_manage_hr(p_org_id) then
      raise exception 'Only HR may clock in on behalf of another employee'
        using errcode = '42501';
    end if;
    -- `0789`. HR of THIS company, for an employee of this company.
    if not exists (select 1 from public.employees e
                    where e.id = p_employee_id and e.org_id = p_org_id) then
      raise exception 'No such employee in this company.'
        using errcode = 'P0002';
    end if;
    v_emp := p_employee_id;
  else
    v_emp := v_me;
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

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
revoke all on function public.clock_in(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  from public, anon;
grant execute on function public.clock_in(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  to authenticated;

comment on function public.clock_in(uuid, app.clock_method, numeric, numeric, text, text, text, uuid) is
  'Starts somebody''s working day and returns the attendance record. '
  'THE EARLIEST PUNCH WINS: a second clock-in on the same day does not '
  'overwrite the first, because tapping again at the door is not a '
  'correction and a record that took the later time would turn an '
  'on-time arrival into a late one. Lateness is worked out here, once, '
  'against the shift rostered for the day and after its grace period. '
  'No shift rostered means no lateness rather than lateness from '
  'midnight. Punching for somebody else needs `can_manage_hr`, whether '
  'or not the caller is on the payroll, and the employee must be this '
  'company''s (0789). The day is Kuala Lumpur''s, not the server''s.';

create or replace function public.clock_out(
  p_org_id     uuid,
  p_method     app.clock_method default 'web',
  p_lat        numeric default null,
  p_lng        numeric default null,
  p_address    text default null,
  p_device     text default null,
  p_terminal   text default null,
  p_employee_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_me        uuid;
  v_emp       uuid;
  v_date      date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_rec       public.attendance_records;
  v_scheduled integer;
begin
  v_me := app.my_employee_id(p_org_id);

  -- `is distinct from`, not `<>`: v_me is null for anybody not on the
  -- payroll, and `<>` against null is null, which neither raises nor
  -- branches. 0285.
  if p_employee_id is not null and p_employee_id is distinct from v_me then
    if not app.can_manage_hr(p_org_id) then
      raise exception 'Only HR may clock out on behalf of another employee'
        using errcode = '42501';
    end if;
    -- `0789`. HR of THIS company, for an employee of this company: the
    -- day below is found by employee alone, so another company's
    -- employee's day was closed, and what it came to handed back.
    if not exists (select 1 from public.employees e
                    where e.id = p_employee_id and e.org_id = p_org_id) then
      raise exception 'No such employee in this company.'
        using errcode = 'P0002';
    end if;
    v_emp := p_employee_id;
  else
    v_emp := v_me;
  end if;

  if v_emp is null then
    raise exception 'No employee record is linked to this login'
      using errcode = 'P0002';
  end if;

  select * into v_rec from public.attendance_records
   where employee_id = v_emp and work_date = v_date;

  if v_rec.id is null or v_rec.clock_in is null then
    raise exception 'There is no clock-in today to close' using errcode = '22023';
  end if;

  update public.attendance_records set
    clock_out = now(),
    clock_out_method = p_method,
    clock_out_lat = p_lat,
    clock_out_lng = p_lng,
    clock_out_address = p_address,
    clock_out_device = p_device,
    clock_out_terminal = p_terminal
  where id = v_rec.id;

  -- Not the morning. Clocking out does not make somebody late.
  v_scheduled := app.recompute_attendance(v_rec.id);

  select * into v_rec from public.attendance_records where id = v_rec.id;
  return jsonb_build_object(
    'worked_minutes', v_rec.worked_minutes,
    'scheduled_minutes', v_scheduled,
    'overtime_minutes', v_rec.ot_normal_minutes
                      + v_rec.ot_restday_minutes
                      + v_rec.ot_holiday_minutes,
    'late_minutes', v_rec.late_minutes);
end $$;

revoke all on function public.clock_out(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  from public, anon;
grant execute on function public.clock_out(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  to authenticated;

comment on function public.clock_out(uuid, app.clock_method, numeric, numeric, text, text, text, uuid) is
  'Closes the day and returns what it came to — worked, scheduled, '
  'overtime split into normal, rest day and holiday, and the lateness '
  'from the morning. RECOMPUTES THE DAY BUT NOT THE LATENESS: clocking '
  'out does not make somebody late, and recomputing everything would be '
  'the easy way to let it. Refuses when there is no clock-in today to '
  'close, rather than inventing one. Clocking out for somebody else '
  'needs `can_manage_hr`, and the employee must be this company''s '
  '(0789). Repeated calls move the clock-out later, unlike `clock_in` — '
  'the last time somebody left is the one that counts.';

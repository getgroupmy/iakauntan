-- =====================================================================
-- iAkauntan :: 0285 the HR manager who is not an employee
--
-- clock_out means to let HR close somebody else's day:
--
--   if p_employee_id is not null
--      and p_employee_id <> app.my_employee_id(p_org_id) then
--     if not app.can_manage_hr(p_org_id) then
--       raise exception 'Only HR may clock out on behalf of another employee'
--     end if;
--     v_emp := p_employee_id;
--   else
--     v_emp := app.my_employee_id(p_org_id);
--   end if;
--
-- app.my_employee_id is null for anybody not on the payroll, and
-- `p_employee_id <> null` is null, so the whole condition is null and
-- control goes to the else branch -- which sets v_emp from that same
-- null and stops two lines later on
--
--   'No employee record is linked to this login'
--
-- So an HR manager who is not themselves an employee cannot close
-- anybody's day, and the error tells them their own record is missing
-- rather than that the person they named was ignored. An owner running
-- their own company, or an outsourced HR administrator, is exactly the
-- person this feature is for and exactly the person it refuses.
--
-- This is 0283's bug in the same three-valued logic, failing the other
-- way. submit_leave_request let a stranger through because a null
-- condition does not raise; clock_out locks HR out because a null
-- condition does not branch either. Both come from comparing against
-- something that can be null with an operator that goes null with it,
-- and both are fixed by `is distinct from`, which is true when one side
-- is null and the other is not.
--
-- The fix also gives a non-HR caller the honest error. Before, somebody
-- without HR rights naming another employee fell into the else branch
-- and was told their own record was missing; now they are refused with
-- 42501 and the sentence the function already contains.
--
-- app.my_employee_id is read once into a variable rather than called
-- twice, for the same reason 0283 did it: the guard and the value it
-- guards cannot then disagree.
-- =====================================================================

create or replace function public.clock_out(
  p_org_id uuid,
  p_method app.clock_method default 'web',
  p_lat numeric default null,
  p_lng numeric default null,
  p_address text default null,
  p_device text default null,
  p_terminal text default null,
  p_employee_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid;
  v_emp uuid;
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_rec public.attendance_records;
  v_shift public.work_shifts;
  v_worked integer;
  v_scheduled integer;
  v_ot integer := 0;
  v_is_holiday boolean;
  v_is_restday boolean := false;
begin
  v_me := app.my_employee_id(p_org_id);

  -- `is distinct from`, not `<>`: v_me is null for anybody not on the
  -- payroll, and `<>` against null is null, which neither raises nor
  -- branches.
  if p_employee_id is not null and p_employee_id is distinct from v_me then
    if not app.can_manage_hr(p_org_id) then
      raise exception 'Only HR may clock out on behalf of another employee'
        using errcode = '42501';
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

  v_shift := app.shift_for(v_emp, v_date);

  v_worked := greatest(0,
    (extract(epoch from (now() - v_rec.clock_in)) / 60)::integer
    - coalesce(v_shift.break_minutes, 0));

  v_scheduled := case
    when v_shift.id is null then 480
    else greatest(1, (extract(epoch from (
           v_shift.end_time - v_shift.start_time
           + case when v_shift.crosses_midnight then interval '24 hours'
                  else interval '0' end)) / 60)::integer
         - coalesce(v_shift.break_minutes, 0))
  end;

  select exists (
    select 1 from public.public_holidays h
     where h.org_id = p_org_id and h.holiday_date = v_date and not h.is_working
  ) into v_is_holiday;

  if v_shift.id is not null then
    v_is_restday := not (extract(dow from v_date)::integer = any (v_shift.work_days));
  end if;

  -- Anything beyond the scheduled hours is overtime, at whichever
  -- Employment Act multiplier the day attracts.
  v_ot := greatest(0, v_worked - v_scheduled);

  update public.attendance_records set
    clock_out = now(),
    clock_out_method = p_method,
    clock_out_lat = p_lat,
    clock_out_lng = p_lng,
    clock_out_address = p_address,
    clock_out_device = p_device,
    clock_out_terminal = p_terminal,
    worked_minutes = v_worked,
    early_leave_minutes = greatest(0, v_scheduled - v_worked),
    ot_holiday_minutes = case when v_is_holiday then v_ot else 0 end,
    ot_restday_minutes = case when v_is_restday and not v_is_holiday then v_ot else 0 end,
    ot_normal_minutes  = case when not v_is_holiday and not v_is_restday then v_ot else 0 end,
    status = case
      when v_is_holiday then 'public_holiday'::app.attendance_status
      when v_is_restday then 'rest_day'::app.attendance_status
      when v_rec.late_minutes > 0 then 'late'::app.attendance_status
      else 'present'::app.attendance_status end
  where id = v_rec.id;

  return jsonb_build_object(
    'worked_minutes', v_worked,
    'scheduled_minutes', v_scheduled,
    'overtime_minutes', v_ot,
    'late_minutes', v_rec.late_minutes);
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.clock_out(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  to authenticated;

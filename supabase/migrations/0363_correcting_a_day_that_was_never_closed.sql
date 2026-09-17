-- =====================================================================
-- iAkauntan :: 0363 correcting a day that was never closed
--
-- `0360` made `incomplete` reachable — a clock-in with no clock-out
-- stops reading as an ordinary day — and in doing so it created a state
-- with no way out of it. `clock_out` only ever touches **today's**
-- record: it reads `work_date = (now() at time zone
-- 'Asia/Kuala_Lumpur')::date` and refuses anything else with "There is
-- no clock-in today to close". So last Tuesday's forgotten punch-out
-- was marked, correctly, and then nobody could do anything about it.
--
-- `0027` anticipated this and got as far as the columns:
-- `attendance_records.is_adjusted`, `adjusted_by` and
-- `adjustment_reason` have existed since the table did and nothing has
-- ever written one. They are the right three: the question an auditor
-- or an employee asks about a corrected timesheet is not what it now
-- says, it is who changed it and why.
--
-- ---------------------------------------------------------------------
-- One copy of the arithmetic
--
-- Working minutes, scheduled minutes, overtime at whichever Employment
-- Act multiplier the day attracts, and the status that comes out of it
-- were computed inside `clock_out` and nowhere else. A correction has
-- to produce exactly the same numbers a punch would have, so the
-- arithmetic moves into `app.recompute_attendance` and both callers use
-- it. Two copies of an overtime calculation is two answers to what
-- somebody is owed.
--
-- The one difference: `clock_out` measured the day against `now()`,
-- because it is closing the day as it happens. Recomputation measures
-- against the times on the row, which is the same thing for a punch and
-- the only possible thing for a correction.
--
-- ---------------------------------------------------------------------
-- What it will not do
--
-- Change a day inside a pay period that has been closed. The overtime
-- on that row has been paid; moving it afterwards makes the payslip and
-- the timesheet disagree, and the payslip is the one that was remitted
-- against. The refusal names the period so somebody can decide whether
-- to reopen it deliberately rather than discovering the disagreement at
-- an audit.
-- =====================================================================

create or replace function app.recompute_attendance(
  p_record uuid,
  -- Whether the morning is being re-read as well as the evening.
  --
  -- Clocking out must not make somebody retrospectively late: lateness
  -- is a fact about when they arrived, `clock_in` recorded it against
  -- the shift at the moment it happened, and an evening punch has no
  -- business revising it. A correction is the opposite case — the
  -- arrival time is the thing being changed — so it asks for the
  -- re-read.
  --
  -- This is not a hypothetical distinction. Wiring `clock_out` through
  -- this function with lateness always recomputed turned an existing
  -- assertion in `clock_out.sql` from `present` to `late`.
  p_reread_lateness boolean default false)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rec        public.attendance_records;
  v_shift      public.work_shifts;
  v_worked     integer;
  v_scheduled  integer;
  v_ot         integer := 0;
  v_late       integer;
  v_is_holiday boolean;
  v_is_restday boolean := false;
begin
  select * into v_rec from public.attendance_records where id = p_record;
  if v_rec.id is null then
    raise exception 'No such attendance record.' using errcode = 'P0002';
  end if;

  v_shift := app.shift_for(v_rec.employee_id, v_rec.work_date);

  select exists (
    select 1 from public.public_holidays h
     where h.org_id = v_rec.org_id and h.holiday_date = v_rec.work_date
       and not h.is_working
  ) into v_is_holiday;

  if v_shift.id is not null then
    v_is_restday := not (extract(dow from v_rec.work_date)::integer
                         = any (v_shift.work_days));
  end if;

  v_scheduled := case
    when v_shift.id is null then 480
    else greatest(1, (extract(epoch from (
           v_shift.end_time - v_shift.start_time
           + case when v_shift.crosses_midnight then interval '24 hours'
                  else interval '0' end)) / 60)::integer
         - coalesce(v_shift.break_minutes, 0))
  end;

  -- A day with no clock-out is not a day of zero hours; it is a day
  -- nobody knows the length of. Everything derived from it stays null
  -- or zero and the status says why, which is what `0360` established.
  if v_rec.clock_in is null or v_rec.clock_out is null then
    update public.attendance_records
       set worked_minutes = 0,
           ot_normal_minutes = 0, ot_restday_minutes = 0,
           ot_holiday_minutes = 0, early_leave_minutes = 0,
           status = case
             when v_rec.clock_in is not null then 'incomplete'
             else v_rec.status end
     where id = p_record;
    return v_scheduled;
  end if;

  v_worked := greatest(0,
    (extract(epoch from (v_rec.clock_out - v_rec.clock_in)) / 60)::integer
    - coalesce(v_shift.break_minutes, 0));

  -- Late against the shift's start plus its grace, in the shift's own
  -- day — the same arithmetic `clock_in` does, written against the
  -- stored time rather than `now()` so a corrected arrival is measured
  -- the same way a real one was.
  v_late := case
    when not p_reread_lateness then coalesce(v_rec.late_minutes, 0)
    when v_shift.id is null or v_is_restday or v_is_holiday then 0
    else greatest(0, (extract(epoch from (
           (v_rec.clock_in at time zone 'Asia/Kuala_Lumpur')
           - (v_rec.work_date + v_shift.start_time
              + make_interval(mins => coalesce(v_shift.grace_minutes, 0)))
         )) / 60)::integer)
  end;

  v_ot := greatest(0, v_worked - v_scheduled);

  update public.attendance_records set
    worked_minutes = v_worked,
    late_minutes = v_late,
    early_leave_minutes = greatest(0, v_scheduled - v_worked),
    ot_holiday_minutes = case when v_is_holiday then v_ot else 0 end,
    ot_restday_minutes = case when v_is_restday and not v_is_holiday
                              then v_ot else 0 end,
    ot_normal_minutes  = case when not v_is_holiday and not v_is_restday
                              then v_ot else 0 end,
    status = case
      when v_is_holiday then 'public_holiday'::app.attendance_status
      when v_is_restday then 'rest_day'::app.attendance_status
      when v_late > 0 then 'late'::app.attendance_status
      else 'present'::app.attendance_status end
  where id = p_record;

  -- Handed back rather than stored, because it is not a fact about the
  -- day: it is what the shift said the day should have been, and
  -- `clock_out` puts it on the screen a person is standing in front of.
  return v_scheduled;
end $$;

revoke all on function app.recompute_attendance(uuid, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The correction itself
-- ---------------------------------------------------------------------
create or replace function public.adjust_attendance(
  p_record    uuid,
  p_clock_in  timestamptz,
  p_clock_out timestamptz,
  p_reason    text)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rec    public.attendance_records;
  v_closed text;
begin
  select * into v_rec from public.attendance_records where id = p_record;
  if v_rec.id is null then
    raise exception 'No such attendance record.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_rec.org_id) then
    raise exception 'Only HR may correct somebody''s timesheet'
      using errcode = '42501';
  end if;

  -- The reason is the point of the three columns. A corrected timesheet
  -- with no reason is a changed number nobody can account for, and the
  -- person it belongs to is the one who will be asked about it.
  if coalesce(btrim(p_reason), '') = '' then
    raise exception
      'Say why the day is being corrected. It goes on the record beside '
      'the change.'
      using errcode = '23514';
  end if;

  if p_clock_in is null then
    raise exception 'A corrected day still needs a time somebody started.'
      using errcode = '23514';
  end if;
  if p_clock_out is not null and p_clock_out <= p_clock_in then
    raise exception 'The day cannot end before it started.'
      using errcode = '23514';
  end if;

  -- Not inside a closed pay period. The overtime on this row has been
  -- paid, and moving it afterwards makes the timesheet and the payslip
  -- disagree — with the payslip being the one that was remitted
  -- against.
  select pp.code into v_closed
    from public.pay_periods pp
   where pp.org_id = v_rec.org_id
     and pp.is_closed
     and v_rec.work_date between pp.period_start and pp.period_end
   limit 1;
  if v_closed is not null then
    raise exception
      'Pay period % is closed and this day was paid in it. Reopen the '
      'period first if the correction is meant to change what was paid.',
      v_closed
      using errcode = '23514';
  end if;

  update public.attendance_records
     set clock_in = p_clock_in,
         clock_out = p_clock_out,
         is_adjusted = true,
         adjusted_by = auth.uid(),
         adjustment_reason = btrim(p_reason)
   where id = p_record;

  -- The arrival time is what changed, so the morning is re-read too.
  perform app.recompute_attendance(p_record, p_reread_lateness => true);

  select * into v_rec from public.attendance_records where id = p_record;
  return jsonb_build_object(
    'status', v_rec.status,
    'worked_minutes', v_rec.worked_minutes,
    'late_minutes', v_rec.late_minutes,
    'overtime_minutes', v_rec.ot_normal_minutes
                      + v_rec.ot_restday_minutes
                      + v_rec.ot_holiday_minutes);
end $$;

revoke all on function public.adjust_attendance(uuid, timestamptz, timestamptz, text)
  from public, anon;
grant execute on function public.adjust_attendance(uuid, timestamptz, timestamptz, text)
  to authenticated;

comment on function public.adjust_attendance(uuid, timestamptz, timestamptz, text) is
  'Corrects a day''s clock times, recording who changed it and why. '
  'HR only, a reason is required, and a day inside a closed pay period '
  'is refused because its overtime has already been paid.';

-- ---------------------------------------------------------------------
-- And the punch uses the same arithmetic
-- ---------------------------------------------------------------------
-- Unchanged in behaviour and shorter by forty lines. What it did before
-- was compute working minutes, scheduled minutes and the overtime
-- multiplier itself, and a correction has to produce exactly the
-- numbers a punch would have — two copies of an overtime calculation is
-- two answers to what somebody is owed.
--
-- The one thing that reads differently: this now stamps the clock-out
-- and then measures the row, where before it measured `now()` and then
-- stamped. For a punch they are the same instant. For everything else
-- the row is the only thing there is.
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

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
revoke all on function public.clock_out(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  from public, anon;
grant execute on function public.clock_out(
  uuid, app.clock_method, numeric, numeric, text, text, text, uuid)
  to authenticated;

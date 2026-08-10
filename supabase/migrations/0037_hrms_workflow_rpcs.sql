-- =====================================================================
-- iAkauntan :: 0037 hrms workflow rpcs
-- Applied as project migration 20260810055309.
-- =====================================================================

-- The shift that applies to an employee on a date.
create or replace function app.shift_for(p_employee_id uuid, p_date date)
returns public.work_shifts language sql stable
set search_path = public, pg_temp as $$
  select s.* from public.employee_shifts es
    join public.work_shifts s on s.id = es.shift_id
   where es.employee_id = p_employee_id
     and es.effective_from <= p_date
     and (es.effective_to is null or es.effective_to >= p_date)
   order by es.effective_from desc
   limit 1;
$$;

-- ---------------------------------------------------------------------
-- Clock in and out
-- ---------------------------------------------------------------------
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
    case when v_late > 0 then 'late' else 'present' end, v_late)
  -- A second punch on the same day does not overwrite the first: the
  -- earliest clock-in is the one that counts.
  on conflict (employee_id, work_date) do update
    set clock_in = coalesce(a.clock_in, excluded.clock_in)
  returning id into v_id;

  return v_id;
end;
$$;

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
  if p_employee_id is not null and p_employee_id <> app.my_employee_id(p_org_id) then
    if not app.can_manage_hr(p_org_id) then
      raise exception 'Only HR may clock out on behalf of another employee'
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

-- ---------------------------------------------------------------------
-- Leave
-- ---------------------------------------------------------------------
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
  v_emp uuid;
  v_type public.leave_types;
  v_year integer := extract(year from p_start_date)::integer;
  v_available numeric;
  v_id uuid;
begin
  v_emp := coalesce(p_employee_id, app.my_employee_id(p_org_id));
  if v_emp is null then
    raise exception 'No employee record is linked to this login'
      using errcode = 'P0002';
  end if;
  if v_emp <> app.my_employee_id(p_org_id)
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

create or replace function public.decide_leave_request(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_req public.leave_requests;
  v_year integer;
begin
  select * into v_req from public.leave_requests where id = p_request_id;
  if v_req.id is null then
    raise exception 'Leave request not found' using errcode = 'P0002';
  end if;
  if v_req.status <> 'submitted' then
    raise exception 'This request is already %', v_req.status
      using errcode = '22023';
  end if;
  if not (app.can_manage_hr(v_req.org_id)
          or app.manages_employee(v_req.employee_id)) then
    raise exception 'Only HR or the employee''s manager may decide this request'
      using errcode = '42501';
  end if;

  v_year := extract(year from v_req.start_date)::integer;

  update public.leave_requests set
    status = case when p_approve then 'approved'::app.request_status
                  else 'rejected'::app.request_status end,
    approver_id = auth.uid(),
    decided_at = now(),
    decision_note = p_note
  where id = p_request_id;

  -- The hold comes off either way; only an approval consumes the balance.
  update public.leave_balances set
    pending_days = greatest(pending_days - v_req.total_days, 0),
    taken_days = taken_days + case when p_approve then v_req.total_days else 0 end
  where employee_id = v_req.employee_id
    and leave_type_id = v_req.leave_type_id
    and leave_year = v_year;
end;
$$;

-- ---------------------------------------------------------------------
-- Claims
-- ---------------------------------------------------------------------
create or replace function public.decide_expense_claim(
  p_claim_id uuid,
  p_approve boolean,
  p_note text default null,
  p_approved_amount numeric default null
)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_claim public.expense_claims;
begin
  select * into v_claim from public.expense_claims where id = p_claim_id;
  if v_claim.id is null then
    raise exception 'Claim not found' using errcode = 'P0002';
  end if;
  if v_claim.status <> 'submitted' then
    raise exception 'This claim is already %', v_claim.status
      using errcode = '22023';
  end if;
  if not (app.can_manage_hr(v_claim.org_id)
          or app.can_post(v_claim.org_id)
          or app.manages_employee(v_claim.employee_id)) then
    raise exception 'Only HR, finance or the employee''s manager may decide this claim'
      using errcode = '42501';
  end if;

  update public.expense_claims set
    status = case when p_approve then 'approved'::app.request_status
                  else 'rejected'::app.request_status end,
    approved_amount = case when p_approve
      then coalesce(p_approved_amount, v_claim.total_amount) else 0 end,
    approver_id = auth.uid(),
    decided_at = now(),
    decision_note = p_note
  where id = p_claim_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Payroll periods and runs
-- ---------------------------------------------------------------------
create or replace function public.ensure_pay_period(
  p_org_id uuid, p_year integer, p_month integer)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
  v_start date := make_date(p_year, p_month, 1);
  v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_pay_day integer;
  v_pay date;
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Not permitted to manage payroll' using errcode = '42501';
  end if;

  select coalesce(pay_day, 25) into v_pay_day
    from public.payroll_settings where org_id = p_org_id;
  v_pay_day := coalesce(v_pay_day, 25);

  -- Day 0 means the last day of the month, and a pay day past the end of
  -- a short month falls back to its last day.
  v_pay := case when v_pay_day = 0 then v_end
                else least(make_date(p_year, p_month, least(v_pay_day, 28)), v_end) end;
  if v_pay_day between 29 and 31 then v_pay := v_end; end if;

  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (p_org_id, to_char(v_start, 'YYYY-MM'), v_start, v_end, v_pay)
  on conflict (org_id, code) do update set code = excluded.code
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.create_payroll_run(
  p_org_id uuid, p_period_id uuid, p_description text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Not permitted to run payroll' using errcode = '42501';
  end if;

  insert into public.payroll_runs
    (org_id, run_no, period_id, description, created_by)
  values (p_org_id, public.next_document_number(p_org_id, 'payroll_run'),
          p_period_id, p_description, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- =====================================================================
-- iAkauntan :: 0784 a cancelled vacancy is not hired into
--
-- `hire_applicant` (`0381`) refuses a rejected or withdrawn applicant,
-- and a requisition whose places are all taken. It never asked whether
-- the requisition had been CANCELLED. Measured on 9 October 2026,
-- locally: an applicant on a cancelled vacancy was hired, an employee
-- record was made, and the requisition stayed 'cancelled' with a hire
-- against it -- the function's own last paragraph declines to mark a
-- cancelled requisition filled, which is the one place it had noticed.
-- The vacancy report then shows a vacancy nobody was meant to fill,
-- filled, and the headcount the cancellation released is spent anyway.
-- Found sweeping `hire_applicant`.
--
-- Answered "refuse; reopen first". A hire against a cancelled
-- requisition is refused, naming it and saying what to do. Draft and
-- on-hold requisitions are unchanged.
--
-- The sentence the question suggested said "reopen it", and nothing
-- can: `open_requisition` (`0394`) opens a draft or one on hold and
-- refuses a cancelled one, and the vacancy editor never writes the
-- status. So the refusal names the road that exists -- raise a new
-- requisition for the place -- rather than one that would be refused
-- in turn.
--
-- Restated from `0381`, whose text production runs exactly (identical
-- source hash on 9 October). One paragraph is new.
-- =====================================================================

create or replace function public.hire_applicant(
  p_applicant     uuid,
  p_employee_no   text,
  p_hire_date     date,
  p_basic_salary  numeric,
  p_date_of_birth date default null,
  p_department    uuid default null,
  p_position      uuid default null,
  p_manager       uuid default null,
  p_early_start_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a        public.applicants;
  v_req      public.job_requisitions;
  v_emp      uuid;
  v_today    date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_earliest date;
  v_hired    integer;
begin
  select * into v_a from public.applicants where id = p_applicant;
  if v_a.id is null then
    raise exception 'No such applicant.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_a.org_id) then
    raise exception 'not permitted to hire' using errcode = '42501';
  end if;
  if v_a.hired_employee_id is not null then
    raise exception
      '% has already been hired. Their employee record is the one to '
      'edit.', v_a.full_name using errcode = '23505';
  end if;
  if v_a.status in ('rejected', 'withdrawn') then
    raise exception
      '% is marked %. Put them back in the pipeline before hiring them, '
      'so the history says what happened.', v_a.full_name, v_a.status
      using errcode = '23514';
  end if;
  if p_hire_date is null then
    raise exception 'A hire needs a start date.' using errcode = '23514';
  end if;
  if btrim(coalesce(p_employee_no, '')) = '' then
    raise exception 'A hire needs an employee number.' using errcode = '23514';
  end if;

  -- The notice they owe somebody else. A start date inside it is a date
  -- they cannot make, and the way through is to say why it is being
  -- overridden — notice does get bought out.
  if coalesce(v_a.notice_period_days, 0) > 0 then
    v_earliest := v_today + v_a.notice_period_days;
    if p_hire_date < v_earliest
       and btrim(coalesce(p_early_start_note, '')) = '' then
      raise exception
        '% owes % days'' notice, so the earliest they can start is %. '
        'If it has been waived or bought out, say so and the date '
        'stands.',
        v_a.full_name, v_a.notice_period_days,
        to_char(v_earliest, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
  end if;

  -- The requisition this came from, and whether it still has a place.
  if v_a.requisition_id is not null then
    select * into v_req from public.job_requisitions
     where id = v_a.requisition_id;
    -- `0784`. A cancelled vacancy was decided against; hiring into it
    -- spends the headcount the cancellation released.
    if v_req.status = 'cancelled' then
      raise exception
        '% was cancelled. Raise a new requisition for the place, or hire '
        'against another one.',
        v_req.requisition_no using errcode = '23514';
    end if;
    select count(*) into v_hired from public.applicants
     where requisition_id = v_req.id and hired_employee_id is not null;
    if v_hired >= v_req.headcount then
      raise exception
        '% was raised for % position(s) and % have been filled. Raise '
        'the headcount, or hire against another requisition.',
        v_req.requisition_no, v_req.headcount, v_hired
        using errcode = '23514';
    end if;
  end if;

  -- Everything the applicant record already knows, carried across. The
  -- point of the whole exercise: nobody retypes what is sitting in
  -- front of them, and the two records cannot disagree about the name.
  insert into public.employees
    (org_id, employee_no, full_name, email, phone, nric, hire_date,
     basic_salary, date_of_birth, department_id, position_id, manager_id,
     employment_type, employment_status)
  values (v_a.org_id, btrim(p_employee_no), v_a.full_name, v_a.email,
          v_a.phone, v_a.nric, p_hire_date, p_basic_salary,
          p_date_of_birth, p_department, p_position, p_manager,
          coalesce(v_req.employment_type, 'full_time'), 'probation')
  returning id into v_emp;

  update public.applicants set
    hired_employee_id = v_emp,
    status            = 'hired',
    updated_at        = now()
  where id = p_applicant;

  insert into public.applicant_stage_history
    (org_id, applicant_id, from_status, to_status, note, changed_by)
  values (v_a.org_id, p_applicant, v_a.status, 'hired',
          nullif(btrim(coalesce(p_early_start_note, '')), ''), auth.uid());

  -- The requisition is filled when its places are taken, on the day
  -- they were taken rather than whenever somebody remembers.
  if v_req.id is not null and v_hired + 1 >= v_req.headcount then
    update public.job_requisitions
       set status = 'filled', closed_date = v_today, updated_at = now()
     where id = v_req.id and status <> 'cancelled';
  end if;

  return v_emp;
end $$;

comment on function public.hire_applicant(
  uuid, text, date, numeric, date, uuid, uuid, uuid, text) is
  'Turns an applicant into an employee and links the two. '
  '`hired_employee_id` carried a comment saying it was set when this '
  'happened and nothing set it, so a hire was a status label and the '
  'person was typed in again from the record beside them. Refuses a '
  'requisition that was cancelled (`0784`).';

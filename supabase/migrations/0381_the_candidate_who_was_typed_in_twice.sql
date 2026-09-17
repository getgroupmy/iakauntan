-- =====================================================================
-- iAkauntan :: 0381 the candidate who was typed in twice
--
-- `applicants.hired_employee_id` carries the comment it was created
-- with in `0036`:
--
--     -- Set when the applicant becomes an employee, so the two records
--     -- stay linked and the hire is traceable back to its requisition.
--
-- Nothing sets it. The candidates tab moves an applicant along the
-- pipeline with `moveApplicant`, which writes a status and a history
-- row, and `hired` is the last label on that list. Somebody then opens
-- the employee editor and types the name, the phone number, the NRIC
-- and the salary in again, from the record sitting beside them.
--
-- What is lost is not the typing. It is every question the recruiting
-- data exists to answer: which requisition this person came from, what
-- the offer was against what they expected, how long it took, and — the
-- one somebody is usually asking about money — who referred them.
--
-- ---------------------------------------------------------------------
-- Four more columns, each of which stops something
--
-- `notice_period_days` is what the candidate owes their current
-- employer. A start date inside it is a date they cannot make, and
-- discovering that after the offer has gone out is how a start slips a
-- month. It is refused with a way through, because notice does get
-- bought out and a refusal with no way through is how somebody puts the
-- wrong date in to get past the screen.
--
-- `headcount` on the requisition has been displayed since the screen
-- was written — "3 position(s)" — and nothing has ever counted against
-- it. So a requisition for one could be filled four times and the
-- register of open roles would go on saying it was open.
--
-- `closed_date` and the `filled` status are the other half of that: a
-- requisition whose headcount is taken is closed here, on the day it
-- was taken, rather than whenever somebody remembers.
--
-- `referred_by` is a reference to an employee that nothing wrote, which
-- makes an employee referral scheme unpayable — the question "who
-- introduced the people we hired this quarter" had no answer in the
-- data at all.
--
-- ---------------------------------------------------------------------
-- What this does not do
--
-- `applicants.resume_path` is left alone deliberately. Attachments have
-- had a home since `0046` — a bucket, a row, a lifecycle and a policy —
-- and a second text column holding a storage path beside it is a second
-- place for the file to be missing from. The place to delete this
-- paragraph is the day the applicant screen grows an attachments
-- section, which is where a CV belongs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who is already in this state
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.applicants
   where status = 'hired' and hired_employee_id is null;
  if v_n > 0 then
    raise notice
      '0381: % applicant(s) marked hired with no employee record linked. '
      'The employee exists — somebody typed them in — but which '
      'requisition they came from, and who referred them, cannot be '
      'recovered from the data. Link them by hand if it matters.', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Hired means there is somebody on the payroll
-- ---------------------------------------------------------------------
create or replace function app.applicant_hire_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if new.status <> 'hired' then return new; end if;
  -- Judging the change. Rows that were marked hired before this stay
  -- editable: a phone number should not be uncorrectable because of a
  -- link nobody could have made at the time.
  if tg_op = 'UPDATE' and old.status = 'hired' then return new; end if;

  if new.hired_employee_id is null then
    raise exception
      'Somebody is hired when they are on the payroll, not when the '
      'label says so. Use hire_applicant, which makes the employee '
      'record from this one and keeps the two linked.'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists applicants_hire_ck on public.applicants;
create trigger applicants_hire_ck
  before insert or update on public.applicants
  for each row execute function app.applicant_hire_guard();

-- ---------------------------------------------------------------------
-- Making the employee out of the applicant
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Who introduced the people we hired
-- ---------------------------------------------------------------------
create or replace function public.report_referral_hires(
  p_org  uuid,
  p_from date default null,
  p_to   date default null)
returns table (
  referrer_id   uuid,
  referrer_no   text,
  referrer_name text,
  hires         integer,
  candidates    integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select r.id, r.employee_no, r.full_name,
         count(*) filter (where a.hired_employee_id is not null)::integer,
         count(*)::integer
    from public.applicants a
    join public.employees r on r.id = a.referred_by
   where a.org_id = p_org
     and app.can_manage_hr(p_org)
     and (p_from is null or a.applied_at >= p_from)
     and (p_to is null or a.applied_at < p_to + 1)
   group by r.id, r.employee_no, r.full_name
   -- Both counts, because a scheme that only shows hires cannot tell
   -- somebody who introduced six people and had none taken on from
   -- somebody who introduced nobody.
   order by count(*) filter (where a.hired_employee_id is not null) desc,
            count(*) desc, r.full_name;
$$;

-- ---------------------------------------------------------------------
revoke all on function public.hire_applicant(
  uuid, text, date, numeric, date, uuid, uuid, uuid, text)
  from public, anon;
revoke all on function
  public.report_referral_hires(uuid, date, date) from public, anon;

grant execute on function public.hire_applicant(
  uuid, text, date, numeric, date, uuid, uuid, uuid, text) to authenticated;
grant execute on function
  public.report_referral_hires(uuid, date, date) to authenticated;

comment on function public.hire_applicant(
  uuid, text, date, numeric, date, uuid, uuid, uuid, text) is
  'Turns an applicant into an employee and links the two. '
  '`hired_employee_id` carried a comment saying it was set when this '
  'happened and nothing set it, so a hire was a status label and the '
  'person was typed in again from the record beside them.';
comment on function public.report_referral_hires(uuid, date, date) is
  'Who introduced the people we hired. `applicants.referred_by` was a '
  'reference nothing wrote, which made an employee referral scheme '
  'unpayable from the data.';

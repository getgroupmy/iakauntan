-- =====================================================================
-- iAkauntan :: the vacancy nobody could open
--
-- Three columns on `job_requisitions` have never been written —
-- `hiring_manager_id`, `requirements`, `target_start_date` — and the
-- reason is the one `0389` found on `projects`: nothing writes *any*
-- column. `Repo.requisitions()` selects the table, the talent screen
-- lists what it finds, and there is no insert and no update anywhere in
-- the client. A vacancy has to be typed straight into the table by
-- somebody with a database connection.
--
-- `0381` built the other end of this and could only assume the front
-- one. It hires an applicant against a requisition, counts the places
-- taken against `headcount`, and closes the requisition on the day its
-- last place is filled. All of that works on rows nobody can create.
--
-- So: the door, and the rules that belong on the far side of it.
--
-- **A vacancy is for at least one person.** `headcount` defaults to 1
-- and nothing stopped a zero, which `0381` would then treat as a
-- requisition with no places — filled before it opened.
--
-- **A salary band runs upwards**, and a target start date does not
-- precede the day the vacancy opened.
--
-- **A vacancy that is open has a hiring manager.** This is the one with
-- teeth. The hiring manager is who the applicants belong to: it is the
-- person an interview is arranged with, the person who decides, and —
-- once `0381` hires somebody — the manager the new employee reports to.
-- A requisition advertised with nobody owning it collects applications
-- that sit in a queue no one is looking at, which is the same failure
-- as the ticket queue with no team in `0192` and the matter with no fee
-- earner in `0383`. Draft requisitions are exempt: a draft is somebody
-- working out whether the role is wanted at all.
--
-- **And the dates follow the status.** `opened_date` and `closed_date`
-- are plain date columns that a form could set independently of the
-- status beside them — the shape `0387` and `0391` both found. Here
-- they are written by the transitions and not offered to be typed.
-- =====================================================================

alter table public.job_requisitions
  drop constraint if exists job_requisitions_headcount_ck;
alter table public.job_requisitions
  add constraint job_requisitions_headcount_ck check (headcount >= 1);

alter table public.job_requisitions
  drop constraint if exists job_requisitions_salary_ck;
alter table public.job_requisitions
  add constraint job_requisitions_salary_ck
  check (salary_min is null or salary_max is null
         or salary_max >= salary_min);

alter table public.job_requisitions
  drop constraint if exists job_requisitions_dates_ck;
alter table public.job_requisitions
  add constraint job_requisitions_dates_ck
  check (opened_date is null or target_start_date is null
         or target_start_date >= opened_date);

-- ---------------------------------------------------------------------
-- A vacancy that is open has somebody who owns it
--
-- Judged on the row rather than the change: a requisition that is open
-- and has no hiring manager is wrong however it got that way, including
-- by the manager being deleted out from under it — which
-- `on delete set null` on that foreign key makes possible.
-- ---------------------------------------------------------------------
create or replace function app.requisition_owner_guard()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if new.status in ('open', 'on_hold')
     and new.hiring_manager_id is null then
    raise exception
      'An open vacancy needs a hiring manager. Applications to a '
      'requisition nobody owns go into a queue nobody is reading.'
      using errcode = '23502';
  end if;
  return new;
end $$;

drop trigger if exists job_requisitions_owner_ck on public.job_requisitions;
create trigger job_requisitions_owner_ck
  before insert or update on public.job_requisitions
  for each row execute function app.requisition_owner_guard();

-- ---------------------------------------------------------------------
-- Opening one
--
-- The date comes from the act rather than from a form field, which is
-- the lesson `0391` wrote down about the three dates on a filing: a
-- date somebody types beside a status is a date that can disagree with
-- it.
-- ---------------------------------------------------------------------
create or replace function public.open_requisition(
  p_requisition uuid, p_opened_on date default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  r public.job_requisitions;
  v_on date;
begin
  select * into r from public.job_requisitions where id = p_requisition;
  if r.id is null then
    raise exception 'No such requisition.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(r.org_id) then
    raise exception 'not permitted to open a vacancy' using errcode = '42501';
  end if;
  if r.status not in ('draft', 'on_hold') then
    raise exception
      'That requisition is %. Only a draft or one on hold is opened.',
      r.status using errcode = '22023';
  end if;
  if r.hiring_manager_id is null then
    raise exception
      'Name the hiring manager before opening the vacancy. Applications '
      'to a requisition nobody owns go into a queue nobody is reading.'
      using errcode = '23502';
  end if;

  v_on := coalesce(p_opened_on, r.opened_date,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'A vacancy cannot have opened on a day that has not '
      'happened.' using errcode = '23514';
  end if;

  update public.job_requisitions
     set status = 'open', opened_date = v_on, closed_date = null,
         updated_at = now()
   where id = p_requisition;
end $$;

-- ---------------------------------------------------------------------
-- Closing one
--
-- `0381` already closes a requisition the day its last place is filled.
-- This is the other way it ends: the role is withdrawn, or put on hold
-- while somebody decides. `cancelled` takes the closing date;
-- `on_hold` does not, because a vacancy on hold has not closed.
-- ---------------------------------------------------------------------
create or replace function public.close_requisition(
  p_requisition uuid,
  p_status app.requisition_status default 'cancelled',
  p_closed_on date default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  r public.job_requisitions;
  v_on date;
begin
  select * into r from public.job_requisitions where id = p_requisition;
  if r.id is null then
    raise exception 'No such requisition.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(r.org_id) then
    raise exception 'not permitted to close a vacancy'
      using errcode = '42501';
  end if;
  if p_status not in ('cancelled', 'on_hold') then
    raise exception
      'A vacancy is closed by cancelling it or putting it on hold. It is '
      'filled by hiring somebody, which `hire_applicant` does.'
      using errcode = '22023';
  end if;
  if r.status in ('filled', 'cancelled') then
    raise exception 'That requisition is already %.', r.status
      using errcode = '22023';
  end if;

  v_on := coalesce(p_closed_on, (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'A vacancy cannot have closed on a day that has not '
      'happened.' using errcode = '23514';
  end if;
  if r.opened_date is not null and v_on < r.opened_date then
    raise exception
      'That vacancy opened on %, so it cannot have closed on %.',
      to_char(r.opened_date, 'DD Mon YYYY'), to_char(v_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  update public.job_requisitions
     set status = p_status,
         -- On hold is not closed. A requisition parked while somebody
         -- decides is still a vacancy, and giving it a closing date
         -- would take it off the open list and out of the count.
         closed_date = case when p_status = 'cancelled' then v_on end,
         updated_at = now()
   where id = p_requisition;
end $$;

-- ---------------------------------------------------------------------
-- What is open, and how long it has been
--
-- The question an HR manager asks: which vacancies are still running,
-- who owns each, how many applicants it has drawn, and how many places
-- are still to fill. Days open is the number that starts conversations,
-- so it is computed here rather than in the screen.
-- ---------------------------------------------------------------------
create or replace function public.report_open_vacancies(p_org_id uuid)
returns table (
  requisition_id uuid,
  requisition_no text,
  title text,
  department text,
  hiring_manager text,
  status app.requisition_status,
  opened_date date,
  target_start_date date,
  days_open integer,
  headcount integer,
  hired integer,
  remaining integer,
  applicants integer)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'not permitted to read the vacancies'
      using errcode = '42501';
  end if;

  return query
    select r.id, r.requisition_no, r.title, d.name, e.full_name, r.status,
           r.opened_date, r.target_start_date,
           case when r.opened_date is null then null
                else (current_date - r.opened_date)::integer end,
           r.headcount,
           coalesce(h.hired, 0)::integer,
           greatest(r.headcount - coalesce(h.hired, 0), 0)::integer,
           coalesce(a.n, 0)::integer
      from public.job_requisitions r
      left join public.departments d on d.id = r.department_id
      left join public.employees e on e.id = r.hiring_manager_id
      left join lateral (
        select count(*) as hired from public.applicants x
         where x.requisition_id = r.id and x.hired_employee_id is not null
      ) h on true
      left join lateral (
        select count(*) as n from public.applicants x
         where x.requisition_id = r.id
      ) a on true
     where r.org_id = p_org_id
       and r.status in ('open', 'on_hold')
     order by r.opened_date nulls last, r.requisition_no;
end $$;

grant execute on function public.open_requisition(uuid, date)
  to authenticated;
grant execute on function public.close_requisition(
  uuid, app.requisition_status, date) to authenticated;
grant execute on function public.report_open_vacancies(uuid)
  to authenticated;

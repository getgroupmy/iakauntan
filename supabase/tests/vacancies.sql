-- =====================================================================
-- iAkauntan :: the vacancy nobody could open
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/vacancies.sql
--
-- `hiring_manager_id`, `requirements` and `target_start_date` have never
-- been written on `job_requisitions`, and the reason is `0389`'s: the
-- client selects the table and never writes it. `0381` hires against a
-- requisition, counts places against `headcount` and closes it when the
-- last is filled — all on rows nobody could create.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.vac_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'hr', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

create or replace function pg_temp.vac_employee(
  p_org uuid, p_no text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary, date_of_birth)
  values (p_org, p_no, p_name, date '2020-01-01', 6000, date '1985-01-01')
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The rules a requisition row obeys
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.vac_org('Kekosongan Sdn Bhd');
  v_mgr  uuid;
  v_r    uuid;
  v_said text;
begin
  v_mgr := pg_temp.vac_employee(v_org, 'E1', 'Puan Hasnah');

  begin
    insert into public.job_requisitions
      (org_id, requisition_no, title, headcount)
    values (v_org, 'REQ-0', 'Nobody', 0);
    raise exception 'FAIL: a vacancy was opened for nobody';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a vacancy is for at least one person',
    v_said like '%job_requisitions_headcount_ck%');

  begin
    insert into public.job_requisitions
      (org_id, requisition_no, title, salary_min, salary_max)
    values (v_org, 'REQ-B', 'Backwards band', 9000, 4000);
    raise exception 'FAIL: a salary band ran downwards';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a salary band runs upwards',
    v_said like '%job_requisitions_salary_ck%');

  -- A draft with nobody named is fine: somebody is still working out
  -- whether the role is wanted at all.
  insert into public.job_requisitions
    (org_id, requisition_no, title, headcount, requirements,
     target_start_date)
  values (v_org, 'REQ-1', 'Account Executive', 2,
          'SPM, two years in a similar role', current_date + 60)
  returning id into v_r;
  perform pg_temp.check_eq('a draft needs nobody yet',
    (select status::text from public.job_requisitions where id = v_r),
    'draft');
  -- The columns that had never been written.
  perform pg_temp.check_eq('the requirements are recorded',
    (select requirements from public.job_requisitions where id = v_r),
    'SPM, two years in a similar role');
  perform pg_temp.check_eq('and when the role is wanted from',
    (select target_start_date from public.job_requisitions where id = v_r)::text,
    (current_date + 60)::text);

  -- Opening it without an owner is refused, by the function and by the
  -- trigger behind it.
  begin
    perform public.open_requisition(v_r);
    raise exception 'FAIL: a vacancy was opened with nobody owning it';
  exception when sqlstate '23502' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an open vacancy has a hiring manager',
    v_said like '%Name the hiring manager%');

  begin
    update public.job_requisitions set status = 'open' where id = v_r;
    raise exception 'FAIL: a vacancy was opened around the function';
  exception when sqlstate '23502' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and not by writing the status directly',
    v_said like '%queue nobody is reading%');

  -- On hold is the same case. A vacancy parked while somebody decides
  -- is still advertised and still collecting applications, so it still
  -- needs somebody they belong to — and `on delete set null` on that
  -- foreign key means the manager can vanish from under it.
  begin
    update public.job_requisitions set status = 'on_hold' where id = v_r;
    raise exception 'FAIL: a vacancy went on hold with nobody owning it';
  exception when sqlstate '23502' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a vacancy on hold needs one too',
    v_said like '%queue nobody is reading%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Opening, holding and cancelling
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.vac_org('Buka Kekosongan Sdn Bhd');
  v_mgr  uuid;
  v_r    uuid;
  v_said text;
  v_row  record;
  v_n    integer;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_mgr := pg_temp.vac_employee(v_org, 'E1', 'Encik Rizal');
  insert into public.job_requisitions
    (org_id, requisition_no, title, headcount, hiring_manager_id)
  values (v_org, 'REQ-1', 'Storekeeper', 2, v_mgr) returning id into v_r;

  perform public.open_requisition(v_r, v_today - 20);
  select * into v_row from public.job_requisitions where id = v_r;
  perform pg_temp.check_eq('it opens', v_row.status::text, 'open');
  perform pg_temp.check_eq('on the day it was opened',
    v_row.opened_date::text, (v_today - 20)::text);

  -- The date is the act's, and an act has happened.
  begin
    perform public.close_requisition(v_r, 'cancelled', v_today + 1);
    raise exception 'FAIL: a vacancy closed on a day that has not happened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a closing date is not a plan',
    v_said like '%has not happened%');

  begin
    perform public.close_requisition(v_r, 'cancelled', v_today - 30);
    raise exception 'FAIL: a vacancy closed before it opened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor before the vacancy opened',
    v_said like '%so it cannot have closed on%');

  -- On hold is not closed, which is why it takes no closing date.
  perform public.close_requisition(v_r, 'on_hold');
  select * into v_row from public.job_requisitions where id = v_r;
  perform pg_temp.check_eq('it can be put on hold',
    v_row.status::text, 'on_hold');
  perform pg_temp.check_true('and holding is not closing',
    v_row.closed_date is null);
  -- Still a vacancy, so still on the list.
  select count(*)::integer into v_n
    from public.report_open_vacancies(v_org) where requisition_id = v_r;
  perform pg_temp.check_eq('a vacancy on hold is still a vacancy', v_n, 1);

  -- And back off hold, keeping the day it originally opened.
  perform public.open_requisition(v_r);
  select * into v_row from public.job_requisitions where id = v_r;
  perform pg_temp.check_eq('it comes back off hold',
    v_row.status::text, 'open');
  perform pg_temp.check_eq('and keeps the day it opened',
    v_row.opened_date::text, (v_today - 20)::text);

  perform public.close_requisition(v_r, 'cancelled', v_today - 1);
  select * into v_row from public.job_requisitions where id = v_r;
  perform pg_temp.check_eq('cancelling closes it',
    v_row.closed_date::text, (v_today - 1)::text);
  select count(*)::integer into v_n
    from public.report_open_vacancies(v_org) where requisition_id = v_r;
  perform pg_temp.check_eq('and takes it off the list', v_n, 0);

  begin
    perform public.close_requisition(v_r);
    raise exception 'FAIL: a cancelled vacancy was cancelled again';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('already cancelled',
    v_said like '%already cancelled%');

  -- Filling is hiring, which is `0381`'s job and not this one's.
  -- And a cancelled vacancy is not reopened. Reopening one is raising a
  -- new requisition: the old one has a closing date and a reason, and
  -- writing over them loses both.
  begin
    perform public.open_requisition(v_r);
    raise exception 'FAIL: a cancelled vacancy was reopened';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('only a draft or one on hold is opened',
    v_said like '%Only a draft or one on hold is opened%');

  begin
    perform public.close_requisition(v_r, 'filled');
    raise exception 'FAIL: a vacancy was marked filled without a hire';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a vacancy is filled by hiring somebody',
    v_said like '%filled by hiring somebody%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What is open, and for how long
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.vac_org('Senarai Kekosongan Sdn Bhd');
  v_mgr  uuid;
  v_dept uuid;
  v_r    uuid;
  v_a    uuid;
  v_row  record;
  v_said text;
  v_out  uuid := pg_temp.another_user('outsider@vac.test');
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  insert into public.departments (org_id, code, name)
  values (v_org, 'OPS', 'Operations') returning id into v_dept;
  v_mgr := pg_temp.vac_employee(v_org, 'E1', 'Cik Farah');

  insert into public.job_requisitions
    (org_id, requisition_no, title, headcount, hiring_manager_id,
     department_id)
  values (v_org, 'REQ-1', 'Driver', 3, v_mgr, v_dept) returning id into v_r;
  perform public.open_requisition(v_r, v_today - 45);

  insert into public.applicants
    (org_id, requisition_id, full_name, email, status)
  values (v_org, v_r, 'Ali', 'ali@vac.test', 'applied');
  insert into public.applicants
    (org_id, requisition_id, full_name, email, status)
  values (v_org, v_r, 'Bala', 'bala@vac.test', 'applied')
  returning id into v_a;

  select * into v_row from public.report_open_vacancies(v_org)
   where requisition_id = v_r;
  perform pg_temp.check_eq('the vacancy is on the list',
    v_row.title, 'Driver');
  perform pg_temp.check_eq('with the manager who owns it',
    v_row.hiring_manager, 'Cik Farah');
  perform pg_temp.check_eq('and the department', v_row.department,
    'Operations');
  -- The number that starts the conversation.
  perform pg_temp.check_eq('and how long it has been open',
    v_row.days_open, 45);
  perform pg_temp.check_eq('two applied', v_row.applicants, 2);
  perform pg_temp.check_eq('nobody hired yet', v_row.hired, 0);
  perform pg_temp.check_eq('so three places remain', v_row.remaining, 3);

  -- One hired: the places remaining come down, which is what the count
  -- is for.
  update public.applicants
     set hired_employee_id = pg_temp.vac_employee(v_org, 'E2', 'Bala')
   where id = v_a;
  select * into v_row from public.report_open_vacancies(v_org)
   where requisition_id = v_r;
  perform pg_temp.check_eq('one place is taken', v_row.hired, 1);
  perform pg_temp.check_eq('and two remain', v_row.remaining, 2);

  -- Personal data and a hiring plan. An outsider reads none of it.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform count(*) from public.report_open_vacancies(v_org);
    raise exception 'FAIL: an outsider read the vacancies';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not permitted to read the vacancies',
    v_said like '%not permitted to read the vacancies%');

  begin
    perform public.open_requisition(v_r);
    raise exception 'FAIL: an outsider opened a vacancy';
  exception when sqlstate '42501' or sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor open one',
    v_said like '%not permitted to open a vacancy%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

rollback;

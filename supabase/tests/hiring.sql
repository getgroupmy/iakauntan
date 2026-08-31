-- =====================================================================
-- iAkauntan :: turning an applicant into an employee
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hiring.sql
--
-- `applicants.hired_employee_id` was created in `0036` with a comment
-- saying it is set when the applicant becomes an employee. Nothing set
-- it. `hired` was the last label on the pipeline and somebody then
-- typed the name, the phone number, the NRIC and the salary into the
-- employee editor again, from the record in front of them.
--
-- The first assertion is the one that matters: after a hire, the
-- employee record carries what the applicant record knew, and the two
-- are linked. The rest are the things that stop: notice owed to
-- somebody else, a requisition whose places are taken, and a status
-- that claims a hire nobody made.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.hi_req(
  p_org uuid, p_no text, p_headcount integer,
  p_type text default 'contract')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  -- Deliberately not the column default. A fixture that asks for the
  -- value the row would hold anyway asserts nothing about where it came
  -- from, and the mutation run said so.
  insert into public.job_requisitions
    (org_id, requisition_no, title, headcount, status, opened_date,
     employment_type)
  values (p_org, p_no, 'Bookkeeper', p_headcount, 'open',
          current_date - 30, p_type::app.employment_type)
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.hi_applicant(
  p_org uuid, p_name text, p_req uuid default null,
  p_notice integer default null, p_referrer uuid default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.applicants
    (org_id, requisition_id, full_name, email, phone, nric,
     current_employer, current_position, expected_salary,
     notice_period_days, source, referred_by, status)
  values (p_org, p_req, p_name,
          lower(replace(p_name, ' ', '.')) || '@example.test',
          '012-3456789', '900101-10-1234',
          'Syarikat Lama Sdn Bhd', 'Accounts assistant', 4200,
          p_notice, case when p_referrer is null then 'jobstreet'
                         else 'referral' end,
          p_referrer, 'offer')
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- What the applicant record already knew
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Ambil Kerja Sdn Bhd');
  v_req  uuid;
  v_app  uuid;
  v_emp  uuid;
  v_row  public.employees;
  v_said text;
begin
  v_req := pg_temp.hi_req(v_org, 'REQ-1', 1);
  v_app := pg_temp.hi_applicant(v_org, 'Nurul Aina', v_req);

  -- The label on its own is the thing that used to happen.
  begin
    update public.applicants set status = 'hired' where id = v_app;
    raise exception 'FAIL: an applicant was hired with nobody on the payroll';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('hired means somebody is on the payroll',
    v_said like '%not when the label says so%');

  v_emp := public.hire_applicant(v_app, 'E-100', current_date + 14, 4500,
    date '1990-01-01');

  select * into v_row from public.employees where id = v_emp;
  perform pg_temp.check_eq('the name comes across', v_row.full_name,
    'Nurul Aina');
  perform pg_temp.check_eq('and the phone number nobody retypes',
    v_row.phone, '012-3456789');
  perform pg_temp.check_eq('and the NRIC, which is the one worth not '
    'retyping', v_row.nric, '900101-10-1234');
  perform pg_temp.check_eq('and the email',
    v_row.email, 'nurul.aina@example.test');
  perform pg_temp.check_eq('the salary agreed, not the one expected',
    v_row.basic_salary, 4500);
  perform pg_temp.check_eq('the employment type from the requisition',
    v_row.employment_type::text, 'contract');
  perform pg_temp.check_eq('and they start on probation',
    v_row.employment_status::text, 'probation');

  perform pg_temp.check_eq('the two records are linked',
    (select hired_employee_id from public.applicants where id = v_app),
    v_emp);
  perform pg_temp.check_eq('and the applicant is hired',
    (select status::text from public.applicants where id = v_app), 'hired');
  perform pg_temp.check_eq('with the move kept as history',
    (select count(*) from public.applicant_stage_history
      where applicant_id = v_app and to_status = 'hired'), 1);

  -- The requisition was for one and it has been taken.
  perform pg_temp.check_eq('the requisition is filled',
    (select status::text from public.job_requisitions where id = v_req),
    'filled');
  perform pg_temp.check_eq('on the day it was taken',
    (select closed_date from public.job_requisitions where id = v_req)::text,
    ((now() at time zone 'Asia/Kuala_Lumpur')::date)::text);

  -- Twice is the mistake the link exists to make impossible.
  begin
    perform public.hire_applicant(v_app, 'E-101', current_date + 30, 4500);
    raise exception 'FAIL: the same candidate was hired twice';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and nobody is hired twice',
    v_said like '%already been hired%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Notice owed to somebody else
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Notis Sebulan Sdn Bhd');
  v_app   uuid;
  v_app2  uuid;
  v_emp   uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_app  := pg_temp.hi_applicant(v_org, 'Tan Wei Ling', null, 30);
  v_app2 := pg_temp.hi_applicant(v_org, 'Lim Chee Keong', null, 30);

  begin
    perform public.hire_applicant(v_app, 'E-1', v_today + 7, 5000);
    raise exception 'FAIL: somebody started inside their notice period';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a start date inside the notice is refused',
    v_said like '%owes 30 days%');
  perform pg_temp.check_true('and the message says the earliest day',
    v_said like '%' || to_char(v_today + 30, 'DD Mon YYYY') || '%');
  perform pg_temp.check_true('and there is a way through',
    v_said like '%bought out%');

  -- The way through, which is what keeps the refusal honest: notice
  -- does get waived, and a refusal with none is how somebody puts the
  -- wrong date in to get past the screen.
  v_emp := public.hire_applicant(v_app, 'E-1', v_today + 7, 5000, null,
    null, null, null, 'Notice bought out by us.');
  perform pg_temp.check_eq('and saying why lets the date stand',
    (select hire_date from public.employees where id = v_emp)::text,
    (v_today + 7)::text);
  perform pg_temp.check_eq('with the reason kept in the history',
    (select note from public.applicant_stage_history
      where applicant_id = v_app and to_status = 'hired'),
    'Notice bought out by us.');

  -- Hiring the same person again, with no requisition in the way to
  -- refuse it first. The link is what makes this impossible.
  begin
    perform public.hire_applicant(v_app, 'E-9', v_today + 60, 5000);
    raise exception 'FAIL: the same candidate was hired twice';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nobody is hired twice',
    v_said like '%already been hired%');
  perform pg_temp.check_true('and the second employee record was never made',
    (select count(*) from public.employees
      where org_id = v_org and employee_no = 'E-9') = 0);

  -- After the notice runs out, no note is needed.
  v_emp := public.hire_applicant(v_app2, 'E-2', v_today + 45, 5000);
  perform pg_temp.check_eq('a date past the notice needs no explaining',
    (select hire_date from public.employees where id = v_emp)::text,
    (v_today + 45)::text);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A requisition has a number of places
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Dua Kekosongan Sdn Bhd');
  v_req  uuid;
  v_a1   uuid;
  v_a2   uuid;
  v_a3   uuid;
  v_said text;
begin
  v_req := pg_temp.hi_req(v_org, 'REQ-2', 2);
  v_a1 := pg_temp.hi_applicant(v_org, 'One', v_req);
  v_a2 := pg_temp.hi_applicant(v_org, 'Two', v_req);
  v_a3 := pg_temp.hi_applicant(v_org, 'Three', v_req);

  perform public.hire_applicant(v_a1, 'E-1', current_date, 4000);
  perform pg_temp.check_eq('one of two filled leaves it open',
    (select status::text from public.job_requisitions where id = v_req),
    'open');
  perform pg_temp.check_true('and unclosed',
    (select closed_date is null from public.job_requisitions
      where id = v_req));

  perform public.hire_applicant(v_a2, 'E-2', current_date, 4000);
  perform pg_temp.check_eq('the second closes it',
    (select status::text from public.job_requisitions where id = v_req),
    'filled');

  begin
    perform public.hire_applicant(v_a3, 'E-3', current_date, 4000);
    raise exception 'FAIL: a third was hired against two positions';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a third has nowhere to go',
    v_said like '%2 position(s) and 2 have been filled%');
  perform pg_temp.check_true('with the way through named',
    v_said like '%Raise the headcount%');

  -- Which is the way through.
  update public.job_requisitions set headcount = 3, status = 'open'
   where id = v_req;
  perform pg_temp.check_true('raising it lets the third through',
    public.hire_applicant(v_a3, 'E-3', current_date, 4000) is not null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who introduced them
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Kenalan Sdn Bhd');
  v_mei  uuid;
  v_ali  uuid;
  v_a1   uuid;
  v_a2   uuid;
  v_a3   uuid;
  r      record;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'E1', 'Mei', date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_mei;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'E2', 'Ali', date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_ali;

  v_a1 := pg_temp.hi_applicant(v_org, 'Introduced One', null, null, v_mei);
  v_a2 := pg_temp.hi_applicant(v_org, 'Introduced Two', null, null, v_mei);
  v_a3 := pg_temp.hi_applicant(v_org, 'Introduced Three', null, null, v_ali);

  perform public.hire_applicant(v_a1, 'E-100', current_date, 4000);

  select * into r from public.report_referral_hires(v_org);
  perform pg_temp.check_eq('the referrer with a hire comes first',
    r.referrer_name, 'Mei');
  perform pg_temp.check_eq('and their hires are counted', r.hires, 1);
  -- Both counts, because a scheme that shows only hires cannot tell
  -- somebody who introduced two and had one taken on from somebody who
  -- introduced one and had none.
  perform pg_temp.check_eq('beside everybody they introduced',
    r.candidates, 2);

  perform pg_temp.check_eq('somebody who introduced nobody who was hired '
    'is still named',
    (select hires from public.report_referral_hires(v_org)
      where referrer_name = 'Ali'), 0);
  perform pg_temp.check_eq('with their candidate counted',
    (select candidates from public.report_referral_hires(v_org)
      where referrer_name = 'Ali'), 1);

  -- Dated, because a referral scheme pays for a quarter.
  perform pg_temp.check_eq('and the window is honoured',
    (select count(*) from public.report_referral_hires(
       v_org, current_date + 1)), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What will not be hired
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Tidak Boleh Sdn Bhd');
  v_app  uuid;
  v_old  uuid;
  v_ref  uuid;
  v_out  uuid := pg_temp.another_user('outsider@hire.test');
  v_said text;
begin
  v_app := pg_temp.hi_applicant(v_org, 'Somebody');

  -- A row exactly as one stood before this rule: marked hired with
  -- nothing on the payroll. Refusing every later edit to these would
  -- mean a note could not be corrected because of a link nobody could
  -- have made at the time, so the trigger is turned off to make one.
  alter table public.applicants disable trigger applicants_hire_ck;
  insert into public.applicants (org_id, full_name, status, notes)
  values (v_org, 'Hired long ago', 'hired', 'Started in March')
  returning id into v_old;
  alter table public.applicants enable trigger applicants_hire_ck;

  update public.applicants set notes = 'Started in April' where id = v_old;
  perform pg_temp.check_eq('a record made before this rule stays editable',
    (select notes from public.applicants where id = v_old),
    'Started in April');

  update public.applicants set status = 'withdrawn' where id = v_app;
  begin
    perform public.hire_applicant(v_app, 'E-1', current_date, 4000);
    raise exception 'FAIL: somebody who withdrew was hired anyway';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a withdrawn candidate is put back first',
    v_said like '%back in the pipeline%');
  update public.applicants set status = 'offer' where id = v_app;

  begin
    perform public.hire_applicant(v_app, '   ', current_date, 4000);
    raise exception 'FAIL: a hire had no employee number';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform public.hire_applicant(v_app, 'E-1', null, 4000);
    raise exception 'FAIL: a hire had no start date';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform public.hire_applicant(gen_random_uuid(), 'E-1', current_date, 4000);
    raise exception 'FAIL: a candidate who does not exist was hired';
  exception when sqlstate 'P0002' then null;
  end;

  -- Somebody referred, so "empty to them" is an assertion about who is
  -- asking and not about an empty company.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'E9', 'The referrer', date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_ref;
  perform pg_temp.hi_applicant(v_org, 'Introduced', null, null, v_ref);
  perform pg_temp.check_eq('the company''s own HR sees the referral',
    (select count(*) from public.report_referral_hires(v_org)), 1);

  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.hire_applicant(v_app, 'E-1', current_date, 4000);
    raise exception 'FAIL: an outsider hired somebody';
  exception when sqlstate '42501' then null;
  end;
  perform pg_temp.check_eq('and the referral report is empty to them',
    (select count(*) from public.report_referral_hires(v_org)), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('hiring is closed to anon',
    not has_function_privilege('anon',
      'public.hire_applicant(uuid, text, date, numeric, date, uuid, uuid, '
      'uuid, text)', 'execute'));
  perform pg_temp.check_true('and the referral report',
    not has_function_privilege('anon',
      'public.report_referral_hires(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may hire',
    has_function_privilege('authenticated',
      'public.hire_applicant(uuid, text, date, numeric, date, uuid, uuid, '
      'uuid, text)', 'execute'));
end $$;

rollback;

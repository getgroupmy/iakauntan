-- =====================================================================
-- iAkauntan :: a manager sees the person, not the record (0869)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/employee_record_withheld.sql
--
-- A line manager who is neither HR nor payroll read each report's whole
-- employee row: salary, NRIC, bank account, address, date of birth and
-- the rest. They keep the person -- name, position, contact, dates --
-- and the record goes to HR, payroll and the employee themselves.
-- Asked with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_er (org uuid, other uuid, mgr_user uuid,
  aminah_user uuid, hr uuid, payroll uuid, bystander uuid,
  mgr uuid, aminah uuid, theirs uuid);
grant select on t_er to authenticated;

do $$
declare r t_er;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Pasukan Rekod Sdn Bhd');
  r.other := pg_temp.test_org('Pasukan Lain Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select o, 'hr', true from unnest(array[r.org, r.other]) o
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.mgr_user    := pg_temp.another_user('ketua@pasukanrekod.test');
  r.aminah_user := pg_temp.another_user('aminah@pasukanrekod.test');
  r.hr          := pg_temp.another_user('hr@pasukanrekod.test');
  r.payroll     := pg_temp.another_user('akaun@pasukanrekod.test');
  r.bystander   := pg_temp.another_user('lain@pasukanrekod.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.mgr_user, 'sales', 'active'),
         (r.org, r.aminah_user, 'employee', 'active'),
         (r.org, r.hr, 'hr_manager', 'active'),
         (r.org, r.payroll, 'accountant', 'active'),
         (r.org, r.bystander, 'sales', 'active');

  insert into public.employees (org_id, employee_no, full_name, user_id,
     basic_salary, hire_date)
  values (r.org, 'E1', 'Ketua Jualan', r.mgr_user, 9000, pg_temp.today())
  returning id into r.mgr;
  insert into public.employees (org_id, employee_no, full_name, user_id,
     manager_id, email, basic_salary, nric, bank_name, bank_account_no,
     address_line1, date_of_birth, hire_date)
  values (r.org, 'E2', 'Aminah binti Ali', r.aminah_user, r.mgr,
     'aminah@pasukanrekod.test', 3800, '900101-14-5678', 'Maybank',
     '1122334455', '12 Jalan Mawar', '1990-01-01', pg_temp.today())
  returning id into r.aminah;
  insert into public.employees (org_id, employee_no, full_name,
     basic_salary, hire_date)
  values (r.other, 'X1', 'Orang Lain', 5000, pg_temp.today())
  returning id into r.theirs;
  insert into t_er select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The manager: the person, and none of the record
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select mgr_user from t_er));
set local role authenticated;

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_true('the premise: the manager is neither HR nor payroll, and manages Aminah',
    not app.can_manage_hr(d.org) and not app.can_run_payroll(d.org)
    and app.manages_employee(d.aminah));
  perform pg_temp.check_eq('the manager reads who Aminah is and where she sits',
    (select employee_no || ' / ' || full_name || ' / ' || email || ' / '
            || (manager_id = d.mgr)::text || ' / ' || employment_status
       from public.employees where id = d.aminah),
    'E2 / Aminah binti Ali / aminah@pasukanrekod.test / true / probation');
  perform pg_temp.check_refused('and not her salary',
    format('select basic_salary from public.employees where id = %L', d.aminah),
    '%permission denied%', '42501');
  perform pg_temp.check_refused('nor her NRIC',
    format('select nric from public.employees where id = %L', d.aminah),
    '%permission denied%', '42501');
  perform pg_temp.check_refused('nor her bank account',
    format('select bank_account_no from public.employees where id = %L', d.aminah),
    '%permission denied%', '42501');
  perform pg_temp.check_refused('nor the whole row at once',
    'select * from public.employees', '%permission denied%', '42501');
  perform pg_temp.check_eq('and the function gives him nothing of hers',
    (select count(*) from public.employee_private_fields(d.org, d.aminah))::int, 0);
  perform pg_temp.check_eq('but his own record, his own',
    (select string_agg((fields ->> 'basic_salary'), ',')
       from public.employee_private_fields(d.org)), '9000.00');
end $$;

reset role;

-- A member who manages nobody is not given Aminah's row at all, as before.
select pg_temp.sign_in_as((select bystander from t_er));
set local role authenticated;

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_eq('a member who manages nobody reads no employee',
    (select count(*) from public.employees where org_id = d.org)::int, 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Aminah reads her own record
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select aminah_user from t_er));
set local role authenticated;

do $$
declare d t_er; v jsonb;
begin
  select * into d from t_er;
  select fields into v from public.employee_private_fields(d.org, d.aminah);
  perform pg_temp.check_eq('Aminah reads her own salary, NRIC, bank and address',
    v ->> 'basic_salary' || ' / ' || (v ->> 'nric') || ' / '
      || (v ->> 'bank_account_no') || ' / ' || (v ->> 'address_line1'),
    '3800.00 / 900101-14-5678 / 1122334455 / 12 Jalan Mawar');
  perform pg_temp.check_eq('and only her own',
    (select count(*) from public.employee_private_fields(d.org))::int, 1);
  perform pg_temp.check_true('and the object holds none of the columns anybody may read',
    not (v ? 'full_name') and not (v ? 'employee_no') and not (v ? 'id'));
end $$;

reset role;

-- ---------------------------------------------------------------------
-- HR and payroll read every record
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select hr from t_er));
set local role authenticated;

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_eq('HR reads both records, salaries and all',
    (select string_agg(e.employee_no || ' ' || (p.fields ->> 'basic_salary'), ', '
                       order by e.employee_no)
       from public.employee_private_fields(d.org) p
       join public.employees e on e.id = p.employee_id),
    'E1 9000.00, E2 3800.00');
  perform pg_temp.check_eq('and nothing of a company HR is not in',
    (select count(*) from public.employee_private_fields(d.other))::int, 0);
  -- And keeps the record: an update and an insert are not selects.
  update public.employees set basic_salary = 4000 where id = d.aminah;
  insert into public.employees (org_id, employee_no, full_name, basic_salary, hire_date)
  values (d.org, 'E3', 'Baru', 2500, pg_temp.today());
  perform pg_temp.check_eq('and still sets a salary and takes somebody on',
    (select string_agg(e.employee_no || ' ' || (p.fields ->> 'basic_salary'), ', '
                       order by e.employee_no)
       from public.employee_private_fields(d.org) p
       join public.employees e on e.id = p.employee_id),
    'E1 9000.00, E2 4000.00, E3 2500.00');
end $$;

reset role;

select pg_temp.sign_in_as((select payroll from t_er));
set local role authenticated;

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_true('the premise: the accountant runs payroll and is not HR',
    app.can_run_payroll(d.org) and not app.can_manage_hr(d.org));
  perform pg_temp.check_eq('payroll reads every record''s bank account',
    (select string_agg(coalesce(fields ->> 'bank_account_no', '-'), ', ')
       from public.employee_private_fields(d.org)),
    '-, 1122334455, -');
end $$;

reset role;

-- A company that has stopped paying for HR shows nobody its records, as
-- the table's own module gate does.
update public.org_modules set is_enabled = false
 where org_id = (select org from t_er) and module_code = 'hr';

select pg_temp.sign_in_as((select hr from t_er));
set local role authenticated;

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_eq('with HR switched off, HR reads no record either',
    (select count(*) from public.employee_private_fields(d.org))::int, 0);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon calls nothing and reads nothing',
    not has_function_privilege('anon', 'public.employee_private_fields(uuid, uuid)', 'execute')
    and not has_column_privilege('anon', 'public.employees', 'basic_salary', 'select'));
end $$;

rollback;

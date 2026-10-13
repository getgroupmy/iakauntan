-- =====================================================================
-- iAkauntan :: a pay band is HR's (0863)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pay_bands_withheld.sql
--
-- Every member read `positions`, and with it each role's salary band.
-- The position stays everybody's; the band is HR's. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pb (org uuid, other uuid, sales uuid, hr uuid, pos uuid);
grant select on t_pb to authenticated;

do $$
declare r t_pb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Jawatan Sdn Bhd');
  r.other := pg_temp.test_org('Jawatan Lain Sdn Bhd');
  r.sales := pg_temp.another_user('sales@jawatan.test');
  r.hr := pg_temp.another_user('hr@jawatan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.hr, 'hr_manager', 'active');
  insert into public.positions (org_id, code, title, grade, min_salary, max_salary)
  values (r.org, 'FM', 'Finance Manager', 'M2', 9000, 14000) returning id into r.pos;
  insert into public.positions (org_id, code, title, min_salary, max_salary)
  values (r.other, 'XX', 'Elsewhere', 1, 2);
  insert into t_pb select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_pb), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_pb;
begin
  select * into d from t_pb;
  perform pg_temp.check_true('the premise: the salesman does not manage HR',
    not app.can_manage_hr(d.org));
  perform pg_temp.check_eq('the salesman still reads the position, its title and grade',
    (select title || ' / ' || grade from public.positions where id = d.pos),
    'Finance Manager / M2');
  perform pg_temp.check_refused('but not what it pays',
    format('select min_salary from public.positions where id = %L', d.pos),
    'permission denied for table positions', '42501');
  perform pg_temp.check_refused('nor the top of the band',
    format('select max_salary from public.positions where id = %L', d.pos),
    'permission denied for table positions', '42501');
  perform pg_temp.check_eq('nor through the function that serves it',
    (select count(*) from public.position_salary_bands(d.org))::int, 0);
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select hr from t_pb), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_pb;
begin
  select * into d from t_pb;
  perform pg_temp.check_refused('a select of every column is refused to HR too',
    format('select * from public.positions where id = %L', d.pos),
    'permission denied for table positions', '42501');
  -- The list `Repo.positions` names in `repository.dart`, word for word.
  perform pg_temp.check_eq('while the columns the app names are read',
    (select count(*) from (
       select id, org_id, code, title, department_id, grade,
              job_description, is_active, created_at, import_source,
              import_ref, import_batch_id, imported_at
         from public.positions where org_id = d.org) x)::int, 1);
  perform pg_temp.check_eq('and HR is given the band through the function',
    (select min_salary || ' - ' || max_salary
       from public.position_salary_bands(d.org) where position_id = d.pos),
    '9000.00 - 14000.00');
  perform pg_temp.check_eq('this company''s positions, and no other''s',
    (select count(*) from public.position_salary_bands(d.other))::int, 0);

  -- The setup screen's own writes: an update and an insert that ask for
  -- no row back, as `saveSetupRow` sends them.
  update public.positions set max_salary = 15000 where id = d.pos;
  insert into public.positions (org_id, code, title, min_salary, max_salary)
  values (d.org, 'AC', 'Accountant', 5000, 8000);
  perform pg_temp.check_eq('and HR still sets the band from the setup screen',
    (select string_agg(max_salary::text, ',' order by max_salary)
       from public.position_salary_bands(d.org)), '8000.00,15000.00');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon may not call it',
    not has_function_privilege('anon', 'public.position_salary_bands(uuid)', 'execute'));
  perform pg_temp.check_true('nor read the table at all',
    not has_any_column_privilege('anon', 'public.positions', 'select'));
end $$;

rollback;

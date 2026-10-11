-- =====================================================================
-- iAkauntan :: a leave balance is adjusted with a reason (0812)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/leave_adjustments.sql
--
-- `adjustment_days` was in the balance arithmetic and nothing wrote it,
-- so HR adjusted a balance by writing the table -- which let any column
-- be written: eight days taken were set back to nought, and sixteen
-- paid days were approved on an entitlement of eight. Now
-- `adjust_leave_balance` is the only road, HR's, with a reason kept
-- beside the change, and the balance itself is read-only to clients.
-- Asked as HR and as the employee, each with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_la (
  org uuid, hr uuid, staff uuid, emp uuid, al uuid, theirs uuid);
grant select on t_la to authenticated;

do $$
declare
  r       t_la;
  v_them  uuid;
begin
  perform pg_temp.allow_many_companies();
  r.hr := pg_temp.test_user();
  r.org := pg_temp.test_org('Cuti Sebab Sdn Bhd');
  perform pg_temp.sign_in_as(r.hr);
  r.staff := pg_temp.another_user('staff@cutisebab.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.staff, 'viewer', 'active');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id)
  values (r.org, 'E2', 'Encik Zul', date '2021-01-01', 4000,
          date '1995-01-01', 'citizen', r.staff)
  returning id into r.emp;
  insert into public.leave_types (org_id, code, name, is_paid)
  values (r.org, 'AL', 'Annual leave', true) returning id into r.al;
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (r.org, r.emp, r.al, 2026, 8);

  -- Another company's kind of leave, for the refusal below.
  v_them := pg_temp.test_org('Syarikat Sebelah Sdn Bhd');
  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_them, 'AL', 'Annual leave', true) returning id into r.theirs;
  perform pg_temp.sign_in_as(r.hr);

  insert into t_la select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select hr from t_la), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The balance is the functions'
-- =====================================================================
do $$
declare
  d     t_la;
  v_req uuid;
begin
  select * into d from t_la;
  perform pg_temp.check_eq('HR asks as a client', current_user, 'authenticated');

  v_req := public.submit_leave_request(d.org, d.al, date '2026-04-06',
    date '2026-04-15', 8, 'Holiday', false, null, d.emp);
  perform public.decide_leave_request(v_req, true, 'ok');
  perform pg_temp.check_eq('eight days entitled, eight taken',
    (select taken_days from public.leave_balances where employee_id = d.emp), 8::numeric);
  perform pg_temp.check_refused('so a ninth is refused',
    format($q$select public.submit_leave_request(%L, %L, date '2026-05-04',
              date '2026-05-04', 1, 'More', false, null, %L)$q$, d.org, d.al, d.emp),
    'Only 0.00 day(s) of Annual leave remain; this request is for 1');

  -- What was measured: the taken days set back by hand.
  perform pg_temp.check_refused('the days taken are not set back by hand',
    format('update public.leave_balances set taken_days = 0 where employee_id = %L', d.emp),
    'permission denied for table leave_balances', '42501');
  perform pg_temp.check_refused('nor the entitlement raised by hand',
    format('update public.leave_balances set entitled_days = 30 where employee_id = %L', d.emp),
    'permission denied for table leave_balances', '42501');
  perform pg_temp.check_refused('nor a balance typed in for a year',
    format($q$insert into public.leave_balances
                (org_id, employee_id, leave_type_id, leave_year, entitled_days)
              values (%L, %L, %L, 2027, 30)$q$, d.org, d.emp, d.al),
    'permission denied for table leave_balances', '42501');
  perform pg_temp.check_refused('nor one deleted',
    format('delete from public.leave_balances where employee_id = %L', d.emp),
    'permission denied for table leave_balances', '42501');
  perform pg_temp.check_refused('nor the record of an adjustment written by hand',
    format($q$insert into public.leave_balance_adjustments
                (org_id, employee_id, leave_type_id, leave_year, days, reason)
              values (%L, %L, %L, 2026, 5, 'by hand')$q$, d.org, d.emp, d.al),
    'permission denied for table leave_balance_adjustments', '42501');
end $$;

-- =====================================================================
-- Adjusted through the function, with a reason
-- =====================================================================
do $$
declare
  d      t_la;
  v_left numeric;
begin
  select * into d from t_la;

  v_left := public.adjust_leave_balance(d.emp, d.al, 2026, 2,
    'Replacement leave for working the Hari Raya weekend');
  perform pg_temp.check_eq('two days added leave two to take', v_left, 2::numeric);
  perform pg_temp.check_eq('and are on the balance as an adjustment',
    (select adjustment_days from public.leave_balances
      where employee_id = d.emp and leave_year = 2026), 2::numeric);
  perform pg_temp.check_true('kept with who, how many and why',
    (select a.days = 2 and a.adjusted_by = d.hr
            and a.reason = 'Replacement leave for working the Hari Raya weekend'
            and a.org_id = d.org and a.leave_year = 2026
       from public.leave_balance_adjustments a where a.employee_id = d.emp));
  perform pg_temp.check_true('so a ninth day can now be filed',
    public.submit_leave_request(d.org, d.al, date '2026-05-04',
      date '2026-05-04', 1, 'Replacement', false, null, d.emp) is not null);

  v_left := public.adjust_leave_balance(d.emp, d.al, 2026, -0.5,
    '  Half a day granted twice  ');
  perform pg_temp.check_eq('an adjustment takes days away as well', v_left, 0.5::numeric);
  perform pg_temp.check_eq('both are kept, in their own rows',
    (select count(*)::integer from public.leave_balance_adjustments where employee_id = d.emp), 2);
  perform pg_temp.check_true('and the reason is kept without its spaces',
    exists (select 1 from public.leave_balance_adjustments
             where employee_id = d.emp and reason = 'Half a day granted twice'));

  -- A year with no balance yet gets one, holding only the adjustment.
  v_left := public.adjust_leave_balance(d.emp, d.al, 2027, 3, 'Carried by agreement');
  perform pg_temp.check_eq('and says what that year has left', v_left, 3::numeric);
  perform pg_temp.check_true('a year with no balance is given one, of the adjustment',
    (select adjustment_days = 3 and entitled_days = 0 and taken_days = 0
       from public.leave_balances where employee_id = d.emp and leave_year = 2027));
  perform pg_temp.check_eq('and the 2026 balance is not touched by it',
    (select adjustment_days from public.leave_balances
      where employee_id = d.emp and leave_year = 2026), 1.5::numeric);

  perform pg_temp.check_refused('an adjustment without a reason is refused',
    format('select public.adjust_leave_balance(%L, %L, 2026, 1, %L)', d.emp, d.al, '   '),
    'Say why the balance is being adjusted.%', '23514');
  perform pg_temp.check_refused('so is one of no days',
    format('select public.adjust_leave_balance(%L, %L, 2026, 0, %L)', d.emp, d.al, 'Nothing'),
    'An adjustment of no days adjusts nothing.', '23514');
  perform pg_temp.check_refused('and another company''s kind of leave',
    format('select public.adjust_leave_balance(%L, %L, 2026, 1, %L)', d.emp, d.theirs, 'Theirs'),
    'That kind of leave is not one of this company''s.', '23503');
  perform pg_temp.check_refused('and an employee who is not there',
    format('select public.adjust_leave_balance(%L, %L, 2026, 1, %L)', gen_random_uuid(), d.al, 'Nobody'),
    'No such employee.', 'P0002');
end $$;

-- =====================================================================
-- The employee reads it, and does not make it
-- =====================================================================
select set_config('request.jwt.claims',
  json_build_object('sub', (select staff from t_la), 'role', 'authenticated')::text, true);

do $$
declare d t_la;
begin
  select * into d from t_la;
  perform pg_temp.check_true('the employee is not HR', not app.can_manage_hr(d.org));
  perform pg_temp.check_eq('and reads why their balance moved',
    (select count(*)::integer from public.leave_balance_adjustments where employee_id = d.emp), 3);
  perform pg_temp.check_refused('but does not adjust it',
    format('select public.adjust_leave_balance(%L, %L, 2026, 10, %L)', d.emp, d.al, 'Mine'),
    'Only HR may adjust a leave balance.', '42501');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the balance or its adjustments',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('leave_balances', 'leave_balance_adjustments')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;

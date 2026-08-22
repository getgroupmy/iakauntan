-- =====================================================================
-- iAkauntan :: closing the day, and which overtime it was
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/clock_out.sql
--
-- attendance.sql covers clock_in. clock_out was called by nothing, and
-- it is the half that does the arithmetic: how long somebody worked,
-- how much of that was overtime, and -- the part with a statute behind
-- it -- which kind of overtime.
--
-- calculate_payroll_run multiplies the three columns clock_out writes
-- by three different rates:
--
--   ot_normal_minutes   x 1.5
--   ot_restday_minutes  x 2.0
--   ot_holiday_minutes  x 3.0
--
-- (Employment Act 1955: s.60A for ordinary overtime, s.60 for a rest
-- day, s.60D for a public holiday.) payroll_run.sql asserts what
-- payroll does with those minutes; nothing asserted that the right
-- column gets them. Two hours put in the normal column on a public
-- holiday is half the pay the Act requires, and it arrives as a
-- perfectly ordinary-looking payslip.
--
-- worked_minutes is `now() - clock_in`, and now() is fixed for the
-- transaction, so setting clock_in to a chosen distance back makes
-- every number below exact rather than approximate.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Punch in, then move the punch back by a chosen number of minutes, so
-- the elapsed time clock_out measures is the one the case intends.
create or replace function pg_temp.punched(p_org uuid, p_minutes integer)
returns uuid language plpgsql as $$
declare v_id uuid; v_emp uuid;
begin
  v_emp := app.my_employee_id(p_org);
  delete from public.attendance_records
   where employee_id = v_emp
     and work_date = (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_id := public.clock_in(p_org_id => p_org, p_method => 'web');
  -- late_minutes is clock_in's arithmetic, against the shift's start
  -- time and the hour the file happens to run at -- attendance.sql
  -- covers it. Zeroed here so the status assertions below are about
  -- the holiday and rest day routing and not about what time it is.
  update public.attendance_records
     set clock_in = now() - make_interval(mins => p_minutes),
         late_minutes = 0
   where id = v_id;
  return v_id;
end;
$$;

do $$
declare
  v_org     uuid;
  v_user    uuid := pg_temp.test_user();
  v_emp     uuid;
  v_other   uuid;
  v_e_other uuid;
  v_shift   uuid;
  v_today   date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_id      uuid;
  j         jsonb;
  r         record;
  v_took    boolean;
begin
  v_org := pg_temp.test_org('Syif Sdn Bhd');
  perform pg_temp.sign_in_as(v_user);

  insert into public.employees
    (org_id, employee_no, user_id, full_name, hire_date, employment_status)
  values (v_org, 'E1', v_user, 'Fixture Employee',
          current_date - 30, 'active')
  returning id into v_emp;

  -- Nine to five with an hour off: 480 minutes of shift, 420 scheduled.
  -- work_days is 1-5, so the rest-day case below turns on today's own
  -- day of week rather than on a hardcoded date.
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, break_minutes, work_days)
  values (v_org, 'GEN', 'General', time '09:00', time '17:00', 60,
          array[0,1,2,3,4,5,6])
  returning id into v_shift;
  insert into public.employee_shifts
    (org_id, employee_id, shift_id, effective_from)
  values (v_org, v_emp, v_shift, current_date - 30);

  -- ==================================================================
  -- An ordinary long day
  -- ==================================================================
  v_id := pg_temp.punched(v_org, 600);          -- ten hours ago
  j := public.clock_out(p_org_id => v_org);

  perform pg_temp.check_eq('ten hours less the break is nine worked',
    (j ->> 'worked_minutes')::integer, 540);
  perform pg_temp.check_eq('the shift is seven hours of it',
    (j ->> 'scheduled_minutes')::integer, 420);
  perform pg_temp.check_eq('so two hours are overtime',
    (j ->> 'overtime_minutes')::integer, 120);

  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('and the row agrees with what was returned',
    r.worked_minutes, 540);
  perform pg_temp.check_true('the clock-out time is recorded',
    r.clock_out is not null);
  -- The assertion this file exists for.
  perform pg_temp.check_eq('an ordinary day puts them in the normal column',
    r.ot_normal_minutes, 120);
  perform pg_temp.check_eq('not the rest day column', r.ot_restday_minutes, 0);
  perform pg_temp.check_eq('nor the holiday column', r.ot_holiday_minutes, 0);
  perform pg_temp.check_eq('and the day is an ordinary one',
    r.status::text, 'present');
  perform pg_temp.check_eq('nothing was left early', r.early_leave_minutes, 0);

  -- And somebody who arrived late is marked late, on an otherwise
  -- ordinary day. The minutes come from clock_in; what clock_out does
  -- is let them decide the status.
  v_id := pg_temp.punched(v_org, 600);
  update public.attendance_records set late_minutes = 15 where id = v_id;
  perform public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('a late arrival is recorded as late',
    r.status::text, 'late');
  perform pg_temp.check_eq('and still earns ordinary overtime',
    r.ot_normal_minutes, 120);

  -- ==================================================================
  -- The same hours on a public holiday
  -- ==================================================================
  insert into public.public_holidays (org_id, holiday_date, name, is_working)
  values (v_org, v_today, 'Hari Probe', false);

  v_id := pg_temp.punched(v_org, 600);
  perform public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;

  perform pg_temp.check_eq('the same two hours on a holiday go to the holiday column',
    r.ot_holiday_minutes, 120);
  perform pg_temp.check_eq('and not to the normal one', r.ot_normal_minutes, 0);
  perform pg_temp.check_eq('nor the rest day one', r.ot_restday_minutes, 0);
  perform pg_temp.check_eq('the day is recorded as a public holiday',
    r.status::text, 'public_holiday');

  -- A holiday the company works through is not a holiday for this.
  update public.public_holidays set is_working = true
   where org_id = v_org and holiday_date = v_today;
  v_id := pg_temp.punched(v_org, 600);
  perform public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('a holiday the company works through pays as normal',
    r.ot_normal_minutes, 120);
  perform pg_temp.check_eq('with nothing at holiday rate', r.ot_holiday_minutes, 0);
  delete from public.public_holidays
   where org_id = v_org and holiday_date = v_today;

  -- ==================================================================
  -- A rest day
  --
  -- The shift's work_days is narrowed to exclude today, whatever today
  -- happens to be, so the file does not depend on the day it is run.
  -- ==================================================================
  update public.work_shifts
     set work_days = array(select d from generate_series(0, 6) d
                            where d <> extract(dow from v_today)::integer)
   where id = v_shift;

  v_id := pg_temp.punched(v_org, 600);
  perform public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('a day off worked is rest day overtime',
    r.ot_restday_minutes, 120);
  perform pg_temp.check_eq('and not ordinary overtime', r.ot_normal_minutes, 0);
  perform pg_temp.check_eq('the day is recorded as a rest day',
    r.status::text, 'rest_day');

  -- A public holiday that falls on a rest day is paid as the holiday,
  -- which is the higher of the two.
  insert into public.public_holidays (org_id, holiday_date, name, is_working)
  values (v_org, v_today, 'Hari Probe', false);
  v_id := pg_temp.punched(v_org, 600);
  perform public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('a holiday falling on a rest day pays as the holiday',
    r.ot_holiday_minutes, 120);
  perform pg_temp.check_eq('and not twice', r.ot_restday_minutes, 0);
  delete from public.public_holidays
   where org_id = v_org and holiday_date = v_today;
  update public.work_shifts set work_days = array[0,1,2,3,4,5,6]
   where id = v_shift;

  -- ==================================================================
  -- Going home early, and having no shift at all
  -- ==================================================================
  v_id := pg_temp.punched(v_org, 120);          -- two hours ago
  j := public.clock_out(p_org_id => v_org);
  select * into r from public.attendance_records where id = v_id;
  perform pg_temp.check_eq('two hours less the break is one worked',
    r.worked_minutes, 60);
  perform pg_temp.check_eq('which is six hours short', r.early_leave_minutes, 360);
  perform pg_temp.check_eq('and no overtime at all', r.ot_normal_minutes, 0);
  perform pg_temp.check_eq('the return says the same',
    (j ->> 'overtime_minutes')::integer, 0);

  -- With no shift assigned the day is assumed to be eight hours, and
  -- there is no break to take off because there is no shift to take it
  -- from.
  delete from public.employee_shifts where employee_id = v_emp;
  v_id := pg_temp.punched(v_org, 600);
  j := public.clock_out(p_org_id => v_org);
  perform pg_temp.check_eq('with no shift the day is eight hours',
    (j ->> 'scheduled_minutes')::integer, 480);
  perform pg_temp.check_eq('and the whole ten hours count as worked',
    (j ->> 'worked_minutes')::integer, 600);
  perform pg_temp.check_eq('leaving two hours over',
    (j ->> 'overtime_minutes')::integer, 120);
  insert into public.employee_shifts
    (org_id, employee_id, shift_id, effective_from)
  values (v_org, v_emp, v_shift, current_date - 30);

  -- ==================================================================
  -- What it refuses
  -- ==================================================================
  delete from public.attendance_records
   where employee_id = v_emp and work_date = v_today;
  begin
    perform public.clock_out(p_org_id => v_org);
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('there has to be a clock-in to close',
    not v_took);

  -- Somebody who is not HR cannot close another person's day, and is
  -- told so. Before 0285 this comparison went null for a caller with no
  -- employee record, control fell to the else branch, and they were
  -- told their own record was missing -- an answer about the wrong
  -- person.
  v_other := pg_temp.another_user('outsider@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_other, 'accounts_clerk', 'active');
  perform pg_temp.sign_in_as(v_other);
  begin
    perform public.clock_out(p_org_id => v_org, p_employee_id => v_emp);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('only HR closes somebody else''s day', not v_took);

  -- And with nobody named, the same caller is told what is actually
  -- wrong: they have no record of their own.
  begin
    perform public.clock_out(p_org_id => v_org);
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('and has no day of their own to close',
    not v_took);

  -- HR may -- including an HR manager who is not on the payroll, which
  -- is the case 0285 restored. Before it, an owner or an outsourced HR
  -- administrator got 'No employee record is linked to this login' and
  -- the feature was unreachable for exactly the people it is for.
  perform pg_temp.sign_in_as(v_user);
  v_id := pg_temp.punched(v_org, 600);
  perform pg_temp.sign_in_as(v_other);
  update public.org_members set role = 'hr_manager'
   where org_id = v_org and user_id = v_other;
  perform pg_temp.check_true('the HR manager is not an employee themselves',
    app.my_employee_id(v_org) is null);
  j := public.clock_out(p_org_id => v_org, p_employee_id => v_emp);
  perform pg_temp.check_eq('HR may close somebody else''s day',
    (j ->> 'overtime_minutes')::integer, 120);
  perform pg_temp.check_eq('and it is that employee''s row that moved',
    (select ot_normal_minutes from public.attendance_records where id = v_id),
    120);

  perform pg_temp.sign_out();
end $$;

rollback;

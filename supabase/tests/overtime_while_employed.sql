-- =====================================================================
-- iAkauntan :: overtime is worked while employed (0895)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/overtime_while_employed.sql
--
-- `clock_in` took any day and payroll read overtime across the whole
-- period, so a leaver clocked in after their last day was paid for it.
-- Clocked as HR and as the leaver themselves, with the role
-- `authenticated`, as the app clocks; the payroll is the owner's.
--
-- A 09:00-18:00 shift worked to 21:00 is three hours at time and a
-- half: 3,100.00 over 26 days of 8 hours is 14.9038... an hour, so
-- 67.07.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ow (org uuid, stayer uuid, leaver uuid, gone uuid,
  gone_user uuid, joiner uuid, last_day uuid, first_day uuid, run uuid);
grant select, update on t_ow to authenticated;

create or replace function pg_temp.ow_employee(p_org uuid, p_no text, p_name text,
  p_hired date, p_shift uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (p_org, p_no, p_name, p_hired, 3100, date '1992-04-15', 'single', 'citizen')
  returning id into v;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (p_org, v, p_shift, least(p_hired, pg_temp.today() - 30));
  return v;
end $$;

-- The overtime a run paid somebody: hours, and what they came to. Summed,
-- so somebody with no payslip in the run reads as none paid.
create or replace function pg_temp.ow_paid(p_run uuid, p_emp uuid)
returns text language sql as $$
  select coalesce(sum(ot_hours), 0)::numeric(10, 2) || ' hours = '
         || coalesce(sum(ot_amount), 0)::numeric(10, 2)
    from public.payslips where run_id = p_run and employee_id = p_emp;
$$;

do $$
declare r t_ow; v_shift uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Lebih Masa Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.work_shifts (org_id, code, name, start_time, end_time)
  values (r.org, 'PG', 'Pagi', '09:00', '18:00') returning id into v_shift;

  r.stayer    := pg_temp.ow_employee(r.org, 'S1', 'Kekal', date '2020-01-01', v_shift);
  r.leaver    := pg_temp.ow_employee(r.org, 'L1', 'Pergi Semalam', date '2020-01-01', v_shift);
  r.gone      := pg_temp.ow_employee(r.org, 'L2', 'Sudah Lama Pergi', date '2020-01-01', v_shift);
  r.joiner    := pg_temp.ow_employee(r.org, 'J1', 'Belum Mula', pg_temp.today() + 5, v_shift);
  r.last_day  := pg_temp.ow_employee(r.org, 'B1', 'Hari Terakhir', date '2020-01-01', v_shift);
  r.first_day := pg_temp.ow_employee(r.org, 'B2', 'Hari Pertama', pg_temp.today(), v_shift);

  r.gone_user := pg_temp.another_user('sudahpergi@lebihmasa.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.gone_user, 'employee', 'active');
  update public.employees set user_id = r.gone_user where id = r.gone;

  perform public.record_departure(r.gone, pg_temp.today() - 3, 'resigned', 'Berpindah',
                                  pg_temp.today() - 40);
  perform public.record_departure(r.last_day, pg_temp.today(), 'resigned', 'Berpindah',
                                  pg_temp.today() - 40);
  insert into t_ow select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The clock: not before the first day, not after the last
-- ---------------------------------------------------------------------
set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  perform pg_temp.check_refused('HR cannot clock a leaver in after their last day',
    format('select public.clock_in(%L, %L, null, null, null, null, null, %L)', d.org, 'web', d.gone),
    format('Sudah Lama Pergi''s last working day was %s, and nobody clocks in after it.',
           to_char(pg_temp.today() - 3, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_refused('nor anybody before their first',
    format('select public.clock_in(%L, %L, null, null, null, null, null, %L)', d.org, 'web', d.joiner),
    format('Belum Mula starts on %s, and cannot clock in before then.',
           to_char(pg_temp.today() + 5, 'DD Mon YYYY')),
    '23514');
  perform public.clock_in(d.org, 'web', null, null, null, null, null, d.last_day);
  perform public.clock_in(d.org, 'web', null, null, null, null, null, d.first_day);
  perform pg_temp.check_eq('the last day and the first are clocked',
    (select count(*) from public.attendance_records
      where employee_id in (d.last_day, d.first_day) and work_date = pg_temp.today())::int, 2);

  -- A day each for the one staying and the one about to leave, worked
  -- to nine at night.
  perform public.clock_in(d.org, 'web', null, null, null, null, null, d.stayer);
  perform public.clock_in(d.org, 'web', null, null, null, null, null, d.leaver);
  perform public.adjust_attendance(a.id,
      (pg_temp.today()::timestamp + time '09:00') at time zone 'Asia/Kuala_Lumpur',
      (pg_temp.today()::timestamp + time '21:00') at time zone 'Asia/Kuala_Lumpur',
      'Kerja lebih masa')
    from public.attendance_records a
   where a.employee_id in (d.stayer, d.leaver) and a.work_date = pg_temp.today();
end $$;

reset role;
select pg_temp.sign_in_as((select gone_user from t_ow));
set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  perform pg_temp.check_refused('and a leaver whose login still works cannot clock in either',
    format('select public.clock_in(%L)', d.org),
    format('Sudah Lama Pergi''s last working day was %s, and nobody clocks in after it.',
           to_char(pg_temp.today() - 3, 'DD Mon YYYY')),
    '23514');
end $$;

reset role;
select pg_temp.sign_in_as(pg_temp.test_user());

-- ---------------------------------------------------------------------
-- The payslip: overtime only on the days it pays for
-- ---------------------------------------------------------------------
do $$
declare d t_ow; v_period uuid;
begin
  select * into d from t_ow;
  -- The leaver's departure is recorded after the day was worked, with
  -- yesterday as the last day. (On the first of a month that is last
  -- month, the leaver is not on this run at all, and paid nothing.)
  perform public.record_departure(d.leaver, pg_temp.today() - 1, 'resigned', 'Berpindah',
                                  pg_temp.today() - 40);
  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (d.org, 'OT', date_trunc('month', pg_temp.today())::date,
          (date_trunc('month', pg_temp.today()) + interval '1 month - 1 day')::date,
          (date_trunc('month', pg_temp.today()) + interval '1 month - 1 day')::date)
  returning id into v_period;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (d.org, v_period, 'PAY-OT') returning id into d.run;
  perform public.calculate_payroll_run(d.run);

  perform pg_temp.check_eq('three hours worked while employed are paid',
    pg_temp.ow_paid(d.run, d.stayer), '3.00 hours = 67.07');
  perform pg_temp.check_eq('and the same three hours after the last day are not',
    pg_temp.ow_paid(d.run, d.leaver), '0.00 hours = 0.00');
end $$;

rollback;

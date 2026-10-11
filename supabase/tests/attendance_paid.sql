-- =====================================================================
-- iAkauntan :: a paid day is kept as it was paid (0818)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attendance_paid.sql
--
-- `adjust_attendance` refused a day in a closed pay period, and nothing
-- ever closed one: a day whose overtime January's posted run had paid
-- was moved from one hour to five after it, and February, reading its
-- own month, paid none of the difference. Since `0818` it refuses a day
-- the employee has a payslip for on a posted or paid run, and names the
-- run. Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ap (
  org uuid, owner uuid, shift uuid, siti uuid, run uuid,
  jan1 uuid, jan7 uuid, jan31 uuid, feb4 uuid, ali uuid, ali_jan8 uuid);
grant select on t_ap to authenticated;

create or replace function pg_temp.ap_day(p_org uuid, p_emp uuid, p_shift uuid, p_on date)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status)
  values (p_org, p_emp, p_on, p_shift,
          (p_on + time '09:00') at time zone 'Asia/Kuala_Lumpur', 'incomplete')
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.ap_until(p_rec uuid, p_out time, p_why text)
returns jsonb language sql as $$
  select public.adjust_attendance(p_rec,
    (r.work_date + time '09:00') at time zone 'Asia/Kuala_Lumpur',
    (r.work_date + p_out) at time zone 'Asia/Kuala_Lumpur', p_why)
    from public.attendance_records r where r.id = p_rec;
$$;
grant execute on function pg_temp.ap_until(uuid, time, text) to authenticated;

do $$
declare
  r t_ap;
begin
  r.org := pg_temp.test_org('Hari Dibayar Sdn Bhd', array['hr', 'payroll']);
  r.owner := (select user_id from public.org_members
               where org_id = r.org and role = 'owner' limit 1);
  perform pg_temp.sign_in_as(r.owner);
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, break_minutes,
     grace_minutes, work_days, is_default)
  values (r.org, 'DAY', 'Nine to six', '09:00', '18:00', 60, 10,
          array[1,2,3,4,5], true)
  returning id into r.shift;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, bank_name, bank_account_no)
  values (r.org, 'E-1', 'Siti', date '2020-01-01', 2600,
          date '1990-01-01', 'citizen', 'Maybank', '1234567890')
  returning id into r.siti;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (r.org, r.siti, r.shift, date '2020-01-01');

  -- The first and last days of January, a day between, and a day in a
  -- February nobody has run yet.
  r.jan1 := pg_temp.ap_day(r.org, r.siti, r.shift, date '2026-01-01');
  r.jan7 := pg_temp.ap_day(r.org, r.siti, r.shift, date '2026-01-07');
  r.jan31 := pg_temp.ap_day(r.org, r.siti, r.shift, date '2026-01-31');
  r.feb4 := pg_temp.ap_day(r.org, r.siti, r.shift, date '2026-02-04');

  r.run := public.create_payroll_run(r.org,
    public.ensure_pay_period(r.org, 2026, 1), 'January');

  insert into t_ap select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_ap), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- Corrected until it is paid, and not after
-- =====================================================================
do $$
declare
  d t_ap;
begin
  select * into d from t_ap;
  perform pg_temp.check_eq('HR asks as a client', current_user, 'authenticated');

  -- Before the run is worked out, and while it is only worked out, the
  -- days are HR's to correct: nothing has been paid on them.
  perform pg_temp.ap_until(d.jan1, '18:00', 'Card reader was down');
  perform pg_temp.ap_until(d.jan31, '18:00', 'Came in for the stock count');
  perform pg_temp.ap_until(d.jan7, '19:00', 'Stayed for the delivery');
  perform pg_temp.check_eq('a day is corrected before its run is worked out',
    (select ot_normal_minutes from public.attendance_records where id = d.jan7), 60);
  perform public.calculate_payroll_run(d.run);
  perform pg_temp.ap_until(d.jan7, '19:00', 'Confirmed by the supervisor');
  perform pg_temp.check_eq('and while it is only calculated',
    (select adjustment_reason from public.attendance_records where id = d.jan7),
    'Confirmed by the supervisor');
  perform public.calculate_payroll_run(d.run);

  perform public.post_payroll_run(d.run);
  perform pg_temp.check_eq('January is posted, paying the hour: RM18.75',
    (select r.status || '/' || s.ot_amount
       from public.payroll_runs r join public.payslips s on s.run_id = r.id
      where r.id = d.run and s.employee_id = d.siti), 'posted/18.75');

  -- What was measured: the paid hour made five afterwards.
  perform pg_temp.check_refused('a day paid on a posted run is not rewritten',
    format('select pg_temp.ap_until(%L, %L, %L)', d.jan7, '23:00', 'Afterthought'),
    'Payroll run PYR-%-00001 for 2026-01 is posted, and this day was paid on it.%',
    '23514');
  perform pg_temp.check_refused('nor the first day of the period',
    format('select pg_temp.ap_until(%L, %L, %L)', d.jan1, '20:00', 'Afterthought'),
    'Payroll run PYR-%-00001 for 2026-01 is posted%', '23514');
  perform pg_temp.check_refused('nor the last',
    format('select pg_temp.ap_until(%L, %L, %L)', d.jan31, '20:00', 'Afterthought'),
    'Payroll run PYR-%-00001 for 2026-01 is posted%', '23514');
  perform pg_temp.check_true('so the day still says what was paid on it',
    (select ot_normal_minutes = 60 and adjustment_reason = 'Confirmed by the supervisor'
       from public.attendance_records where id = d.jan7));

  perform public.mark_payroll_paid(d.run);
  perform pg_temp.check_refused('nor once the bank has paid it',
    format('select pg_temp.ap_until(%L, %L, %L)', d.jan7, '23:00', 'Afterthought'),
    'Payroll run PYR-%-00001 for 2026-01 is paid, and this day was paid on it.%',
    '23514');

  -- February has not been run: its days are still HR's.
  perform pg_temp.ap_until(d.feb4, '18:00', 'Left on time');
  perform pg_temp.check_eq('a day in a month not yet run is still corrected',
    (select worked_minutes from public.attendance_records where id = d.feb4), 480);
end $$;

reset role;

-- Somebody who joined on 5 January and was entered after January was
-- run: their January days are in a paid period, and were not paid.
do $$
declare
  d   t_ap;
  v_e uuid;
begin
  select * into d from t_ap;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (d.org, 'E-2', 'Ali', date '2026-01-05', 2600,
          date '1995-01-01', 'citizen')
  returning id into v_e;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (d.org, v_e, d.shift, date '2026-01-05');
  update t_ap set ali = v_e,
                  ali_jan8 = pg_temp.ap_day(d.org, v_e, d.shift, date '2026-01-08');
end $$;

set local role authenticated;

do $$
declare
  d t_ap;
begin
  select * into d from t_ap;
  perform pg_temp.check_eq('Ali has no January payslip',
    (select count(*)::integer from public.payslips where employee_id = d.ali), 0);
  perform pg_temp.ap_until(d.ali_jan8, '18:00', 'His first week, from the book');
  perform pg_temp.check_eq('so his January day is still corrected',
    (select worked_minutes from public.attendance_records where id = d.ali_jan8), 480);
end $$;

reset role;

rollback;

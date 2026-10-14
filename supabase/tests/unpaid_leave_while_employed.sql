-- =====================================================================
-- iAkauntan :: unpaid leave is taken while employed (0894)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_leave_while_employed.sql
--
-- `calculate_payroll_run` prorated basic to the days employed and then
-- deducted unpaid leave clipped only to the period, so leave on a day
-- the person was not employed was taken off pay that never included
-- it. And nothing refused such leave. The payroll is the owner's; the
-- requests are filed as HR with the role `authenticated`, as the app
-- files them, and as a draft written straight into the table, which a
-- client still may.
--
-- One month, April 2026, at 3,100.00 basic over 26 working days: a
-- day of unpaid leave is 119.230769..., five are 596.15, three 357.69.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ul (org uuid, ul uuid, leaver uuid, joiner uuid, stayer uuid,
  run uuid);
grant select on t_ul to authenticated;

create or replace function pg_temp.ul_leave(p_org uuid, p_no text, p_emp uuid,
  p_type uuid, p_from date, p_to date, p_days numeric)
returns void language sql as $$
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (p_org, p_no, p_emp, p_type, p_from, p_to, p_days, 'approved');
$$;

-- A payslip's basic, its unpaid leave, and what that cost.
create or replace function pg_temp.ul_slip(p_run uuid, p_emp uuid)
returns text language sql as $$
  select basic_salary || ' less ' || unpaid_leave_days || ' days = ' || unpaid_leave_amount
    from public.payslips where run_id = p_run and employee_id = p_emp;
$$;

do $$
declare r t_ul; v_period uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Cuti Bergaji Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  insert into public.leave_types (org_id, code, name, default_days, is_paid)
  values (r.org, 'UL', 'Cuti tanpa gaji', 0, false) returning id into r.ul;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (r.org, 'L1', 'Pergi Bulan Ini', date '2020-01-01', 3100,
          date '1992-04-15', 'single', 'citizen') returning id into r.leaver;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (r.org, 'J1', 'Baru Masuk', date '2026-04-01', 3100,
          date '1992-04-15', 'single', 'citizen') returning id into r.joiner;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (r.org, 'S1', 'Kekal', date '2020-01-01', 3100,
          date '1992-04-15', 'single', 'citizen') returning id into r.stayer;

  -- Leave approved while the boundaries were elsewhere: before the
  -- leaver resigned, and before the joiner's start was put back.
  perform pg_temp.ul_leave(r.org, 'LR-1', r.leaver, r.ul, date '2026-04-13', date '2026-04-17', 5);
  perform pg_temp.ul_leave(r.org, 'LR-2', r.leaver, r.ul, date '2026-04-20', date '2026-04-24', 5);
  perform pg_temp.ul_leave(r.org, 'LR-3', r.joiner, r.ul, date '2026-04-06', date '2026-04-10', 5);
  perform pg_temp.ul_leave(r.org, 'LR-4', r.joiner, r.ul, date '2026-04-14', date '2026-04-18', 5);
  perform pg_temp.ul_leave(r.org, 'LR-5', r.stayer, r.ul, date '2026-04-20', date '2026-04-24', 5);
  perform public.record_departure(r.leaver, date '2026-04-15', 'resigned', 'Berpindah',
                                  date '2026-03-01');
  update public.employees set hire_date = date '2026-04-16' where id = r.joiner;

  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (r.org, '2026-04', date '2026-04-01', date '2026-04-30', date '2026-04-30')
  returning id into v_period;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (r.org, v_period, 'PAY-2026-04') returning id into r.run;
  perform public.calculate_payroll_run(r.run);
  insert into t_ul select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The payslips: leave counts only on the days the slip pays for
-- ---------------------------------------------------------------------
do $$
declare d t_ul;
begin
  select * into d from t_ul;
  perform pg_temp.check_eq('a leaver is docked only the leave inside their last fortnight',
    pg_temp.ul_slip(d.run, d.leaver), '1550.00 less 3.00 days = 357.69');
  perform pg_temp.check_eq('a joiner only the leave from their first day',
    pg_temp.ul_slip(d.run, d.joiner), '1550.00 less 3.00 days = 357.69');
  perform pg_temp.check_eq('and a whole month is docked the whole of it, as before',
    pg_temp.ul_slip(d.run, d.stayer), '3100.00 less 5.00 days = 596.15');
end $$;

-- ---------------------------------------------------------------------
-- New leave outside employment is refused
-- ---------------------------------------------------------------------
set local role authenticated;

do $$
declare d t_ul;
begin
  select * into d from t_ul;
  perform pg_temp.check_refused('leave starting before the hire date is refused',
    format('select public.submit_leave_request(%L, %L, %L, %L, 5, %L, false, null, %L)',
           d.org, d.ul, date '2026-04-14', date '2026-04-18', 'Awal', d.joiner),
    'Baru Masuk joined on 16 Apr 2026, and has no leave to take before then.', '23514');
  perform pg_temp.check_refused('leave ending after the last working day is refused',
    format('select public.submit_leave_request(%L, %L, %L, %L, 3, %L, false, null, %L)',
           d.org, d.ul, date '2026-04-14', date '2026-04-16', 'Lewat', d.leaver),
    'Pergi Bulan Ini''s last working day is 15 Apr 2026, and leave cannot run past it.', '23514');
  -- A draft is the one thing a client still writes into the table.
  perform pg_temp.check_refused('and so is a draft typed straight into the table',
    format('insert into public.leave_requests (org_id, request_no, employee_id, leave_type_id,
              start_date, end_date, total_days, status)
            values (%L, %L, %L, %L, %L, %L, 1, %L)',
           d.org, 'LR-X', d.joiner, d.ul, date '2026-04-15', date '2026-04-15', 'draft'),
    'Baru Masuk joined on 16 Apr 2026, and has no leave to take before then.', '23514');
  insert into public.leave_requests (org_id, request_no, employee_id, leave_type_id,
    start_date, end_date, total_days, status)
  values (d.org, 'LR-D', d.joiner, d.ul, date '2026-04-20', date '2026-04-20', 1, 'draft');
  perform pg_temp.check_refused('or a draft moved back before the hire date',
    format('update public.leave_requests set start_date = %L where request_no = %L',
           date '2026-04-15', 'LR-D'),
    'Baru Masuk joined on 16 Apr 2026, and has no leave to take before then.', '23514');

  perform public.submit_leave_request(d.org, d.ul, date '2026-04-16', date '2026-04-16', 1,
    'Hari pertama', false, null, d.joiner);
  perform public.submit_leave_request(d.org, d.ul, date '2026-04-15', date '2026-04-15', 1,
    'Hari terakhir', false, null, d.leaver);
  perform pg_temp.check_eq('a day on the first day and one on the last are kept',
    (select count(*) from public.leave_requests
      where reason in ('Hari pertama', 'Hari terakhir'))::int, 2);
end $$;

reset role;

rollback;

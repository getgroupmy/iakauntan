-- =====================================================================
-- iAkauntan :: the pay period and the run raised against it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_periods.sql
--
-- payroll_run.sql asserts what calculate_payroll_run does with a
-- period. This file asserts the two functions that make one:
-- ensure_pay_period, which decides the period's boundaries and its pay
-- date, and create_payroll_run, which raises a run against it. Both
-- were called by no test.
--
-- The pay date is the one that matters. It is not a label: app.age_at
-- reads it for the sixty year boundary that stops EPF employee
-- contributions and EIS, app.calc_statutory reads it to pick the
-- effective rate schedule, and app.calc_pcb reads it to decide which
-- month is being annualised. A pay date two days out is a payslip with
-- different statutory figures on it, so every day-of-month rule below
-- is asserted against three months of different lengths.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The pay date for one setting in one month, so the table of cases
-- below reads as a table rather than as twenty variable assignments.
create or replace function pg_temp.pay_date_for(
  p_org uuid, p_day integer, p_year integer, p_month integer)
returns date language plpgsql as $$
declare v_period uuid; v_date date;
begin
  update public.payroll_settings set pay_day = p_day where org_id = p_org;
  delete from public.pay_periods where org_id = p_org;
  v_period := public.ensure_pay_period(p_org, p_year, p_month);
  select pay_date into v_date from public.pay_periods where id = v_period;
  return v_date;
end;
$$;

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_period uuid;
  v_again  uuid;
  v_run    uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Bulan Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.payroll_settings (org_id, pay_day) values (v_org, 25)
    on conflict (org_id) do update set pay_day = 25;

  -- ==================================================================
  -- The period itself
  -- ==================================================================
  v_period := public.ensure_pay_period(v_org, 2026, 2);
  select * into r from public.pay_periods where id = v_period;
  perform pg_temp.check_eq('the code is the calendar month', r.code, '2026-02');
  perform pg_temp.check_eq('it starts on the first',
    r.period_start::text, '2026-02-01');
  perform pg_temp.check_eq('and ends on the last day of that month',
    r.period_end::text, '2026-02-28');
  perform pg_temp.check_eq('a monthly period by default',
    r.frequency::text, 'monthly');
  perform pg_temp.check_true('and it is open', not r.is_closed);

  -- February 2028 has a twenty-ninth, and the period has to know it.
  v_period := public.ensure_pay_period(v_org, 2028, 2);
  perform pg_temp.check_eq('a leap February ends on the 29th',
    (select period_end::text from public.pay_periods where id = v_period),
    '2028-02-29');

  -- ==================================================================
  -- The pay date, over three months of different lengths
  --
  --   day | Jan 2026 (31) | Feb 2026 (28) | Apr 2026 (30)
  --   ----+---------------+---------------+--------------
  --     0 |        31 Jan |        28 Feb |        30 Apr
  --     1 |         1 Jan |         1 Feb |         1 Apr
  --    25 |        25 Jan |        25 Feb |        25 Apr
  --    28 |        28 Jan |        28 Feb |        28 Apr
  --    29 |        29 Jan |        28 Feb |        29 Apr
  --    30 |        30 Jan |        28 Feb |        30 Apr
  --    31 |        31 Jan |        28 Feb |        30 Apr
  --
  -- The bottom three rows are what 0279 changed: before it, 29, 30 and
  -- 31 all fell to the last day of every month rather than only of the
  -- months too short to hold them.
  -- ==================================================================
  perform pg_temp.check_eq('day 0 is the last day of a long month',
    pg_temp.pay_date_for(v_org, 0, 2026, 1)::text, '2026-01-31');
  perform pg_temp.check_eq('day 0 in February',
    pg_temp.pay_date_for(v_org, 0, 2026, 2)::text, '2026-02-28');
  perform pg_temp.check_eq('day 0 in a thirty day month',
    pg_temp.pay_date_for(v_org, 0, 2026, 4)::text, '2026-04-30');

  perform pg_temp.check_eq('the first of the month',
    pg_temp.pay_date_for(v_org, 1, 2026, 1)::text, '2026-01-01');
  perform pg_temp.check_eq('the twenty-fifth, which is the default',
    pg_temp.pay_date_for(v_org, 25, 2026, 2)::text, '2026-02-25');
  perform pg_temp.check_eq('the twenty-eighth in February',
    pg_temp.pay_date_for(v_org, 28, 2026, 2)::text, '2026-02-28');

  -- A day the month is long enough to hold is that day.
  perform pg_temp.check_eq('the twenty-ninth in January is the 29th',
    pg_temp.pay_date_for(v_org, 29, 2026, 1)::text, '2026-01-29');
  perform pg_temp.check_eq('the twenty-ninth in April is the 29th',
    pg_temp.pay_date_for(v_org, 29, 2026, 4)::text, '2026-04-29');
  perform pg_temp.check_eq('the thirtieth in January is the 30th',
    pg_temp.pay_date_for(v_org, 30, 2026, 1)::text, '2026-01-30');

  -- A day it is not long enough to hold falls back to the last day.
  perform pg_temp.check_eq('the twenty-ninth in a short February',
    pg_temp.pay_date_for(v_org, 29, 2026, 2)::text, '2026-02-28');
  perform pg_temp.check_eq('but a leap February does hold it',
    pg_temp.pay_date_for(v_org, 29, 2028, 2)::text, '2028-02-29');
  perform pg_temp.check_eq('the thirtieth in February',
    pg_temp.pay_date_for(v_org, 30, 2026, 2)::text, '2026-02-28');
  perform pg_temp.check_eq('the thirty-first in April',
    pg_temp.pay_date_for(v_org, 31, 2026, 4)::text, '2026-04-30');
  perform pg_temp.check_eq('the thirty-first in January is the 31st',
    pg_temp.pay_date_for(v_org, 31, 2026, 1)::text, '2026-01-31');

  -- A company that has never opened the payroll settings screen has no
  -- row at all, and is paid on the twenty-fifth.
  delete from public.payroll_settings where org_id = v_org;
  delete from public.pay_periods where org_id = v_org;
  v_period := public.ensure_pay_period(v_org, 2026, 3);
  perform pg_temp.check_eq('with no settings row at all, the 25th',
    (select pay_date::text from public.pay_periods where id = v_period),
    '2026-03-25');
  insert into public.payroll_settings (org_id, pay_day) values (v_org, 25);

  -- ==================================================================
  -- Asking twice is asking once
  -- ==================================================================
  delete from public.pay_periods where org_id = v_org;
  v_period := public.ensure_pay_period(v_org, 2026, 5);
  v_again  := public.ensure_pay_period(v_org, 2026, 5);
  perform pg_temp.check_eq('asking for the same month twice is the same period',
    v_again, v_period);
  perform pg_temp.check_eq('and does not raise a second one',
    (select count(*) from public.pay_periods
      where org_id = v_org and code = '2026-05'), 1);

  -- Deliberately: changing the pay day does not move a period that has
  -- already been raised. A run may have been calculated against this
  -- date, and every statutory figure on it was computed from the date.
  update public.payroll_settings set pay_day = 5 where org_id = v_org;
  v_again := public.ensure_pay_period(v_org, 2026, 5);
  perform pg_temp.check_eq('an existing period keeps the pay date it was raised with',
    (select pay_date::text from public.pay_periods where id = v_again),
    '2026-05-25');
  -- The new pay day applies to the months raised after it.
  v_period := public.ensure_pay_period(v_org, 2026, 6);
  perform pg_temp.check_eq('the next month takes the new pay day',
    (select pay_date::text from public.pay_periods where id = v_period),
    '2026-06-05');

  -- ==================================================================
  -- The run raised against it
  -- ==================================================================
  update public.payroll_settings set pay_day = 25 where org_id = v_org;
  v_period := public.ensure_pay_period(v_org, 2026, 7);
  v_run := public.create_payroll_run(v_org, v_period, 'July, everybody');

  select * into r from public.payroll_runs where id = v_run;
  perform pg_temp.check_eq('a new run is a draft', r.status::text, 'draft');
  perform pg_temp.check_eq('against the period it was given',
    r.period_id, v_period);
  perform pg_temp.check_eq('carrying its description',
    r.description, 'July, everybody');
  -- Its own series, and not the payment series. 0099 dropped the
  -- payroll_run arm from app.default_doc_prefix, so the fallback
  -- upper(left('payroll_run', 3)) took over and produced 'PAY-' --
  -- the same prefix payments use, from a separate counter, so a
  -- company could hold a supplier payment and a payroll run both
  -- called PAY-000007. 0280 put the arm back.
  perform pg_temp.check_eq('numbered from the payroll run series',
    left(r.run_no, 4), 'PYR-');
  perform pg_temp.check_eq('and the prefix stored on the sequence agrees',
    (select prefix from public.number_sequences
      where org_id = v_org and doc_type = 'payroll_run'), 'PYR-');
  perform pg_temp.check_eq('a payment keeps PAY- to itself',
    app.default_doc_prefix('payment'), 'PAY-');
  perform pg_temp.check_true('so the two series cannot be confused',
    app.default_doc_prefix('payroll_run')
      <> app.default_doc_prefix('payment'));
  -- The sibling arm 0099 dropped in the same edit.
  perform pg_temp.check_eq('and a leave request is LV-, not LEA-',
    app.default_doc_prefix('leave_request'), 'LV-');

  -- No two document series in use share a prefix. This is the check
  -- that would have caught 0099 at the time, and it costs one query.
  perform pg_temp.check_eq('no two live document series share a prefix',
    (select count(*) from (
       select app.default_doc_prefix(d) p
         from unnest(array[
           'bank_transfer','bill','cheque','contact','contra','credit_note',
           'deposit','invoice','journal','landed_cost','leave_request',
           'opportunity','payment','payroll_run','pos_sale','pos_shift',
           'purchase_order','receipt','rent_run','stock_movement',
           'stock_transfer','strata_charge','ticket','withholding']) d
        group by 1 having count(*) > 1) x), 0);
  perform pg_temp.check_eq('and stamped with whoever raised it',
    r.created_by, v_owner);
  perform pg_temp.check_eq('with nobody on it yet', r.employee_count, 0);
  perform pg_temp.check_eq('and nothing computed', r.total_gross, 0);

  -- Two runs against one period are numbered in sequence rather than
  -- colliding: a company that voids a run and raises another needs both.
  perform pg_temp.check_true('a second run against the same period is allowed',
    public.create_payroll_run(v_org, v_period, 'July, again') is not null);
  perform pg_temp.check_eq('and the numbers do not collide',
    (select count(distinct run_no) from public.payroll_runs
      where org_id = v_org), 2);

  -- The whole point of the two of them: a run raised this way is one
  -- calculate_payroll_run accepts.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'B1', 'Somebody', date '2020-01-01', 4000,
          date '1990-06-01', 'citizen');
  perform public.calculate_payroll_run(v_run);
  perform pg_temp.check_eq('and the engine will calculate it',
    (select status::text from public.payroll_runs where id = v_run),
    'calculated');
  perform pg_temp.check_eq('against the pay date the period carries',
    (select pay_date::text from public.pay_periods where id = v_period),
    '2026-07-25');

  -- ==================================================================
  -- Neither is open to somebody outside the organization
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('outsider@example.test'));
  begin
    perform public.ensure_pay_period(v_org, 2026, 8);
    raise exception 'FAIL: a non-member raised a pay period';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot raise a pay period';
  end;
  begin
    perform public.create_payroll_run(v_org, v_period, 'Not mine');
    raise exception 'FAIL: a non-member raised a payroll run';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot raise a payroll run';
  end;
  perform pg_temp.sign_out();
end $$;

rollback;

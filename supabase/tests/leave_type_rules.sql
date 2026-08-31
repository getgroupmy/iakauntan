-- =====================================================================
-- iAkauntan :: the leave type's rules, which were only labels
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/leave_type_rules.sql
--
-- `leave_types.allow_half_day` and `carry_forward_expiry_months` have
-- existed since `0027` and neither had ever been read.
--
-- The first is a rule a company states and the system ignored: a type
-- marked whole-days-only took half days anyway, and the balance simply
-- moved by 0.5 with nothing said.
--
-- The second has a figure attached. `0058` wrote the carry-forward cap
-- because "silently rolling everything forward is how leave liability
-- grows unnoticed" — and the cap only bounds one year's roll. A company
-- whose policy is "carry five days, use them by March" carried them and
-- kept them for ever, and the liability in its accounts was overstated
-- by every unused carried day of every employee.
--
-- The convention that decides which days were used is the ordinary one
-- and the one that favours the employee: carried days go first, because
-- they are the ones with an expiry on them. Which makes what survives
-- exactly `least(taken_days, carried_forward)`, and the assertions
-- below walk all three cases of that.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_emp    uuid;
  v_whole  uuid;   -- whole days only
  v_half   uuid;   -- half days allowed
  v_annual uuid;   -- carries, and expires at the end of March
  v_none   uuid;   -- carries and never expires
  v_zero   uuid;   -- carries, with the expiry typed as nought
  v_year   integer := 2026;
  v_march  date := date '2026-04-01';
  v_feb    date := date '2026-02-15';
  v_refused boolean;
  v_msg    text;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Cuti Berkala Sdn Bhd');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti', date '2020-01-01', 'active')
  returning id into v_emp;

  insert into public.leave_types (org_id, code, name, default_days, allow_half_day)
  values (v_org, 'UNPAID', 'Unpaid leave', 0, false) returning id into v_whole;
  insert into public.leave_types (org_id, code, name, default_days, allow_half_day)
  values (v_org, 'AL', 'Annual leave', 14, true) returning id into v_half;

  -- ------------------------------------------------------------------
  -- Half a day, where the type allows one
  -- ------------------------------------------------------------------
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, is_half_day, half_day_period, status)
  values (v_org, 'LV-1', v_emp, v_half, date '2026-05-04', date '2026-05-04',
          0.5, true, 'morning', 'submitted');
  perform pg_temp.check_eq('half a day of annual leave is half a day',
    (select total_days from public.leave_requests
      where org_id = v_org and request_no = 'LV-1'), 0.5);

  v_refused := false;
  begin
    insert into public.leave_requests
      (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
       total_days, is_half_day, half_day_period, status)
    values (v_org, 'LV-2', v_emp, v_whole, date '2026-05-05', date '2026-05-05',
            0.5, true, 'morning', 'submitted');
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'a type taken in whole days does not take half of one', v_refused);
  -- Named, because the person asking has a list of leave types in front
  -- of them and needs to know which one refused.
  perform pg_temp.check_true('and the refusal names the type: ' || coalesce(v_msg, ''),
    v_msg like '%Unpaid leave%');

  -- The control: the same type, a whole day, goes through.
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (v_org, 'LV-3', v_emp, v_whole, date '2026-05-06', date '2026-05-06',
          1, 'submitted');
  perform pg_temp.check_eq('a whole day of it is fine',
    (select total_days from public.leave_requests
      where org_id = v_org and request_no = 'LV-3'), 1);

  -- ------------------------------------------------------------------
  -- Carried leave that lapses
  -- ------------------------------------------------------------------
  insert into public.leave_types
    (org_id, code, name, default_days, max_carry_forward,
     carry_forward_expiry_months)
  values (v_org, 'AL2', 'Annual, carried', 14, 5, 3)
  returning id into v_annual;
  insert into public.leave_types
    (org_id, code, name, default_days, max_carry_forward)
  values (v_org, 'AL3', 'Annual, kept', 14, 5) returning id into v_none;
  -- Nought months, which somebody typing it means as "no expiry" and
  -- not as "lapses on the first of January". The mutation run found
  -- this gap: with only a null and a three, removing the `> 0` guard
  -- broke nothing, because `make_interval(months => null)` is null and
  -- the date comparison excluded the null type anyway.
  insert into public.leave_types
    (org_id, code, name, default_days, max_carry_forward,
     carry_forward_expiry_months)
  values (v_org, 'AL4', 'Annual, nought', 14, 5, 0) returning id into v_zero;

  -- Five carried, none of them used.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days,
     carried_forward, taken_days)
  values (v_org, v_emp, v_annual, v_year, 14, 5, 0);
  -- Five carried, three used — under the carried-first convention, three
  -- of the carried days went.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days,
     carried_forward, taken_days)
  values (v_org, v_emp, v_none, v_year, 14, 5, 3);
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days,
     carried_forward, taken_days)
  values (v_org, v_emp, v_zero, v_year, 14, 5, 0);

  -- Before the deadline, nothing lapses. Stated first: without it every
  -- assertion below is satisfied by a function that never runs.
  perform pg_temp.check_eq('nothing lapses in February',
    app.expire_carried_leave(v_org, v_feb), 0);
  perform pg_temp.check_eq('and the five days are still there',
    (select carried_forward from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_annual), 5.00);

  -- On the first of April, three months are up.
  v_n := app.expire_carried_leave(v_org, v_march);
  perform pg_temp.check_eq('one balance lapses', v_n, 1);
  perform pg_temp.check_eq('the unused carried days are gone',
    (select carried_forward from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_annual), 0.00);
  -- The type with no expiry keeps its five, which is what makes the
  -- above a statement about the column rather than about the date.
  perform pg_temp.check_eq('a type with no expiry keeps them',
    (select carried_forward from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_none), 5.00);
  perform pg_temp.check_eq('and nought months means the same thing',
    (select carried_forward from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_zero), 5.00);

  -- Running it again changes nothing. A sweep that lapses what it
  -- lapsed last night takes days off somebody every day of April.
  perform pg_temp.check_eq('and running it again lapses nothing',
    app.expire_carried_leave(v_org, v_march), 0);

  -- ------------------------------------------------------------------
  -- Days already used out of the carry survive
  -- ------------------------------------------------------------------
  -- The middle case, and the one the convention is for: three of the
  -- five were taken before the deadline, so three stay and two lapse.
  update public.leave_types set carry_forward_expiry_months = 3
   where id = v_none;
  perform pg_temp.check_eq('the partly used balance lapses too',
    app.expire_carried_leave(v_org, v_march), 1);
  perform pg_temp.check_eq(
    'but only the two nobody used — carried days go first',
    (select carried_forward from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_none), 3.00);

  perform pg_temp.sign_out();
end $$;

rollback;

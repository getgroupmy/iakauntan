-- =====================================================================
-- iAkauntan :: attendance tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attendance.sql
--
-- These exist because clock_in shipped broken and stayed broken. It
-- compiled, deployed, and passed everything that did not actually call
-- it — the CASE that chooses between 'late' and 'present' resolved to
-- text, and PostgreSQL will not implicitly cast text to an enum, so
-- every punch died with 42804 at runtime.
--
-- The lesson is the shape of the test, not the assertion: a function
-- whose only caller is the app has to be called by something in CI.
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid := pg_temp.test_org('Attendance Test Sdn Bhd');
  v_user  uuid := pg_temp.test_user();
  v_emp   uuid;
  v_id    uuid;
  v_rec   public.attendance_records;
begin
  insert into public.employees (org_id, employee_no, user_id, full_name,
                                hire_date, employment_status)
  values (v_org, 'EMP-T001', v_user, 'Fixture Employee',
          current_date - 30, 'active')
  returning id into v_emp;

  -- The punch itself. Before the fix this raised 42804 here.
  v_id := public.clock_in(p_org_id => v_org, p_method => 'web');
  perform pg_temp.check_true('clock_in returns a record id', v_id is not null);

  select * into v_rec from public.attendance_records where id = v_id;

  perform pg_temp.check_true('the punch is today',
    v_rec.work_date = (now() at time zone 'Asia/Kuala_Lumpur')::date);
  perform pg_temp.check_true('clock_in time is recorded',
    v_rec.clock_in is not null);

  -- The status is the column that broke. With no shift assigned there is
  -- nothing to be late for, so it must be 'present' — and it must be a
  -- real enum value, which is what the cast is for.
  perform pg_temp.check_true('status with no shift is present',
    v_rec.status = 'present');
  perform pg_temp.check_eq('late minutes with no shift', v_rec.late_minutes, 0);

  -- Badging again the same day must not open a second attendance row.
  -- Whether it moves the clock_in timestamp cannot be asserted from here
  -- — now() is fixed for the whole transaction, so both punches carry
  -- the same instant — but the conflict path is what would break, and
  -- that is visible in the row count.
  perform public.clock_in(p_org_id => v_org, p_method => 'web');
  perform pg_temp.check_eq('one attendance row per employee per day',
    (select count(*) from public.attendance_records
      where employee_id = v_emp
        and work_date = (now() at time zone 'Asia/Kuala_Lumpur')::date), 1);

  perform pg_temp.sign_out();
end $$;

-- Somebody with no employee record gets a clear refusal rather than a
-- constraint violation from three functions down.
do $$
declare
  v_org uuid := pg_temp.test_org('No Employee Sdn Bhd');
begin
  begin
    perform public.clock_in(p_org_id => v_org, p_method => 'web');
    raise exception 'FAIL: a login with no employee record clocked in';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a login with no employee record is told so';
  end;
  perform pg_temp.sign_out();
end $$;

rollback;

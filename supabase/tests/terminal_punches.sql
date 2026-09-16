-- =====================================================================
-- iAkauntan :: the punch the clock on the wall made
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/terminal_punches.sql
--
-- `0612`. `attendance_records.clock_in_terminal` has been there since
-- `0027` and nothing ever wrote it, because a device bolted to a door
-- frame has no login and `clock_in` reads `auth.uid()`.
--
-- ## The assertion this file exists for
--
-- **A punch is filed at the time the DEVICE says it happened.**
--
-- `clock_in` stamps `now()`. A terminal that lost its network at 08:55
-- and reconnected at 17:30 sends the morning's punches when it
-- reconnects, and `now()` files every one of them at half past five --
-- which turns a day's attendance into nine hours of nothing followed by
-- a clock-in and a clock-out a second apart. So the punch carries its
-- own time, and the replay below arrives hours after the fact and lands
-- on the right minute anyway.
--
-- Two more that each cost somebody money if wrong:
--
--   * **A replay writes nothing.** A reconnecting device re-sends
--     everything it has.
--   * **Out of order, the earliest in and the latest out win.** A
--     device keeps its backlog in whatever order it likes.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.tp_company(p_name text)
returns table (org uuid, emp uuid, term uuid, secret text)
language plpgsql as $$
declare v_org uuid; v_emp uuid; v_t uuid; v_s text; r record;
begin
  v_org := pg_temp.test_org(p_name, array['hr', 'payroll']);

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Aminah', date '2024-01-01', 3000,
          date '1995-05-05', 'citizen')
  returning id into v_emp;

  select * into r from public.register_time_terminal(v_org, 'Front door');
  v_t := r.terminal_id; v_s := r.secret;

  insert into public.terminal_enrolments
    (org_id, terminal_id, employee_id, enrolment_no)
  values (v_org, v_t, v_emp, '0042');

  org := v_org; emp := v_emp; term := v_t; secret := v_s;
  return next;
end $$;

-- =====================================================================
-- The secret is issued once and cannot be read back
-- =====================================================================
do $$
declare
  v      record;
  v_new  text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into v from pg_temp.tp_company('Jam Dinding Sdn Bhd');

  perform pg_temp.check_true(
    'registering a terminal returns a secret',
    length(v.secret) = 64);

  perform pg_temp.check_true(
    'which is not what is stored',
    (select t.secret_hash from public.time_terminals t where t.id = v.term)
      <> v.secret);

  perform pg_temp.check_true(
    'and the right one is recognised',
    public.terminal_secret_matches(v.term, v.secret));
  perform pg_temp.check_true(
    'while a wrong one is not',
    not public.terminal_secret_matches(v.term, 'not the secret'));
  perform pg_temp.check_true(
    'nor an empty one, which a missing header arrives as',
    not public.terminal_secret_matches(v.term, ''));
  perform pg_temp.check_true(
    'nor any secret against a terminal that does not exist',
    not public.terminal_secret_matches(gen_random_uuid(), v.secret));

  -- Reissuing. The old one stops working the moment it returns.
  v_new := public.reissue_terminal_secret(v.term);
  perform pg_temp.check_true(
    'a reissued secret works', public.terminal_secret_matches(v.term, v_new));
  perform pg_temp.check_true(
    'and the old one has stopped',
    not public.terminal_secret_matches(v.term, v.secret));

  -- A terminal switched off proves nothing, whatever it sends.
  update public.time_terminals set is_active = false where id = v.term;
  perform pg_temp.check_true(
    'a terminal switched off is not recognised at all',
    not public.terminal_secret_matches(v.term, v_new));
end $$;

-- =====================================================================
-- THE assertion: the punch is filed when the device says, not now
-- =====================================================================
do $$
declare
  v       record;
  v_when  timestamptz;
  v_got   timestamptz;
  v_res   jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Rangkaian Putus Sdn Bhd');

  -- Eight fifty-five this morning, Malaysian time, reported now --
  -- which is what a terminal that reconnected at half past five does.
  v_when := (app.today() + time '08:55') at time zone 'Asia/Kuala_Lumpur';

  v_res := app.record_terminal_punch(v.term, '0042', v_when, null);
  perform pg_temp.check_true('the punch was taken', (v_res ->> 'ok')::boolean);
  perform pg_temp.check_eq(
    'and with no direction given, the first punch of the day is an in',
    v_res ->> 'direction', 'in');

  select a.clock_in into v_got from public.attendance_records a
   where a.employee_id = v.emp and a.work_date = app.today();
  perform pg_temp.check_eq(
    'filed at the minute the device recorded, not the minute it arrived',
    v_got::text, v_when::text);

  -- The control that makes that a distinction: `now()` is a different
  -- time, and a version of this that stamped it would have passed the
  -- assertion above only by coincidence.
  perform pg_temp.check_true(
    'which is not now', abs(extract(epoch from (now() - v_got))) > 60);

  perform pg_temp.check_eq(
    'the method says where it came from',
    (select a.clock_in_method::text from public.attendance_records a
      where a.employee_id = v.emp and a.work_date = app.today()),
    'biometric');
  perform pg_temp.check_eq(
    'and the terminal is named on the record',
    (select a.clock_in_terminal from public.attendance_records a
      where a.employee_id = v.emp and a.work_date = app.today()),
    'Front door');
end $$;

-- =====================================================================
-- A reconnecting device re-sends everything it has
-- =====================================================================
do $$
declare
  v      record;
  v_when timestamptz;
  v_res  jsonb;
  v_n    integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Hantar Semula Sdn Bhd');
  v_when := (app.today() + time '08:55') at time zone 'Asia/Kuala_Lumpur';

  perform app.record_terminal_punch(v.term, '0042', v_when, null);
  v_res := app.record_terminal_punch(v.term, '0042', v_when, null);

  perform pg_temp.check_true(
    'the second time is a duplicate, not an error',
    (v_res ->> 'ok')::boolean and (v_res ->> 'duplicate')::boolean);

  select count(*)::integer into v_n from public.terminal_punches
   where terminal_id = v.term;
  perform pg_temp.check_eq('and there is one punch, not two', v_n, 1);

  -- Padding. Devices write "0042" and "42" for the same finger, and
  -- treating them as two people is how somebody gets two half days.
  perform app.record_terminal_punch(v.term, '42',
    v_when + interval '9 hours', null);
  perform pg_temp.check_eq(
    'a padded number and a bare one are the same person',
    (select count(distinct p.employee_id)::integer
       from public.terminal_punches p where p.terminal_id = v.term), 1);
end $$;

-- =====================================================================
-- Out of order, the earliest in and the latest out win
-- =====================================================================
do $$
declare
  v      record;
  v_base timestamptz;
  v_rec  public.attendance_records;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Tak Tersusun Sdn Bhd');
  v_base := (app.today() + time '08:00') at time zone 'Asia/Kuala_Lumpur';

  -- The device sends its backlog in the order it kept it: the 09:00
  -- punch first, then the 08:00 one, then 18:00, then 17:00.
  perform app.record_terminal_punch(v.term, '42', v_base + interval '1 hour', 'in');
  perform app.record_terminal_punch(v.term, '42', v_base, 'in');
  perform app.record_terminal_punch(v.term, '42', v_base + interval '10 hours', 'out');
  perform app.record_terminal_punch(v.term, '42', v_base + interval '9 hours', 'out');

  select * into v_rec from public.attendance_records
   where employee_id = v.emp and work_date = app.today();

  perform pg_temp.check_eq(
    'the earliest punch is the clock-in, however late it arrived',
    v_rec.clock_in::text, v_base::text);
  perform pg_temp.check_eq(
    'and the latest is the clock-out, and a later arrival does not move it back',
    v_rec.clock_out::text, (v_base + interval '10 hours')::text);
  perform pg_temp.check_eq(
    'so the day is ten hours, not one', v_rec.worked_minutes, 600);
end $$;

-- =====================================================================
-- A finger nobody enrolled
-- =====================================================================
do $$
declare
  v     record;
  v_res jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Jari Asing Sdn Bhd');

  v_res := app.record_terminal_punch(v.term, '9999', now(), null);
  perform pg_temp.check_true(
    'a punch from a number nobody enrolled is refused',
    not (v_res ->> 'ok')::boolean);
  perform pg_temp.check_true(
    'and says which number it was',
    v_res ->> 'problem' like '%9999%');

  -- Kept anyway. Somebody pressed a finger to a machine and the person
  -- it belongs to will be asking about it.
  perform pg_temp.check_eq(
    'the punch is recorded even though it matched nobody',
    (select count(*)::integer from public.terminal_punches
      where terminal_id = v.term and enrolment_no = '9999'), 1);
  perform pg_temp.check_true(
    'against no employee, and with the reason on it',
    (select p.employee_id is null and p.problem is not null
       from public.terminal_punches p
      where p.terminal_id = v.term and p.enrolment_no = '9999'));
end $$;

-- =====================================================================
-- Two terminals number their users independently
-- =====================================================================
do $$
declare
  v       record;
  v_other uuid;
  v_t2    uuid;
  r       record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Dua Pintu Sdn Bhd');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v.org, 'E2', 'Bakar', date '2024-01-01', 3000,
          date '1994-04-04', 'citizen')
  returning id into v_other;

  select * into r from public.register_time_terminal(v.org, 'Warehouse gate');
  v_t2 := r.terminal_id;

  -- The warehouse's user 42 is a different person from the front
  -- door's. A single employees.biometric_id column would file one
  -- person's hours against the other, silently.
  insert into public.terminal_enrolments
    (org_id, terminal_id, employee_id, enrolment_no)
  values (v.org, v_t2, v_other, '0042');

  perform app.record_terminal_punch(v.term, '42', now(), 'in');
  perform app.record_terminal_punch(v_t2, '42', now(), 'in');

  perform pg_temp.check_eq(
    'the same number on two terminals is two people',
    (select count(distinct p.employee_id)::integer
       from public.terminal_punches p where p.org_id = v.org), 2);

  -- And the two directions the unique keys refuse.
  perform pg_temp.check_refused(
    'a number cannot point at two people on one terminal',
    format($q$ insert into public.terminal_enrolments
                 (org_id, terminal_id, employee_id, enrolment_no)
               values (%L, %L, %L, '0042') $q$, v.org, v.term, v_other),
    '%terminal_enrolments_terminal_id_enrolment_no_key%', '23505');
  perform pg_temp.check_refused(
    'nor one person at two numbers on one terminal',
    format($q$ insert into public.terminal_enrolments
                 (org_id, terminal_id, employee_id, enrolment_no)
               values (%L, %L, %L, '0099') $q$, v.org, v.term, v.emp),
    '%terminal_enrolments_terminal_id_employee_id_key%', '23505');
end $$;

-- =====================================================================
-- Who may set one up, and who may call the ingest
-- =====================================================================
do $$
declare
  v       record;
  v_me    uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Siapa Jam Sdn Bhd');
  v_me := pg_temp.test_user();
  v_other := pg_temp.another_user('kerani@siapajam.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v.org, v_other, 'accounts_clerk', 'active')
  on conflict (org_id, user_id) do update set role = 'accounts_clerk';

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'somebody who is not HR cannot add a terminal',
    format($q$ select * from public.register_time_terminal(%L, 'Sneaky') $q$,
           v.org),
    '%HR%', '42501');

  -- The ingest is service role only. A client that could call it could
  -- file attendance for anybody, which is why EXECUTE is revoked from
  -- `authenticated` and not only from `anon`.
  --
  -- The role is switched for real here. This suite runs as the table
  -- owner, and an owner is not subject to its own GRANTs -- so without
  -- the switch these two would call the functions successfully and the
  -- assertions would be asserting nothing.
  set local role authenticated;
  perform pg_temp.check_eq(
    'and this really is running as authenticated',
    current_user::text, 'authenticated');

  perform pg_temp.check_refused(
    'and nobody signed in can file a punch directly',
    format($q$ select public.record_terminal_punch(%L, '42', now(), 'in') $q$,
           v.term),
    '%permission denied%', '42501');
  perform pg_temp.check_refused(
    'nor test a secret at their leisure',
    format($q$ select public.terminal_secret_matches(%L, 'guess') $q$, v.term),
    '%permission denied%', '42501');

  reset role;

  -- CONTROL. HR can, so the first refusal is about the role.
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_true(
    'while HR can add one',
    (select count(*) from public.register_time_terminal(v.org, 'Side door')) = 1);
end $$;

rollback;

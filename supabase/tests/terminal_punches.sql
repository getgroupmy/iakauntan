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

-- =====================================================================
-- record_terminal_punch, rule by rule
--
-- A sweep of `0612`'s definition over this file left fourteen mutants
-- alive. The fixture's employee was on no roster, so lateness and its
-- grace were never measured at all; every rejected punch above was an
-- unknown number, so the terminal, the time and the number were never
-- missing; the out-of-order test sent the later clock-in FIRST, which
-- the earliest-wins rule and its opposite answer alike; and nothing
-- read what a punch does to its terminal, which day a punch near
-- midnight lands on, or that the punch row points at the day it made.
--
-- One roster, fixed dates, one day per rule. A later in-punch after an
-- earlier one; a clock-in inside and outside the ten minutes' grace; a
-- punch at half past seven on a Friday morning in Kuala Lumpur, which
-- is still Thursday in UTC.
--
-- Not asserted, and recorded here: a punch's lateness is measured on any
-- day the roster names -- `clock_in` does the same -- while
-- `recompute_attendance` re-reading a corrected morning gives a rest day
-- or a holiday none. No money reads `late_minutes`, so it is a register
-- that disagrees with itself rather than a wrong payslip.
-- =====================================================================
do $$
declare
  v record; v_off uuid; v_shift uuid; v_res jsonb; v_rec public.attendance_records;
  v_tue date := date '2026-06-02';
  v_wed date := date '2026-06-03';
  v_thu date := date '2026-06-04';
  v_fri date := date '2026-06-05';
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.tp_company('Jam Peraturan Sdn Bhd');
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, grace_minutes, work_days)
  values (v.org, 'DAY', 'Nine to six', '09:00', '18:00', 10, array[0,1,2,3,4,5,6])
  returning id into v_shift;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (v.org, v.emp, v_shift, date '2026-01-01');

  -- REFUSED, AND SAYING WHY.
  perform pg_temp.check_eq('a terminal that is not there says so',
    app.record_terminal_punch(gen_random_uuid(), '42', now(), null) ->> 'problem',
    'No such terminal');
  select r.terminal_id into v_off from public.register_time_terminal(v.org, 'Back door') r;
  update public.time_terminals set is_active = false where id = v_off;
  perform pg_temp.check_eq('a terminal switched off says so',
    app.record_terminal_punch(v_off, '42', now(), null) ->> 'problem',
    'Terminal is switched off');
  perform pg_temp.check_eq('a punch with no time says so',
    app.record_terminal_punch(v.term, '42', null, null) ->> 'problem',
    'A punch needs a time');
  perform pg_temp.check_eq('and a punch with no number',
    app.record_terminal_punch(v.term, '   ', now(), null) ->> 'problem',
    'A punch needs a user number');

  -- TUESDAY. In at 08:50 with no direction, then a stray 09:30 "in",
  -- then 18:00 with no direction: the second undirected punch is the
  -- clock-out, and the later "in" moves neither the arrival nor its
  -- lateness. The number arrives padded with spaces.
  v_res := app.record_terminal_punch(v.term, ' 42 ',
    (v_tue + time '08:50') at time zone 'Asia/Kuala_Lumpur', null);
  perform pg_temp.check_eq('a number sent with spaces is stored without them',
    (select enrolment_no from public.terminal_punches
      where terminal_id = v.term
        and punched_at = (v_tue + time '08:50') at time zone 'Asia/Kuala_Lumpur'), '42');
  perform app.record_terminal_punch(v.term, '42',
    (v_tue + time '09:30') at time zone 'Asia/Kuala_Lumpur', 'in');
  v_res := app.record_terminal_punch(v.term, '42',
    (v_tue + time '18:00') at time zone 'Asia/Kuala_Lumpur', null);
  perform pg_temp.check_eq('an undirected punch after an arrival is the clock-out',
    v_res ->> 'direction', 'out');
  select * into v_rec from public.attendance_records
   where employee_id = v.emp and work_date = v_tue;
  perform pg_temp.check_eq('a later in-punch does not move the arrival',
    v_rec.clock_in::text,
    ((v_tue + time '08:50') at time zone 'Asia/Kuala_Lumpur')::text);
  perform pg_temp.check_eq('nor make an on-time arrival late', v_rec.late_minutes, 0);
  perform pg_temp.check_eq('and the punch points at the day it made',
    (select attendance_id from public.terminal_punches
      where terminal_id = v.term
        and punched_at = (v_tue + time '18:00') at time zone 'Asia/Kuala_Lumpur'),
    v_rec.id);

  -- WEDNESDAY, five minutes late against ten minutes' grace: on time.
  perform app.record_terminal_punch(v.term, '42',
    (v_wed + time '09:05') at time zone 'Asia/Kuala_Lumpur', 'in');
  select * into v_rec from public.attendance_records
   where employee_id = v.emp and work_date = v_wed;
  perform pg_temp.check_eq('inside the grace is on time', v_rec.status::text, 'present');
  -- THURSDAY, half an hour late: twenty minutes past the grace.
  perform app.record_terminal_punch(v.term, '42',
    (v_thu + time '09:30') at time zone 'Asia/Kuala_Lumpur', 'in');
  select * into v_rec from public.attendance_records
   where employee_id = v.emp and work_date = v_thu;
  perform pg_temp.check_eq('outside it is late', v_rec.status::text, 'late');
  perform pg_temp.check_eq('by what is past the grace', v_rec.late_minutes, 20);

  -- FRIDAY at 07:30 in Kuala Lumpur, Thursday 23:30 in UTC.
  perform app.record_terminal_punch(v.term, '42',
    (v_fri + time '07:30') at time zone 'Asia/Kuala_Lumpur', 'in');
  perform pg_temp.check_true('a punch before eight in the morning is that morning''s',
    exists (select 1 from public.attendance_records
             where employee_id = v.emp and work_date = v_fri));

  -- THE TERMINAL. Seen just now; and an old punch arriving last does
  -- not wind its latest punch back.
  perform app.record_terminal_punch(v.term, '42',
    (v_tue + time '07:00') at time zone 'Asia/Kuala_Lumpur', 'in');
  perform pg_temp.check_eq('the terminal was seen just now',
    (select last_seen_at::text from public.time_terminals where id = v.term), now()::text);
  perform pg_temp.check_eq('and its latest punch is still Friday''s',
    (select last_punch_at::text from public.time_terminals where id = v.term),
    ((v_fri + time '07:30') at time zone 'Asia/Kuala_Lumpur')::text);
end $$;

rollback;

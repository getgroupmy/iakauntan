-- =====================================================================
-- iAkauntan :: the work that only a scheduler may start
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheduled_work.sql
--
-- Every other file here asserts that a function computes the right
-- answer when it is called. This one asserts that something calls it.
--
-- The two failures are unrelated and only one of them is loud. A
-- function that computes the wrong number breaks a test the moment it
-- is written. A function that is never invoked passes every test it
-- has, forever, because the tests are its only caller — which is
-- exactly what happened to `ticket_sla_sweep`: 0193 wrote it, 0194
-- built a lifecycle on it, `ticketing.sql` asserted its arithmetic to
-- the minute, and a comment in that file even reasoned about
-- re-alerting "every five minutes". Nothing scheduled it. In a live
-- tenant no deadline was ever marked as passed.
--
-- ---------------------------------------------------------------------
-- How reachability is decided
--
-- Start with every `cron.job` command, strip the `--` comments, and
-- look for a call shape. Any `app` or `public` function named that way
-- is reached; append its own definition and go round again until
-- nothing new appears. What comes out is the set of functions the
-- scheduler can actually get to.
--
-- Stripping the comments matters. Half the function headers in this
-- schema name their neighbours while explaining themselves, and a check
-- that counted those would call almost everything reachable and assert
-- nothing at all.
--
-- It is still an over-approximation: a name inside a string literal
-- counts. That is the safe direction — it can call something reached
-- that is not, so a passing run is weaker than it looks, but it cannot
-- call something unreached that is. The failure this file exists to
-- catch is a function nothing anywhere names, and no amount of
-- over-approximation invents a caller for that.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.scheduler_reaches()
returns text[] language plpgsql as $$
declare
  v_text  text;
  v_seen  text[] := '{}';
  v_added integer;
  r record;
begin
  select coalesce(string_agg(command, E'\n'), '') into v_text from cron.job;

  loop
    v_added := 0;
    for r in
      select n.nspname, p.proname, p.oid
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('app', 'public')
         and p.prokind = 'f'
         and p.prolang <> (select oid from pg_language where lanname = 'c')
    loop
      continue when (r.nspname || '.' || r.proname) = any(v_seen);
      -- The call shape, not the bare word: `grant`, `comment on` and
      -- `revoke` all name a function without calling it. Qualified or
      -- not — the cron commands say `app.run_daily_jobs(`, and a
      -- boundary that excluded a leading dot matched none of them.
      continue when v_text !~ ('(^|[^a-z0-9_])' || r.proname || '\s*\(');

      v_seen := v_seen || (r.nspname || '.' || r.proname);
      v_text := v_text || E'\n' ||
                regexp_replace(pg_get_functiondef(r.oid), '--[^\n]*', '', 'g');
      v_added := v_added + 1;
    end loop;
    exit when v_added = 0;
  end loop;

  return v_seen;
end $$;

-- ---------------------------------------------------------------------
-- Everything that has to be driven, is
-- ---------------------------------------------------------------------
do $$
declare
  v_reached text[] := pg_temp.scheduler_reaches();
  v_name    text;
  -- The list is the claim. A periodic function added without a line
  -- here is not caught by this file, so adding the line is part of
  -- writing one — same as adding the test file to `ci.yml`.
  v_periodic constant text[] := array[
    'app.run_daily_jobs',
    'app.run_recurring_journals',
    'app.run_recurring_documents',
    'app.queue_overdue_reminders',
    'app.queue_sales_digest',
    'app.sweep_idempotency_keys',
    'app.purge_audit_history',
    'app.close_attendance_day',
    'app.expire_carried_leave',
    'app.queue_activity_reminders',
    'app.roll_leave_year',
    'app.roll_einvoice_consolidation',
    'public.chat_expire_calls',
    'public.prune_device_tokens',
    'public.ticket_sla_sweep'
  ];
begin
  -- Stated first. If the walk found nothing the loop below passes
  -- vacuously for every name, and a broken check reads as a green run.
  perform pg_temp.check_true(
    'the walk over the scheduled commands found something at all',
    array_length(v_reached, 1) >= array_length(v_periodic, 1));

  foreach v_name in array v_periodic loop
    -- Named individually rather than as one set difference, because
    -- "one of twelve is unscheduled" is not a useful thing to be told.
    perform pg_temp.check_true(
      v_name || ' is reachable from a scheduled job',
      v_name = any(v_reached));
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- And the SLA sweep runs at the cadence an SLA is measured in
-- ---------------------------------------------------------------------
do $$
declare
  v_schedule text;
  v_every    integer;
begin
  select schedule into v_schedule from cron.job where jobname = 'iakauntan-sla-sweep';
  perform pg_temp.check_true(
    'the sweep has a job of its own, so a failure in it cannot take the '
    'nightly run down with it',
    v_schedule is not null);

  -- `sla_targets.response_minutes` only has to be greater than zero, so
  -- a fifteen-minute first response is a promise this schema can hold.
  -- A daily sweep would mark that breach up to a day after it happened,
  -- which is true and no use to anybody on shift.
  v_every := (regexp_match(v_schedule, '^\*/([0-9]+) \* \* \* \*$'))[1]::integer;
  perform pg_temp.check_true(
    'and runs at least every fifteen minutes: ' || v_schedule,
    v_every is not null and v_every <= 15);
end $$;

-- ---------------------------------------------------------------------
-- And the purge keeps records for the seven years the Act asks for
-- ---------------------------------------------------------------------
-- Section 245(5) of the Companies Act 2016 requires accounting records
-- to be kept for seven years, and a record of who changed them is part
-- of them. `docs/security.md` says so and says how it is done:
--
--     `app.purge_audit_history(7)` runs weekly under `pg_cron` as its
--     own job rather than a line in `run_daily_jobs`, so a purge that
--     fails cannot take the recurring invoices with it.
--
-- Both halves of that were already true and only one was asserted.
-- `security_audit.sql` proves the function keeps six years and eleven
-- months and drops eight, calling it with a literal 7; the block above
-- proves the function is reachable from *some* scheduled job. Neither
-- reads the number in the command the scheduler actually runs.
--
-- So `purge_audit_history(1)` in that string would pass every assertion
-- in this repository while destroying a company's statutory records six
-- years early, and the only sign would be an audit trail that started
-- last year. `CLAUDE.md`: "anything touching EPF, SOCSO, EIS, PCB or an
-- SSM deadline needs a test that would fail if the number moved."
do $$
declare
  v_schedule text;
  v_command  text;
  v_years    integer;
begin
  select schedule, command into v_schedule, v_command
    from cron.job where jobname = 'iakauntan-purge-audit';

  perform pg_temp.check_true(
    'the purge has a job of its own, so a purge that fails cannot take '
    'the nightly run with it',
    v_command is not null);

  -- The number, out of the command the scheduler runs -- not out of a
  -- literal written beside the assertion.
  v_years := (regexp_match(v_command, 'purge_audit_history\s*\(\s*([0-9]+)\s*\)'))[1]::integer;
  perform pg_temp.check_eq(
    'and keeps seven years, which is what section 245(5) asks for: '
    || coalesce(v_command, '(no job)'),
    v_years, 7);

  -- Weekly, and the reason is in the doc: its own cadence, not the
  -- daily run's. Asserted as "not more often than daily" rather than
  -- "exactly Sunday", because purging more often is harmless and the
  -- thing that would matter is it being folded back into the daily job.
  perform pg_temp.check_true(
    'on its own schedule rather than inside the daily run: '
    || coalesce(v_schedule, '(none)'),
    v_schedule is not null and v_schedule <> (
      select schedule from cron.job where jobname = 'iakauntan-daily'));

  -- And it is genuinely a separate command, not `run_daily_jobs` with a
  -- purge hidden inside it.
  perform pg_temp.check_true(
    'and the daily run does not purge anything itself',
    not exists (select 1 from cron.job
                 where jobname = 'iakauntan-daily'
                   and command ~ 'purge_audit_history'));
end $$;

-- ---------------------------------------------------------------------
-- The shape the scheduler calls it in: no argument, every tenant
-- ---------------------------------------------------------------------
--
-- `ticketing.sql` always passes an organization. The cron command does
-- not, and one tenant's overdue ticket must not be what stops another
-- tenant's from being marked.
do $$
declare
  v_a uuid; v_b uuid; v_ta uuid; v_tb uuid; v_n integer;
begin
  v_a := pg_temp.test_org('Sweep One Sdn Bhd');
  v_b := pg_temp.test_org('Sweep Two Sdn Bhd');

  v_ta := public.create_ticket(v_a, 'Nobody answered this one', null);
  v_tb := public.create_ticket(v_b, 'Nor this one', null);

  update public.tickets
     set response_due_at   = now() - interval '1 hour',
         resolution_due_at = now() - interval '1 hour'
   where id in (v_ta, v_tb);

  v_n := public.ticket_sla_sweep();

  perform pg_temp.check_true(
    'a sweep with no organization marks both companies'' overdue tickets',
    (select response_breached and resolution_breached
       from public.tickets where id = v_ta)
    and
    (select response_breached and resolution_breached
       from public.tickets where id = v_tb));
  perform pg_temp.check_true(
    'and counts both rather than stopping at the first: ' || v_n,
    v_n >= 2);
end $$;

-- ---------------------------------------------------------------------
-- And the nightly run actually does the HR work wired into it
-- ---------------------------------------------------------------------
--
-- `run_daily_jobs` wraps its per-organization work in an exception
-- handler that turns any failure into a `raise warning`. That is the
-- right choice — a company whose roster is in a state the attendance
-- pass cannot read must not stop the recurring invoices behind it — and
-- it means a genuine bug in either function is swallowed into a log
-- nobody reads.
--
-- Reachability is asserted above and is not the same claim. This is the
-- run, on a company that holds the module, with data that should move.
-- Without it, `close_attendance_day` and `expire_carried_leave` could
-- each raise on every organization every night and every test here
-- would still pass.
do $$
declare
  v_org   uuid;
  v_shift uuid;
  v_emp   uuid;
  v_type  uuid;
  v_yday  date := current_date - 1;
begin
  v_org := pg_temp.test_org('Kerja Malam Sdn Bhd', array['hr']);

  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, work_days, is_default)
  values (v_org, 'DAY', 'Office hours', '09:00', '18:00',
          array[0,1,2,3,4,5,6], true)
  returning id into v_shift;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti', v_yday - 90, 'active') returning id into v_emp;
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from)
  values (v_org, v_emp, v_shift, v_yday - 90);

  -- Every weekday is a working day for this shift, so yesterday is one
  -- whatever day the suite happens to run on.
  insert into public.attendance_records
    (org_id, employee_id, work_date, shift_id, clock_in, status)
  values (v_org, v_emp, v_yday, v_shift,
          (v_yday + time '09:00') at time zone 'Asia/Kuala_Lumpur', 'present');

  insert into public.leave_types
    (org_id, code, name, default_days, max_carry_forward,
     carry_forward_expiry_months)
  values (v_org, 'AL', 'Annual', 14, 5, 1) returning id into v_type;
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days,
     carried_forward, taken_days)
  values (v_org, v_emp, v_type, extract(year from current_date)::integer,
          14, 5, 0);

  perform app.run_daily_jobs(current_date);

  perform pg_temp.check_eq(
    'the nightly run marks yesterday''s forgotten punch-out',
    (select r.status::text from public.attendance_records r
      where r.employee_id = v_emp and r.work_date = v_yday), 'incomplete');
  perform pg_temp.check_eq('and lapses the carried leave that was due to',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type), 0.00);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Every scheduled command actually runs
--
-- `0392` is why this block exists. `app.roll_einvoice_consolidation`
-- compared a status against an enum literal that does not exist and
-- raised `22P02` on every call — for as long as the function had been
-- in the repository. Nothing noticed, because the only caller is
-- `pg_cron` and nobody reads a cron log.
--
-- This file already asserts that each job **is** scheduled. That is a
-- different question from whether the thing scheduled **works**, and
-- `0392` is what the gap between the two costs: a statutory return
-- LHDN expects every month, never once gathered.
--
-- So: take the commands out of `cron.job` and run them. Derived from
-- the schedule rather than from a list kept by hand, because a hand-
-- kept list is a list that drifts — and the job this would have caught
-- was one nobody thought to add to a list.
--
-- It is a smoke test and says so: it asserts that each command
-- completes, not that it did the right thing. What each one computes is
-- asserted in its own file. What is caught here is the class of fault
-- that makes a job fail on its first statement, which is the class that
-- has actually happened.
--
-- One thing this cannot do is take a calendar branch. `run_daily_jobs`
-- is called below with whatever today is, and `0392`'s fault lived
-- behind `if extract(day from p_on) = 1`. `supabase/tests/monthly_jobs.sql`
-- pins the dates for that reason, and its header says so.
-- ---------------------------------------------------------------------
do $$
declare
  j       record;
  v_n     integer := 0;
  v_bad   text := '';
begin
  for j in select jobid, command from cron.job order by jobid
  loop
    begin
      execute j.command;
      v_n := v_n + 1;
    exception when others then
      v_bad := v_bad || format(E'\n  job %s: %s\n    %s',
                               j.jobid, j.command, sqlerrm);
    end;
  end loop;

  if v_bad <> '' then
    raise exception 'FAIL a scheduled command does not run: %', v_bad;
  end if;

  -- A run that found no jobs is not a run that passed. The same hole
  -- this suite's own runner had, one layer down.
  perform pg_temp.check_true(
    format('every scheduled command runs (%s of them)', v_n), v_n >= 4);
end $$;

rollback;

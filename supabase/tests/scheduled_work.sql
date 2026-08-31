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

rollback;

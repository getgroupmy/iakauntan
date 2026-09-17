-- =====================================================================
-- iAkauntan :: the demo puts itself back, and says when it could not
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_rebuild_schedule.sql
--
-- `0552` schedules `app.demo_rebuild()` every six hours. Two things
-- about that are worth asserting and neither is the arithmetic of a
-- rebuild, which `demo_rebuild.sql` already owns.
--
-- The first is that a deployment with no demo does not grow one. The
-- job is a rebuild, and a build that runs by itself in the small hours
-- on somebody's own installation is a different and unwelcome thing.
--
-- The second is that a failure leaves a trace. `app.demo_teardown()`
-- refuses when a company marked `is_demo` has a real member (`0182`),
-- and `0551` is the other way it fails. Under a scheduler both are
-- rolled back and silent: pg_cron writes to `cron.job_run_details`,
-- which nobody reads, and the transaction takes everything else with
-- it. The wrapper's whole job is to catch, write the reason down, and
-- return normally so the row survives.
--
-- The fixture for the failure is the real guard rather than a mutant:
-- an ordinary company, flagged demo, with an ordinary person in it.
-- That is the state 0182 was written for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- It is scheduled, six-hourly, and it names the wrapper
-- ---------------------------------------------------------------------
do $$
declare
  v_schedule text;
  v_command  text;
begin
  select schedule, command into v_schedule, v_command
    from cron.job where jobname = 'iakauntan-demo-rebuild';

  perform pg_temp.check_true('the demo rebuild is scheduled',
    v_schedule is not null);

  -- Six firings' worth of hours, six apart. Asserted as the set rather
  -- than as the string, so the offset may move and the cadence may not.
  perform pg_temp.check_eq('four times a day, six hours apart',
    (select string_agg(h::text, ',' order by h)
       from unnest(string_to_array(split_part(v_schedule, ' ', 2), ',')) x(h)),
    '11,17,23,5');

  perform pg_temp.check_true('at the top of the hour',
    split_part(v_schedule, ' ', 1) = '0');

  perform pg_temp.check_true('and it calls the wrapper, not demo_rebuild',
    v_command like '%rebuild_demo_on_schedule%'
      and v_command not like '%demo_rebuild(%');
end $$;

-- ---------------------------------------------------------------------
-- Nobody may call it from a browser
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the wrapper is not granted to anon',
    not has_function_privilege('anon',
      'app.rebuild_demo_on_schedule()', 'execute'));
  perform pg_temp.check_true('nor to a signed-in user',
    not has_function_privilege('authenticated',
      'app.rebuild_demo_on_schedule()', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- No demo, no build
-- ---------------------------------------------------------------------
do $$
declare
  v_orgs_before integer;
  v_orgs_after  integer;
begin
  perform pg_temp.check_eq('the fixture starts with no demo tenant',
    (select count(*) from public.organizations where is_demo), 0::bigint);

  select count(*) into v_orgs_before from public.organizations;
  perform app.rebuild_demo_on_schedule();
  select count(*) into v_orgs_after from public.organizations;

  -- The assertion that would fail if the guard were removed: without
  -- it this call seeds eleven companies onto a database that asked for
  -- none.
  perform pg_temp.check_eq('a deployment with no demo does not grow one',
    v_orgs_after, v_orgs_before);
  perform pg_temp.check_eq('and there is nothing to report',
    (select count(*) from app.demo_rebuild_runs), 0::bigint);
end $$;

-- ---------------------------------------------------------------------
-- A rebuild that cannot run says so, and leaves the demo standing
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_run  record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Sebenar Sdn Bhd', array['crm']);

  -- 0182's case: the flag is wrong, and a real person is inside it.
  update public.organizations set is_demo = true where id = v_org;

  -- Not `check_refused`: the point is that it does NOT raise. A
  -- scheduled call that throws is a call whose reason is rolled back
  -- with it.
  perform app.rebuild_demo_on_schedule();

  select * into v_run from app.demo_rebuild_runs
   order by id desc limit 1;

  -- `found`, not `v_run is not null`: a composite is null only when
  -- every field of it is, and a failure row has no summary.
  perform pg_temp.check_true('the failure is written down', found);
  perform pg_temp.check_true('and marked as one', not v_run.ok);
  perform pg_temp.check_true('with the reason the teardown gave',
    v_run.error ilike '%' || (select email from auth.users
                               where id = auth.uid()) || '%');
  perform pg_temp.check_true('and how long it took',
    v_run.finished_at >= v_run.started_at);

  -- The half that matters more than the row: a rebuild that could not
  -- run has not deleted anything on its way to failing.
  perform pg_temp.check_eq('the company it refused to delete is still there',
    (select count(*) from public.organizations where id = v_org), 1::bigint);
end $$;

rollback;

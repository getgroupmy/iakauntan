-- =====================================================================
-- iAkauntan :: 0552 a demo that puts itself back
--
-- The demo is a shop window with the door unlocked. Anybody who signs
-- in as demo@iakauntan.com can post a journal, void a bill, delete a
-- contact or leave a half-typed invoice on the screen, and every one
-- of those stays there until somebody runs `app.demo_rebuild()` by
-- hand. Asked for: that it happens by itself, every six hours.
--
-- ---------------------------------------------------------------------
-- Rebuild, not build
--
-- The job does nothing unless a demo tenant already exists. That makes
-- this a rebuild in the sense the name promises, and it keeps a
-- deployment that has no demo -- a customer's own, or one where the
-- demo was deliberately torn down and meant to stay gone -- from
-- growing eleven fictional companies at three in the morning because
-- a migration ran.
--
-- `app.demo_rebuild()` tears down and reseeds in one transaction, so
-- the guard cannot be undone by a rebuild that fails halfway: a
-- failure rolls the teardown back with it and the demo orgs are still
-- there for the next firing to find.
--
-- ---------------------------------------------------------------------
-- What happens when it fails
--
-- `app.demo_teardown()` REFUSES if a company marked `is_demo` has a
-- member who is not a demo auth user (`0182`) -- the guard that stops
-- a mis-flagged real tenant being deleted and reported as success.
-- On a schedule that refusal has to be louder than an exception nobody
-- reads: pg_cron records failures in `cron.job_run_details`, which is
-- not where anybody looks, and rolls the whole call back, so a plain
-- `raise` would leave no trace inside this database at all.
--
-- So the wrapper catches, writes the reason into
-- `app.demo_rebuild_runs`, and returns normally -- which is what makes
-- the row survive. `0551` is the example of why this matters: a
-- retired module made the rebuild fail, the rebuild was being run by
-- hand at the time, and the error was read within the minute. The same
-- failure on a schedule would have been a demo quietly not rebuilding
-- for as long as it took somebody to notice the data was stale.
--
-- The table keeps its last forty rows, which is ten days at this
-- cadence.
--
-- ---------------------------------------------------------------------
-- When
--
-- `0 5,11,17,23 * * *` UTC, six-hourly, which in Malaysian time is
-- 13:00, 19:00, 01:00 and 07:00. The offset is chosen so one firing
-- lands just before the working day rather than inside it: any
-- six-hour cadence must cross office hours twice, and 07:00 means
-- whoever opens the demo in the morning opens a fresh one.
--
-- The job runs as the migration's role, as every other job scheduled
-- here does (`0060`, `0356`, `0366`). To pause it without a migration:
-- `select cron.unschedule('iakauntan-demo-rebuild')`.
--
-- Note on the number: 0552 was briefly used by a migration that was
-- withdrawn before it ever applied (see `3329034`). It reached no
-- database, and the number is reused rather than skipped.
-- =====================================================================

create table if not exists app.demo_rebuild_runs (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean not null,
  summary     text,
  error       text
);

comment on table app.demo_rebuild_runs is
  'One row per firing of the six-hourly demo rebuild (0552). A failed '
  'rebuild rolls its own work back, so this row is the only record of '
  'it inside the database.';

revoke all on table app.demo_rebuild_runs from public, anon, authenticated;

create or replace function app.rebuild_demo_on_schedule()
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_summary text;
begin
  -- Rebuild, not build. Nothing to put back means nothing to do.
  if not exists (select 1 from public.organizations where is_demo) then
    return;
  end if;

  begin
    v_summary := app.demo_rebuild();
  exception when others then
    -- Everything the rebuild did is already rolled back to this block.
    -- Returning normally is what lets the row below survive to say so.
    insert into app.demo_rebuild_runs (started_at, finished_at, ok, error)
    values (v_started, clock_timestamp(), false,
            left(sqlstate || ' ' || sqlerrm, 2000));
    return;
  end;

  insert into app.demo_rebuild_runs (started_at, finished_at, ok, summary)
  values (v_started, clock_timestamp(), true, left(v_summary, 2000));

  delete from app.demo_rebuild_runs
   where id <= (select max(id) - 40 from app.demo_rebuild_runs);
end $$;

comment on function app.rebuild_demo_on_schedule() is
  'The six-hourly demo rebuild. Does nothing where no demo tenant '
  'exists; records the outcome either way in app.demo_rebuild_runs.';

revoke all on function app.rebuild_demo_on_schedule()
  from public, anon, authenticated;

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'iakauntan-demo-rebuild')
  then
    perform cron.unschedule('iakauntan-demo-rebuild');
  end if;
  perform cron.schedule(
    'iakauntan-demo-rebuild',
    '0 5,11,17,23 * * *',
    $job$select app.rebuild_demo_on_schedule()$job$);
end
$do$;

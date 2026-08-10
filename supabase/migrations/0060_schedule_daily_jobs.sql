-- =====================================================================
-- iAkauntan :: 0060 something to actually run the jobs
--
-- 17:00 UTC is 01:00 in Malaysia: after the day's work, before anyone
-- is back at a keyboard, and on the 1st it is still the same calendar
-- day in MYT that the consolidation period closed — which is why the
-- job is passed the Malaysian date rather than the server's.
-- =====================================================================

create extension if not exists pg_cron;

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'iakauntan-daily') then
    perform cron.unschedule('iakauntan-daily');
  end if;
  perform cron.schedule(
    'iakauntan-daily',
    '0 17 * * *',
    $job$select app.run_daily_jobs((now() at time zone 'Asia/Kuala_Lumpur')::date)$job$);
end
$do$;

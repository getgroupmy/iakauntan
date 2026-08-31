-- =====================================================================
-- iAkauntan :: 0356 the SLA clock nobody wound
--
-- 0193 wrote `ticket_sla_sweep`, 0194 built the lifecycle around it and
-- `supabase/tests/ticketing.sql` asserts its arithmetic to the minute.
-- All of that is correct and none of it ever ran: the only two callers
-- in the repository are that test and `0195_demo_service_desk`, which
-- calls it once while seeding. Nothing schedules it.
--
-- The consequence is not a crash, which is why it survived four
-- ticketing migrations. `response_due_at` and `resolution_due_at` are
-- computed when the ticket is raised and are correct. What never
-- happened is the moment they pass: `response_breached` stayed false
-- forever, no `sla_breach` row was ever written to `ticket_events`, and
-- a support manager reading the ticket list saw a clean board while
-- every deadline on it had gone.
--
-- ---------------------------------------------------------------------
-- Why five minutes and not the nightly job
--
-- `sla_targets.response_minutes` is an integer greater than zero, so a
-- P1 promising a fifteen-minute first response is a thing this schema
-- can express and a thing a support contract routinely says. Folding
-- the sweep into `app.run_daily_jobs` at 17:00 UTC would mark that
-- breach up to a day after it happened — technically true and useless
-- to anybody on shift.
--
-- Five minutes is the coarsest cadence at which the flag is still
-- honest against the tightest promise the schema allows. It is its own
-- job rather than a line in the daily one for the reason
-- `iakauntan-purge-audit` is: a sweep that fails must not be able to
-- take the recurring invoices down with it.
--
-- ---------------------------------------------------------------------
-- What a five-minute job needs from the indexes
--
-- The sweep is called with no argument, so it runs across every
-- organization at once and `tickets_open_deadlines` — leading on
-- `org_id` — cannot serve it. Two hundred and eighty-eight scans of the
-- whole ticket table a day is not a cost worth carrying.
--
-- Both index predicates exclude tickets already marked, so a ticket
-- leaves the index the moment the sweep has dealt with it and what is
-- scanned is only what is still running against a deadline.
-- =====================================================================

create index if not exists tickets_response_running
  on public.tickets (response_due_at)
  where deleted_at is null
    and first_response_at is null
    and not response_breached
    and status not in ('resolved', 'closed', 'cancelled');

create index if not exists tickets_resolution_running
  on public.tickets (resolution_due_at)
  where deleted_at is null
    and resolved_at is null
    and not resolution_breached
    and status not in ('resolved', 'closed', 'cancelled');

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'iakauntan-sla-sweep') then
    perform cron.unschedule('iakauntan-sla-sweep');
  end if;
  perform cron.schedule(
    'iakauntan-sla-sweep',
    '*/5 * * * *',
    $job$select public.ticket_sla_sweep()$job$);
end
$do$;

comment on function public.ticket_sla_sweep(uuid) is
  'Marks response and resolution deadlines that have passed and writes '
  'the breach to ticket_events. Scheduled as iakauntan-sla-sweep every '
  'five minutes; passing an organization narrows it, passing nothing '
  'sweeps them all.';

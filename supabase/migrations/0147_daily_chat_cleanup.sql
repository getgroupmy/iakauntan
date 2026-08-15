-- =====================================================================
-- iAkauntan :: run the two tidy-ups that nothing was running
--
-- 0140 wrote `chat_expire_calls` and 0141 wrote `prune_device_tokens`,
-- and both said in their own comments that nothing scheduled them. That
-- was true for three migrations and is the reason this file exists.
--
-- ---------------------------------------------------------------------
-- Why they are here rather than in a workflow
--
-- 0060 already has `pg_cron` calling `app.run_daily_jobs` at 17:00 UTC —
-- one in Malaysia, after the day's work. Adding a GitHub workflow would
-- mean a second scheduler, a credential for it, and a job billed at a
-- minute a run for two statements that take milliseconds. These belong
-- inside the nightly pass that already exists.
--
-- ---------------------------------------------------------------------
-- Daily is the right cadence for both, for different reasons
--
-- `chat_expire_calls` does not stop a phone ringing — `chat_incoming_calls`
-- already filters on `ringing_until > now()`, so a call past its deadline
-- reads as not ringing whether or not this has run. What it fixes is the
-- *label*: without it the history says a call has been "ringing" since
-- Tuesday. That is worth correcting once a day and not worth a scheduler
-- of its own.
--
-- `prune_device_tokens` removes registrations nobody has presented in
-- ninety days — an app uninstalled without signing out. Nothing depends
-- on it having run; the sender already drops tokens the push service
-- rejects. This stops the register growing forever with rows that will
-- never be delivered to.
-- =====================================================================

create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  -- The two new lines. Both are tidy-ups: nothing downstream waits on
  -- either, which is why a failure in one must not take the recurring
  -- invoices down with it.
  begin
    perform public.chat_expire_calls();
  exception when others then
    raise warning 'chat_expire_calls failed: %', sqlerrm;
  end;

  begin
    perform public.prune_device_tokens();
  exception when others then
    raise warning 'prune_device_tokens failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;

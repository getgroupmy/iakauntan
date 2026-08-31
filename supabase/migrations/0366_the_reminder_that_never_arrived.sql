-- =====================================================================
-- iAkauntan :: 0366 the reminder that never arrived
--
-- `activities.reminder_at` and `reminder_sent` have been columns since
-- `0008`. Nothing writes them, nothing reads them, and no screen offers
-- either — so a salesperson who set a reminder to ring somebody back
-- was reminded by nothing, and the column recording that the reminder
-- had gone stayed false because it had.
--
-- This is `0356`'s shape one table over: a feature whose data model is
-- finished and whose driver was never written. The difference is that
-- `ticket_sla_sweep` at least existed to be scheduled; here the sweep
-- had to be written too.
--
-- ---------------------------------------------------------------------
-- Where the reminder goes
--
-- Into `email_outbox`, which already exists, is already drained by a
-- workflow, already carries a `dedupe_key`, and is already the way this
-- system tells somebody something. Inventing a notification table to
-- put one line in would be a second delivery mechanism to keep working.
--
-- The person is `assigned_to`, and an activity assigned to nobody is
-- skipped rather than sent to whoever created it: a reminder addressed
-- to somebody who did not ask for it is how people learn to ignore
-- them.
--
-- ---------------------------------------------------------------------
-- How late it can be, said plainly
--
-- This runs every fifteen minutes, and the mail then leaves on the
-- outbox's own schedule — half-hourly through the working day, per
-- `send-email.yml`, for the billing reason set out there. So a reminder
-- set for half past nine arrives some time before eleven.
--
-- That makes this a nudge rather than an alarm, and it should be
-- described as one wherever it is offered. Anything tighter means the
-- outbox drain gets tighter first, which is a decision about GitHub
-- Actions minutes rather than about reminders.
--
-- ---------------------------------------------------------------------
-- What is not reminded about
--
-- An activity somebody has already completed, and one that has been
-- cancelled. Being reminded to make a call you made yesterday is worse
-- than not being reminded at all: it teaches people the reminders are
-- wrong, and after that the useful ones are ignored too.
-- =====================================================================

create index if not exists activities_reminder_due
  on public.activities (reminder_at)
  where reminder_at is not null and not reminder_sent;

create or replace function app.queue_activity_reminders(
  p_org uuid, p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  a       record;
  v_to    text;
  v_who   text;
  v_n     integer := 0;
begin
  for a in
    select act.id, act.subject, act.description, act.due_date,
           act.assigned_to, act.activity_type,
           c.name as contact_name,
           -- A lead has no `name`: it has a company and a person, and
           -- either can be missing. The company first, because "ring
           -- Sinar Teknologi back" is what somebody wrote in their
           -- diary.
           coalesce(nullif(btrim(l.company_name), ''),
                    nullif(btrim(concat_ws(' ', l.first_name, l.last_name)), ''))
             as lead_name
      from public.activities act
      left join public.contacts c on c.id = act.contact_id
      left join public.leads l on l.id = act.lead_id
     where act.org_id = p_org
       and act.reminder_at is not null
       and not act.reminder_sent
       and act.reminder_at <= p_now
       and act.completed_at is null
       and act.status <> 'cancelled'
       and act.assigned_to is not null
  loop
    select u.email into v_to from auth.users u where u.id = a.assigned_to;

    -- Marked whatever happens. A person with no e-mail address on file
    -- cannot be told, and leaving the flag false would make this try
    -- again every fifteen minutes for ever.
    update public.activities set reminder_sent = true where id = a.id;
    v_n := v_n + 1;
    continue when coalesce(btrim(v_to), '') = '';

    v_who := coalesce(a.contact_name, a.lead_name);

    insert into public.email_outbox
      (org_id, to_email, subject, body, dedupe_key)
    values (
      p_org, v_to,
      'Reminder: ' || a.subject,
      a.subject
        || case when v_who is null then '' else E'\n' || v_who end
        || case when a.due_date is null then ''
                else E'\n' || 'Due ' ||
                     to_char(a.due_date at time zone 'Asia/Kuala_Lumpur',
                             'FMDay DD Mon YYYY, HH12:MIam') end
        || case when coalesce(btrim(a.description), '') = '' then ''
                else E'\n\n' || a.description end,
      -- The activity's own id. A reminder queued twice is a reminder
      -- somebody stops reading, and `reminder_sent` alone would not
      -- stop a re-run that had already inserted the row.
      'activity-reminder:' || a.id)
    on conflict do nothing;
  end loop;

  return v_n;
end $$;

revoke all on function app.queue_activity_reminders(uuid, timestamptz)
  from public, anon, authenticated;

comment on function app.queue_activity_reminders(uuid, timestamptz) is
  'Turns a due activity reminder into an outbox message for whoever the '
  'activity is assigned to. Skips one already completed or cancelled, '
  'and marks reminder_sent whether or not the person has an address on '
  'file, so a missing one does not retry for ever.';

-- ---------------------------------------------------------------------
-- Every quarter of an hour, across every company that holds the module
-- ---------------------------------------------------------------------
create or replace function app.queue_all_activity_reminders()
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare o record;
begin
  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    begin
      if app.has_module(o.id, 'crm') then
        perform app.queue_activity_reminders(o.id);
      end if;
    exception when others then
      raise warning 'queue_activity_reminders failed for %: %', o.id, sqlerrm;
    end;
  end loop;
end $$;

revoke all on function app.queue_all_activity_reminders()
  from public, anon, authenticated;

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'iakauntan-activity-reminders') then
    perform cron.unschedule('iakauntan-activity-reminders');
  end if;
  perform cron.schedule(
    'iakauntan-activity-reminders',
    '*/15 * * * *',
    $job$select app.queue_all_activity_reminders()$job$);
end
$do$;

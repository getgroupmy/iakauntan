-- =====================================================================
-- iAkauntan :: the reminder that never arrived
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/activity_reminders.sql
--
-- `activities.reminder_at` and `reminder_sent` have been columns since
-- `0008` and nothing wrote or read either. A salesperson who set a
-- reminder to ring somebody back was reminded by nothing, and the
-- column that records the reminder having gone stayed false because it
-- had.
--
-- The four refusals are what stop a reminder system being worse than
-- none. Being reminded to make a call you made yesterday teaches people
-- the reminders are wrong, and after that the useful ones are ignored
-- too.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_me    uuid := pg_temp.test_user();
  v_them  uuid;
  v_cust  uuid;
  v_due   uuid;
  v_done  uuid;
  v_off   uuid;
  v_soon  uuid;
  v_nobody uuid;
  v_n     integer;
begin
  v_org := pg_temp.test_org('Jualan Ingat Sdn Bhd');
  v_them := pg_temp.another_user('colleague@example.test');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Encik Rashid', 'customer') returning id into v_cust;

  -- Due an hour ago and still to do: the one reminder that should go.
  insert into public.activities
    (org_id, activity_type, subject, contact_id, assigned_to,
     due_date, reminder_at)
  values (v_org, 'call', 'Ring him back about the quotation', v_cust, v_me,
          now() + interval '2 hours', now() - interval '1 hour')
  returning id into v_due;

  -- Already made the call.
  insert into public.activities
    (org_id, activity_type, subject, contact_id, assigned_to,
     reminder_at, completed_at)
  values (v_org, 'call', 'Rang him yesterday', v_cust, v_me,
          now() - interval '1 hour', now() - interval '20 hours')
  returning id into v_done;

  -- Called off.
  insert into public.activities
    (org_id, activity_type, subject, contact_id, assigned_to,
     reminder_at, status)
  values (v_org, 'meeting', 'Meeting he cancelled', v_cust, v_me,
          now() - interval '1 hour', 'cancelled')
  returning id into v_off;

  -- Not yet.
  insert into public.activities
    (org_id, activity_type, subject, contact_id, assigned_to, reminder_at)
  values (v_org, 'call', 'Next week''s call', v_cust, v_me,
          now() + interval '3 days')
  returning id into v_soon;

  -- Nobody to remind.
  insert into public.activities
    (org_id, activity_type, subject, contact_id, reminder_at)
  values (v_org, 'task', 'Somebody should do this', v_cust,
          now() - interval '1 hour')
  returning id into v_nobody;

  v_n := app.queue_activity_reminders(v_org);

  perform pg_temp.check_eq('one reminder is due', v_n, 1);
  perform pg_temp.check_eq('and it is in the outbox',
    (select count(*) from public.email_outbox
      where org_id = v_org
        and dedupe_key = 'activity-reminder:' || v_due), 1);
  perform pg_temp.check_true('addressed to whoever it is assigned to',
    (select o.to_email = (select u.email from auth.users u where u.id = v_me)
       from public.email_outbox o
      where o.dedupe_key = 'activity-reminder:' || v_due));
  -- The subject line is what somebody sees in a list of forty messages.
  perform pg_temp.check_true('saying what it is about',
    (select o.subject like '%quotation%' from public.email_outbox o
      where o.dedupe_key = 'activity-reminder:' || v_due));
  -- And the body names the person, because "ring him back" without a
  -- name is a reminder to look something up.
  perform pg_temp.check_true('and who it is about',
    (select o.body like '%Rashid%' from public.email_outbox o
      where o.dedupe_key = 'activity-reminder:' || v_due));

  perform pg_temp.check_true('the activity is marked as reminded',
    (select reminder_sent from public.activities where id = v_due));

  -- ------------------------------------------------------------------
  -- And the four that should not go
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a call already made is not reminded about',
    not exists (select 1 from public.email_outbox
                 where dedupe_key = 'activity-reminder:' || v_done));
  perform pg_temp.check_true('nor a meeting that was called off',
    not exists (select 1 from public.email_outbox
                 where dedupe_key = 'activity-reminder:' || v_off));
  perform pg_temp.check_true('nor one whose time has not come',
    not exists (select 1 from public.email_outbox
                 where dedupe_key = 'activity-reminder:' || v_soon));
  perform pg_temp.check_true('nor one nobody is assigned to',
    not exists (select 1 from public.email_outbox
                 where dedupe_key = 'activity-reminder:' || v_nobody));
  -- The last one is still marked, because trying again every quarter of
  -- an hour for ever is the alternative.
  perform pg_temp.check_true(
    'though an unassignable one stops being asked about',
    (select reminder_sent from public.activities where id = v_nobody)
    is not true);

  -- ------------------------------------------------------------------
  -- Once, not every quarter of an hour
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('running it again finds nothing',
    app.queue_activity_reminders(v_org), 0);
  perform pg_temp.check_eq('and queues nothing',
    (select count(*) from public.email_outbox
      where dedupe_key = 'activity-reminder:' || v_due), 1);

  -- The control: when the near one comes due, it goes. Without this
  -- every "nothing was queued" above is satisfied by a function that
  -- queues nothing at all.
  update public.activities set reminder_at = now() - interval '1 minute'
   where id = v_soon;
  perform pg_temp.check_eq('and next week''s call goes when next week comes',
    app.queue_activity_reminders(v_org), 1);

  perform pg_temp.sign_out();
end $$;

rollback;

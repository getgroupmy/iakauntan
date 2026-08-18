-- =====================================================================
-- iAkauntan :: the service desk
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ticketing.sql
--
-- Two things here are arithmetic rather than opinion, and both are the
-- kind that is wrong quietly.
--
-- **The SLA clock.** "Fifteen minutes" means nothing until you say
-- fifteen minutes of what. Under a business-hours policy a P1 raised at
-- 17:50 on a Friday is due at 09:20 on Monday, and if the code counts
-- wall clock instead it is due at 18:05 on Friday and breached before
-- anybody could read it. Both answers look plausible on a screen. Only
-- one of them is what the contract says.
--
-- The timezone is part of that arithmetic and is the easiest thing to
-- get wrong: the database runs in UTC, so a policy that starts at 09:00
-- without a timezone starts at five in the afternoon in Kuala Lumpur.
-- Every assertion below is written in local time for that reason.
--
-- **The state machine.** A helpdesk where a cancelled ticket can be
-- reopened, or a pending one closed without ever being resolved,
-- produces reports that do not add up and nobody can say why. The
-- allowed moves are asserted both ways round — that the legal ones are
-- permitted and the illegal ones refused — because a machine that
-- allows everything passes any test that only checks the legal ones.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company with the module switched on, a service desk, and a policy
-- that works Monday to Friday, nine to six, in Malaysia.
create or replace function pg_temp.desk_org()
returns uuid language plpgsql as $$
declare v_org uuid; v_user uuid; v_team uuid; v_net uuid; v_pol uuid;
begin
  v_user := pg_temp.test_user();
  v_org  := pg_temp.test_org('Service Desk Sdn Bhd');

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.ticket_teams (org_id, code, name, is_default)
  values (v_org, 'SVC', 'Service Desk', true) returning id into v_team;
  insert into public.ticket_teams (org_id, code, name)
  values (v_org, 'NET', 'Network Engineering') returning id into v_net;

  insert into public.sla_policies
    (org_id, code, name, business_hours_only, is_default, time_zone)
  values (v_org, 'STD', 'Standard', true, true, 'Asia/Kuala_Lumpur')
  returning id into v_pol;
  insert into public.sla_policies (org_id, code, name, business_hours_only)
  values (v_org, 'DAYNIGHT', 'Round the clock', false);

  insert into public.sla_targets
    (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (v_org, v_pol, 'p1', 15, 240),
         (v_org, v_pol, 'p3', 240, 2880);

  -- Printing is urgent and belongs to the network team, which is what
  -- makes the routing assertion below mean something: the ticket must
  -- land somewhere other than the default.
  insert into public.ticket_categories
    (org_id, code, name, default_priority, team_id)
  values (v_org, 'PRINTER', 'Printing', 'p1', v_net);

  -- test_org() already signed in as the owner; this is here so the
  -- fixture reads as one thing rather than relying on a side effect.
  perform pg_temp.sign_in_as(v_user);
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- The clock
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.desk_org();
  v_bh  uuid;
  v_247 uuid;
  fmt constant text := 'Dy YYYY-MM-DD HH24:MI';
  tz  constant text := 'Asia/Kuala_Lumpur';
begin
  select id into v_bh  from public.sla_policies where org_id = v_org and code = 'STD';
  select id into v_247 from public.sla_policies where org_id = v_org and code = 'DAYNIGHT';

  -- The dates below are only meaningful if they are the weekdays the
  -- assertions assume. Stated first, so a wrong assumption fails here
  -- rather than surfacing as a confusing deadline three checks later.
  perform pg_temp.check_eq('2026-08-14 is a Friday',
    extract(isodow from date '2026-08-14'), 5);
  perform pg_temp.check_eq('2026-08-17 is a Monday',
    extract(isodow from date '2026-08-17'), 1);

  perform pg_temp.check_true(
    'round the clock just adds minutes: Friday 23:50 + 30 is Saturday 00:20',
    to_char(app.sla_advance(v_org, v_247, timestamptz '2026-08-14 23:50+08', 30)
            at time zone tz, fmt) = 'Sat 2026-08-15 00:20');

  perform pg_temp.check_true(
    'business hours carry the weekend: Friday 17:50 + 30 is Monday 09:20, '
    'not Friday 18:20',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-14 17:50+08', 30)
            at time zone tz, fmt) = 'Mon 2026-08-17 09:20');

  perform pg_temp.check_true(
    'a ticket raised before the day starts waits for it: Monday 07:00 + 60 '
    'is 10:00, not 08:00',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-17 07:00+08', 60)
            at time zone tz, fmt) = 'Mon 2026-08-17 10:00');

  perform pg_temp.check_true(
    'and one raised after it ends goes to the next morning: Monday 19:00 + '
    '60 is Tuesday 10:00',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-17 19:00+08', 60)
            at time zone tz, fmt) = 'Tue 2026-08-18 10:00');

  perform pg_temp.check_true(
    'ten hours of work spans two days of a nine-hour day: Monday 09:00 + '
    '600 is Tuesday 10:00',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-17 09:00+08', 600)
            at time zone tz, fmt) = 'Tue 2026-08-18 10:00');

  -- The timezone assertion, stated as its own check because it is the
  -- one that fails silently: in UTC the working day would start at
  -- 09:00Z, which is 17:00 local, and this deadline would land on
  -- Monday evening instead of Monday morning.
  perform pg_temp.check_true(
    'the working day belongs to Kuala Lumpur, not to UTC',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-17 01:00+08', 30)
            at time zone tz, fmt) = 'Mon 2026-08-17 09:30');

  -- A public holiday stops the clock exactly as a weekend does.
  insert into public.public_holidays (org_id, holiday_date, name, is_working)
  values (v_org, date '2026-08-17', 'Fixture Holiday', false);
  perform pg_temp.check_true(
    'a public holiday is not a working day either: the same Friday ticket '
    'now falls due on Tuesday',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-14 17:50+08', 30)
            at time zone tz, fmt) = 'Tue 2026-08-18 09:20');

  -- ...unless it was worked, which is what is_working means.
  update public.public_holidays set is_working = true
   where org_id = v_org and holiday_date = date '2026-08-17';
  perform pg_temp.check_true(
    'a holiday marked as worked is a working day again — otherwise a '
    'replacement day would pause a clock nobody paused',
    to_char(app.sla_advance(v_org, v_bh, timestamptz '2026-08-14 17:50+08', 30)
            at time zone tz, fmt) = 'Mon 2026-08-17 09:20');
  delete from public.public_holidays where org_id = v_org;

  -- No policy, no promise. A deadline invented where none was agreed
  -- would be breached on a report somebody trusts.
  perform pg_temp.check_true('no policy means no deadline, not a default one',
    (select response_due from app.sla_deadlines(v_org, null, 'p1', now())) is null);
end $$;

-- ---------------------------------------------------------------------
-- The state machine, both ways round
-- ---------------------------------------------------------------------
do $$
declare
  v_legal   integer;
  v_illegal integer;
begin
  select count(*) into v_legal
    from unnest(enum_range(null::app.ticket_status)) a
    cross join unnest(enum_range(null::app.ticket_status)) b
   where app.ticket_transition_allowed(a, b);

  -- The positive control. If the function ever returns false for
  -- everything, every "is refused" assertion below still passes and the
  -- machine tests nothing at all.
  perform pg_temp.check_true(
    format('the machine permits some moves (%s of them)', v_legal), v_legal > 10);

  select count(*) into v_illegal
    from unnest(enum_range(null::app.ticket_status)) a
    cross join unnest(enum_range(null::app.ticket_status)) b
   where not app.ticket_transition_allowed(a, b);
  perform pg_temp.check_true(
    format('and refuses some (%s)', v_illegal), v_illegal > 10);

  perform pg_temp.check_true('a new ticket can be opened',
    app.ticket_transition_allowed('new', 'open'));
  perform pg_temp.check_true('a resolved ticket can be closed',
    app.ticket_transition_allowed('resolved', 'closed'));
  perform pg_temp.check_true('a closed ticket can be reopened, and is counted',
    app.ticket_transition_allowed('closed', 'open'));

  perform pg_temp.check_true('an open ticket cannot be closed without being resolved',
    not app.ticket_transition_allowed('open', 'closed'));
  perform pg_temp.check_true('a cancelled ticket is finished for good',
    not app.ticket_transition_allowed('cancelled', 'open'));
  perform pg_temp.check_true('and nothing may go back to new',
    not app.ticket_transition_allowed('open', 'new'));

  perform pg_temp.check_true('pending and on_hold are the states that pause the clock',
    app.ticket_status_pauses_clock('pending')
    and app.ticket_status_pauses_clock('on_hold')
    and not app.ticket_status_pauses_clock('open'));
end $$;

-- ---------------------------------------------------------------------
-- Routing, first response, and the refusal
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.desk_org();
  v_net uuid; v_svc uuid; v_tkt uuid; v_other uuid; v_t public.tickets;
  v_refused boolean := false;
  v_msg text;
begin
  select id into v_net from public.ticket_teams where org_id = v_org and code = 'NET';
  select id into v_svc from public.ticket_teams where org_id = v_org and code = 'SVC';

  v_tkt := public.create_ticket(v_org, 'The printer is offline', 'Third floor',
                                'PRINTER', null, null, 'email');
  select * into v_t from public.tickets where id = v_tkt;

  perform pg_temp.check_true(
    'the category routes the ticket to its own team rather than the default '
    'queue', v_t.team_id = v_net);
  perform pg_temp.check_true(
    'and hands it the category''s priority', v_t.priority = 'p1');
  perform pg_temp.check_true(
    'both deadlines are stamped at creation, not computed on read',
    v_t.response_due_at is not null and v_t.resolution_due_at is not null);

  -- A ticket with no category still has to land somewhere.
  --
  -- The id is captured before the select rather than calling
  -- create_ticket() inside the WHERE clause: the function is volatile
  -- and inserts a row, and that row is not visible to the snapshot of
  -- the query that is calling it. Written the short way this reads
  -- perfectly and asserts nothing, because the select finds no row and
  -- the comparison is null rather than false.
  v_other := public.create_ticket(v_org, 'Something else');
  perform pg_temp.check_true(
    'an uncategorised ticket falls to the default team, because a ticket '
    'with no team is a queue nobody is looking at',
    (select team_id from public.tickets where id = v_other) = v_svc);

  perform public.add_ticket_comment(v_tkt, 'Checked the print queue', true);
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true(
    'an internal note does not stop the first-response clock — it answers '
    'nobody', v_t.first_response_at is null);

  perform public.add_ticket_comment(v_tkt, 'We are looking at it now', false);
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true(
    'a reply the requester can see does', v_t.first_response_at is not null);

  perform public.transition_ticket(v_tkt, 'open');
  perform public.transition_ticket(v_tkt, 'pending', 'waiting on the user');
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true('pending stops the clock', v_t.paused_at is not null);

  begin
    perform public.transition_ticket(v_tkt, 'closed');
  exception when others then
    v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'pending cannot jump straight to closed', v_refused);
  perform pg_temp.check_true(
    'and the refusal says what was allowed instead, which is the useful '
    'half of a refusal: ' || coalesce(v_msg, '(none)'),
    v_msg like '%Allowed from pending%');

  -- Escalation
  v_refused := false;
  begin
    perform public.escalate_ticket(v_tkt, 'functional', null, null, 'nowhere');
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true(
    'a functional escalation that names no team is a counter being '
    'incremented for the look of it, and is refused', v_refused);

  perform public.escalate_ticket(v_tkt, 'functional', v_svc, null, 'wrong queue');
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true('escalating sideways moves the team and counts',
    v_t.team_id = v_svc and v_t.escalation_level = 1);

  perform public.transition_ticket(v_tkt, 'resolved', 'Toner replaced');
  perform public.transition_ticket(v_tkt, 'closed');
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true('resolving and closing stamp their times',
    v_t.resolved_at is not null and v_t.closed_at is not null);
  perform pg_temp.check_true('and the resolution note survives the close',
    v_t.resolution_note = 'Toner replaced');
end $$;

-- ---------------------------------------------------------------------
-- The breach sweep
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.desk_org();
  v_tkt uuid; v_other uuid; v_t public.tickets; v_n integer; v_before integer;
begin
  v_tkt := public.create_ticket(v_org, 'Nobody answered this one', null, 'PRINTER');

  -- A deadline in the past, which is the only interesting case.
  update public.tickets
     set response_due_at   = now() - interval '1 hour',
         resolution_due_at = now() - interval '1 hour'
   where id = v_tkt;

  select count(*) into v_before from public.ticket_events
   where ticket_id = v_tkt and event_type = 'sla_breach';

  v_n := public.ticket_sla_sweep(v_org);
  select * into v_t from public.tickets where id = v_tkt;

  perform pg_temp.check_eq('the sweep found the overdue ticket', v_n, 1);
  perform pg_temp.check_true('and flagged both deadlines',
    v_t.response_breached and v_t.resolution_breached);
  perform pg_temp.check_eq(
    'writing the breach onto the ticket''s own history, because a '
    'notification is a thing that was sent and this is a thing that '
    'happened',
    (select count(*) from public.ticket_events
      where ticket_id = v_tkt and event_type = 'sla_breach') - v_before, 2);

  -- Idempotence. A sweep that re-flags what it flagged last time fills
  -- the history with duplicates and re-alerts every five minutes.
  perform pg_temp.check_eq('running it again finds nothing new',
    public.ticket_sla_sweep(v_org), 0);

  -- The control: a ticket inside its deadline is left alone. Same
  -- reason as above for splitting the call out of the select.
  v_other := public.create_ticket(v_org, 'This one is fine', null, 'PRINTER');
  perform pg_temp.check_true('a ticket still within its deadline is untouched',
    not (select response_breached from public.tickets where id = v_other));
end $$;

rollback;

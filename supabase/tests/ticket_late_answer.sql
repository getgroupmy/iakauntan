-- =====================================================================
-- iAkauntan :: a late answer is late when it is given (0830)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ticket_late_answer.sql
--
-- The five-minute sweep marks a deadline missed only while a ticket is
-- still waiting. Before `0830` a P1 answered three minutes late, or
-- resolved three minutes late, before the next sweep, was never marked
-- at all. Now `add_ticket_comment` and `transition_ticket` mark it when
-- the answer is given. Asked as the owner, with the role
-- `authenticated`, as the ticket screens ask.
--
-- The deadlines are set by the session to minutes either side of now,
-- which is the only thing a sweep-free test can do with a clock.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tl (org uuid,
  late uuid, ontime uuid, noted uuid, swept uuid,
  rlate uuid, rontime uuid, paused uuid, gone uuid);
grant select on t_tl to authenticated;

-- How many breaches of a kind a ticket's history holds.
create or replace function pg_temp.breaches(p_ticket uuid, p_kind text)
returns integer language sql as $$
  select count(*)::integer from public.ticket_events
   where ticket_id = p_ticket and event_type = 'sla_breach' and to_value = p_kind;
$$;
grant execute on function pg_temp.breaches(uuid, text) to authenticated;

do $$
declare r t_tl; v_pol uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Jawapan Lewat Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.ticket_teams (org_id, code, name, is_default)
  values (r.org, 'SVC', 'Service Desk', true);
  insert into public.sla_policies (org_id, code, name, business_hours_only, is_default)
  values (r.org, 'RTC', 'Round the clock', false, true) returning id into v_pol;
  insert into public.sla_targets (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (r.org, v_pol, 'p1', 15, 240);

  r.late    := public.create_ticket(r.org, 'Answered late', null, null, 'p1');
  r.ontime  := public.create_ticket(r.org, 'Answered in time', null, null, 'p1');
  r.noted   := public.create_ticket(r.org, 'A note first', null, null, 'p1');
  r.swept   := public.create_ticket(r.org, 'Swept, then answered', null, null, 'p1');
  r.rlate   := public.create_ticket(r.org, 'Resolved late', null, null, 'p1');
  r.rontime := public.create_ticket(r.org, 'Resolved in time', null, null, 'p1');
  r.paused  := public.create_ticket(r.org, 'Waited on the customer', null, null, 'p1');
  r.gone    := public.create_ticket(r.org, 'Withdrawn late', null, null, 'p1');

  -- Every deadline went three minutes ago, except the two in time.
  update public.tickets
     set response_due_at = now() - interval '3 minutes',
         resolution_due_at = now() - interval '3 minutes'
   where org_id = r.org and id not in (r.ontime, r.rontime);
  update public.tickets
     set response_due_at = now() + interval '10 minutes',
         resolution_due_at = now() + interval '10 minutes'
   where id in (r.ontime, r.rontime);
  -- One the sweep has already caught.
  perform public.ticket_sla_sweep(r.org);
  -- That marked all six that were late; put back the five the sweep
  -- would not yet have reached, so the functions are asked on their own.
  update public.tickets set response_breached = false, resolution_breached = false
   where org_id = r.org and id <> r.swept;
  delete from public.ticket_events
   where org_id = r.org and event_type = 'sla_breach' and ticket_id <> r.swept;
  -- One waiting on the customer for the last ten minutes: its
  -- resolution deadline moves on by those ten when it resumes.
  update public.tickets set status = 'pending', paused_at = now() - interval '10 minutes'
   where id = r.paused;
  insert into t_tl select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_tl;
begin
  select * into d from t_tl;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- What was measured: answered three minutes late, before any sweep.
  perform public.add_ticket_comment(d.late, 'Sorry for the wait', false);
  perform pg_temp.check_true('a reply three minutes late is a response breach',
    (select response_breached from public.tickets where id = d.late));
  perform pg_temp.check_eq('on the ticket''s history, once',
    pg_temp.breaches(d.late, 'response'), 1);
  perform pg_temp.check_eq('saying so',
    (select note from public.ticket_events
      where ticket_id = d.late and event_type = 'sla_breach'),
    'First response sent after its deadline');

  -- In time is in time.
  perform public.add_ticket_comment(d.ontime, 'On it', false);
  perform pg_temp.check_true('a reply in time is not',
    not (select response_breached from public.tickets where id = d.ontime)
    and pg_temp.breaches(d.ontime, 'response') = 0);

  -- An internal note answers nobody; the public reply after it does.
  perform public.add_ticket_comment(d.noted, 'Checked the logs', true);
  perform pg_temp.check_true('an internal note is no first response, late or not',
    not (select response_breached from public.tickets where id = d.noted));
  perform public.add_ticket_comment(d.noted, 'Found it', false);
  perform pg_temp.check_true('the public reply after it is late',
    (select response_breached from public.tickets where id = d.noted));

  -- Already caught by the sweep: not caught twice, either one.
  perform public.add_ticket_comment(d.swept, 'Here now', false);
  perform pg_temp.check_eq('a breach the sweep marked is not marked again',
    pg_temp.breaches(d.swept, 'response'), 1);
  perform public.transition_ticket(d.swept, 'resolved', 'Sorted');
  perform pg_temp.check_eq('nor its resolution, resolved after',
    pg_temp.breaches(d.swept, 'resolution'), 1);

  -- Resolved three minutes late, and in time.
  perform public.transition_ticket(d.rlate, 'resolved', 'Restarted it');
  perform pg_temp.check_true('a resolution three minutes late is a resolution breach',
    (select resolution_breached from public.tickets where id = d.rlate));
  perform pg_temp.check_eq('on the history, saying so',
    (select note from public.ticket_events
      where ticket_id = d.rlate and event_type = 'sla_breach'),
    'Resolved after its deadline');
  perform public.transition_ticket(d.rontime, 'resolved', 'Done');
  perform pg_temp.check_true('one in time is not',
    not (select resolution_breached from public.tickets where id = d.rontime)
    and pg_temp.breaches(d.rontime, 'resolution') = 0);
  -- And closing it after does not mark it again.
  perform public.transition_ticket(d.rlate, 'closed');
  perform pg_temp.check_eq('nor does closing it after',
    pg_temp.breaches(d.rlate, 'resolution'), 1);

  -- Ten minutes waiting on the customer move the deadline on by ten, so
  -- resolved now it is seven minutes early.
  perform public.transition_ticket(d.paused, 'resolved', 'They confirmed');
  perform pg_temp.check_true('time paused moves the deadline, and resolved inside it is on time',
    not (select resolution_breached from public.tickets where id = d.paused));

  -- Withdrawn is not answered.
  perform public.transition_ticket(d.gone, 'cancelled', 'Raised twice');
  perform pg_temp.check_true('a ticket cancelled late is no breach',
    not (select resolution_breached from public.tickets where id = d.gone)
    and pg_temp.breaches(d.gone, 'resolution') = 0);
end $$;

-- Resolved in time, closed after the deadline has gone: closing is not
-- resolving, and the deadline was met. (Moved past by the session, as
-- time would move it.)
reset role;
update public.tickets set resolution_due_at = now() - interval '1 minute'
 where id = (select rontime from t_tl);
set local role authenticated;

do $$
declare d t_tl;
begin
  select * into d from t_tl;
  perform public.transition_ticket(d.rontime, 'closed');
  perform pg_temp.check_true('one resolved in time and closed after its deadline is no breach',
    not (select resolution_breached from public.tickets where id = d.rontime)
    and pg_temp.breaches(d.rontime, 'resolution') = 0);
end $$;

rollback;

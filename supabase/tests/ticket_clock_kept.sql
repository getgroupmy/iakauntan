-- =====================================================================
-- iAkauntan :: a ticket keeps its own time (0831)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ticket_clock_kept.sql
--
-- A ticket's clock -- its status, priority, policy, deadlines, the
-- moments it was answered, resolved and closed, its breaches and its
-- counters -- is moved by the workflow functions and the sweep. Before
-- `0831` a client could move it by hand: a late ticket's breaches
-- cleared, its first response backdated, it closed by hand, or a
-- deadline pushed a week out so it would never breach. Asked as the
-- owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tc (org uuid, u uuid, late uuid, fresh uuid);
grant select, update on t_tc to authenticated;

do $$
declare r t_tc; v_pol uuid;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  r.org := pg_temp.test_org('Jam Tiket Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.ticket_teams (org_id, code, name, is_default)
  values (r.org, 'SVC', 'Service Desk', true);
  insert into public.sla_policies (org_id, code, name, business_hours_only, is_default)
  values (r.org, 'RTC', 'Round the clock', false, true) returning id into v_pol;
  insert into public.sla_targets (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (r.org, v_pol, 'p1', 15, 240), (r.org, v_pol, 'p4', 2880, 10080);
  -- A P1 that went past both deadlines unanswered, caught by the sweep.
  r.late := public.create_ticket(r.org, 'Server down', null, null, 'p1');
  update public.tickets
     set response_due_at = now() - interval '1 hour',
         resolution_due_at = now() - interval '1 hour'
   where id = r.late;
  perform public.ticket_sla_sweep(r.org);
  insert into t_tc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_tc;
  r record;
begin
  select * into d from t_tc;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_true('the late ticket is marked late, both ways',
    (select response_breached and resolution_breached from public.tickets where id = d.late));

  -- What was measured.
  perform pg_temp.check_refused('its breaches are not cleared by hand',
    format('update public.tickets set response_breached = false, resolution_breached = false where id = %L', d.late),
    'The response_breached of ticket % is the workflow''s%', '42501');
  perform pg_temp.check_refused('nor is it closed by hand with its first response backdated',
    format($q$update public.tickets set status = 'closed', first_response_at = opened_at,
                     resolved_at = opened_at + interval '5 minutes' where id = %L$q$, d.late),
    'The status of ticket % is the workflow''s%', '42501');

  -- Each part of the clock on its own. The trigger answers before a
  -- foreign key or a check does, so any value will do.
  for r in select * from (values
      ('status', '''closed'''),
      ('priority', '''p4'''),
      ('sla_policy_id', 'gen_random_uuid()'),
      ('opened_at', 'now() - interval ''1 day'''),
      ('response_due_at', 'now() + interval ''7 days'''),
      ('resolution_due_at', 'now() + interval ''7 days'''),
      ('first_response_at', 'now() - interval ''1 day'''),
      ('resolved_at', 'now()'),
      ('closed_at', 'now()'),
      ('response_breached', 'false'),
      ('resolution_breached', 'false'),
      ('paused_minutes', '999'),
      ('paused_at', 'now()'),
      ('escalation_level', '9'),
      ('reopened_count', '9'))
      as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor its %s', r.col),
      format('update public.tickets set %s = %s where id = %L', r.col, r.val, d.late),
      format('The %s of ticket %% is the workflow''s: it moves when the ticket is answered, transitioned, escalated or swept, not by hand.', r.col),
      '42501');
  end loop;

  -- Nor is one made by hand, with whatever clock it likes.
  perform pg_temp.check_refused('a ticket is not made by hand',
    format($q$insert into public.tickets (org_id, ticket_no, subject, requester_user_id, response_breached)
              values (%L, 'TIC-HAND', 'Made up', %L, false)$q$, d.org, d.u),
    'permission denied for table tickets', '42501');

  -- What the ticket screen writes is as before.
  update public.tickets
     set subject = 'Server down (rack 3)', description = 'Since 09:10',
         tags = array['infra'], assignee_id = d.u, custom_fields = '{}'::jsonb
   where id = d.late;
  perform pg_temp.check_eq('the screen still writes its subject, description, tags and assignee',
    (select subject || '/' || description || '/' || array_to_string(tags, ',') || '/' || (assignee_id = d.u)
       from public.tickets where id = d.late),
    'Server down (rack 3)/Since 09:10/infra/true');

  -- And the workflow still moves the clock.
  d.fresh := public.create_ticket(d.org, 'Printer', null, null, 'p4');
  update t_tc set fresh = d.fresh;
  perform public.add_ticket_comment(d.fresh, 'Looking now', false);
  perform public.escalate_ticket(d.fresh, 'hierarchic', null, d.u, 'Needs a manager');
  perform public.transition_ticket(d.fresh, 'resolved', 'Paper jam');
  perform pg_temp.check_eq('the workflow answers, escalates and resolves it',
    (select status || '/' || (first_response_at is not null) || '/' || escalation_level
            || '/' || (resolved_at is not null)
       from public.tickets where id = d.fresh), 'resolved/true/1/true');

  perform pg_temp.check_true('so the late ticket is still marked late',
    (select response_breached and resolution_breached and status::text = 'new'
       from public.tickets where id = d.late));
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every function that moves the clock is a definer,
-- which runs as the owner at any depth.
do $$
declare d t_tc;
begin
  select * into d from t_tc;
  update public.tickets set priority = 'p4' where id = d.late;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select priority::text from public.tickets where id = d.late), 'p4');
  perform pg_temp.check_true('and no client may insert a ticket',
    not has_table_privilege('authenticated', 'public.tickets', 'INSERT'));
end $$;

rollback;

-- The lifecycle: who a ticket goes to, what states it may enter, and
-- when the clock stops.
--
-- ## The state machine is a function, not a check constraint
--
-- A constraint cannot see who is asking and cannot produce a useful
-- error. `app.ticket_transition_allowed` is a pure function of the two
-- states, so it can be read by the UI to grey out the buttons that
-- would fail, and the refusal it produces lists the moves that were
-- available instead — which is the difference between an error a user
-- can act on and one they file a support ticket about.
--
-- The one edge worth arguing about is `closed -> open`. Some desks
-- forbid it and make the requester raise a new ticket. This allows it
-- and counts it, because the alternative loses the connection between
-- the second report and the first, and "how often does our fix not
-- hold" is a question worth being able to answer.
--
-- `cancelled` is terminal. A ticket raised in error is not a ticket
-- that later becomes real.
--
-- ## Time spent waiting on somebody else is given back
--
-- `pending` and `on_hold` stop the clock. When the ticket comes back
-- off hold the resolution deadline moves forward by however long it
-- waited — a customer who took three days to answer a question has not
-- consumed a promise we made about our own speed. The response deadline
-- is deliberately *not* extended: the first reply is owed regardless.
--
-- ## First response means a reply the requester can see
--
-- `is_internal` defaults to true on a comment, so a note between
-- colleagues cannot accidentally stop the response clock or, worse, be
-- shown to the customer it is about. Only a visible reply stamps
-- `first_response_at`.
--
-- ## Escalation has two directions and they are not the same
--
-- Functional escalation moves a ticket sideways, to a team that knows
-- the subject. Hierarchic escalation moves it up, to somebody senior.
-- Each is refused without the thing it needs — a team, a person —
-- because an escalation that names neither is a counter being
-- incremented for the look of it.

-- ---------------------------------------------------------------------
-- The legal moves
-- ---------------------------------------------------------------------
create or replace function app.ticket_transition_allowed(
  p_from app.ticket_status, p_to app.ticket_status)
returns boolean
language sql
immutable
as $$
  select case p_from
    when 'new'       then p_to in ('open','pending','on_hold','resolved','cancelled')
    when 'open'      then p_to in ('pending','on_hold','resolved','cancelled')
    when 'pending'   then p_to in ('open','on_hold','resolved','cancelled')
    when 'on_hold'   then p_to in ('open','pending','resolved','cancelled')
    when 'resolved'  then p_to in ('closed','open')
    when 'closed'    then p_to in ('open')
    when 'cancelled' then false
    else false
  end;
$$;

create or replace function app.ticket_status_pauses_clock(p_status app.ticket_status)
returns boolean language sql immutable as $$
  select p_status in ('pending', 'on_hold');
$$;

grant execute on function app.ticket_transition_allowed(app.ticket_status, app.ticket_status)
  to authenticated;
grant execute on function app.ticket_status_pauses_clock(app.ticket_status) to authenticated;

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
create or replace function public.create_ticket(
  p_org_id      uuid,
  p_subject     text,
  p_description text default null,
  p_category    text default null,
  p_priority    app.ticket_priority default null,
  p_type        app.ticket_type default null,
  p_channel     app.ticket_channel default 'web',
  p_requester_user_id    uuid default null,
  p_requester_contact_id uuid default null,
  p_asset_id    uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cat    public.ticket_categories;
  v_team   uuid;
  v_policy uuid;
  v_prio   app.ticket_priority;
  v_type   app.ticket_type;
  v_req    uuid := p_requester_user_id;
  v_id     uuid;
  v_due    record;
begin
  if not app.can_write_module(p_org_id, 'ticketing') then
    raise exception 'Insufficient privileges to raise a ticket'
      using errcode = '42501';
  end if;

  -- Somebody has to own the question. When neither is given the caller
  -- is raising it for themselves, which is the self-service case.
  if v_req is null and p_requester_contact_id is null then
    v_req := auth.uid();
  end if;

  if p_category is not null then
    select * into v_cat from public.ticket_categories
     where org_id = p_org_id and code = p_category and is_active;
    if not found then
      raise exception 'No active ticket category % in this organization', p_category
        using errcode = 'P0002';
    end if;
  end if;

  v_prio := coalesce(p_priority, v_cat.default_priority, 'p3');
  v_type := coalesce(p_type, v_cat.default_type, 'incident');

  -- Routing: the category's team, else whichever team is marked
  -- default. A ticket with no team is a queue nobody is looking at.
  v_team := coalesce(v_cat.team_id,
                     (select id from public.ticket_teams
                       where org_id = p_org_id and is_default and is_active));

  v_policy := coalesce(v_cat.sla_policy_id,
                       (select id from public.sla_policies
                         where org_id = p_org_id and is_default and is_active));

  select * into v_due
    from app.sla_deadlines(p_org_id, v_policy, v_prio, now());

  insert into public.tickets
    (org_id, ticket_no, subject, description, ticket_type, priority, status,
     channel, category_id, team_id, requester_user_id, requester_contact_id,
     asset_id, sla_policy_id, opened_at, response_due_at, resolution_due_at,
     created_by)
  values
    (p_org_id, app.next_document_number_internal(p_org_id, 'ticket'),
     p_subject, p_description, v_type, v_prio, 'new',
     p_channel, v_cat.id, v_team, v_req, p_requester_contact_id,
     p_asset_id, v_policy, now(), v_due.response_due, v_due.resolution_due,
     auth.uid())
  returning id into v_id;

  insert into public.ticket_events (org_id, ticket_id, event_type, to_value, actor_id)
  values (p_org_id, v_id, 'created', v_prio::text, auth.uid());

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Giving it to somebody
-- ---------------------------------------------------------------------
create or replace function public.assign_ticket(p_ticket uuid, p_user uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.tickets;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then raise exception 'Ticket % not found', p_ticket; end if;
  if not app.can_write_module(v_t.org_id, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if p_user is not null and not exists (
       select 1 from public.org_members m
        where m.org_id = v_t.org_id and m.user_id = p_user and m.status = 'active') then
    raise exception 'That person is not an active member of this organization'
      using errcode = '23503';
  end if;

  update public.tickets
     set assignee_id = p_user,
         status = case when status = 'new' then 'open'::app.ticket_status else status end
   where id = p_ticket;

  insert into public.ticket_events (org_id, ticket_id, event_type, from_value, to_value, actor_id)
  values (v_t.org_id, p_ticket, 'assigned', v_t.assignee_id::text, p_user::text, auth.uid());
end $$;

-- ---------------------------------------------------------------------
-- Moving it through its states
-- ---------------------------------------------------------------------
create or replace function public.transition_ticket(
  p_ticket uuid, p_to app.ticket_status, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_t public.tickets;
  v_paused integer := 0;
  v_new_due timestamptz;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then raise exception 'Ticket % not found', p_ticket; end if;
  if not app.can_write_module(v_t.org_id, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if v_t.status = p_to then
    return;
  end if;

  -- The refusal names what was available instead, because the useful
  -- part of "you cannot do that" is what you can do.
  if not app.ticket_transition_allowed(v_t.status, p_to) then
    raise exception 'A ticket cannot go from % to %. Allowed from %: %',
      v_t.status, p_to, v_t.status,
      (select string_agg(s::text, ', ') from unnest(enum_range(null::app.ticket_status)) s
        where app.ticket_transition_allowed(v_t.status, s))
      using errcode = '22023';
  end if;

  v_new_due := v_t.resolution_due_at;

  if app.ticket_status_pauses_clock(v_t.status)
     and not app.ticket_status_pauses_clock(p_to)
     and v_t.paused_at is not null then
    v_paused := greatest(0, floor(extract(epoch from (now() - v_t.paused_at)) / 60)::integer);
    if v_paused > 0 and v_new_due is not null and v_t.sla_policy_id is not null then
      v_new_due := app.sla_advance(v_t.org_id, v_t.sla_policy_id, v_new_due, v_paused);
    end if;
  end if;

  update public.tickets
     set status = p_to,
         paused_at = case
           when app.ticket_status_pauses_clock(p_to)
                and not app.ticket_status_pauses_clock(v_t.status) then now()
           when not app.ticket_status_pauses_clock(p_to) then null
           else paused_at end,
         paused_minutes = paused_minutes + v_paused,
         resolution_due_at = v_new_due,
         resolved_at = case when p_to = 'resolved' then now()
                            when p_to in ('open','pending','on_hold') then null
                            else resolved_at end,
         closed_at = case when p_to = 'closed' then now()
                          when p_to = 'open' then null
                          else closed_at end,
         reopened_count = reopened_count
           + case when v_t.status in ('resolved','closed') and p_to = 'open' then 1 else 0 end,
         resolution_note = coalesce(
           case when p_to in ('resolved','closed') then p_note else null end, resolution_note)
   where id = p_ticket;

  insert into public.ticket_events
    (org_id, ticket_id, event_type, from_value, to_value, note, actor_id)
  values (v_t.org_id, p_ticket, 'status', v_t.status::text, p_to::text, p_note, auth.uid());
end $$;

-- ---------------------------------------------------------------------
-- Talking to the requester, or about them
-- ---------------------------------------------------------------------
create or replace function public.add_ticket_comment(
  p_ticket uuid, p_body text,
  p_internal boolean default true,
  p_channel app.ticket_channel default 'web')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.tickets; v_id uuid;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then raise exception 'Ticket % not found', p_ticket; end if;
  if not app.can_write_module(v_t.org_id, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  insert into public.ticket_comments
    (org_id, ticket_id, body, is_internal, author_user_id, channel)
  values (v_t.org_id, p_ticket, p_body, p_internal, auth.uid(), p_channel)
  returning id into v_id;

  -- The first-response clock stops on the first reply the requester can
  -- actually see. An internal note is a conversation between colleagues
  -- and does not answer anybody.
  if not p_internal and v_t.first_response_at is null then
    update public.tickets set first_response_at = now() where id = p_ticket;
    insert into public.ticket_events (org_id, ticket_id, event_type, actor_id)
    values (v_t.org_id, p_ticket, 'first_response', auth.uid());
  end if;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Sideways, or up
-- ---------------------------------------------------------------------
create or replace function public.escalate_ticket(
  p_ticket uuid,
  p_kind   app.ticket_escalation,
  p_to_team uuid default null,
  p_to_user uuid default null,
  p_reason text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.tickets;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then raise exception 'Ticket % not found', p_ticket; end if;
  if not app.can_write_module(v_t.org_id, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if p_kind = 'functional' and p_to_team is null then
    raise exception 'A functional escalation has to name the team it goes to'
      using errcode = '22023';
  end if;
  if p_kind = 'hierarchic' and p_to_user is null then
    raise exception 'A hierarchic escalation has to name the person it goes to'
      using errcode = '22023';
  end if;
  if p_to_team is not null and not exists (
       select 1 from public.ticket_teams where id = p_to_team and org_id = v_t.org_id) then
    raise exception 'No such team in this organization' using errcode = '23503';
  end if;

  update public.tickets
     set team_id = coalesce(p_to_team, team_id),
         assignee_id = coalesce(p_to_user, assignee_id),
         escalation_level = escalation_level + 1,
         status = case when status = 'new' then 'open'::app.ticket_status else status end
   where id = p_ticket;

  insert into public.ticket_events
    (org_id, ticket_id, event_type, from_value, to_value, note, actor_id)
  values (v_t.org_id, p_ticket, 'escalated', v_t.escalation_level::text,
          (v_t.escalation_level + 1)::text,
          coalesce(p_reason, '') || ' (' || p_kind::text || ')', auth.uid());
end $$;

grant execute on function public.create_ticket(
  uuid, text, text, text, app.ticket_priority, app.ticket_type,
  app.ticket_channel, uuid, uuid, uuid) to authenticated;
grant execute on function public.assign_ticket(uuid, uuid) to authenticated;
grant execute on function public.transition_ticket(uuid, app.ticket_status, text) to authenticated;
grant execute on function public.add_ticket_comment(uuid, text, boolean, app.ticket_channel)
  to authenticated;
grant execute on function public.escalate_ticket(uuid, app.ticket_escalation, uuid, uuid, text)
  to authenticated;

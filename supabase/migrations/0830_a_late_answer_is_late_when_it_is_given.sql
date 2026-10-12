-- =====================================================================
-- iAkauntan :: 0830 a late answer is late when it is given
--
-- `ticket_sla_sweep` runs every five minutes (`0356`) and marks a
-- ticket's response or resolution breached when its deadline has gone
-- and the ticket is still waiting -- no first response, or not yet
-- resolved. It stops looking the moment either arrives. And neither
-- `add_ticket_comment`, which stamps the first response, nor
-- `transition_ticket`, which resolves and closes, asked the deadline.
--
-- Measured on 12 October 2026, locally: a P1 promising a fifteen-minute
-- response, answered three minutes after the deadline and before the
-- next sweep -- never marked; the sweep afterwards found nothing to do.
-- One resolved three minutes late, the same. A five-minute sweep and a
-- fifteen-minute promise leave a third of every deadline's lateness
-- unrecorded, and a support board and its SLA figures that say every
-- such ticket was on time.
--
-- Answered "both" (the client's own writes to the clock are `0831`).
-- `add_ticket_comment` marks the response breached, and writes the
-- `sla_breach` event the sweep writes, when the first public reply
-- lands after its deadline. `transition_ticket` does the same for the
-- resolution when a ticket is resolved after its deadline, the deadline
-- moved on by any paused time exactly as the transition itself moves
-- it. A ticket already marked is not marked twice, and a cancelled one
-- is no breach.
--
-- Both restated from `pg_get_functiondef` of the live ones, with only
-- what is marked `0830` added. Production held thirteen tickets on 12
-- October, every one in the demonstration company.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.add_ticket_comment(p_ticket uuid, p_body text, p_internal boolean DEFAULT true, p_channel app.ticket_channel DEFAULT 'web'::app.ticket_channel)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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

    -- Late, and marked so now (0830). The sweep only looks at tickets
    -- still waiting, so a reply that lands after the deadline and
    -- before its next run was never marked at all.
    if v_t.response_due_at is not null and now() > v_t.response_due_at
       and not v_t.response_breached then
      update public.tickets set response_breached = true where id = p_ticket;
      insert into public.ticket_events (org_id, ticket_id, event_type, to_value, note)
      values (v_t.org_id, p_ticket, 'sla_breach', 'response',
              'First response sent after its deadline');
    end if;
  end if;

  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION app.transition_ticket_internal(p_ticket uuid, p_to app.ticket_status, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_t public.tickets;
  v_paused integer := 0;
  v_new_due timestamptz;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then
    raise exception 'No such ticket.' using errcode = 'P0002';
  end if;
  if v_t.status = p_to then return; end if;
  if not app.ticket_transition_allowed(v_t.status, p_to) then
    -- The refusal names what was available instead, because the useful
    -- part of "you cannot do that" is what you can do. Kept verbatim
    -- from `0194`: it is the message members already see.
    raise exception 'A ticket cannot go from % to %. Allowed from %: %',
      v_t.status, p_to, v_t.status,
      (select string_agg(x::text, ', ')
         from unnest(enum_range(null::app.ticket_status)) x
        where app.ticket_transition_allowed(v_t.status, x))
      using errcode = '22023';
  end if;

  v_new_due := v_t.resolution_due_at;
  if app.ticket_status_pauses_clock(v_t.status)
     and not app.ticket_status_pauses_clock(p_to)
     and v_t.paused_at is not null then
    v_paused := greatest(0,
      floor(extract(epoch from (now() - v_t.paused_at)) / 60)::integer);
    if v_paused > 0 and v_new_due is not null
       and v_t.sla_policy_id is not null then
      v_new_due := app.sla_advance(v_t.org_id, v_t.sla_policy_id,
                                   v_new_due, v_paused);
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
           + case when v_t.status in ('resolved','closed') and p_to = 'open'
                  then 1 else 0 end,
         resolution_note = coalesce(
           case when p_to in ('resolved','closed') then p_note else null end,
           resolution_note)
   where id = p_ticket;

  insert into public.ticket_events
    (org_id, ticket_id, event_type, from_value, to_value, note)
  values (v_t.org_id, p_ticket, 'status', v_t.status::text, p_to::text,
          p_note);

  -- Resolved after the deadline -- the one moved on by any time it
  -- spent paused -- and marked so now (0830). The sweep stops looking
  -- the moment a ticket is resolved, so one resolved after the deadline
  -- and before its next run was never marked at all. Closed is reached
  -- only from resolved, and a cancelled ticket was withdrawn, not
  -- answered, and is no breach.
  if p_to = 'resolved'
     and v_new_due is not null and now() > v_new_due
     and not v_t.resolution_breached then
    update public.tickets set resolution_breached = true where id = p_ticket;
    insert into public.ticket_events
      (org_id, ticket_id, event_type, to_value, note)
    values (v_t.org_id, p_ticket, 'sla_breach', 'resolution',
            'Resolved after its deadline');
  end if;
end $function$;

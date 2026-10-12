-- =====================================================================
-- iAkauntan :: 0831 a ticket keeps its own time
--
-- A ticket's clock is the database's. `create_ticket` sets its priority,
-- its SLA policy and both deadlines; `add_ticket_comment` stamps the
-- first response; `transition_ticket` moves its status, pauses and
-- resumes the clock and stamps resolved and closed; `escalate_ticket`
-- counts escalations; the sweep and (`0830`) the workflow mark the
-- breaches. Every one of them is a definer. The ticket screens call
-- those and write `custom_fields` on the row and nothing else. But
-- `0192`'s policy lets anybody who may work tickets write every column.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`, on three P1 tickets with a fifteen-minute response
-- promise: one answered late and its breaches cleared by hand -- the
-- sweep never looked at it again, because it had been answered; one set
-- closed by hand, its breaches cleared and its first response backdated
-- to the minute it was raised -- answered at once and closed in five
-- minutes, by its own row; and one inside its deadline with the
-- deadline pushed a week out -- the sweep will never mark it.
--
-- Answered "both" (`0830` is the other half). A trigger refuses a
-- client's own statement -- role `authenticated` or `anon`, at the top
-- trigger depth -- that changes a ticket's status, priority, SLA policy,
-- opened, due, first-response, resolved or closed times, breach flags,
-- pause or escalation counters. Its subject, description, tags, custom
-- fields, team and assignee are as before. Client insert is revoked:
-- `create_ticket` makes a ticket. The functions run as their owner and
-- pass. NOT security definer.
--
-- Production held thirteen tickets on 12 October, every one in the
-- demonstration company.
-- =====================================================================

revoke insert on public.tickets from authenticated, anon;

create or replace function app.a_ticket_keeps_its_own_time()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  -- What the workflow decides. The rest is the ticket screen's.
  c_clock constant text[] := array[
    'status', 'priority', 'sla_policy_id', 'opened_at',
    'response_due_at', 'resolution_due_at', 'first_response_at',
    'resolved_at', 'closed_at', 'response_breached',
    'resolution_breached', 'paused_minutes', 'paused_at',
    'escalation_level', 'reopened_count'];
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array c_clock loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'The % of ticket % is the workflow''s: it moves when the ticket '
        'is answered, transitioned, escalated or swept, not by hand.',
        v_col, old.ticket_no
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

revoke all on function app.a_ticket_keeps_its_own_time() from public, anon, authenticated;

comment on function app.a_ticket_keeps_its_own_time() is
  'On tickets: refuses a client''s own statement that changes the '
  'status, priority, SLA policy, opened, due, first-response, resolved '
  'or closed times, breach flags, pause or escalation counters. The '
  'workflow functions and the sweep pass. 0831.';

create trigger a_ticket_keeps_its_own_time
  before update on public.tickets
  for each row execute function app.a_ticket_keeps_its_own_time();

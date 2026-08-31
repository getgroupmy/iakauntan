-- =====================================================================
-- iAkauntan :: 0355 who is actually on the team
--
-- `0192` created `ticket_team_members` — a team, the people on it, and
-- which of them leads it — gave it row level security, a read policy, a
-- write policy for an admin and every grant it needs. Nothing anywhere
-- has ever written a row, and nothing reads one.
--
-- So a support team is a label. A ticket is routed to Billing, and
-- "assign it to somebody on Billing" is a question the database cannot
-- answer: `assign_ticket` checks only that the person is an active
-- member of the company, and the sheet offers every one of them —
-- warehouse, payroll and all. On a desk of five that is fine. On one
-- where routing exists because it is not, the routing decides nothing.
--
-- ## The rule, and how it declines to bite
--
-- A ticket on a team whose membership has been filled in may only be
-- assigned to somebody on that team. A team with nobody on it accepts
-- anybody, which is exactly what happens today — so a company that
-- never opens the Members list sees no change at all, and one that
-- fills it in gets the rule it was asking for by filling it in.
--
-- That degradation is `0264`'s, deliberately: "a supermarket counting
-- stock to the gram wants the till to refuse; a warung that has never
-- weighed its rice would find every sale blocked by a number nobody
-- maintains." An empty list is not a statement that nobody may take
-- these tickets.
--
-- A ticket on no team at all is unaffected. There is no team to be off.
--
-- ## Writing it
--
-- Nothing new. `0192` already grants insert, update and delete on the
-- table to `authenticated` behind a policy that asks `app.can_admin`,
-- so the console writes it directly. What was missing was a reason to.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Assigning, to somebody on the team the ticket is on
-- ---------------------------------------------------------------------
create or replace function public.assign_ticket(p_ticket uuid, p_user uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_t     public.tickets;
  v_staff integer;
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

  -- The team's own list, when it has one. Counted rather than tested
  -- with `exists`, because the two questions are different: "is this
  -- person on the team" and "does the team have a list at all", and
  -- treating an empty list as a refusal locks every company that has
  -- not filled one in out of its own tickets.
  --
  -- No `v_t.team_id is not null` here, deliberately. It reads as the
  -- obvious guard and it is redundant: `where tm.team_id = null` is
  -- never true, so a ticket on no team counts nothing and falls through
  -- the same way an empty team does. A branch no test can tell apart
  -- from its absence is a branch that should not be written.
  if p_user is not null then
    select count(*) into v_staff
      from public.ticket_team_members tm
     where tm.team_id = v_t.team_id;

    if v_staff > 0 and not exists (
         select 1 from public.ticket_team_members tm
          where tm.team_id = v_t.team_id and tm.user_id = p_user) then
      raise exception
        'That person is not on the team this ticket is with. Move the '
        'ticket to their team first, or add them to this one.'
        using errcode = '23503';
    end if;
  end if;

  update public.tickets
     set assignee_id = p_user,
         status = case when status = 'new' then 'open'::app.ticket_status else status end
   where id = p_ticket;

  insert into public.ticket_events (org_id, ticket_id, event_type, from_value, to_value, actor_id)
  values (v_t.org_id, p_ticket, 'assigned', v_t.assignee_id::text, p_user::text, auth.uid());
end $$;

grant execute on function public.assign_ticket(uuid, uuid) to authenticated;

comment on function public.assign_ticket(uuid, uuid) is
  'Hands a ticket to somebody. They have to be an active member of the company, and — when the ticket is on a team whose membership has been filled in — on that team.';

-- ---------------------------------------------------------------------
-- Who is on one
-- ---------------------------------------------------------------------
--
-- The names come from `profiles`, which the members table does not
-- carry, and the sheet needs both. Runs as the caller so the read
-- policy on `ticket_team_members` still decides.
create or replace function public.ticket_team_roster(p_team_id uuid)
returns table (
  user_id   uuid,
  full_name text,
  email     text,
  is_lead   boolean)
language sql
stable
set search_path = public, app, pg_temp as $$
  select tm.user_id, p.full_name, p.email::text, tm.is_lead
    from public.ticket_team_members tm
    left join public.profiles p on p.id = tm.user_id
   where tm.team_id = p_team_id
   order by tm.is_lead desc, coalesce(p.full_name, p.email::text);
$$;

revoke all on function public.ticket_team_roster(uuid) from public, anon;
grant execute on function public.ticket_team_roster(uuid) to authenticated;

comment on function public.ticket_team_roster(uuid) is
  'Who is on a support team, leads first. Runs as the caller, so the read policy still decides.';

-- One lead per team. Two people who are both "the" lead is a question
-- nobody can answer, and `is_lead` exists so an escalation has somebody
-- to go to.
create unique index if not exists ticket_team_members_one_lead
  on public.ticket_team_members (team_id) where is_lead;

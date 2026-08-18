-- The SLA clock, which does not run at night.
--
-- A service level agreement says "we will answer a P1 within fifteen
-- minutes". The only interesting question is fifteen minutes of what.
-- Wall clock, and a ticket raised at 23:50 on Friday is breached before
-- anybody could reasonably have read it. Working time, and the same
-- ticket is due at 09:15 on Monday. Both are defensible; which one
-- applies is the most argued line in any support contract, so it is a
-- column on the policy rather than an assumption in the code.
--
-- ## Timezone is not optional here
--
-- The database runs in UTC and no other table in this schema carries a
-- timezone. A policy whose day starts at 09:00 therefore starts at
-- 09:00 UTC — five in the afternoon in Kuala Lumpur — and every
-- deadline computed from it is eight hours wrong while looking
-- completely reasonable. `sla_policies.time_zone` exists so the working
-- day belongs to somewhere.
--
-- ## What counts as a day off
--
-- Weekends come from `work_days`, as ISO weekday numbers, because
-- Malaysia is not uniform: most states run Monday to Friday, but Johor,
-- Kedah, Kelantan and Terengganu run Sunday to Thursday, and a policy
-- that hardcodes Saturday and Sunday is wrong in four states.
--
-- Public holidays come from `public_holidays`, which the HR module
-- already maintains. A row with `is_working` set is a holiday that was
-- worked — a replacement day — and does not stop the clock. National
-- holidays carry no state and always apply; state holidays apply only
-- to the state the policy names.
--
-- ## The guard is not paranoia
--
-- A policy whose `work_days` never match any real weekday — an empty
-- intersection after somebody edits it — makes the loop advance a day
-- at a time forever, holding a transaction open. It raises after four
-- hundred days instead, and says why.

-- ---------------------------------------------------------------------
-- Move a number of working minutes forward from a moment
-- ---------------------------------------------------------------------
create or replace function app.sla_advance(
  p_org     uuid,
  p_policy  uuid,
  p_from    timestamptz,
  p_minutes integer)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p       public.sla_policies;
  v_tz      text;
  v_local   timestamp;
  v_day     date;
  v_start   timestamp;
  v_end     timestamp;
  v_avail   integer;
  v_left    integer := p_minutes;
  v_guard   integer := 0;
begin
  select * into v_p from public.sla_policies
   where id = p_policy and org_id = p_org;
  if not found then
    raise exception 'No SLA policy % for this organization', p_policy
      using errcode = 'P0002';
  end if;
  if p_minutes <= 0 then
    return p_from;
  end if;

  if not v_p.business_hours_only then
    return p_from + make_interval(mins => p_minutes);
  end if;

  v_tz := v_p.time_zone;
  v_local := p_from at time zone v_tz;
  v_day := v_local::date;

  loop
    v_guard := v_guard + 1;
    if v_guard > 400 then
      raise exception 'SLA clock ran past a year without consuming % minutes; '
        'the policy has no working days it can use', p_minutes
        using errcode = '22023';
    end if;

    if extract(isodow from v_day)::smallint = any (v_p.work_days)
       and not exists (
         select 1 from public.public_holidays h
          where h.org_id = p_org
            and h.holiday_date = v_day
            and not h.is_working
            and (h.state_code is null or h.state_code = v_p.holiday_state_code))
    then
      -- greatest() is what makes a ticket raised at 07:00 wait for the
      -- day to start rather than earning an hour of credit before it.
      v_start := greatest(v_day + v_p.work_start, v_local);
      v_end   := v_day + v_p.work_end;

      if v_end > v_start then
        v_avail := floor(extract(epoch from (v_end - v_start)) / 60)::integer;
        if v_left <= v_avail then
          return (v_start + make_interval(mins => v_left)) at time zone v_tz;
        end if;
        v_left := v_left - v_avail;
      end if;
    end if;

    v_day := v_day + 1;
    v_local := v_day::timestamp;
  end loop;
end $$;

grant execute on function app.sla_advance(uuid, uuid, timestamptz, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Both deadlines for a priority, from one moment
-- ---------------------------------------------------------------------
create or replace function app.sla_deadlines(
  p_org      uuid,
  p_policy   uuid,
  p_priority app.ticket_priority,
  p_from     timestamptz,
  out response_due   timestamptz,
  out resolution_due timestamptz)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.sla_targets;
begin
  -- No policy, or no target for this priority, means no promise was
  -- made. Nulls out rather than inventing one: a deadline nobody agreed
  -- to would be breached on a report somebody trusts.
  if p_policy is null then
    return;
  end if;

  select * into v_t from public.sla_targets
   where policy_id = p_policy and priority = p_priority;

  if not found then
    return;
  end if;

  response_due   := app.sla_advance(p_org, p_policy, p_from, v_t.response_minutes);
  resolution_due := app.sla_advance(p_org, p_policy, p_from, v_t.resolution_minutes);
end $$;

grant execute on function app.sla_deadlines(uuid, uuid, app.ticket_priority, timestamptz)
  to authenticated;

-- ---------------------------------------------------------------------
-- Mark what has been breached
--
-- Stamped onto the ticket rather than derived on read, so that a report
-- of what was breached last month does not change when somebody edits
-- the policy this month. Driven by the scheduler alongside the other
-- periodic work.
-- ---------------------------------------------------------------------
create or replace function public.ticket_sla_sweep(p_org uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row record;
  v_n integer := 0;
begin
  for v_row in
    select t.id, t.org_id, t.ticket_no, t.assignee_id,
           (t.first_response_at is null and t.response_due_at is not null
            and now() > t.response_due_at and not t.response_breached) as resp,
           (t.resolved_at is null and t.resolution_due_at is not null
            and now() > t.resolution_due_at and not t.resolution_breached) as reso
      from public.tickets t
     where t.deleted_at is null
       and t.status not in ('resolved', 'closed', 'cancelled')
       and (p_org is null or t.org_id = p_org)
       and (
         (t.first_response_at is null and t.response_due_at is not null
          and now() > t.response_due_at and not t.response_breached)
         or
         (t.resolved_at is null and t.resolution_due_at is not null
          and now() > t.resolution_due_at and not t.resolution_breached))
  loop
    update public.tickets
       set response_breached   = response_breached   or v_row.resp,
           resolution_breached = resolution_breached or v_row.reso
     where id = v_row.id;

    -- The breach goes on the ticket's own history rather than only into
    -- a notification, because a notification is a thing that was sent
    -- and this is a thing that happened.
    if v_row.resp then
      insert into public.ticket_events (org_id, ticket_id, event_type, to_value, note)
      values (v_row.org_id, v_row.id, 'sla_breach', 'response',
              'First response deadline passed with no reply');
    end if;
    if v_row.reso then
      insert into public.ticket_events (org_id, ticket_id, event_type, to_value, note)
      values (v_row.org_id, v_row.id, 'sla_breach', 'resolution',
              'Resolution deadline passed with the ticket still open');
    end if;

    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

revoke all on function public.ticket_sla_sweep(uuid) from public, anon, authenticated;

comment on function app.sla_advance(uuid, uuid, timestamptz, integer) is
  'Adds working minutes to a moment under an SLA policy, skipping '
  'non-working weekdays and public holidays, in the policy''s own '
  'timezone. Round-the-clock policies are plain wall-clock addition.';

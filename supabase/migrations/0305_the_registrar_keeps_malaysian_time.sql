-- ---------------------------------------------------------------------
-- The Registrar keeps Malaysian time
--
-- `corp_upcoming_filings` decided what was due by reading
-- `current_date`. In Postgres that is not "today" — it is today in the
-- *session's* time zone, and on Supabase the session is UTC. Malaysia
-- is UTC+8, so for the eight hours between midnight in Kuala Lumpur and
-- midnight in London the engine was a day behind the country whose Act
-- it implements.
--
-- What that costs, concretely. A secretary in Kuala Lumpur opens the
-- app at nine in the morning on the day an Annual Return falls due. UTC
-- still says yesterday, so the filing is reported as due tomorrow
-- rather than today and the queue they work from does not show it. The
-- window is eight hours wide and it is exactly the window in which
-- somebody is most likely to be looking: the Malaysian working morning.
--
-- CA 2016 s.68 gives thirty days from the anniversary of incorporation,
-- and those are days in Malaysia. So the clock is pinned to
-- `Asia/Kuala_Lumpur` rather than inherited from whoever connected.
--
-- ## This changes what the engine returns
--
-- Not a refactor. For eight hours of every day the answer moves by a
-- day, and near a month boundary a filing moves between months. That is
-- the correction; the previous behaviour was the defect.
--
-- Nothing else changes. The anniversary arithmetic, 180 + 30 for
-- financial statements, the AGM applying only to public companies and
-- the leap-day handling are all as 0063 wrote them, and stay asserted
-- in `supabase/tests/secretarial.sql`.
--
-- ## The project already agreed with this
--
-- 0060 passes `app.run_daily_jobs` the Malaysian date rather than the
-- server's, for this reason and nearly in these words: "on the 1st it
-- is still the same calendar day in MYT that the consolidation period
-- closed". This brings the deadline engine into line with the schedule
-- that drives it.
--
-- ## Why the test is written the way it is
--
-- A test that compared UTC against Kuala Lumpur directly could only
-- fail during the eight hours they differ — green all morning, red
-- after lunch. That is worse than no test. So `secretarial.sql` asserts
-- the property rather than the value: run the function under two
-- session time zones twenty-six hours apart and it must give the same
-- answer. A `current_date` implementation fails that at every instant,
-- because two zones that far apart are never on the same date.
-- ---------------------------------------------------------------------

create or replace function public.corp_upcoming_filings(
  p_org_id uuid, p_within_days integer default 120)
returns table (
  entity_id uuid,
  entity_name text,
  filing_type text,
  filing_name text,
  statute_ref text,
  legacy_form text,
  trigger_date date,
  due_date date,
  period_label text,
  status app.corp_filing_status,
  filing_id uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  -- The Act's dates are Malaysian dates. Named once rather than read
  -- seven times, so every window in this query is bounded by the same
  -- day even if the query runs across midnight.
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;

  return query
  with anniversaries as (
    select e.id, e.name, t.code, t.name as tname, t.statute_ref, t.legacy_form,
           d.trigger_date,
           (d.trigger_date + t.days_allowed)::date as due_date,
           to_char(d.trigger_date, 'YYYY') as period_label
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind = 'anniversary'
       and e.entity_type = any (t.applies_to)
      cross join lateral (
        select (e.incorporated_on + (n || ' years')::interval)::date as trigger_date
          from generate_series(
                 greatest(extract(year from v_today)::int
                          - extract(year from e.incorporated_on)::int - 1, 0),
                 extract(year from v_today)::int
                          - extract(year from e.incorporated_on)::int + 1) n) d
     where e.org_id = p_org_id
       and e.incorporated_on is not null
       and e.status in ('incorporated', 'dormant')
       and e.disengaged_on is null
  ),
  year_ends as (
    select e.id, e.name, t.code, t.name as tname, t.statute_ref, t.legacy_form,
           d.trigger_date,
           (d.trigger_date + t.days_allowed)::date as due_date,
           to_char(d.trigger_date, 'YYYY') as period_label
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind in ('fye', 'agm')
       and e.entity_type = any (t.applies_to)
      cross join lateral (
        select app.corp_fye(e, y) as trigger_date
          from generate_series(extract(year from v_today)::int - 1,
                               extract(year from v_today)::int) y) d
     where e.org_id = p_org_id
       and e.financial_year_end_month is not null
       and e.status in ('incorporated', 'dormant')
       and e.disengaged_on is null
       and d.trigger_date is not null
       -- Nothing is due for a year the company had not been incorporated for.
       and d.trigger_date >= e.incorporated_on
  ),
  computed as (
    select * from anniversaries union all select * from year_ends
  )
  select c.id, c.name, c.code, c.tname, c.statute_ref, c.legacy_form,
         c.trigger_date, c.due_date, c.period_label,
         coalesce(f.status,
           case when c.due_date < v_today then 'due'
                else 'not_due' end::app.corp_filing_status),
         f.id
    from computed c
    left join public.corp_filings f
      on f.entity_id = c.id and f.filing_type = c.code
     and f.trigger_date = c.trigger_date
   where c.due_date between v_today - 365
                        and v_today + coalesce(p_within_days, 120)
     -- The first Annual Return is only due once there has been an
     -- anniversary at all.
     and c.trigger_date > (select e2.incorporated_on
                             from public.corp_entities e2 where e2.id = c.id)
     and coalesce(f.status, 'due') not in ('lodged', 'approved', 'not_applicable')
   order by c.due_date, c.name;
end;
$$;

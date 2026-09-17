-- ---------------------------------------------------------------------
-- 0461  The next annual return follows the last one lodged
-- ---------------------------------------------------------------------
-- `corp_upcoming_filings` built the annual return's anniversaries as
--
--   generate_series(
--     greatest(years_since_incorporation - 1, 0),
--     years_since_incorporation + 1)
--
-- -- that is, **one year back from today**, whatever has actually been
-- lodged. Two things follow, and the second is the serious one.
--
-- ### The date is right and the series was not
--
-- Section 68 of the Companies Act 2016 puts the annual return not later
-- than thirty days from the anniversary of the incorporation date, and
-- that anniversary never moves. This migration does not change it.
--
-- What it changes is **which anniversaries are outstanding**. A company
-- three years behind was shown one filing and told nothing about the
-- other two, because the series never looked further back than last
-- year.
--
-- A company secretary works from the last return lodged, and the way to
-- get that right is not to anchor the series on it. The series now runs
-- from the **first** anniversary, and the join to `corp_filings` below
-- removes the ones already lodged -- so what is left is exactly what is
-- still owed, and the next one due is the earliest of those. That is
-- the same answer as "the one after the last lodged" whenever nothing
-- has been skipped, and the right answer when something has: a company
-- that lodged 2023 but never lodged 2022 still owes 2022, and anchoring
-- on the last one lodged would have hidden it. That case is asserted.
--
-- ### And nothing that is late falls off the list
--
-- The window was `due_date between today - 365 and today + n`. An
-- annual return two years overdue is not less overdue for being old,
-- and a list that quietly drops it is how a company finds out from SSM
-- instead. Anniversary filings now have no lower bound.
--
-- The other kinds keep the year's window on purpose: a financial
-- statement whose year end was four years ago is history rather than a
-- task, and a compliance list that never forgets anything is a list
-- nobody reads.
--
-- ### Mutants
--
-- Five, restated into a built database and run against
-- `supabase/tests/secretarial.sql`. Five kills:
--
--   * the series back to one year from today -- killed by "a company
--     years behind is shown every return it owes";
--   * the year's window put back on everything, so an old return ages
--     off the list -- killed by the same assertion;
--   * **the series anchored on the last return lodged** -- killed by "a
--     year skipped in the middle is still owed". This one is worth
--     dwelling on, because it is the design this migration was first
--     written as: start the series at the year after the last lodged
--     return. It reads exactly like the request and it is wrong. A
--     company that lodged 2023 but never lodged 2022 still owes 2022,
--     and anchoring on the last one lodged hides it -- silently, and
--     for good. Running from the first anniversary and letting the
--     existing join remove what has been lodged gives the same answer
--     when nothing was skipped and the right one when something was;
--   * lodged filings no longer removed -- killed by "lodging one takes
--     it off the list", which is what makes the wider series safe;
--   * the statutory thirty days changed to twenty-eight -- killed by
--     the assertion `secretarial.sql` already had.
--
-- One assertion was dropped rather than kept: "an ancient financial
-- statement stays off the list" could not fail, because the year-end
-- series only ever generates this year and last, so no old one exists
-- to be filtered. It is replaced by an assertion of what is actually
-- true -- that a financial statement is only ever asked for this year
-- or last -- because the window clause reads as though it were what
-- keeps them out, and it is not.
-- ---------------------------------------------------------------------

create or replace function public.corp_upcoming_filings(p_org_id uuid, p_within_days integer DEFAULT 120)
 RETURNS TABLE(entity_id uuid, entity_name text, filing_type text, filing_name text, statute_ref text, legacy_form text, trigger_date date, due_date date, period_label text, status app.corp_filing_status, filing_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
           to_char(d.trigger_date, 'YYYY') as period_label,
           t.trigger_kind as kind
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind = 'anniversary'
       and e.entity_type = any (t.applies_to)
      -- Which anniversaries are still outstanding.
      --
      -- The *date* is the Act's: section 68 puts the annual return
      -- thirty days from the anniversary of incorporation, and that
      -- never moves. What was wrong was the *series*: it started one
      -- year back from today, so a company two years behind on its
      -- annual return was shown one filing and told nothing about the
      -- other. A secretary works from the last return lodged, and so
      -- does this now.
      cross join lateral (
        select (e.incorporated_on + (n || ' years')::interval)::date
                 as trigger_date
          from generate_series(
                 -- Every anniversary there has been. The ones already
                 -- lodged are removed further down by the join to
                 -- `corp_filings`, so what is left is precisely what is
                 -- still owed -- including a year skipped in the middle,
                 -- which anchoring on the *last* lodged return would
                 -- hide. See the header.
                 1,
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
           to_char(d.trigger_date, 'YYYY') as period_label,
           t.trigger_kind as kind
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
   where c.due_date <= v_today + coalesce(p_within_days, 120)
     -- No lower bound on an anniversary filing. Something two years
     -- overdue is not less overdue for being old, and a list that
     -- quietly drops it is how a company finds out from SSM instead.
     -- The other kinds keep the year's window: a financial statement
     -- from four years ago is history, not a task.
     and (c.kind = 'anniversary' or c.due_date >= v_today - 365)
     -- The first Annual Return is only due once there has been an
     -- anniversary at all.
     and c.trigger_date > (select e2.incorporated_on
                             from public.corp_entities e2 where e2.id = c.id)
     and coalesce(f.status, 'due') not in ('lodged', 'approved', 'not_applicable')
   order by c.due_date, c.name;
end;
$function$

;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('public.corp_upcoming_filings(uuid, integer)'));
begin
  -- The series runs from the first anniversary, not from last year.
  if position('greatest(extract(year from v_today)::int' in v_src) > 0 then
    raise exception '0461: the series still starts one year back from today';
  end if;

  -- And what has been lodged is still what removes a filing from the
  -- list, which is what makes the series safe to widen.
  if position('not in (''lodged'', ''approved'', ''not_applicable'')'
              in v_src) = 0 then
    raise exception '0461: a lodged return would be asked for again';
  end if;

  -- Nothing anniversary-shaped falls off the bottom of the list.
  if position('c.kind = ''anniversary'' or c.due_date >= v_today - 365'
              in v_src) = 0 then
    raise exception '0461: an overdue annual return still ages off the list';
  end if;

  -- And the statutory date is untouched: thirty days from the
  -- anniversary, which is section 68 and not ours to move.
  if (select days_allowed from public.corp_filing_types
       where code = 'annual_return') <> 30 then
    raise exception '0461: the statutory period changed, which it has not';
  end if;
end
$do$;

comment on function public.corp_upcoming_filings(uuid, integer) is
  'What each company owes SSM and when. The annual return''s date is '
  'the anniversary of incorporation, per section 68; which '
  'anniversaries are outstanding follows the last return lodged. '
  'See 0461.';

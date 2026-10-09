-- =====================================================================
-- iAkauntan :: 0782 a fiscal year is tiled, whatever day it starts
--
-- `create_fiscal_year` (`0422`) and `create_previous_fiscal_year`
-- (`0659`) built a year's twelve periods by adding whole months to a
-- date: period n began at "the year's start plus n months" and ended a
-- month after its own start, less a day. Month arithmetic clamps to the
-- end of a short month and never gives the day back, so a year starting
-- on the 29th, 30th or 31st lost days between its periods. Measured on
-- 9 October 2026, locally, for a year from 31 January 2026: 28 to 30
-- March, 30 May, 30 July, 30 October and 30 December fell in no period,
-- and a journal dated 29 March was refused with "No fiscal period
-- covers 2026-03-29. Create the fiscal year before posting to it" --
-- inside a year that existed. `0659` had already met the same clamp at
-- the far end of a year and patched only that end.
--
-- Answered "tile the periods". Each period now begins the day after the
-- one before it ends, and ends the day before "the year's start plus
-- its number of months" -- counted from the YEAR's start, so the clamp
-- in one month is never carried into the next. The twelfth ends on the
-- year end. Every day of the year is in exactly one period, whatever
-- day it starts on.
--
-- For a year starting on the 1st to the 28th this gives exactly the
-- periods it gave before, day for day. All 47 years in production on 9
-- October started on the 1st and none had an uncovered day, so nothing
-- that exists would have been built differently. The app never passes
-- a start date; the derived one always falls on the 28th or earlier.
-- This was the API's road (`p_start_date`).
--
-- Restated from `0422` and `0659`, whose text production runs exactly
-- (identical source hashes on 9 October). Only the period loop changes
-- in each.
-- =====================================================================

create or replace function public.create_fiscal_year(
  p_org_id uuid, p_start_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org public.organizations; v_start date; v_end date; v_fy_id uuid;
  v_last date; v_p_start date; v_p_end date; i integer;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if not found then raise exception 'Organization % not found', p_org_id; end if;
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select max(end_date) into v_last from public.fiscal_years where org_id = p_org_id;

  if p_start_date is not null then
    v_start := p_start_date;
  elsif v_last is not null then
    v_start := (v_last + interval '1 day')::date;
  else
    v_end := (date_trunc('month', make_date(extract(year from app.today())::int,
                v_org.fiscal_year_end_month, 1))
              + interval '1 month' - interval '1 day')::date;
    if v_org.fiscal_year_end_day < 28 then
      v_end := make_date(extract(year from v_end)::int,
                 v_org.fiscal_year_end_month, v_org.fiscal_year_end_day);
    end if;
    if v_end < app.today() then v_end := (v_end + interval '1 year')::date; end if;
    v_start := (v_end - interval '1 year' + interval '1 day')::date;
  end if;

  v_end := (v_start + interval '1 year' - interval '1 day')::date;

  if exists (select 1 from public.fiscal_years f
              where f.org_id = p_org_id
                and f.start_date <= v_end and f.end_date >= v_start) then
    raise exception 'A fiscal year already covers % to %', v_start, v_end
      using errcode = '23505';
  end if;

  insert into public.fiscal_years (org_id, name, start_date, end_date)
  values (p_org_id,
          case when extract(year from v_start) = extract(year from v_end)
               then extract(year from v_start)::text
               else extract(year from v_start)::text || '/' ||
                    extract(year from v_end)::text end,
          v_start, v_end)
  returning id into v_fy_id;

  -- `0782`: back to back. Each period starts the day after the last
  -- ended and ends the day before the year's start plus its number of
  -- months, counted from the YEAR's start so a short month's clamp is
  -- not carried forward. The twelfth ends on the year end.
  v_p_end := (v_start - 1)::date;
  for i in 0 .. 11 loop
    v_p_start := (v_p_end + 1)::date;
    v_p_end := (v_start + ((i + 1) || ' months')::interval
                - interval '1 day')::date;
    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;
    insert into public.fiscal_periods
      (org_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),
            v_p_start, v_p_end);
  end loop;

  return v_fy_id;
end; $$;

create or replace function public.create_previous_fiscal_year(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_earliest date; v_start date; v_end date; v_fy_id uuid;
  v_p_start date; v_p_end date; i integer;
begin
  if not exists (select 1 from public.organizations where id = p_org_id) then
    raise exception 'Organization % not found', p_org_id;
  end if;
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select min(start_date) into v_earliest
    from public.fiscal_years where org_id = p_org_id;

  -- Nothing to precede. Said as its own refusal rather than creating
  -- one, because "the year before nothing" has no answer and the
  -- caller wanted a specific year, not any year.
  if v_earliest is null then
    raise exception
      'There is no fiscal year yet, so there is none to come before. '
      'Create the first one instead.'
      using errcode = 'P0002';
  end if;

  -- Anchored to the END. See the note at the top of this file.
  v_end := (v_earliest - interval '1 day')::date;
  v_start := (v_end - interval '1 year' + interval '1 day')::date;

  if exists (select 1 from public.fiscal_years f
              where f.org_id = p_org_id
                and f.start_date <= v_end and f.end_date >= v_start) then
    raise exception 'A fiscal year already covers % to %', v_start, v_end
      using errcode = '23505';
  end if;

  -- The property this function exists for, checked rather than
  -- assumed. True by construction today; the point is that it stays
  -- true after somebody edits the two lines above.
  if v_end <> (v_earliest - 1) then
    raise exception 'the new year would leave % uncovered',
      (v_earliest - 1)::date;
  end if;

  insert into public.fiscal_years (org_id, name, start_date, end_date)
  values (p_org_id,
          case when extract(year from v_start) = extract(year from v_end)
               then extract(year from v_start)::text
               else extract(year from v_start)::text || '/' ||
                    extract(year from v_end)::text end,
          v_start, v_end)
  returning id into v_fy_id;

  -- Twelve monthly periods from the start, the same shape
  -- `create_fiscal_year` gives every other year. The last one is
  -- extended to the year end rather than left at a month boundary: a
  -- year anchored to its end does not always divide into twelve whole
  -- months, and a period that stopped short would leave the same
  -- uncovered days this function was written to avoid.
  -- `0782`: back to back. Each period starts the day after the last
  -- ended and ends the day before the year's start plus its number of
  -- months, counted from the YEAR's start so a short month's clamp is
  -- not carried forward. The twelfth ends on the year end.
  v_p_end := (v_start - 1)::date;
  for i in 0 .. 11 loop
    v_p_start := (v_p_end + 1)::date;
    v_p_end := (v_start + ((i + 1) || ' months')::interval
                - interval '1 day')::date;
    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;
    insert into public.fiscal_periods
      (org_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),
            v_p_start, v_p_end);
  end loop;

  return v_fy_id;
end; $$;

comment on function public.create_fiscal_year(uuid, date) is
  'Opens a fiscal year and its periods, from the date given or from '
  'where the last one ended, honouring the company''s own year-end day. '
  'Refuses a year overlapping one that already exists, naming the '
  'dates: two periods covering one date would make "which period does '
  'this post to" ambiguous, and posting is refused outside an open '
  'period. The twelve periods tile the year back to back, so every day '
  'is in exactly one whatever day the year starts (`0782`). Needs '
  '`can_post`.';

comment on function public.create_previous_fiscal_year(uuid) is
  'Opens the fiscal year immediately BEFORE the earliest one, with its '
  'periods, for a company posting history it arrived with. Anchored to '
  'its END -- the day before the earliest year -- rather than to a '
  'start date, because deriving the end from a start leaves a day '
  'uncovered when the earliest year begins on a leap day. The periods '
  'tile the year back to back (`0782`). Refuses a company with no fiscal '
  'year at all, and one where the year it would create already exists. '
  'The periods arrive OPEN, because the reason to add a prior year is to '
  'post to it. Needs `can_post`.';

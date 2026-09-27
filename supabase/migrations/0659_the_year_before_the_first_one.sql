-- =====================================================================
-- The year before the first one
--
-- Asked for from the Fiscal years card, which could only ever add the
-- NEXT year. A company arriving with history — books brought across
-- from somewhere else, a first year that turned out to need a
-- comparative, an audit that wants the prior figures in the same
-- ledger — had no way to open a period before the earliest one, and so
-- no way to post anything dated there.
--
-- ---------------------------------------------------------------------
-- Why this is not `create_fiscal_year` with an earlier date
--
-- It nearly is, and the difference is the whole reason for a separate
-- function.
--
-- `create_fiscal_year` is anchored to a START: it takes a start date
-- and derives the end as `start + 1 year - 1 day`. That is right for
-- the next year, whose start is fixed by the previous year's end and
-- whose end follows from it.
--
-- A PREVIOUS year is the other way round. Its end is fixed — the day
-- before the earliest year begins — and its start follows. Deriving it
-- from a start date instead produces a gap on exactly one input:
--
--     earliest year begins  2024-02-29   (a leap day)
--     start := earliest - 1 year       = 2023-02-28  (clamped)
--     end   := start + 1 year - 1 day  = 2024-02-27
--
-- which leaves 2024-02-28 covered by no period at all. Nothing can be
-- posted to it, nothing reports it, and the only symptom is a single
-- day that refuses entries in a year that looks complete. Anchoring to
-- the end cannot do that, because the end is not computed:
--
--     end   := earliest - 1 day        = 2024-02-28
--     start := end - 1 year + 1 day    = 2023-03-01
--
-- The assertion at the bottom of the function is that `end` is exactly
-- the day before the earliest year, which is true by construction and
-- is checked anyway — it is the property the whole function exists for,
-- and a later edit that reintroduces start-anchoring would pass every
-- other test in this file.
--
-- ---------------------------------------------------------------------
-- What it deliberately does not do
--
-- **It does not close the year it creates.** The periods arrive open,
-- like every other year's. A prior year is added in order to post to
-- it — opening balances, comparatives, the entries that were missing —
-- and a year that arrived closed would have to be reopened before it
-- was any use. Closing is `close_fiscal_year`, which already exists and
-- already does the arithmetic.
--
-- **It does not touch `books_start_date`.** That column records when
-- the company says its books begin, which is a statement about the
-- company rather than about which periods exist. Moving it silently
-- because somebody added a year would change what several reports
-- consider in-scope.
-- =====================================================================

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
  for i in 0 .. 11 loop
    v_p_start := (v_start + (i || ' months')::interval)::date;
    v_p_end := (v_p_start + interval '1 month' - interval '1 day')::date;
    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;
    insert into public.fiscal_periods
      (org_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),
            v_p_start, v_p_end);
  end loop;

  return v_fy_id;
end; $$;

-- Written out in full: a hosted Supabase project's default privileges
-- hand a newly created function in `public` an EXECUTE grant held
-- DIRECTLY by `anon` and `authenticated`, and revoking from the PUBLIC
-- pseudo-role does not touch a direct grant. `0657` learned this by
-- being refused in CI.
revoke all on function public.create_previous_fiscal_year(uuid)
  from public, anon;
grant execute on function public.create_previous_fiscal_year(uuid)
  to authenticated;

comment on function public.create_previous_fiscal_year(uuid) is
  'Opens the fiscal year immediately BEFORE the earliest one, with its '
  'periods, for a company posting history it arrived with. Anchored to '
  'its END -- the day before the earliest year -- rather than to a '
  'start date, because deriving the end from a start leaves a day '
  'uncovered when the earliest year begins on a leap day. Refuses a '
  'company with no fiscal year at all, and one where the year it would '
  'create already exists. The periods arrive OPEN, because the reason '
  'to add a prior year is to post to it. Needs `can_post`.';

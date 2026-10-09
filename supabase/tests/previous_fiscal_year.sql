-- =====================================================================
-- iAkauntan :: the year before the first one
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/previous_fiscal_year.sql
--
-- `create_previous_fiscal_year` opens the year immediately before the
-- earliest one, so a company can post history it arrived with. The
-- ways it can be wrong are all silent:
--
--   1. **A gap.** A day between the new year's end and the old year's
--      start is a day nothing can be posted to. Nothing reports it;
--      the symptom is one date that refuses entries inside a year that
--      looks complete. This is what start-anchoring does on a leap
--      day, and it is the reason the function exists separately from
--      `create_fiscal_year`.
--   2. **An overlap.** Two periods covering one date makes "which
--      period does this post to" ambiguous. The function's overlap
--      guard turns out to be UNREACHABLE through the function itself
--      -- the year before the earliest is by construction not taken --
--      so what is asserted here is the property instead: however many
--      times it is called, no date is covered twice.
--   3. **Periods that do not cover their own year.** Twelve whole
--      months from the start do not always reach the end.
--   4. **Anyone being able to call it.** It writes to the ledger's
--      calendar; `can_post` is the gate, and `anon` must not have it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Every date the year covers, as the periods see it. A gap or an
-- overlap both show up here and nowhere else.
create or replace function pg_temp.pfy_cover(p_year uuid)
returns table (covered bigint, distinct_days bigint)
language sql as $$
  select count(*), count(distinct d)
    from public.fiscal_periods p
    cross join lateral generate_series(p.start_date, p.end_date,
                                       interval '1 day') as g(d)
   where p.fiscal_year_id = p_year;
$$;

-- ---------------------------------------------------------------------
-- An ordinary calendar year
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_first uuid; v_prev uuid;
  v_start date; v_end date; v_name text; v_periods integer;
  v_covered bigint; v_days bigint;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Previous Year');
  v_first := public.create_fiscal_year(v_org, date '2026-01-01');

  v_prev := public.create_previous_fiscal_year(v_org);

  select start_date, end_date, name into v_start, v_end, v_name
    from public.fiscal_years where id = v_prev;

  perform pg_temp.check_eq('previous year starts',
                           v_start::text, '2025-01-01');
  -- The assertion the whole function is for: it ends the day before
  -- the year it precedes, not a year after its own start.
  perform pg_temp.check_eq('previous year ends the day before the first',
                           v_end::text, '2025-12-31');
  perform pg_temp.check_eq('and is named for its calendar year',
                           v_name, '2025');

  select count(*) into v_periods
    from public.fiscal_periods where fiscal_year_id = v_prev;
  perform pg_temp.check_eq('twelve periods', v_periods, 12);

  select covered, distinct_days into v_covered, v_days
    from pg_temp.pfy_cover(v_prev);
  perform pg_temp.check_eq('every day of 2025 is covered', v_days, 365);
  perform pg_temp.check_eq('and none of them twice', v_covered, v_days);

  -- The periods arrive open, because the reason to add a prior year is
  -- to post to it.
  if exists (select 1 from public.fiscal_periods
              where fiscal_year_id = v_prev and status <> 'open') then
    raise exception 'FAIL: a period of the new year did not arrive open';
  end if;
  raise notice 'ok   every period of the new year is open';
end $$;

-- ---------------------------------------------------------------------
-- The leap day, which is the reason for the whole design
--
-- A year beginning 2024-02-29. Anchored to a start,
-- `earliest - 1 year` clamps to 2023-02-28 and the derived end is
-- 2024-02-27 -- leaving 2024-02-28 covered by nothing. Anchored to the
-- end, the end IS 2024-02-28 and the start follows.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_prev uuid;
  v_start date; v_end date; v_gap integer; v_days bigint; v_covered bigint;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Leap Day');
  perform public.create_fiscal_year(v_org, date '2024-02-29');

  v_prev := public.create_previous_fiscal_year(v_org);
  select start_date, end_date into v_start, v_end
    from public.fiscal_years where id = v_prev;

  perform pg_temp.check_eq('the leap-day year is preceded to its eve',
                           v_end::text, '2024-02-28');
  perform pg_temp.check_eq('and starts a year and a day earlier',
                           v_start::text, '2023-03-01');

  -- Said again at the level that matters: no date in the company's
  -- whole calendar is uncovered.
  select count(*) into v_gap
    from generate_series(v_start, date '2024-02-29', interval '1 day') g(d)
   where not exists (select 1 from public.fiscal_periods p
                      where p.org_id = v_org
                        and g.d::date between p.start_date and p.end_date);
  perform pg_temp.check_eq('no day between the two years is uncovered',
                           v_gap, 0);

  select covered, distinct_days into v_covered, v_days
    from pg_temp.pfy_cover(v_prev);
  -- 365, not 366: the leap day itself belongs to the year that
  -- FOLLOWS, which begins on it. Asserted at 366 first, and the test
  -- caught the assertion rather than the function.
  perform pg_temp.check_eq('and the new year covers 365 days', v_days, 365);
  perform pg_temp.check_eq('none of them twice', v_covered, v_days);
end $$;

-- ---------------------------------------------------------------------
-- A year end that is not December, and going back twice
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_a uuid; v_b uuid;
  v_start date; v_end date; v_name text; v_gap integer;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe June Year End');
  perform public.create_fiscal_year(v_org, date '2026-07-01');

  v_a := public.create_previous_fiscal_year(v_org);
  select start_date, end_date, name into v_start, v_end, v_name
    from public.fiscal_years where id = v_a;
  perform pg_temp.check_eq('a July year is preceded by a July year',
                           v_start::text, '2025-07-01');
  perform pg_temp.check_eq('ending the day before', v_end::text, '2026-06-30');
  -- Spanning two calendar years, it is named for both.
  perform pg_temp.check_eq('and named across both', v_name, '2025/2026');

  -- Twice, because a company bringing books across may need more than
  -- one year of history and each must precede the last.
  v_b := public.create_previous_fiscal_year(v_org);
  select start_date, end_date into v_start, v_end
    from public.fiscal_years where id = v_b;
  perform pg_temp.check_eq('and again, one year further back',
                           v_start::text, '2024-07-01');
  perform pg_temp.check_eq('ending before the one just made',
                           v_end::text, '2025-06-30');

  select count(*) into v_gap
    from generate_series(date '2024-07-01', date '2027-06-30',
                         interval '1 day') g(d)
   where not exists (select 1 from public.fiscal_periods p
                      where p.org_id = v_org
                        and g.d::date between p.start_date and p.end_date);
  perform pg_temp.check_eq('three years, no uncovered day', v_gap, 0);
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_owner uuid; v_said text;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Refusals');

  -- No year at all. "The year before nothing" has no answer, and
  -- quietly creating some year would not be the one asked for.
  begin
    perform public.create_previous_fiscal_year(v_org);
    raise exception 'FAIL: it made a year before no year';
  exception when sqlstate 'P0002' then
    raise notice 'ok   refuses a company with no fiscal year';
  end;

  -- And there is deliberately no test that it refuses an overlap,
  -- because it cannot reach one: the year before the EARLIEST year is
  -- by construction a year that does not exist. Asserted at first with
  -- two years already made, which simply produced a third, correctly.
  --
  -- The guard stays in the function. It costs one query and it is the
  -- thing that would catch an edit to the two date lines above -- the
  -- same reason the contiguity check is there. What is asserted about
  -- overlapping is the property, above: call it as often as you like
  -- and no date is covered twice.
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.create_previous_fiscal_year(v_org);
  perform public.create_previous_fiscal_year(v_org);
  if exists (
    select 1 from public.fiscal_periods a
      join public.fiscal_periods b
        on b.org_id = a.org_id and b.id <> a.id
       and b.start_date <= a.end_date and b.end_date >= a.start_date
     where a.org_id = v_org) then
    raise exception 'FAIL: two periods cover the same date';
  end if;
  raise notice 'ok   repeated calls never cover a date twice';
end $$;

-- ---------------------------------------------------------------------
-- Who is refused, and what the periods are called
--
-- The privilege checks above ask whether a role may call it at all.
-- These ask the function's own two guards, and the one figure on a
-- period nothing read: its name.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tahun Lalu Sdn Bhd');
  v_clerk uuid := pg_temp.another_user('kerani@tahunlalu.test');
  v_ghost uuid := gen_random_uuid();
  v_prev  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.check_refused('a company that does not exist is said so',
    format('select public.create_previous_fiscal_year(%L)', v_ghost),
    format('Organization %s not found', v_ghost), 'P0001');

  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'sales', 'active');
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused('a member who may not post does not open a year',
    format('select public.create_previous_fiscal_year(%L)', v_org),
    'Insufficient privileges', '42501');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_prev := public.create_previous_fiscal_year(v_org);
  perform pg_temp.check_eq('each period is named for its month',
    (select string_agg(name, ', ' order by period_no)
       from public.fiscal_periods
      where fiscal_year_id = v_prev and period_no in (1, 2, 12)),
    'Jan 2025, Feb 2025, Dec 2025');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A year that starts late in a month  (`0782`)
--
-- Month arithmetic clamps a short month and never gives the day back.
-- Periods built by adding months to a 31st left days in no period --
-- before `0782`, 28 to 30 March, 30 May, 30 July, 30 October and 30
-- December of a year from 31 January -- and a journal on one of them
-- was refused inside a year that existed. Asked of both functions, for
-- a 31st and for a leap day.
-- ---------------------------------------------------------------------
create or replace function pg_temp.pfy_tiling(p_fy uuid)
returns text language sql as $$
  -- Days in the year, days in a period, and days in two -- which must
  -- read N, N, 0 -- and whether period n+1 starts the day after n ends.
  with y as (select start_date, end_date from public.fiscal_years where id = p_fy),
       d as (select g::date as day from y, generate_series(y.start_date, y.end_date, interval '1 day') g),
       c as (select d.day, count(p.id) as n
               from d left join public.fiscal_periods p
                 on p.fiscal_year_id = p_fy and d.day between p.start_date and p.end_date
              group by d.day)
  select (select count(*) from d) || ' days, '
      || (select count(*) from c where n = 1) || ' in one period, '
      || (select count(*) from c where n <> 1) || ' in none or two, '
      || (select count(*) from public.fiscal_periods a
            join public.fiscal_periods b on b.fiscal_year_id = a.fiscal_year_id
                                        and b.period_no = a.period_no + 1
           where a.fiscal_year_id = p_fy and b.start_date <> a.end_date + 1)
      || ' gaps between periods, last ends '
      || (select max(end_date) from public.fiscal_periods where fiscal_year_id = p_fy)
      || ' of ' || (select end_date from y);
$$;

do $$
declare
  v_org  uuid := pg_temp.test_org('Hujung Bulan Sdn Bhd');
  v_org2 uuid;
  v_fy   uuid;
  v_prev uuid;
  v_e    uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_fy := public.create_fiscal_year(v_org, date '2026-01-31');
  perform pg_temp.check_eq('a year from the 31st is every day once, end to end',
    pg_temp.pfy_tiling(v_fy),
    '365 days, 365 in one period, 0 in none or two, 0 gaps between '
    'periods, last ends 2027-01-30 of 2027-01-30');
  perform pg_temp.check_eq('its second period runs on from the first',
    (select start_date || '..' || end_date from public.fiscal_periods
      where fiscal_year_id = v_fy and period_no = 2),
    '2026-02-28..2026-03-30');

  -- The day that was refused.
  v_e := public.create_gl_entry(v_org, date '2026-03-29',
    'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', (select id from public.accounts
                          where org_id = v_org and code = '1110'),
                         'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', (select id from public.accounts
                          where org_id = v_org and code = '3100'),
                         'debit', 0, 'credit', 100)),
    'Posted on a day that was in no period');
  perform pg_temp.check_eq('and 29 March posts, into the period that holds it',
    (select p.period_no from public.gl_entries e
       join public.fiscal_periods p on p.id = e.fiscal_period_id
      where e.id = v_e), 2);

  v_prev := public.create_previous_fiscal_year(v_org);
  perform pg_temp.check_eq('the year before it is tiled too',
    pg_temp.pfy_tiling(v_prev),
    '365 days, 365 in one period, 0 in none or two, 0 gaps between '
    'periods, last ends 2026-01-30 of 2026-01-30');
  -- Tiled is not enough: periods that each ran a month from their own
  -- start would tile too, drifting to the 28th by March and leaving
  -- the last one five weeks long.
  perform pg_temp.check_eq('and its periods keep to the year''s own day',
    (select string_agg(start_date || '..' || end_date, ', ' order by period_no)
       from public.fiscal_periods
      where fiscal_year_id = v_prev and period_no in (3, 12)),
    '2025-03-31..2025-04-29, 2025-12-31..2026-01-30');

  -- And a leap day, both ways.
  perform pg_temp.allow_many_companies();
  v_org2 := pg_temp.test_org('Hari Lompat Sdn Bhd');
  v_fy := public.create_fiscal_year(v_org2, date '2028-02-29');
  perform pg_temp.check_eq('a year from a leap day is every day once',
    pg_temp.pfy_tiling(v_fy),
    '365 days, 365 in one period, 0 in none or two, 0 gaps between '
    'periods, last ends 2029-02-27 of 2029-02-27');
  v_prev := public.create_previous_fiscal_year(v_org2);
  perform pg_temp.check_eq('and the year before it',
    pg_temp.pfy_tiling(v_prev),
    '365 days, 365 in one period, 0 in none or two, 0 gaps between '
    'periods, last ends 2028-02-28 of 2028-02-28');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may call it
-- ---------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon',
       'public.create_previous_fiscal_year(uuid)', 'execute') then
    raise exception 'FAIL: anon can open a fiscal year';
  end if;
  raise notice 'ok   anon cannot open a fiscal year';

  if not has_function_privilege('authenticated',
       'public.create_previous_fiscal_year(uuid)', 'execute') then
    raise exception 'FAIL: nobody signed in can open a previous year';
  end if;
  raise notice 'ok   a signed-in user may, subject to can_post';
end $$;

rollback;

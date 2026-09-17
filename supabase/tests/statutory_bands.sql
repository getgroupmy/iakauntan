-- =====================================================================
-- iAkauntan :: every shipped statutory table still covers every wage
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statutory_bands.sql
--
-- `app.assert_statutory_bands` (0404) is the rule that a schedule's
-- bands start at zero, run without gaps or OVERLAPS, and end open. It
-- runs when a schedule is published through
-- `platform_publish_statutory_schedule`, and it ran once over the seed
-- at migration time. Nothing re-checks it afterwards.
--
-- Two things depend on that rule holding, and neither says so:
--
--   * A GAP means a wage matches no band and contributes nothing —
--     which is what 0404 was written about.
--   * An OVERLAP means two bands cover one wage, and `calc_statutory`
--     takes whichever `order by wage_from desc` reaches first. A
--     mutation sweep of that function showed that ordering the other
--     way changes NOTHING against this suite, which is only true while
--     no two bands overlap. Without this file, that equivalence is an
--     assumption; with it, it is checked.
--
-- This file has NO FIXTURES on purpose. `statutory_schedules.sql`
-- deliberately builds a schedule with a hole in it to assert what
-- happens to a wage inside one, so a loop over every schedule cannot
-- live there.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

do $$
declare
  r  record;
  v_n integer := 0;
begin
  for r in select id, body, name from public.statutory_schedules
            order by body, effective_from
  loop
    -- Raises, with the body and the figure in the message, if this
    -- schedule has a gap, an overlap, a band that starts above zero or
    -- one that stops short of the top.
    perform app.assert_statutory_bands(r.id);
    v_n := v_n + 1;
  end loop;

  perform pg_temp.check_true(
    'there are statutory schedules to check at all', v_n > 0);
  perform pg_temp.check_eq(
    'every shipped schedule covers every wage exactly once',
    v_n::numeric,
    (select count(*)::numeric from public.statutory_schedules));

  -- And one of each body, so a body losing its table entirely is not
  -- silently "every schedule passes".
  for r in select unnest(enum_range(null::app.statutory_body)) as body loop
    perform pg_temp.check_true(
      format('%s has a table at all', r.body),
      exists (select 1 from public.statutory_schedules s
               where s.body = r.body));
  end loop;

  raise notice 'statutory_bands.sql: all assertions passed';
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: UTC is not today
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/utc_is_not_today.sql
--
-- Postgres runs in UTC, here and on Supabase. A Malaysian business day
-- is eight hours ahead, so `app.today()` exists -- it is
-- `app.malaysian_day(now())`. Between 16:00 and 24:00 UTC, which is
-- midnight to eight in the morning in Kuala Lumpur, `current_date` is
-- THE DAY BEFORE `app.today()`.
--
-- `0545` is what a parameter defaulted to `CURRENT_DATE` costs when
-- somebody actually omits it: the inventory forecast measured demand to
-- yesterday and then raised a purchase order dated today, for a third
-- of every day, in the one module whose whole job is deciding when
-- something runs out.
--
-- ## This file used to hold a list of thirty-nine. It holds none.
--
-- It carried them deliberately, with a reason, and the reason said:
--
--   > The rest are a TRAP AND NOT A BUG [...] the nightly cron passes
--   > `(now() at time zone 'Asia/Kuala_Lumpur')::date` explicitly, and
--   > every Dart caller of the others passes a date of its own -- so not
--   > one of those defaults is currently taken. Rewriting forty function
--   > bodies into an append-only migration to change a default nobody
--   > reaches would be a large irreversible artifact bought with
--   > nothing.
--
-- **The second sentence was wrong, and `0739` was written once it was
-- measured.** Six of the thirty-nine were reached from the shipped
-- client, because `repository.dart` sends those dates with a CONDITIONAL
-- SPREAD -- `if (asAt != null) 'p_as_at': Fmt.iso(asAt)` -- which omits
-- the parameter whenever the caller has no date, and the server default
-- then decides:
--
--   * `report_ar_aging` and `report_ap_aging`. The doc comment three
--     lines above the call says it outright: *"Passing no date asks
--     about today, which is what the dashboard wants."* So the dashboard
--     asked for today and got yesterday, for eight hours a day.
--   * `report_asset_movements` and `report_stock_card`, `p_to`.
--   * `run_recurring_documents_for` and `run_recurring_journals_for`,
--     `p_on` -- and those two WRITE. A recurring invoice or journal run
--     for the wrong day.
--
-- How it was found is the part worth keeping: not by reading. The test
-- suite moved onto the product's clock (`5bfc3141`) and was then run
-- with `PGTZ='Etc/GMT+12'`, a session a day behind Kuala Lumpur all day,
-- which is what CI sees from 16:00 UTC. `report_group_trial_balance`
-- returned NOTHING, because the test posted on the Malaysian day and
-- asked for the default window, which ended the day before. The tests
-- had been wrong about the clock for as long as the product was, so they
-- agreed with each other and neither was tested.
--
-- ## So the assertion is now the inverse, and stronger
--
-- NO function in `public` or `app` may default a date parameter to
-- `CURRENT_DATE`. There is no list to keep in step, nothing to excuse,
-- and the next one fails here by name. A ratchet at zero cannot drift --
-- which is the same argument `check_write_idempotency.py` reached at
-- `BACKLOG = 0` and `check_test_clock.py` at both of its pins.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare v_bad text;
begin
  select string_agg(f.name, ', ' order by f.name) into v_bad
    from (
      select n.nspname || '.' || p.proname as name
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app')
         and p.prokind = 'f'
         and pg_get_function_arguments(p.oid) ~* 'DEFAULT CURRENT_DATE'
    ) f;

  if v_bad is not null then
    raise exception
      'FAIL % defaults a date parameter to CURRENT_DATE, which is UTC. A '
      'Malaysian business day is eight hours ahead, so for eight hours '
      'out of twenty-four that default is YESTERDAY. Use '
      'DEFAULT app.today() -- 0545 and 0739 are the pattern. There is no '
      'list to be added to any more: the previous one said no caller '
      'omitted these defaults and six of them did.', v_bad
      using errcode = 'P0001';
  end if;

  perform pg_temp.check_eq(
    'no function defaults a date to the session clock', 0,
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'app') and p.prokind = 'f'
        and pg_get_function_arguments(p.oid) ~* 'DEFAULT CURRENT_DATE'));
end $$;

-- And that the fix really is on the product's clock, in numbers rather
-- than by the absence of the wrong thing. `0739` restated thirty-nine;
-- `0545` and four others were already right.
do $$
begin
  perform pg_temp.check_true(
    'and a good few now default to the Malaysian day instead',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'app') and p.prokind = 'f'
        and pg_get_function_arguments(p.oid) ~* 'DEFAULT app\.today\(\)')
    >= 39);

  -- The six that the shipped client really can reach with no date, named
  -- so that a later session can see which ones the premise was wrong
  -- about rather than taking it on trust.
  perform pg_temp.check_eq('the six reachable ones are on it', 6,
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f'
        and p.proname in ('report_ar_aging', 'report_ap_aging',
                          'report_asset_movements', 'report_stock_card',
                          'run_recurring_documents_for',
                          'run_recurring_journals_for')
        and pg_get_function_arguments(p.oid) ~* 'DEFAULT app\.today\(\)'));
end $$;

-- And the two facts the whole file rests on, asserted rather than
-- assumed.
do $$
begin
  perform pg_temp.check_eq('app.today() is the Malaysian day',
    app.today()::text,
    ((now() at time zone 'Asia/Kuala_Lumpur')::date)::text);
  perform pg_temp.check_true('and the forecast reads that clock',
    (select pg_get_function_arguments(oid) ~ 'p_as_of date DEFAULT app\.today'
       from pg_proc where proname = 'run_inventory_forecast'));
end $$;

rollback;

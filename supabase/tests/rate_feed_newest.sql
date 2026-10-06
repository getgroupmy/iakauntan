-- =====================================================================
-- iAkauntan :: how old is the newest exchange rate
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rate_feed_newest.sql
--
-- `public.rate_feed_newest()` (0744) is read every morning by
-- `.github/workflows/rate-feed-fresh.yml`, which has no session, to ask
-- whether the exchange rate feed is still alive. It exists because the
-- feed went eleven days dead in September 2026 and nothing noticed.
--
-- It is SECURITY DEFINER and granted to a stranger, so what matters is
-- as much what it cannot do as what it does. Three claims:
--
--   1. It answers with the newest GLOBAL rate -- the feed's -- and not a
--      company's own. Asserted with the company's row NEWER than the
--      feed's, because the other way round the filter could be deleted
--      and `max` would still return the right date. A fixture that
--      collapses the right answer and the wrong one into one value
--      proves nothing; CLAUDE.md's first trap.
--   2. With nothing stored it answers NULL, not a default. The gate
--      treats null as the worst case and must be given the chance to.
--   3. A stranger can call it and cannot do anything else with it: it
--      takes no argument, and the table itself stays shut to them. The
--      second half is the reason the function exists at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid := pg_temp.test_org('Kadar Sendiri Sdn Bhd');
begin
  -- A clean slate of GLOBAL rows, inside the transaction. Whatever a
  -- migration may have seeded is not this file's business.
  delete from public.exchange_rates where org_id is null;

  -- --- 2. nothing stored ---------------------------------------------
  perform pg_temp.check_true('with no rate stored it answers null, not a default',
    public.rate_feed_newest() is null);

  -- --- 1. the feed's rate, not a company's ---------------------------
  insert into public.exchange_rates (org_id, from_currency, to_currency, rate, rate_date)
  values (null, 'USD', 'MYR', 4.2000, date '2026-09-24'),
         (null, 'USD', 'MYR', 4.2100, date '2026-09-25'),
         (null, 'SGD', 'MYR', 3.2500, date '2026-09-25');
  -- A company's OWN rate, deliberately NEWER than anything the feed
  -- stored. If the `org_id is null` filter were gone, this is the date
  -- that would come back.
  insert into public.exchange_rates (org_id, from_currency, to_currency, rate, rate_date)
  values (v_org, 'USD', 'MYR', 4.3000, date '2026-10-05');

  perform pg_temp.check_eq('it answers with the newest rate the FEED stored',
    public.rate_feed_newest()::text, '2026-09-25');
  perform pg_temp.check_true(
    'and not a company''s own rate, which is newer and must not count',
    public.rate_feed_newest() < date '2026-10-05');
  -- The control for the line above: the newer company row really is
  -- there, so the assertion is about the filter and not a missing row.
  perform pg_temp.check_eq('-- the company''s newer rate really is stored',
    (select max(rate_date)::text from public.exchange_rates where org_id = v_org),
    '2026-10-05');

  -- --- 3. what a stranger can and cannot do --------------------------
  perform pg_temp.check_true('a stranger may call it',
    has_function_privilege('anon', 'public.rate_feed_newest()', 'execute'));
  perform pg_temp.check_eq('and it takes no argument that could steer it',
    (select pronargs::integer from pg_proc
      where oid = 'public.rate_feed_newest()'::regprocedure), 0);
  perform pg_temp.check_true('it sees past row security, which is why it can answer',
    (select prosecdef from pg_proc
      where oid = 'public.rate_feed_newest()'::regprocedure));
  perform pg_temp.check_true('with its search path pinned',
    (select proconfig::text like '%search_path=%' from pg_proc
      where oid = 'public.rate_feed_newest()'::regprocedure));
end $$;

-- As the stranger, for real rather than by catalog. The function
-- answers; the table it reads stays shut. That pair is the whole case
-- for 0744: the anon key cannot read `exchange_rates`, and before this
-- function the gate got an HTTP 200 with zero rows and would have
-- reported an empty table for ever.
--
-- The role is switched INSIDE the block and the answers captured before
-- switching back, which is how `demo_accounts_switch.sql` does it: the
-- `pg_temp` assertion helpers are the fixture user's, not a stranger's.
-- `current_user` is captured too, as the control -- without it, "the
-- table shows nothing" could be passing because the switch never
-- happened and the rows were deleted.
do $$
declare
  v_role  text;
  v_date  date;
  v_rows  integer;
begin
  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  v_date := public.rate_feed_newest();
  -- Two ways for a stranger to read nothing, and which one depends on
  -- the stack rather than on this repository. On Supabase, default
  -- privileges grant anon SELECT on every table and the one policy
  -- (`authenticated` only) filters it to zero rows: HTTP 200 and `[]`,
  -- which is what production answered on 6 October. On the local stack
  -- those default privileges are not stubbed and the read is refused
  -- outright. Both are "nothing"; a row would be the failure.
  begin
    select count(*)::integer into v_rows from public.exchange_rates;
  exception when insufficient_privilege then
    v_rows := 0;
  end;
  reset role;

  perform pg_temp.check_eq('the next two really ran as a stranger', v_role, 'anon');
  perform pg_temp.check_eq('called with no session, it still answers',
    v_date::text, '2026-09-25');
  perform pg_temp.check_eq('while the table itself shows a stranger nothing',
    v_rows, 0);
  -- And the rows are THERE, so "nothing" is row security and not an
  -- empty table: four were inserted above.
  perform pg_temp.check_eq('-- although four rows are stored',
    (select count(*)::integer from public.exchange_rates), 4);
end $$;

rollback;

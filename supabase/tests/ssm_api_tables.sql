-- =====================================================================
-- iAkauntan :: what the official SSM lookup may write, and who may read it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ssm_api_tables.sql
--
-- `0604` adds the log and widens the cache for SSM's own Search API.
-- Both are written only by the `ssm-api` edge function, holding the
-- service role, and neither is anybody's to read.
--
-- Three things are decisions rather than columns, and they are what
-- this file is for:
--
--   * **Nobody signed in may read either table.** The log names which
--     company looked which company up, and the cache holds directors'
--     identity numbers, dates of birth and home addresses for the
--     length of its TTL. RLS is on with no policy and the grants are
--     revoked — belt and braces, because either alone is one
--     migration away from being undone.
--
--   * **The log is not on the live feed, and that is deliberate.**
--     `live_change_feed.sql` requires every org-scoped table to wake
--     the clients watching it. This one is excused there in writing.
--     Asserted from this side too, because an exception recorded in
--     the test that enforces it is an exception that can be deleted
--     with the rule.
--
--   * **The cache keeps the columns the interim provider wrote.**
--     `0589`'s rows have no action, no params and no base_url. A `not
--     null` on any of the three would have meant dropping a cache that
--     is doing its job, so all three are nullable and this says so.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_user  uuid;
  v_seen  bigint;
  v_role  text;
  v_purged integer;
  v_refused boolean;
begin
  v_user := pg_temp.test_user();
  v_org := pg_temp.test_org('SSM Lookup Sdn Bhd');

  -- ==================================================================
  -- 1. A call is recorded, with enough on it to reconcile a bill
  -- ==================================================================
  insert into public.ssm_api_log (
    org_id, searched_by, action, path, client_ref_no, request_ref_no,
    status, ok, duration_ms, base_url)
  values (
    v_org, v_user, 'search', '/get-search-entity',
    v_org || ':11111111-1111-1111-1111-111111111111', 'SSM-REF-1',
    200, true, 412, 'https://apigw.ssmsearch.com/gateway/CIDP/V1.1/');

  select count(*) into v_seen
    from public.ssm_api_log where org_id = v_org;
  perform pg_temp.check_eq('the call was recorded', v_seen, 1::bigint);

  -- The host is on the row because the development host is free and
  -- production is charged. A log that did not say which would make the
  -- bill unreconcilable, which is the only reason this table exists at
  -- the row level rather than as a counter.
  perform pg_temp.check_true(
    'the row says which host answered',
    exists (select 1 from public.ssm_api_log
             where org_id = v_org and base_url like '%apigw%'));

  -- ==================================================================
  -- 2. A failure is recorded as one
  --
  -- CIDP puts its errors inside a 200, so `ok` cannot be derived from
  -- `status` and the two are stored separately.
  -- ==================================================================
  insert into public.ssm_api_log (
    org_id, searched_by, action, path, client_ref_no,
    status, ok, error_kind, base_url)
  values (
    v_org, v_user, 'companyProfile', '/get-company-profile-document',
    v_org || ':22222222-2222-2222-2222-222222222222',
    200, false, 'upstream', 'https://cidp.ssmsearch.com/');

  perform pg_temp.check_true(
    'a 200 that failed is stored as a failure',
    exists (select 1 from public.ssm_api_log
             where org_id = v_org and status = 200 and not ok
               and error_kind = 'upstream'));

  -- ==================================================================
  -- 3. Nobody signed in may read the log
  --
  -- The suite runs as the table's OWNER, which bypasses every policy,
  -- so an assertion made without switching role passes whatever the
  -- policy says. `0603` learned this the expensive way. The role is
  -- switched, the switch is asserted, and the refusal is the assertion.
  -- ==================================================================
  set local role authenticated;
  select current_user into v_role;
  perform pg_temp.check_eq('the role actually switched', v_role, 'authenticated');

  -- RLS on with no policy answers zero rows; the revoke answers with a
  -- refusal. Either is the right answer and what must not happen is
  -- ROWS -- so the outcome is captured and then asserted, rather than
  -- the assertion being made inside a block whose exception handler
  -- would swallow it. An assertion that silently did not run is how a
  -- suite reports a clean sweep over a table nobody checked.
  begin
    select count(*) into v_seen from public.ssm_api_log;
    v_refused := false;
  exception when insufficient_privilege then
    v_refused := true;
    v_seen := 0;
  end;
  perform pg_temp.check_true(
    'a signed-in user reads nothing from the log',
    v_refused or v_seen = 0);
  perform pg_temp.check_true(
    'and it was refused outright rather than merely empty', v_refused);

  begin
    select count(*) into v_seen from public.ssm_search_cache;
    v_refused := false;
  exception when insufficient_privilege then
    v_refused := true;
    v_seen := 0;
  end;
  perform pg_temp.check_true(
    'nor anything from the cache', v_refused or v_seen = 0);
  perform pg_temp.check_true(
    'and that one is refused outright too', v_refused);

  -- And the positive control for both, because "a signed-in user sees
  -- nothing" passes against a table that does not exist.
  reset role;
  select count(*) into v_seen from public.ssm_api_log where org_id = v_org;
  perform pg_temp.check_eq(
    'but the service role sees them', v_seen, 2::bigint);

  -- ==================================================================
  -- 4. The cache keeps the interim provider's rows
  --
  -- `0589`'s rows carry no action, no params and no base_url. If any of
  -- the three were `not null` the migration would have had to drop a
  -- working cache.
  -- ==================================================================
  insert into public.ssm_search_cache (cache_key, provider, payload, expires_at)
  values ('ssmsearch_web|maju|1|20', 'ssmsearch_web', '{"items":[]}'::jsonb,
          now() + interval '1 day');
  perform pg_temp.check_true(
    'a row from the interim provider still writes',
    exists (select 1 from public.ssm_search_cache
             where cache_key = 'ssmsearch_web|maju|1|20'
               and action is null and base_url is null));

  -- And the official one carries all three.
  insert into public.ssm_search_cache (
    cache_key, provider, action, params, payload, base_url, expires_at)
  values ('sha256-of-something', 'ssm_api', 'companyProfile',
          '{"regNo":"199301012345"}'::jsonb, '{"rocCompanyInfo":{}}'::jsonb,
          'https://cidp.ssmsearch.com/', now() + interval '7 days');
  perform pg_temp.check_true(
    'and a row from the official API carries the host it came from',
    exists (select 1 from public.ssm_search_cache
             where cache_key = 'sha256-of-something'
               and base_url = 'https://cidp.ssmsearch.com/'));

  -- ==================================================================
  -- 5. Purging takes the expired and leaves the rest
  -- ==================================================================
  insert into public.ssm_search_cache (cache_key, provider, payload, expires_at)
  values ('stale', 'ssm_api', '{}'::jsonb, now() - interval '1 hour');

  select public.ssm_search_cache_purge() into v_purged;
  perform pg_temp.check_true(
    'the expired row is gone', v_purged >= 1);
  perform pg_temp.check_true(
    'and the live ones are not',
    exists (select 1 from public.ssm_search_cache
             where cache_key = 'sha256-of-something'));
end $$;

-- =====================================================================
-- 6. The log is off the live feed, deliberately
--
-- Asserted from this side as well as excused in `live_change_feed.sql`.
-- An exception that lives only in the file enforcing the rule is one
-- that disappears the day somebody rewrites that file, and the reason
-- would go with it: nobody may read this table, so a notice on the feed
-- would wake every client watching the company to say that something
-- they cannot select from has moved.
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'ssm_api_log has no live-change trigger',
    not exists (
      select 1 from pg_trigger t
       where t.tgrelid = 'public.ssm_api_log'::regclass
         and not t.tgisinternal
         and t.tgname like 'live_change%'));

  -- The control: a table that IS on the feed, so this cannot pass by
  -- looking for triggers in the wrong place.
  perform pg_temp.check_true(
    'while a table that is on the feed has one',
    exists (
      select 1 from pg_trigger t
       where t.tgrelid = 'public.mia_credentials'::regclass
         and not t.tgisinternal
         and t.tgname = 'live_change_insert'));
end $$;

-- =====================================================================
-- 7. The purge is nobody's to call
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'authenticated cannot purge the cache',
    not has_function_privilege(
      'authenticated', 'public.ssm_search_cache_purge()', 'execute'));
  perform pg_temp.check_true(
    'nor anon',
    not has_function_privilege(
      'anon', 'public.ssm_search_cache_purge()', 'execute'));
  perform pg_temp.check_true(
    'but the service role can',
    has_function_privilege(
      'service_role', 'public.ssm_search_cache_purge()', 'execute'));
end $$;

rollback;

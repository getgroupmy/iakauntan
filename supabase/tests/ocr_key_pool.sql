-- =====================================================================
-- iAkauntan :: a pool of reader keys, each with a budget and a clock
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ocr_key_pool.sql
--
-- `0675` lets a platform hold several keys for one reader and spreads
-- the traffic across them, standing a key down when it has spent its
-- allowance or when its clock says not now. Every part of that is a
-- thing that can be wrong QUIETLY:
--
--   * a cap that is never reached keeps calling a key Google has
--     already started refusing, and the failure arrives as somebody's
--     scan not working;
--   * a window that reads empty as "never" stands the whole pool down
--     the moment it is filled, and the symptom is the same;
--   * a counter that does not roll over stands a key down for ever
--     after its first busy minute;
--   * a round-robin that is not one burns the first key to its cap
--     before touching the second, which is exactly what several keys
--     were for.
--
-- And one that can be wrong LOUDLY and is worse: a console function
-- that returns the key. `ocr_keys_for` is asserted to return the last
-- four characters and nothing more.
--
-- The claim is asserted through `public.claim_ocr_key`, which is the
-- name the edge function can actually reach. `0675` put it in `app`,
-- where PostgREST does not serve it, and `0676` moved it -- a test
-- written against the `app` name would have gone on passing while
-- every scan in production quietly fell through to the single key in
-- the environment.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_a      uuid;
  v_b      uuid;
  v_got    record;
  v_n      integer;
  v_txt    text;
begin
  v_org := pg_temp.test_org('Sinar Teknologi');

  -- -------------------------------------------------------------------
  -- The clock, asserted against times rather than by making requests
  --
  -- Read in Asia/Kuala_Lumpur, so the instants below are chosen to fall
  -- either side of a boundary in THAT zone and not in UTC. 02:00 UTC is
  -- 10:00 in Kuala Lumpur, which is the whole point of the conversion.
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'three empty arrays is always, not never',
    app.ocr_key_in_window('{}', '{}', '{}', timestamptz '2026-03-04 02:00Z'));

  perform pg_temp.check_true(
    'an hour is read in Malaysian time, not UTC',
    app.ocr_key_in_window(array[10]::smallint[], '{}', '{}',
      timestamptz '2026-03-04 02:00Z'));
  perform pg_temp.check_true(
    'and the UTC hour is not the one that counts',
    not app.ocr_key_in_window(array[2]::smallint[], '{}', '{}',
      timestamptz '2026-03-04 02:00Z'));

  -- 4 March 2026 is a Wednesday, isodow 3.
  perform pg_temp.check_true(
    'a weekday it allows',
    app.ocr_key_in_window('{}', array[3]::smallint[], '{}',
      timestamptz '2026-03-04 02:00Z'));
  perform pg_temp.check_true(
    'a weekday it does not',
    not app.ocr_key_in_window('{}', array[6, 7]::smallint[], '{}',
      timestamptz '2026-03-04 02:00Z'));

  perform pg_temp.check_true(
    'a month it allows',
    app.ocr_key_in_window('{}', '{}', array[3]::smallint[],
      timestamptz '2026-03-04 02:00Z'));

  -- All three bind together, which is what makes a window a window: an
  -- hour that matches does not save a month that does not.
  perform pg_temp.check_true(
    'the three gates are AND, not OR',
    not app.ocr_key_in_window(
      array[10]::smallint[], array[3]::smallint[], array[11]::smallint[],
      timestamptz '2026-03-04 02:00Z'));

  -- -------------------------------------------------------------------
  -- Two keys in the platform's pool, and the round-robin between them
  -- -------------------------------------------------------------------
  insert into public.ocr_provider_keys
    (provider, org_id, label, api_key, per_minute)
  values ('gemini', null, 'Studio one', 'AIza-first-1111', 2)
  returning id into v_a;

  insert into public.ocr_provider_keys
    (provider, org_id, label, api_key, per_minute)
  values ('gemini', null, 'Studio two', 'AIza-second-2222', 2)
  returning id into v_b;

  -- Never used sorts first, and `created_at` breaks the tie, so the
  -- first claim is the first key added.
  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('the first claim takes the first key',
    v_got.label, 'Studio one');
  perform pg_temp.check_eq('and hands back the key itself',
    v_got.api_key, 'AIza-first-1111');

  -- The SECOND claim must not be the same key. This is the assertion
  -- that a pool is a pool: an implementation ordering by id, or by
  -- nothing at all, passes the line above and fails here.
  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('the second claim moves on to the second key',
    v_got.label, 'Studio two');

  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('and the third comes back round',
    v_got.label, 'Studio one');

  -- -------------------------------------------------------------------
  -- The budget
  --
  -- Two each per minute, and four have now been spent. The fifth claim
  -- has nowhere to go and must come back empty rather than handing out
  -- a key that is over its cap.
  -- -------------------------------------------------------------------
  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('the fourth spends the last of the minute',
    v_got.label, 'Studio two');

  select count(*) into v_n from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('a spent pool gives out nothing', v_n, 0);

  -- -------------------------------------------------------------------
  -- And the window rolls
  --
  -- A minute that has passed is not a minute that was spent. Moved back
  -- by hand rather than waited out, which is the only way to assert
  -- this in a test that finishes.
  -- -------------------------------------------------------------------
  update public.ocr_provider_keys
     set minute_start = minute_start - interval '5 minutes'
   where provider = 'gemini' and org_id is null;

  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_true('a new minute is a new allowance',
    v_got.label is not null);
  select minute_count into v_n from public.ocr_provider_keys
   where id = v_got.key_id;
  perform pg_temp.check_eq(
    'and the count restarts at one rather than carrying yesterday forward',
    v_n, 1);

  -- -------------------------------------------------------------------
  -- A day cap binds even when the minute has room
  -- -------------------------------------------------------------------
  update public.ocr_provider_keys
     set per_minute = null, per_day = 3,
         day_start = (now() at time zone 'Asia/Kuala_Lumpur')::date,
         day_count = 3
   where provider = 'gemini' and org_id is null;

  select count(*) into v_n from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq(
    'a key with its day spent is not offered, minute or no minute', v_n, 0);

  -- -------------------------------------------------------------------
  -- The clock stands a key down without spending anything
  -- -------------------------------------------------------------------
  update public.ocr_provider_keys
     set per_day = null, day_count = 0,
         -- An hour that cannot be now, whichever hour it is.
         hours = case
           when extract(hour from (now() at time zone 'Asia/Kuala_Lumpur')) = 3
           then array[4]::smallint[] else array[3]::smallint[] end
   where provider = 'gemini' and org_id is null;

  select count(*) into v_n from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('out of hours is out', v_n, 0);

  -- A key stood down by hand is out too, and for a different reason.
  update public.ocr_provider_keys
     set hours = '{}', is_active = false
   where provider = 'gemini' and org_id is null;
  select count(*) into v_n from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_eq('and so is one switched off', v_n, 0);

  -- -------------------------------------------------------------------
  -- One pool is not another
  --
  -- A company's own keys must never be handed to the platform's pool or
  -- to another company. `is not distinct from` is what does it, and
  -- plain `=` would quietly match nothing for the platform and
  -- everything for nobody.
  -- -------------------------------------------------------------------
  update public.ocr_provider_keys set is_active = true
   where provider = 'gemini' and org_id is null;

  insert into public.ocr_provider_keys
    (provider, org_id, label, api_key)
  values ('gemini', v_org, 'The company''s own', 'AIza-theirs-9999');

  select * into v_got from public.claim_ocr_key('gemini', v_org);
  perform pg_temp.check_eq('a company claims from its own pool',
    v_got.label, 'The company''s own');

  select * into v_got from public.claim_ocr_key('gemini', null);
  perform pg_temp.check_true(
    'and the platform never reaches into it',
    v_got.label in ('Studio one', 'Studio two'));

  -- -------------------------------------------------------------------
  -- What the console may see, and what it may not
  -- -------------------------------------------------------------------
  select count(*) into v_n from public.ocr_keys_for('gemini', v_org);
  perform pg_temp.check_eq('the console lists the pool', v_n, 1);

  select key_tail into v_txt from public.ocr_keys_for('gemini', v_org);
  perform pg_temp.check_eq('and shows the last four characters only',
    v_txt, '9999');

  -- The assertion that matters most in this file. Every column the
  -- function returns is checked against the key, because a key that
  -- leaks does not announce itself.
  select bool_or(t.v like '%AIza-theirs-9999%') into v_txt
    from public.ocr_keys_for('gemini', v_org) k,
         lateral (select to_jsonb(k)::text as v) t;
  perform pg_temp.check_true(
    'and no column of it carries the key',
    coalesce(v_txt::boolean, false) is not true);

  -- -------------------------------------------------------------------
  -- Who may ask
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a member cannot read the platform''s pool',
    $q$ select * from public.ocr_keys_for('gemini', null) $q$,
    '%Only the platform%');

  perform pg_temp.check_refused(
    'nor keep a key in it',
    $q$ select public.save_ocr_key('gemini', null, null, 'Mine', 'AIza-x') $q$,
    '%Only the platform%');

  -- -------------------------------------------------------------------
  -- Keeping a key
  --
  -- The update path takes a null key to mean "leave it alone", which is
  -- what lets somebody raise a cap without retyping a secret they no
  -- longer have. Asserted, because the alternative -- storing the null
  -- -- is a key nobody can use and an error that reads as Google's.
  -- -------------------------------------------------------------------
  select id into v_a from public.ocr_keys_for('gemini', v_org);
  perform public.save_ocr_key(
    'gemini', v_org, v_a, 'The company''s own', null, null, 500);

  select api_key into v_txt from public.ocr_provider_keys where id = v_a;
  perform pg_temp.check_eq('changing a cap does not disturb the key',
    v_txt, 'AIza-theirs-9999');
  select per_day into v_n from public.ocr_provider_keys where id = v_a;
  perform pg_temp.check_eq('and the cap is the one that was set', v_n, 500);

  perform pg_temp.check_refused(
    'adding one with no key at all is refused',
    format($q$ select public.save_ocr_key('gemini', %L, null, 'Empty', '  ') $q$,
           v_org),
    '%A key is needed%');

  -- -------------------------------------------------------------------
  -- What Settings needs before it offers the reader
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the pool size is what it holds',
    (public.ocr_key_pool_size('gemini', v_org) ->> 'keys')::numeric, 1);
  perform pg_temp.check_eq(
    'and how many of them could run right now',
    (public.ocr_key_pool_size('gemini', v_org) ->> 'usable')::numeric, 1);

  update public.ocr_provider_keys set is_active = false where id = v_a;
  perform pg_temp.check_eq(
    'a key switched off is still a key, and is not usable',
    (public.ocr_key_pool_size('gemini', v_org) ->> 'keys')::numeric, 1);
  perform pg_temp.check_eq(
    'usable drops to nought',
    (public.ocr_key_pool_size('gemini', v_org) ->> 'usable')::numeric, 0);

  -- -------------------------------------------------------------------
  -- The reader itself
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'Gemini arrives switched OFF, because its pool starts empty',
    not (select is_active from public.ocr_providers where code = 'gemini'));
  perform pg_temp.check_eq(
    'and speaks the chat-completions shape, so it needs no new handler',
    (select kind from public.ocr_providers where code = 'gemini'), 'openai');
end;
$$;

rollback;

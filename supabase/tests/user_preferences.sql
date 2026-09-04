-- =====================================================================
-- iAkauntan :: where you land when you sign in
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/user_preferences.sql
--
-- 0527. The landing route is read straight into the navigator, so what
-- the column will ACCEPT is the security boundary: a value that is not
-- an in-app path is a value that sends somebody somewhere this app did
-- not choose. The check is asserted on both sides -- what it refuses,
-- and the ordinary routes it must still take, because a pattern that
-- refuses everything would pass every refusal below.
--
-- Every read and write runs as `authenticated`. The suite connects as
-- `postgres`, a superuser, which BYPASSES row level security: a test
-- that only signs in asserts nothing about who is stopped.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_me   uuid := pg_temp.test_user();
  v_them uuid;
  v_role text;
  v_txt  text;
  v_arr  text[];
  v_n    integer;
  v_ok   boolean;
  v_bad  text;
begin
  perform pg_temp.test_org('Kedai Mula Sdn Bhd');
  v_them := pg_temp.another_user('lain@mula.test');
  perform pg_temp.sign_in_as(v_me);

  -- ==================================================================
  -- 1. The defaults, for somebody who has never opened the screen
  -- ==================================================================
  begin
    set local role authenticated;
    v_role := current_user;
    insert into public.user_preferences (user_id) values (v_me);
    select landing_route, dashboard_cards into v_txt, v_arr
      from public.user_preferences where user_id = v_me;
  end;
  reset role;

  perform pg_temp.check_eq('the file runs under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('the dashboard is where somebody lands by default',
    v_txt, '/dashboard');
  perform pg_temp.check_eq('and the default panels are the five',
    array_length(v_arr, 1)::numeric, 5);
  perform pg_temp.check_true('with the to-do list among them',
    'todos' = any (v_arr));
  perform pg_temp.check_true('and the ticker',
    'ticker' = any (v_arr));

  -- ==================================================================
  -- 2. The routes it must take
  --
  -- The control for section 3. Written first, because a pattern that
  -- refused everything would make every refusal below pass.
  -- ==================================================================
  foreach v_txt in array array[
    '/dashboard', '/todos', '/sales/invoice', '/purchases/bill',
    '/reports/general-ledger', '/pos', '/', '/contacts_all'
  ] loop
    begin
      set local role authenticated;
      update public.user_preferences set landing_route = v_txt
       where user_id = v_me;
      get diagnostics v_n = row_count;
    end;
    reset role;
    perform pg_temp.check_eq(
      format('an in-app route is accepted: %s', v_txt), v_n::numeric, 1);
  end loop;

  -- ==================================================================
  -- 3. What it must not take
  --
  -- Each of these reaches a navigator. A scheme leaves the app; a
  -- protocol-relative prefix leaves the HOST, which is the one that
  -- does not look like a URL at a glance; a newline is how a single
  -- field becomes two.
  -- ==================================================================
  foreach v_bad in array array[
    'https://elsewhere.test/steal',
    '//elsewhere.test/steal',
    'javascript:alert(1)',
    'dashboard',
    '/sales invoice',
    E'/dashboard\nX',
    ''
  ] loop
    begin
      set local role authenticated;
      begin
        update public.user_preferences set landing_route = v_bad
         where user_id = v_me;
        v_ok := true;
      exception when check_violation then v_ok := false;
      end;
    end;
    reset role;
    perform pg_temp.check_true(
      format('refused as a landing route: %s', coalesce(nullif(v_bad, ''), '(empty)')),
      not v_ok);
  end loop;

  -- And the row still holds the last good value, which is what
  -- "refused" has to mean.
  perform pg_temp.check_eq('and the last good route still stands',
    (select landing_route from public.user_preferences where user_id = v_me),
    '/contacts_all');

  -- ==================================================================
  -- 4. Turning everything off
  --
  -- A person may legitimately want a bare dashboard. Empty is a CHOICE
  -- and must be storable; it is the DEFAULT that carries the five, so
  -- the client cannot read emptiness as "not set yet".
  -- ==================================================================
  begin
    set local role authenticated;
    update public.user_preferences set dashboard_cards = '{}'
     where user_id = v_me;
    select dashboard_cards into v_arr
      from public.user_preferences where user_id = v_me;
  end;
  reset role;
  perform pg_temp.check_eq('every panel can be turned off',
    coalesce(array_length(v_arr, 1), 0)::numeric, 0);

  -- The order is the person's, and is kept.
  begin
    set local role authenticated;
    update public.user_preferences
       set dashboard_cards = array['ticker', 'todos']
     where user_id = v_me;
    select dashboard_cards into v_arr
      from public.user_preferences where user_id = v_me;
  end;
  reset role;
  perform pg_temp.check_eq('and the order chosen is the order stored',
    array_to_string(v_arr, ','), 'ticker,todos');

  -- ==================================================================
  -- 5. It is MY preference
  --
  -- No company scopes this table, so `user_id = auth.uid()` is the
  -- whole of it. Where somebody starts their day is nobody else's
  -- business.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    -- The control first: they can keep their own.
    insert into public.user_preferences (user_id, landing_route)
    values (v_them, '/pos');
    select count(*) into v_n from public.user_preferences;
  end;
  reset role;
  perform pg_temp.check_eq('somebody else keeps their own, and sees only it',
    v_n::numeric, 1);

  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    begin
      insert into public.user_preferences (user_id, landing_route)
      values (v_me, '/nowhere');
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true('nobody can set where another person lands',
    not v_ok);

  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    update public.user_preferences set landing_route = '/nowhere'
     where user_id = v_me;
    get diagnostics v_n = row_count;
  end;
  reset role;
  perform pg_temp.check_eq('nor change one that exists', v_n::numeric, 0);

  -- Mine is untouched, from my own session.
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    select landing_route into v_txt
      from public.user_preferences where user_id = v_me;
  end;
  reset role;
  perform pg_temp.check_eq('and mine is where I left it',
    v_txt, '/contacts_all');

  raise notice 'ok   where you land when you sign in';
end $$;

do $$
begin
  perform pg_temp.check_true('anon cannot read anybody''s preferences',
    not has_table_privilege('anon', 'public.user_preferences', 'select'));
  perform pg_temp.check_true('nor write them',
    not has_table_privilege('anon', 'public.user_preferences', 'insert'));
  -- No delete policy exists, so the privilege must not either: a grant
  -- with no policy behind it is a refusal that reads as a bug.
  perform pg_temp.check_true('and nobody deletes a preference row',
    not has_table_privilege('authenticated', 'public.user_preferences',
                            'delete'));
end $$;

rollback;

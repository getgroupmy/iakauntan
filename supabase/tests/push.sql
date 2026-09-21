-- =====================================================================
-- iAkauntan :: push notifications
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push.sql
--
-- A push is a message leaving the building. It lands on a handset that
-- may be locked, on a lock screen anybody standing nearby can read, and
-- it goes to whoever the register says is holding that handset. So two
-- things are asserted hardest here:
--
--   the register moves a token to whoever signed in last, and
--   the fan-out never reaches somebody who should not be in the room.
--
-- Everything that touches a policy runs as `authenticated` and checks
-- that it did: the connection is a superuser and a superuser bypasses
-- row level security, so a test that forgets is a test that passes for
-- the wrong reason.
--
-- Every refusal is paired with the thing that must still work. An
-- assertion that only checks "was this refused?" passes for any reason a
-- statement can fail, including a typo in this file.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A company with the chat module on, as in `chat.sql` — push is a
-- feature of chat and inherits all three of its gates.
create or replace function pg_temp.push_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v_org;

  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'chat', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end; $$;

-- ---------------------------------------------------------------------
-- Registering a handset, and what happens when it changes hands
-- ---------------------------------------------------------------------
do $$
declare
  v_ali  uuid := pg_temp.another_user('ali@push.test');
  v_siti uuid := pg_temp.another_user('siti@push.test');
  v_org  uuid;
  v_role text;
  v_n int;
  v_holder uuid;
begin
  v_org := pg_temp.push_org('Push Test Sdn Bhd', v_ali);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_siti, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ali);
  perform public.chat_set_access(v_org, v_ali, true);
  perform public.chat_set_access(v_org, v_siti, true);

  begin
    set local role authenticated;
    v_role := current_user;
    perform public.register_device('token-pixel', 'android', 'Pixel 7');
    -- The app calls this on every start, so twice must not mean two rows.
    perform public.register_device('token-pixel', 'android', 'Pixel 7');
    select count(*) into v_n
      from public.device_tokens where token = 'token-pixel';
  end;
  reset role;

  perform pg_temp.check_true('the registration ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('registering twice is still one handset', v_n, 1);

  -- The one that matters. Siti signs in on the phone Ali was using;
  -- Firebase hands back the same token, because the token belongs to the
  -- installation rather than to the person.
  perform pg_temp.sign_in_as(v_siti);
  begin
    set local role authenticated;
    perform public.register_device('token-pixel', 'android', 'Pixel 7');
  end;
  reset role;

  select count(*) into v_n from public.device_tokens where token = 'token-pixel';
  select user_id into v_holder
    from public.device_tokens where token = 'token-pixel';

  perform pg_temp.check_eq('a handset that changes hands is still one row',
    v_n, 1);
  perform pg_temp.check_true(
    'and belongs to whoever signed in last',
    v_holder = v_siti);
  perform pg_temp.check_true(
    'not to the person who handed it over — otherwise their messages '
    'keep arriving on a phone they no longer hold',
    v_holder <> v_ali);

  perform set_config('pg_temp.org',  v_org::text,  false);
  perform set_config('pg_temp.ali',  v_ali::text,  false);
  perform set_config('pg_temp.siti', v_siti::text, false);
end $$;

-- ---------------------------------------------------------------------
-- Somebody else's handsets are not readable
-- ---------------------------------------------------------------------
do $$
declare
  v_ali  uuid := current_setting('pg_temp.ali')::uuid;
  v_siti uuid := current_setting('pg_temp.siti')::uuid;
  v_mine int; v_theirs int; v_role text;
begin
  perform pg_temp.sign_in_as(v_ali);
  begin
    set local role authenticated;
    v_role := current_user;
    -- A browser, so it carries the keys its payload is encrypted to.
    -- 0143 refuses a web registration without them.
    perform public.register_device('token-ali-laptop', 'web', 'Chrome',
      'BF9r0MNfkTnnOIyDD7OPllJoaJ1pPH3TeznR5L1Ip7u5CxzG7mdpNqmDPRdTZxaec_QQtYxae_qqF8hket0IfxQ',
      'fsR_NIlY2ogaxU0mczQmdw');
    select count(*) into v_mine
      from public.device_tokens where user_id = v_ali;
    select count(*) into v_theirs
      from public.device_tokens where user_id = v_siti;
  end;
  reset role;

  perform pg_temp.check_true('read under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a person sees their own handsets', v_mine, 1);
  perform pg_temp.check_eq(
    'and none of anybody else''s', v_theirs, 0);
end $$;

-- ---------------------------------------------------------------------
-- The fan-out is not readable by a client at all
-- ---------------------------------------------------------------------
do $$
declare
  v_ali uuid := current_setting('pg_temp.ali')::uuid;
  v_refused boolean := false;
  v_n int;
begin
  perform pg_temp.sign_in_as(v_ali);
  begin
    set local role authenticated;
    select count(*) into v_n
      from public.push_targets(gen_random_uuid(), null);
  exception when insufficient_privilege then
    v_refused := true;
  end;
  reset role;
  -- A caught exception rolls back to a savepoint and takes the
  -- `set_config` with it.
  perform pg_temp.sign_in_as(v_ali);

  perform pg_temp.check_true(
    'a signed-in client cannot read the device tokens of a whole room',
    v_refused);
end $$;

-- ---------------------------------------------------------------------
-- Who a message actually reaches
--
-- From here on the caller is the service role, because that is what the
-- edge function is. `push_targets` is the only thing in this file that
-- deliberately runs unauthenticated.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := current_setting('pg_temp.org')::uuid;
  v_ali  uuid := current_setting('pg_temp.ali')::uuid;
  v_siti uuid := current_setting('pg_temp.siti')::uuid;
  v_conv uuid;
  v_tokens text[];
begin
  perform pg_temp.sign_in_as(v_ali);
  v_conv := public.chat_start_direct(v_org, v_siti, v_org);
  perform set_config('pg_temp.conv', v_conv::text, false);
  perform pg_temp.sign_out();

  select array_agg(t.token order by t.token) into v_tokens
    from public.push_targets(v_conv, v_ali) t;
  perform pg_temp.check_true(
    'a message reaches the other person''s handset',
    v_tokens = array['token-pixel']);

  -- The control. Without it the assertion above would also pass for a
  -- function that returns nothing at all to anybody.
  select array_agg(t.token order by t.token) into v_tokens
    from public.push_targets(v_conv, v_siti) t;
  perform pg_temp.check_true(
    'and the other way round',
    v_tokens = array['token-ali-laptop']);

  perform pg_temp.check_true(
    'and never the sender''s own devices — a phone buzzing in the hand '
    'that just pressed send is the most reliably irritating bug there is',
    not exists (select 1 from public.push_targets(v_conv, v_ali) t
                 where t.token = 'token-ali-laptop'));
end $$;

-- ---------------------------------------------------------------------
-- Somebody outside the conversation is never reached
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := current_setting('pg_temp.org')::uuid;
  v_conv uuid := current_setting('pg_temp.conv')::uuid;
  v_zaid uuid := pg_temp.another_user('zaid@push.test');
begin
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_zaid, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_zaid);
  begin
    set local role authenticated;
    perform public.register_device('token-zaid', 'ios', 'iPhone');
  end;
  reset role;
  perform pg_temp.sign_out();

  perform pg_temp.check_true(
    'a colleague who is not in this conversation is not told about it',
    not exists (select 1 from public.push_targets(v_conv, null) t
                 where t.token = 'token-zaid'));

  -- Control: his handset is registered, so the absence above is about
  -- the conversation and not about a missing fixture.
  perform pg_temp.check_true(
    'even though his handset is registered',
    exists (select 1 from public.device_tokens where token = 'token-zaid'));
end $$;

-- ---------------------------------------------------------------------
-- Switching chat off stops the notifications, not just the messages
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := current_setting('pg_temp.org')::uuid;
  v_ali  uuid := current_setting('pg_temp.ali')::uuid;
  v_siti uuid := current_setting('pg_temp.siti')::uuid;
  v_conv uuid := current_setting('pg_temp.conv')::uuid;
  v_before int; v_after int;
begin
  perform pg_temp.sign_out();

  -- The control, taken before the change rather than assumed.
  perform pg_temp.check_true('while chat is on for her, Siti is reachable',
    exists (select 1 from public.push_targets(v_conv, v_ali) t
             where t.user_id = v_siti));

  perform pg_temp.sign_in_as(v_ali);
  perform public.chat_set_access(v_org, v_siti, false);
  perform pg_temp.sign_out();

  perform pg_temp.check_true(
    'switching chat off for somebody stops the notifications as well',
    not exists (select 1 from public.push_targets(v_conv, v_ali) t
                 where t.user_id = v_siti));

  perform pg_temp.sign_in_as(v_ali);
  perform public.chat_set_access(v_org, v_siti, true);
  perform pg_temp.sign_out();

  -- And the company's entitlement, which is the outermost gate.
  select count(*) into v_before from public.push_targets(v_conv, v_ali) t;
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'chat';
  select count(*) into v_after from public.push_targets(v_conv, v_ali) t;

  perform pg_temp.check_true('with the module on, somebody is reached',
    v_before > 0);
  perform pg_temp.check_eq('with it off, nobody is', v_after, 0);

  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'chat';
end $$;

-- ---------------------------------------------------------------------
-- Forgetting a dead token, and signing out
-- ---------------------------------------------------------------------
do $$
declare
  v_ali uuid := current_setting('pg_temp.ali')::uuid;
  v_refused boolean := false;
begin
  perform pg_temp.sign_in_as(v_ali);
  begin
    set local role authenticated;
    perform public.forget_device_token('token-pixel');
  exception when insufficient_privilege then
    v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_ali);

  perform pg_temp.check_true(
    'a client cannot delete somebody else''s registration by naming it',
    v_refused);

  -- The control: the sender can, which is how a token the push service
  -- has rejected gets off the register.
  perform pg_temp.sign_out();
  perform public.forget_device_token('token-pixel');
  perform pg_temp.check_true(
    'while the sender can forget a token the push service rejected',
    not exists (select 1 from public.device_tokens
                 where token = 'token-pixel'));
end $$;

do $$
declare
  v_ali uuid := current_setting('pg_temp.ali')::uuid;
  v_role text;
begin
  perform pg_temp.sign_in_as(v_ali);
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.unregister_device('token-ali-laptop');
    -- And somebody else's, which must do nothing at all.
    perform public.unregister_device('token-zaid');
  end;
  reset role;

  perform pg_temp.check_true('signing out ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true('signing out takes the handset off the register',
    not exists (select 1 from public.device_tokens
                 where token = 'token-ali-laptop'));
  perform pg_temp.check_true(
    'and cannot take somebody else''s off it',
    exists (select 1 from public.device_tokens where token = 'token-zaid'));
end $$;

-- ---------------------------------------------------------------------
-- Nothing new is exposed to anon
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('push_targets', 'forget_device_token',
                       'prune_device_tokens')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));

  perform pg_temp.check_true(
    'the service-role functions are service-role only, not merely '
    'documented as such: ' || coalesce(v_bad, 'none'),
    v_bad is null);
end $$;

-- ---------------------------------------------------------------------
-- A browser subscription (0143)
--
-- A web registration is three values, not one, and the failure this
-- guards against is silent: a row that registers without the keys the
-- payload is encrypted to leaves somebody believing they have
-- notifications while the sender skips them forever.
-- ---------------------------------------------------------------------
do $$
declare
  v_ani  uuid := pg_temp.another_user('ani@webpush.test');
  v_bala uuid := pg_temp.another_user('bala@webpush.test');
  v_org uuid;
  v_conv uuid;
  v_role text;
  v_refused boolean;
  v_p256dh text;
  v_auth text;
  v_n int;
begin
  v_org := pg_temp.push_org('Web Push Sdn Bhd', v_ani);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_bala, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ani);
  perform public.chat_set_access(v_org, v_ani, true);
  perform public.chat_set_access(v_org, v_bala, true);

  -- A browser registers with its endpoint as the token.
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.register_device(
      'https://fcm.googleapis.com/fcm/send/ani-laptop', 'web', 'Chrome',
      'BF9r0MNfkTnnOIyDD7OPllJoaJ1pPH3TeznR5L1Ip7u5CxzG7mdpNqmDPRdTZxaec_QQtYxae_qqF8hket0IfxQ',
      'fsR_NIlY2ogaxU0mczQmdw');
  end;
  reset role;

  perform pg_temp.check_true('a browser registers under row level security',
    v_role = 'authenticated');

  select p256dh, auth into v_p256dh, v_auth
    from public.device_tokens
   where token = 'https://fcm.googleapis.com/fcm/send/ani-laptop';
  perform pg_temp.check_true(
    'and its keys are kept, or there is nothing to encrypt to',
    v_p256dh is not null and v_auth is not null);

  -- Re-subscribing replaces the keys rather than keeping the first pair.
  -- A browser that re-subscribes throws its old key away, and encrypting
  -- to the one we remember produces a notification it cannot open.
  perform pg_temp.sign_in_as(v_ani);
  begin
    set local role authenticated;
    perform public.register_device(
      'https://fcm.googleapis.com/fcm/send/ani-laptop', 'web', 'Chrome',
      'BIT2RZmnQde3aKnW2ZCRZrdYknoWNyFCC36Cou9W3-YdsK38OTVv_fxNozYEG6z-M2b2muiM2b-QsHiz8a82ZtM',
      'W5Z_08z5XS9RsOOJqV5HTQ');
  end;
  reset role;

  select p256dh into v_p256dh from public.device_tokens
   where token = 'https://fcm.googleapis.com/fcm/send/ani-laptop';
  perform pg_temp.check_true('re-subscribing replaces the keys',
    v_p256dh like 'BIT2RZ%');
  perform pg_temp.check_eq('and does not leave a second row',
    (select count(*) from public.device_tokens
      where token = 'https://fcm.googleapis.com/fcm/send/ani-laptop'), 1);

  -- ---------------------------------------------------------------
  -- The refusals, each against the thing that must still work
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_ani);
  v_refused := false;
  begin
    perform public.register_device(
      'https://fcm.googleapis.com/fcm/send/no-keys', 'web', 'Chrome');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_ani);
  perform pg_temp.check_true(
    'a browser cannot register without its keys — the row would look '
    'like a notification that works and reach nobody',
    v_refused);

  v_refused := false;
  begin
    perform public.register_device(
      'token-android-with-keys', 'android', 'Pixel', 'BF9r0M', 'fsR_NI');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_ani);
  perform pg_temp.check_true(
    'and a Firebase token does not carry browser keys', v_refused);

  -- The control for both. Without it the two refusals above would pass
  -- for a function that refuses every registration.
  begin
    set local role authenticated;
    perform public.register_device('token-ani-phone', 'android', 'Pixel 8');
  end;
  reset role;
  perform pg_temp.check_true(
    'while an ordinary Firebase registration still works',
    exists (select 1 from public.device_tokens
             where token = 'token-ani-phone' and p256dh is null));

  -- ---------------------------------------------------------------
  -- The fan-out carries the keys
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_bala);
  begin
    set local role authenticated;
    perform public.register_device(
      'https://updates.push.services.mozilla.com/wpush/v2/bala', 'web',
      'Firefox',
      'BF9r0MNfkTnnOIyDD7OPllJoaJ1pPH3TeznR5L1Ip7u5CxzG7mdpNqmDPRdTZxaec_QQtYxae_qqF8hket0IfxQ',
      'fsR_NIlY2ogaxU0mczQmdw');
  end;
  reset role;

  perform pg_temp.sign_in_as(v_ani);
  v_conv := public.chat_start_direct(v_org, v_bala, v_org);

  select count(*) into v_n
    from public.push_targets(v_conv, v_ani) t
   where t.platform = 'web' and t.p256dh is not null and t.auth is not null;
  perform pg_temp.check_eq(
    'the fan-out hands the sender the keys to encrypt to', v_n, 1);

  -- And still excludes the sender, whose own laptop is also registered.
  perform pg_temp.check_eq('and still leaves the sender out',
    (select count(*) from public.push_targets(v_conv, v_ani) t
      where t.user_id = v_ani), 0);
end $$;

-- ---------------------------------------------------------------------
-- The nightly run actually runs the tidy-ups (0147)
--
-- `chat_expire_calls` and `prune_device_tokens` were written in 0140 and
-- 0141 and scheduled by nothing for three migrations. Asserting that
-- they *work* was never the gap — this asserts that something calls
-- them, which is the part that was missing.
-- ---------------------------------------------------------------------
do $$
declare
  v_ali  uuid := pg_temp.another_user('ali@nightly.test');
  v_siti uuid := pg_temp.another_user('siti@nightly.test');
  v_org uuid; v_conv uuid; v_call uuid;
  v_status text; v_reason text; v_n int;
begin
  v_org := pg_temp.push_org('Nightly Sdn Bhd', v_ali);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_siti, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ali);
  perform public.chat_set_access(v_org, v_ali, true);
  perform public.chat_set_access(v_org, v_siti, true);

  v_conv := public.chat_start_direct(v_org, v_siti, v_org);
  v_call := public.chat_start_call(v_conv, 'voice');

  -- A call nobody answered, as it would be by one in the morning.
  update public.chat_calls set ringing_until = now() - interval '2 hours'
   where id = v_call;

  select status::text into v_status from public.chat_calls where id = v_call;
  perform pg_temp.check_true(
    'before the nightly run the history still says ringing',
    v_status = 'ringing');

  -- And no phone is ringing, which is why this is a label fix rather
  -- than a ringing fix: the reads already filter on the deadline.
  perform pg_temp.sign_in_as(v_siti);
  select count(*) into v_n from public.chat_incoming_calls();
  perform pg_temp.check_eq('while nothing is actually ringing', v_n, 0);
  perform pg_temp.sign_in_as(v_ali);

  insert into public.device_tokens (user_id, token, platform, last_seen_at)
  values (v_siti, 'token-ancient', 'android', now() - interval '400 days');
  -- The control. Without it, "the old one went" would pass for a prune
  -- that emptied the table.
  insert into public.device_tokens (user_id, token, platform, last_seen_at)
  values (v_siti, 'token-fresh', 'android', now());

  perform app.run_daily_jobs(current_date);

  select status::text, end_reason into v_status, v_reason
    from public.chat_calls where id = v_call;
  perform pg_temp.check_true(
    'the nightly run leaves it missed rather than ringing since Tuesday',
    v_status = 'missed');
  perform pg_temp.check_true('and says why', v_reason = 'nobody answered');
  perform pg_temp.check_eq('with nobody left ringing on it',
    (select count(*) from public.chat_call_participants
      where call_id = v_call and state = 'ringing'), 0);

  perform pg_temp.check_true(
    'and a handset nobody has presented in a year is off the register',
    not exists (select 1 from public.device_tokens where token = 'token-ancient'));
  perform pg_temp.check_true('while one in daily use is not',
    exists (select 1 from public.device_tokens where token = 'token-fresh'));
end $$;

-- ---------------------------------------------------------------------
-- 0657: which service a token belongs to
-- ---------------------------------------------------------------------
--
-- An iOS row is now either a Firebase registration token or a raw APNs
-- device token, and they are NOT interchangeable: sent to the wrong
-- service each is refused forever, and both refusals are silent --
-- `send-push` reports the notification, nobody's phone makes a sound.
--
-- So what is asserted is the three ways that can go wrong at the write,
-- because at the read there is nothing to see.
do $$
declare
  v_ali  uuid := pg_temp.another_user('ali-apns@push.test');
  v_org  uuid;
  v_apns text := repeat('a1b2c3d4', 8);   -- 64 hex characters
  v_fcm  text := 'fMEP0vJqSHG:APA91bF-not-hex-at-all_0123';
  v_said text;
begin
  v_org := pg_temp.push_org('APNs Test Sdn Bhd', v_ali);
  perform pg_temp.sign_in_as(v_ali);

  -- Absent means what the platform has always meant, so every caller
  -- written before 0657 keeps working. This is the assertion that says
  -- the migration changed nobody's registration.
  perform public.register_device(v_fcm, 'android');
  perform pg_temp.check_eq('an Android handset is still Firebase',
    (select transport from public.device_tokens where token = v_fcm), 'fcm');

  perform public.register_device('https://push.example.test/x', 'web',
    null, 'a-p256dh-key', 'an-auth-key');
  perform pg_temp.check_eq('and a browser is still web push',
    (select transport from public.device_tokens
      where token = 'https://push.example.test/x'), 'web');

  -- The new one, asked for by name.
  perform public.register_device(v_apns, 'ios', 'An iPhone', null, null,
                                 'apns');
  perform pg_temp.check_eq('an iPhone can be registered straight to Apple',
    (select transport from public.device_tokens where token = v_apns), 'apns');

  -- And the same phone through Firebase, which is still allowed: the
  -- two are a choice about how the build was made, not about the model.
  perform public.register_device('fMEP0vJq:APA91bF-ios', 'ios', null, null,
                                 null, 'fcm');
  perform pg_temp.check_eq('or through Firebase, as before',
    (select transport from public.device_tokens
      where token = 'fMEP0vJq:APA91bF-ios'), 'fcm');

  -- A Firebase token registered as APNs is `BadDeviceToken` on every
  -- notification, forever, with nothing anywhere reporting it. Refused
  -- at the write, where it can still be said out loud.
  begin
    perform public.register_device(v_fcm || 'x', 'ios', null, null, null,
                                   'apns');
    perform pg_temp.check_true(
      'a Firebase token cannot be registered as an APNs one', false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true(
      'a Firebase token cannot be registered as an APNs one',
      v_said like '%not an APNs device token%');
  end;

  -- Android has no direct transport. Saying so beats a check constraint
  -- name, because somebody asking for it has a wrong belief rather than
  -- a typo.
  begin
    perform public.register_device(v_apns || 'ff', 'android', null, null,
                                   null, 'apns');
    perform pg_temp.check_true('Android cannot be reached through APNs',
                               false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('Android cannot be reached through APNs',
      v_said like '%no direct transport%');
  end;

  begin
    perform public.register_device('https://push.example.test/y', 'web',
      null, 'k', 'a', 'apns');
    perform pg_temp.check_true('nor is a browser an iPhone', false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('nor is a browser an iPhone',
      v_said like '%web push and nothing else%');
  end;

  -- A transport nobody has written a sender for would be a row that is
  -- skipped on every notification with no explanation.
  begin
    perform public.register_device(v_apns || 'ee', 'ios', null, null, null,
                                   'telepathy');
    perform pg_temp.check_true('and a transport nobody sends on is refused',
                               false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('and a transport nobody sends on is refused',
      v_said like '%Unknown transport%');
  end;

  -- The sender routes on this, so it has to arrive. Read through
  -- `push_targets` rather than off the table, because the function is
  -- what `send-push` actually calls and restating it is where the
  -- column would have been dropped.
  perform pg_temp.check_true(
    'and the sender is told which service each token is for',
    exists (
      select 1 from pg_proc p
      cross join lateral unnest(p.proargnames, p.proargmodes) as a(name, mode)
      where p.oid = 'public.push_targets(uuid, uuid)'::regprocedure
        and a.mode = 't' and a.name = 'transport'));
end $$;

-- ---------------------------------------------------------------------
-- A handset that changes transport keeps one row
-- ---------------------------------------------------------------------
--
-- 0141's rule is one token, one handset. A build that moves from
-- Firebase to a direct APNs registration hands back a DIFFERENT token,
-- so that case is two rows and correctly so -- but re-registering the
-- same token with a new transport must replace it rather than keep the
-- old one, or the phone is addressed to the wrong Apple forever.
do $$
declare
  v_ali uuid := pg_temp.another_user('ali-move@push.test');
  v_org uuid;
  v_tok text := repeat('deadbeef', 8);
begin
  v_org := pg_temp.push_org('Transport Move Sdn Bhd', v_ali);
  perform pg_temp.sign_in_as(v_ali);

  perform public.register_device(v_tok, 'ios', null, null, null, 'fcm');
  perform pg_temp.check_eq('registered through Firebase',
    (select transport from public.device_tokens where token = v_tok), 'fcm');

  perform public.register_device(v_tok, 'ios', null, null, null, 'apns');
  perform pg_temp.check_eq('and re-registering moves it to Apple',
    (select transport from public.device_tokens where token = v_tok), 'apns');
  perform pg_temp.check_eq('without leaving a second row behind',
    (select count(*) from public.device_tokens where token = v_tok), 1);
end $$;

-- ---------------------------------------------------------------------
-- 0658: the OTHER token the same iPhone has
-- ---------------------------------------------------------------------
--
-- One handset, two Apple tokens, and every way of confusing them fails
-- silently on the handset rather than loudly here -- so it is refused
-- here. The pairing is the point: `device_id` is what lets the sender
-- ring a phone through CallKit without also sending it a banner about
-- the same call.
do $$
declare
  v_ali   uuid := pg_temp.another_user('ali-voip@push.test');
  v_org   uuid;
  v_alert text := repeat('a1b2c3d4', 8);
  v_voip  text := repeat('f0e1d2c3', 8);
  v_fcm   text := 'fMEP0vJq:APA91bF-voip-shaped';
  v_said  text;
  v_phone text := 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';
begin
  v_org := pg_temp.push_org('PushKit Sdn Bhd', v_ali);
  perform pg_temp.sign_in_as(v_ali);

  perform public.register_device(v_alert, 'ios', 'An iPhone', null, null,
                                 'apns', v_phone);
  perform public.register_device(v_voip, 'ios', 'An iPhone', null, null,
                                 'apns_voip', v_phone);

  perform pg_temp.check_eq('an iPhone can hold a PushKit token',
    (select transport from public.device_tokens where token = v_voip),
    'apns_voip');
  perform pg_temp.check_eq('beside its alert token',
    (select transport from public.device_tokens where token = v_alert),
    'apns');
  perform pg_temp.check_eq('as two rows, because they are two tokens',
    (select count(*) from public.device_tokens
      where token in (v_alert, v_voip)), 2);
  -- The whole reason `device_id` exists. Without this the sender cannot
  -- tell one iPhone holding two tokens from two iPhones holding one
  -- each, and the difference decides whether a ringing phone also
  -- buzzes about the same call.
  perform pg_temp.check_eq('paired, so the sender knows it is one phone',
    (select count(distinct device_id) from public.device_tokens
      where token in (v_alert, v_voip)), 1);

  -- `0657` wrote `transport <> 'apns'` on the shape check. Written that
  -- way a Firebase token registered as `apns_voip` would have gone
  -- straight in, and a PushKit push to it is refused by Apple forever
  -- with nothing anywhere saying so.
  begin
    perform public.register_device(v_fcm, 'ios', null, null, null,
                                   'apns_voip', v_phone);
    perform pg_temp.check_true(
      'a Firebase token cannot be registered as a PushKit one', false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true(
      'a Firebase token cannot be registered as a PushKit one',
      v_said like '%not an APNs device token%');
  end;

  -- PushKit is Apple's alone, and somebody registering an Android call
  -- token has a wrong belief rather than a typo.
  begin
    perform public.register_device(v_voip || 'aa', 'android', null, null,
                                   null, 'apns_voip', v_phone);
    perform pg_temp.check_true('only an iPhone has a VoIP token', false);
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('only an iPhone has a VoIP token',
      v_said like '%Only an iPhone has a VoIP token%');
  end;

  -- An older build re-presents a token it has always had and says
  -- nothing about the handset. Forgetting the pairing already recorded
  -- would unpair a phone that is still perfectly paired -- and the
  -- symptom would be one duplicate banner, months later, on a call.
  perform public.register_device(v_alert, 'ios', null, null, null, 'apns');
  perform pg_temp.check_eq('a caller that says nothing keeps the pairing',
    (select device_id from public.device_tokens where token = v_alert),
    v_phone);

  -- And the control: a caller that DOES name a handset moves it, which
  -- is what happens when a phone is restored from a backup onto another
  -- and identifierForVendor changes.
  perform public.register_device(v_alert, 'ios', null, null, null, 'apns',
    '11111111-2222-3333-4444-555555555555');
  perform pg_temp.check_eq('but a caller that names one is believed',
    (select device_id from public.device_tokens where token = v_alert),
    '11111111-2222-3333-4444-555555555555');

  -- The sender pairs on this column, so it has to survive `push_targets`
  -- being restated -- which is exactly where it would be lost.
  perform pg_temp.check_true(
    'and the sender is told which tokens share a handset',
    exists (
      select 1 from pg_proc p
      cross join lateral unnest(p.proargnames, p.proargmodes) as a(name, mode)
      where p.oid = 'public.push_targets(uuid, uuid)'::regprocedure
        and a.mode = 't' and a.name = 'device_id'));
end $$;

rollback;

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
    perform public.register_device('token-ali-laptop', 'web', 'Chrome');
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

rollback;

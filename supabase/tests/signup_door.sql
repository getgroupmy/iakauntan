-- =====================================================================
-- iAkauntan :: the door that was never shut
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/signup_door.sql
--
-- `0018` seeded `signup_enabled`, described in its own row as "Allow
-- new self-service registrations", and nothing read it for five hundred
-- migrations. An operator could switch it off, watch it save, and
-- strangers would go on getting accounts.
--
-- Every assertion here would pass against that version except one, and
-- that one is the file: with the setting off, a registration is
-- refused.
--
-- Registration happens on `auth.users`, which the suite's stub owns, so
-- these insert there directly -- which is also the honest test. The
-- form is not what is being asserted; the trigger is, because the
-- sign-up endpoint is public and the same whether a button was drawn
-- or not.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Open, which is what it says now and what a missing row means
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the door starts open', app.signups_open());

  -- A lookup that found nothing must not be indistinguishable from a
  -- decision. Deleting the row is how a fresh or half-migrated
  -- deployment looks, and it must not be the thing that stops a
  -- business registering.
  delete from public.platform_settings where key = 'signup_enabled';
  perform pg_temp.check_true('and a missing setting reads as open',
    app.signups_open());

  insert into public.platform_settings (key, value, description)
  values ('signup_enabled', '{"enabled": true, "message": ""}'::jsonb,
          'Allow new self-service registrations');
end $$;

-- ---------------------------------------------------------------------
-- And somebody can register through it
-- ---------------------------------------------------------------------
do $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_id, 'walkin@iakauntan.test',
          jsonb_build_object('full_name', 'Nurul', 'use_kind', 'business'));

  perform pg_temp.check_eq('a stranger registers while it is open',
    (select count(*)::int from public.profiles where id = v_id), 1);
  perform pg_temp.check_eq('and the profile carries what they typed',
    (select full_name from public.profiles where id = v_id), 'Nurul');
end $$;

-- ---------------------------------------------------------------------
-- Shut
-- ---------------------------------------------------------------------
do $$
begin
  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'signup_enabled';

  perform pg_temp.check_true('the switch is read at all', not app.signups_open());

  -- THE ASSERTION THIS FILE EXISTS FOR. Against every version before
  -- `0563` this insert succeeds and the setting is decoration.
  perform pg_temp.check_refused(
    'a stranger cannot register while it is shut',
    format('insert into auth.users (id, email) values (%L, %L)',
           gen_random_uuid(), 'stranger@iakauntan.test'),
    '%not taking new registrations%', '42501');

  perform pg_temp.check_eq('and no profile is left behind',
    (select count(*)::int from public.profiles
      where email = 'stranger@iakauntan.test'), 0);
end $$;

-- ---------------------------------------------------------------------
-- In the operator's own words, where they wrote any
-- ---------------------------------------------------------------------
do $$
begin
  update public.platform_settings
     set value = jsonb_build_object(
           'enabled', false,
           'message', 'We open again on the first of April.')
   where key = 'signup_enabled';

  -- "We are closed" with no reason reads as a fault, and somebody who
  -- thinks the site is broken comes back and tries again.
  perform pg_temp.check_refused(
    'the refusal says what the operator wrote',
    format('insert into auth.users (id, email) values (%L, %L)',
           gen_random_uuid(), 'stranger2@iakauntan.test'),
    '%first of April%', '42501');

  -- And blank falls back rather than refusing somebody with an empty
  -- sentence.
  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '   ')
   where key = 'signup_enabled';
  perform pg_temp.check_true('and blank is not a message',
    app.signup_closed_message() like '%not taking new registrations%');
end $$;

-- ---------------------------------------------------------------------
-- But an invitation still opens it
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org   uuid;
  v_id    uuid := gen_random_uuid();
begin
  -- The company is made while the door is shut, by somebody who is
  -- already here -- which is the ordinary case, and a reminder that
  -- the setting is about registration and not about the product.
  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', '')
   where key = 'signup_enabled';

  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Jemputan Sdn Bhd', array[]::text[]);

  insert into public.org_members
    (org_id, user_id, role, status, invited_email, invite_expires_at)
  values (v_org, null, 'accounts_clerk', 'invited',
          'invited@iakauntan.test', now() + interval '7 days');

  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'signup_enabled';

  -- Somebody let in by somebody entitled to let them in. "We are not
  -- taking new registrations" was never about them.
  insert into auth.users (id, email)
  values (v_id, 'invited@iakauntan.test');

  perform pg_temp.check_eq('an invitation opens a shut door',
    (select count(*)::int from public.profiles where id = v_id), 1);
  perform pg_temp.check_eq('and is claimed on the way through',
    (select status::text from public.org_members
      where org_id = v_org and user_id = v_id), 'active');
end $$;

-- ---------------------------------------------------------------------
-- An expired one does not
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org   uuid;
begin
  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', '')
   where key = 'signup_enabled';

  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Lewat Sdn Bhd', array[]::text[]);

  insert into public.org_members
    (org_id, user_id, role, status, invited_email, invite_expires_at)
  values (v_org, null, 'accounts_clerk', 'invited',
          'toolate@iakauntan.test', now() - interval '1 day');

  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'signup_enabled';

  -- The same definition of in-date the claim one statement below uses.
  -- A way in that outlives the decision to offer it is a way in nobody
  -- decided on.
  perform pg_temp.check_refused(
    'an expired invitation does not open it',
    format('insert into auth.users (id, email) values (%L, %L)',
           gen_random_uuid(), 'toolate@iakauntan.test'),
    '%not taking new registrations%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- And the form is told before anybody fills it in
-- ---------------------------------------------------------------------
do $$
declare v_ref jsonb;
begin
  update public.platform_settings
     set value = jsonb_build_object('enabled', false,
                                    'message', 'Back in April.')
   where key = 'signup_enabled';

  set local role anon;
  v_ref := public.signup_reference();
  reset role;

  -- Not a secret: anybody learns it by pressing the button once. What
  -- it saves is eight fields filled in before being refused.
  perform pg_temp.check_true('the form is told the door is shut',
    (v_ref ->> 'signups_open')::boolean is false);
  perform pg_temp.check_eq('and what to say', v_ref ->> 'signups_closed_message',
    'Back in April.');

  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', 'Back in April.')
   where key = 'signup_enabled';

  set local role anon;
  v_ref := public.signup_reference();
  reset role;

  perform pg_temp.check_true('and told when it is open',
    (v_ref ->> 'signups_open')::boolean);
  -- Null while open, so a form cannot draw the closed notice from a
  -- field that is always populated.
  perform pg_temp.check_true('with no notice to draw',
    v_ref ->> 'signups_closed_message' is null);

  -- And the three lists `0554` and `0555` put there are still there.
  perform pg_temp.check_true('and the lists the form needs are intact',
    jsonb_array_length(v_ref -> 'salutations') > 0
    and jsonb_array_length(v_ref -> 'dial_codes') > 0
    and jsonb_array_length(v_ref -> 'states') > 0);
end $$;

rollback;

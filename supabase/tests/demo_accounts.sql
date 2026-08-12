-- =====================================================================
-- iAkauntan :: demo account tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_accounts.sql
--
-- The sign-in page hands anybody a session on the demo logins, so the
-- first visitor must not be able to change the password and lock out
-- everyone after them, or move the email and take the account.
--
-- Hiding the button in Settings is not the rule — the change is an
-- ordinary POST to GoTrue that never passes through this app, and can be
-- made with curl by anyone holding a demo session. The rule is the
-- trigger these tests exercise. Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_user uuid;
  v_before text;
begin
  insert into auth.users (
    id, email, encrypted_password, raw_app_meta_data,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (gen_random_uuid(), 'fixture-demo@iakauntan.test',
          crypt('Demo!Akaun2026', gen_salt('bf')),
          jsonb_build_object('demo', true),
          '', '', '', '', '', '', '', '')
  returning id into v_user;

  select encrypted_password into v_before from auth.users where id = v_user;

  begin
    update auth.users set encrypted_password = crypt('taken', gen_salt('bf'))
     where id = v_user;
    raise exception 'FAIL: a demo password was changed';
  exception when sqlstate '42501' then
    raise notice 'ok   a demo password cannot be changed';
  end;

  begin
    update auth.users set email = 'taken@example.com' where id = v_user;
    raise exception 'FAIL: a demo email was changed';
  exception when sqlstate '42501' then
    raise notice 'ok   a demo email cannot be changed';
  end;

  -- GoTrue stages a new address here before it is confirmed, so this is
  -- where an email change has to be stopped: refusing at confirmation
  -- would mean sending a link that cannot work.
  begin
    update auth.users set email_change = 'taken@example.com' where id = v_user;
    raise exception 'FAIL: a demo email change was started';
  exception when sqlstate '42501' then
    raise notice 'ok   a demo email change cannot be started';
  end;

  perform pg_temp.check_true('the password is untouched',
    (select encrypted_password from auth.users where id = v_user) = v_before);

  -- The lock must not break the thing it is protecting. GoTrue writes
  -- this on every sign-in.
  update auth.users set last_sign_in_at = now() where id = v_user;
  raise notice 'ok   signing in still updates the account';

  -- And a reset link can still be asked for: the mail goes nowhere
  -- anybody reads, and the change it leads to is refused above.
  update auth.users set recovery_token = 'fixture', recovery_sent_at = now()
   where id = v_user;
  raise notice 'ok   a reset can still be requested';

  -- Clearing the flag is how the password gets rotated later. It needs
  -- the service role, so it is not a door a visitor can open.
  update auth.users
     set raw_app_meta_data = raw_app_meta_data - 'demo' where id = v_user;
  update auth.users
     set encrypted_password = crypt('rotated', gen_salt('bf')) where id = v_user;
  raise notice 'ok   clearing the flag restores the ability to change it';
end $$;

-- An ordinary account is untouched by the trigger.
do $$
declare v_user uuid;
begin
  insert into auth.users (
    id, email, encrypted_password,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (gen_random_uuid(), 'fixture-real@iakauntan.test',
          crypt('whatever', gen_salt('bf')),
          '', '', '', '', '', '', '', '')
  returning id into v_user;

  update auth.users set encrypted_password = crypt('changed', gen_salt('bf'))
   where id = v_user;
  update auth.users set email = 'moved@iakauntan.test' where id = v_user;
  raise notice 'ok   a normal account can still change password and email';
end $$;

rollback;

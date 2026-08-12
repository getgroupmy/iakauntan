-- Demo accounts cannot have their password or email changed.
--
-- The sign-in page offers one-tap access to five seeded logins. Without
-- this, the first visitor to open Settings could change the owner
-- account's password and lock out every visitor after them — or change
-- its email and take the account outright. The demo is public, so it has
-- to be tamper-evident by construction rather than by asking nicely.
--
-- This lives in the database because hiding the button is not enforcing
-- anything: the password change is an ordinary POST to GoTrue's
-- /auth/v1/user, and anyone holding a demo session and the publishable
-- key can make it with curl.
--
-- What is deliberately still allowed:
--
--   * signing in, which writes last_sign_in_at
--   * requesting a reset email, which writes recovery_token — the mail
--     goes to a mailbox nobody reads, and blocking the request would
--     only turn "Forgot password?" into an error for no gain, since the
--     change it leads to is refused here anyway
--   * everything else GoTrue does to keep a session alive
--
-- Only the columns that would take the account away are frozen.
--
-- To rotate the demo password later, clear the flag first — writing
-- raw_app_meta_data needs the service role, so it is not a door a
-- visitor can open:
--
--   update auth.users
--      set raw_app_meta_data = raw_app_meta_data - 'demo'
--    where email = 'demo@iakauntan.my';

create or replace function app.demo_credentials_locked()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp as $$
begin
  if coalesce(old.raw_app_meta_data ->> 'demo', 'false') <> 'true' then
    return new;
  end if;

  if new.encrypted_password is distinct from old.encrypted_password then
    raise exception
      'The demo accounts share one password, so it cannot be changed.'
      using errcode = '42501';
  end if;

  if new.email is distinct from old.email
     or new.phone is distinct from old.phone then
    raise exception 'A demo account cannot change its email or phone.'
      using errcode = '42501';
  end if;

  -- Starting an email change is refused at the start rather than at the
  -- confirmation, so nobody is sent a link that cannot work.
  if coalesce(new.email_change, '') <> ''
     and new.email_change is distinct from old.email_change then
    raise exception 'A demo account cannot change its email or phone.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists demo_credentials_locked on auth.users;
create trigger demo_credentials_locked
  before update on auth.users
  for each row execute function app.demo_credentials_locked();

-- Mark the seeded demo logins. raw_app_meta_data is writable only by the
-- service role, which is why the flag is kept there rather than in
-- raw_user_meta_data, where the account itself could clear it.
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                           || jsonb_build_object('demo', true)
 where email in (
   'demo@iakauntan.my',
   'clerk@iakauntan.my',
   'auditor@iakauntan.my',
   'secretary@iakauntan.my',
   'superadmin@iakauntan.my'
 );

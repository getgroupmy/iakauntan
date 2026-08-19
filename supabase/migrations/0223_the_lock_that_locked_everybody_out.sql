-- The demo logins could not sign in, and the guard protecting them was
-- the reason.
--
-- ## What a visitor saw
--
-- Every demo button on the sign-in page returned "The demo accounts are
-- not available on this deployment." That message is the client's
-- reading of a 400 from GoTrue, and it was wrong in the most misleading
-- possible way: the accounts were there, confirmed, unbanned, and
-- holding exactly the password the button sends.
--
-- ## What was actually happening
--
-- `app.demo_user` hashes with `extensions.gen_salt('bf')`. pgcrypto's
-- default bcrypt cost is **6**. GoTrue on this project is configured
-- for **10** -- which `superadmin@`, created through Supabase's own UI
-- rather than by this function, demonstrates: its hash is cost 10 and
-- it has always signed in.
--
-- GoTrue, on a *successful* password check, compares the stored cost to
-- its configured cost and, when the stored one is weaker, rehashes the
-- same password and writes it back. That write is an update to
-- `auth.users.encrypted_password`, which is precisely what `0076`'s
-- `demo_credentials_locked` refuses:
--
--     42501  The demo accounts share one password, so it cannot be changed.
--
-- So the sequence was: password verified, `last_sign_in_at` written,
-- rehash attempted, rehash refused, request failed. The evidence sat in
-- the table the whole time -- `demo@iakauntan.com` had a
-- `last_sign_in_at` from an attempt that no human ever completed.
--
-- ## Why the fix is the cost and not the guard
--
-- The obvious alternative is to teach the trigger to permit a rehash.
-- It cannot be done honestly: a rehash and a password change are the
-- same UPDATE, and telling them apart needs the plaintext, which a
-- trigger does not have. Anything that let one through would let the
-- other through, and the guard exists because a visitor who can change
-- the shared password can lock out every visitor after them.
--
-- Matching the cost removes the reason for the write instead. GoTrue
-- rehashes only what is weaker than its configuration; a hash already
-- at the configured cost is left alone, the trigger is never reached,
-- and the guard keeps doing the job it was built for.
--
-- The residual risk is that Supabase raises its default cost later and
-- this breaks again in the same silent way. `demo_credentials.sql`
-- asserts the cost so that lands as a red test rather than as a demo
-- button nobody can press.

-- ---------------------------------------------------------------------
-- Seed at the cost GoTrue expects
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched: the only change is the second
-- argument to gen_salt, and it is the whole point of the migration.
create or replace function app.demo_user(
  p_email text,
  p_full_name text,
  p_password text default 'Demo!Akaun2026')
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated',
    -- Schema-qualified: pgcrypto lives in `extensions` on a Supabase
    -- project, and this function's search_path is deliberately narrow
    -- (see supabase/tests/search_path.sql). Widening it to reach
    -- crypt() would trade a real safety property for a shorter line.
    'authenticated', p_email,
    -- Cost 10 stated rather than defaulted. `gen_salt('bf')` is cost 6,
    -- which GoTrue silently rehashes on first sign-in -- straight into
    -- the credentials lock, which refuses it. See this file's header.
    extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
    now(),
    -- The `demo` flag is what `demo_credentials_locked` keys off, so a
    -- visitor cannot change the password or move the address and lock
    -- everyone else out. It is also what `app.demo_teardown()` uses to
    -- decide what it may remove.
    jsonb_build_object('provider', 'email', 'providers',
                       jsonb_build_array('email'), 'demo', true),
    jsonb_build_object('full_name', p_full_name),
    now(), now(), '', '', '', '', '', '', '', '');
  return v_id;
end $$;

comment on function app.demo_user(text, text, text) is
  'Creates a confirmed auth user flagged demo, so its credentials are '
  'frozen by demo_credentials_locked and app.demo_teardown() may remove '
  'it. Hashed at bcrypt cost 10 to match GoTrue, because a weaker hash '
  'is rehashed on sign-in and that rehash is refused by the very lock '
  'that protects the account.';

-- ---------------------------------------------------------------------
-- Repair the accounts already out there
-- ---------------------------------------------------------------------
--
-- A rebuild would fix them too, but a rebuild deletes and recreates
-- every demo tenant, and a deployment should not have to throw away its
-- demo data to fix a hash. So the existing rows are re-encoded in
-- place, at the same password.
--
-- The flag is cleared and restored around the update because the
-- trigger keys off `old.raw_app_meta_data`: with the flag down, the
-- write is an ordinary one. This is the same procedure the README
-- documents for rotating the demo password, and it needs no ownership
-- of `auth.users` -- which a migration on a hosted project does not
-- reliably have.
do $$
declare
  v_fixed integer := 0;
begin
  -- Nothing to do where the cost is already right, which makes this
  -- safe to re-run and keeps a re-applied migration from touching
  -- accounts it has already repaired.
  if not exists (
    select 1 from auth.users u
     where coalesce(u.raw_app_meta_data ->> 'demo', 'false') = 'true'
       and split_part(u.encrypted_password, '$', 3)::integer < 10)
  then
    raise notice 'demo hashes already at cost 10 or above; nothing to repair';
    return;
  end if;

  update auth.users u
     set raw_app_meta_data = u.raw_app_meta_data - 'demo'
   where coalesce(u.raw_app_meta_data ->> 'demo', 'false') = 'true';

  update auth.users u
     set encrypted_password =
           extensions.crypt('Demo!Akaun2026', extensions.gen_salt('bf', 10)),
         updated_at = now()
   where u.email in (
           'demo@iakauntan.com', 'clerk@iakauntan.com',
           'auditor@iakauntan.com', 'secretary@iakauntan.com',
           'property@iakauntan.com', 'warung@iakauntan.com',
           'salon@iakauntan.com', 'stall@iakauntan.com')
     and split_part(u.encrypted_password, '$', 3)::integer < 10;
  get diagnostics v_fixed = row_count;

  update auth.users u
     set raw_app_meta_data =
           coalesce(u.raw_app_meta_data, '{}'::jsonb)
           || jsonb_build_object('demo', true)
   where u.email in (
           'demo@iakauntan.com', 'clerk@iakauntan.com',
           'auditor@iakauntan.com', 'secretary@iakauntan.com',
           'property@iakauntan.com', 'warung@iakauntan.com',
           'salon@iakauntan.com', 'stall@iakauntan.com');

  raise notice 're-encoded % demo password hash(es) at cost 10', v_fixed;
end $$;

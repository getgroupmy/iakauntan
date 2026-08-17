-- The demo tenants, rebuilt from a function instead of by hand.
--
-- `0182` gave the demo data one guarded way *out*. This is the way back
-- in. Between them, "rebuild the demo" stops being an afternoon of typed
-- SQL that nobody can review and becomes one call that CI has already
-- run on a throwaway stack.
--
-- ## Why the seed is functions and not inserts
--
-- A migration full of `insert` statements runs exactly once, on every
-- stack, forever — including the hosted project, which would get demo
-- companies applied to it automatically the moment the migration
-- landed. That is the wrong shape for data that has to be *re-runnable*
-- and that must never appear on a deployment carrying real books
-- without somebody asking for it.
--
-- So the migration only *defines* the seed. Nothing here creates a
-- company. `app.demo_rebuild()` does, and it is called by hand — once,
-- deliberately, against the project that wants it.
--
-- ## The four logins are fixed
--
-- `demo@`, `clerk@`, `auditor@` and `secretary@` are compiled into the
-- Flutter bundle (`demo_accounts.dart`), so the seed has to produce
-- exactly those addresses. What it does *not* have to preserve is the
-- roles they were given, and two of them were wrong:
--
--     clerk@    was `purchaser`, advertised as "Accounts clerk"
--     auditor@  was `admin`,     advertised as "Reads the ledger,
--                                writes nothing"
--
-- The second is not cosmetic. `auditor@` is offered on the sign-in page
-- as the read-only account and was in fact an administrator of the demo
-- company. Fixed here to `accounts_clerk` and `auditor`, which are the
-- roles the picker has always claimed.
--
-- ## SST is set through the front door
--
-- Sinar is SST registered, and the seed does *not* pass
-- `p_is_sst_registered => true` to `create_organization`. That would
-- produce a company with the flag set, no effective date and a
-- zero-rated default — precisely the broken state `0181` was written to
-- diagnose and prevent, reproduced deliberately in our own demo data.
--
-- It creates the company unregistered and then calls
-- `set_sst_registration()`, which insists on the date, the number and a
-- non-zero-rated code. The demo therefore demonstrates the correct
-- state, and the seed exercises the guard every time it runs.
--
-- ## Impersonation, and why it is the honest way round
--
-- `create_organization()` reads `auth.uid()`, so the seed sets
-- `request.jwt.claims` to the demo owner before calling it. That is not
-- a workaround — it is what makes the demo company identical to one
-- created by a person signing up, chart of accounts and tax codes and
-- fiscal calendar and all. A seed that inserted an `organizations` row
-- directly would produce the half-built tenant this project already has
-- one of.

-- ---------------------------------------------------------------------
-- A demo login
-- ---------------------------------------------------------------------
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
    extensions.crypt(p_password, extensions.gen_salt('bf')),
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
  'it.';

-- ---------------------------------------------------------------------
-- Become somebody, run something, stop being them
-- ---------------------------------------------------------------------
--
-- Transaction-local, so it cannot leak onto the next statement of a
-- pooled connection.
create or replace function app.demo_act_as(p_user uuid)
returns void
language sql
security definer
set search_path = public, app, pg_temp
as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated')::text,
                    true);
$$;

-- ---------------------------------------------------------------------
-- A demo company, built the way a real one is
-- ---------------------------------------------------------------------
create or replace function app.demo_company(
  p_owner            uuid,
  p_name             text,
  p_entity_type      app.entity_type,
  p_registration_no  text,
  p_tin              text,
  p_msic_code        text,
  p_activity         text,
  p_state_code       text,
  p_city             text,
  p_postcode         text,
  p_address          text,
  p_phone            text,
  p_email            text,
  p_fye_month        smallint default 12)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  perform app.demo_act_as(p_owner);

  -- Deliberately not registered for SST here; see the header. Where a
  -- demo company should be registered, the caller uses
  -- set_sst_registration() afterwards.
  v_org := public.create_organization(
    p_name, null, p_entity_type, p_registration_no, p_tin, p_msic_code,
    p_activity, p_state_code, p_city, p_postcode, p_address,
    p_phone, p_email, false, null, p_fye_month);

  update public.organizations set is_demo = true where id = v_org;
  return v_org;
end $$;

comment on function app.demo_company(uuid, text, app.entity_type, text, text,
                                     text, text, text, text, text, text,
                                     text, text, smallint) is
  'Creates a demo company through create_organization(), so it gets the '
  'same chart of accounts, tax codes, payment terms, warehouse, price '
  'levels, pipeline and fiscal calendar a real signup does.';

-- ---------------------------------------------------------------------
-- Entitlements
-- ---------------------------------------------------------------------
create or replace function app.demo_modules(p_org uuid, p_codes text[])
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_n integer;
begin
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  select p_org, c, true, now()
    from unnest(p_codes) c
   where exists (select 1 from public.platform_modules m
                  where m.code = c and m.is_active)
  on conflict (org_id, module_code)
    do update set is_enabled = true, enabled_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------
create or replace function app.demo_member(
  p_org uuid, p_user uuid, p_role app.member_role)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (p_org, p_user, p_role, 'active', now())
  on conflict (org_id, user_id)
    do update set role = excluded.role, status = 'active';
end $$;

revoke all on function app.demo_user(text, text, text)         from public, anon, authenticated;
revoke all on function app.demo_act_as(uuid)                   from public, anon, authenticated;
revoke all on function app.demo_modules(uuid, text[])          from public, anon, authenticated;
revoke all on function app.demo_member(uuid, uuid, app.member_role)
  from public, anon, authenticated;
revoke all on function app.demo_company(uuid, text, app.entity_type, text, text,
                                        text, text, text, text, text, text,
                                        text, text, smallint)
  from public, anon, authenticated;

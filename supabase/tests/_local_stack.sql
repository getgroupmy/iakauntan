-- ---------------------------------------------------------------------
-- The parts of Supabase that `run_locally.sh` has to stand up itself
--
-- Read this before trusting a local run. Everything here is an
-- approximation of something a Supabase service supplies, written to be
-- close enough that the assertions in this directory mean what they
-- mean in CI — and no closer. `supabase start` in CI runs the real
-- thing; when the two disagree, CI is right.
--
-- The one that matters most is `auth.uid()`. `pg_temp.sign_in_as` sets
-- `request.jwt.claims`, and every RLS policy in this schema reaches the
-- current user through that function, so a stub that read the wrong
-- setting would make every policy see nobody — and a test suite where
-- nobody is signed in passes a great many things it should not.
-- ---------------------------------------------------------------------

-- The roles PostgREST connects as. `do` blocks because this file is run
-- against a cluster that may already have them: the schemas are dropped
-- between runs, roles are not.
do $b$ begin create role anon nologin noinherit;
  exception when duplicate_object then null; end $b$;
do $b$ begin create role authenticated nologin noinherit;
  exception when duplicate_object then null; end $b$;
do $b$ begin create role service_role nologin noinherit bypassrls;
  exception when duplicate_object then null; end $b$;
do $b$ begin create role authenticator noinherit login;
  exception when duplicate_object then null; end $b$;
do $b$ begin create role supabase_auth_admin login noinherit createrole;
  exception when duplicate_object then null; end $b$;
do $b$ begin create role supabase_storage_admin login noinherit createrole;
  exception when duplicate_object then null; end $b$;
-- Not used to create anything here, and present for one reason: a
-- hosted project carries a second set of default privileges under this
-- role, and a check that reads every default-ACL entry rather than the
-- one belonging to the role that creates the tables will pass locally
-- and fail against production. That is exactly what happened to 0498.
do $b$ begin create role supabase_admin login noinherit createrole superuser;
  exception when duplicate_object then null; end $b$;
grant anon, authenticated, service_role to authenticator;
grant anon, authenticated, service_role to postgres;

create schema if not exists extensions;

-- In `extensions`, because that is where Supabase puts it, and on the
-- search path below, because migrations call `gen_random_bytes` and
-- `gen_salt` unqualified.
do $b$ begin create extension if not exists pgcrypto with schema extensions;
  exception when others then null; end $b$;
alter database postgres set search_path = "$user", public, extensions;

create schema if not exists auth authorization supabase_auth_admin;
create schema if not exists storage authorization supabase_storage_admin;
create schema if not exists graphql_public;
grant usage on schema auth, storage to postgres, anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Supabase's own default privileges, which are the reason a table
-- created in `public` carries an `anon` grant from the moment it
-- exists. Reproduced here because until they were, a migration that
-- forgot to revoke passed every local run and was refused by its own
-- self-check against the hosted project instead -- which is exactly the
-- wrong way round, and is what happened to 0496. 0498 revokes the
-- default and sweeps what was already there, so these lines and that
-- migration are a pair: take either away and the assertion in
-- `statutory.sql` about what a stranger can read stops meaning
-- anything.
-- Copied from what a hosted project actually has, rather than from
-- what "grant all" would suggest: `anon` gets SELECT and nothing else,
-- `authenticated` gets the four data commands, and `service_role`
-- gets everything. Overstating anon's default here would make the
-- sweep in 0498 look like it was closing more than it was.
alter default privileges for role postgres in schema public
  grant select on tables to anon;
-- NOT `authenticated`, and 0536 is why the line that used to be here is
-- gone. A hosted project gives `authenticated` NO default on a new
-- table: the grant is written out in the migration beside the policy,
-- every time, and `table_grants.sql` fails the build when it is not.
-- Granting it here by default made this machine more generous than CI,
-- so three tables with read policies and no grants passed every local
-- run and were caught by CI instead -- which is the wrong way round,
-- and is the same trap the note above records 0496 falling into.
alter default privileges for role postgres in schema public
  grant all on tables to service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
-- ---------------------------------------------------------------------
-- And FUNCTIONS, which took three migrations and two CI runs to settle
--
-- Supabase ships
--
--     alter default privileges in schema public
--       grant all on functions to anon, authenticated, service_role
--
-- so a new function in `public` arrives executable by all three, and
-- `0165`'s event trigger then strips PUBLIC and `anon` -- leaving
-- `authenticated` and `service_role`. In schema `app` there is no such
-- default, so a new function there arrives callable by nobody. Both are
-- reproduced below.
--
-- ## Why this took so long, and it is worth knowing
--
-- Because CI has TWO databases and nobody said which was being read.
-- `supabase start` brings up the CLI's local stack, and that is where
-- `function_grants.sql` and every other file in this directory runs.
-- The migrations are pushed to the LINKED HOSTED PROJECT, in a
-- different job. The two do not have the same default privileges.
--
-- Every piece of evidence in the argument is correct about the database
-- it came from:
--
--   * `0165` said it verified the default against the hosted project,
--     and it did: after revoking PUBLIC from sixteen functions, the
--     nine in `public` were still reachable by `anon` and the seven in
--     `app` were not -- which is precisely a default that covers
--     `public` and not `app`.
--   * `0617` believed `0165`, taught this file the same default, and
--     **CI refused it** -- against the CLI stack, where the default ACL
--     really is `{postgres=X/postgres}`.
--   * `0618` read that refusal as proof that `0165` had misread itself,
--     and wrote the strict rule down twice. It was reading the CLI
--     stack.
--   * `0621`'s apply-time check failed four times against the hosted
--     project because `set_sst_registration` is executable there by
--     `service_role`, which no migration in this repository granted.
--   * CI run 1941: `0657` DROPPED `public.push_targets`, created it
--     again, revoked it `from public` alone, and its own self-check
--     found `authenticated` could still execute it. A dropped function
--     takes its grants with it, so that grant was written by nothing
--     but a default privilege.
--
-- Three hosted observations against one local one. `0618`'s conclusion
-- is the one that was wrong, and the two files that encode it --
-- `function_grants.sql` and `trigger_reachable_grants.sql` -- are
-- corrected in the same commit as these lines.
--
-- ## What it does NOT mean
--
-- It does not mean anything is open that was thought closed. Counted
-- both ways on this machine, with the default and without it, **738 of
-- the 760 functions in `public` are executable by `authenticated`
-- either way**: the default adds nothing, because every function here
-- already carries an explicit grant or an explicit revoke. The twenty-two
-- that are closed are closed by a revoke, and they stay closed.
--
-- What it changes is the GATE. Until now a migration that forgot to
-- revoke could not fail on this machine, because there was no grant to
-- fail against -- so `0657` passed 333 local files and was refused by
-- CI twenty minutes later. Now it fails here first, which is the
-- direction every other line in this section exists to get right.
--
-- `0141` and `0143` write `from public, anon, authenticated` in full,
-- and every migration should: revoking from the PUBLIC pseudo-role does
-- not touch a grant held directly by a role.
-- ---------------------------------------------------------------------
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;
-- And deliberately NOT in schema `app`, which is the half of `0165`'s
-- observation that pins the shape: the seven functions it revoked there
-- were not reachable by `anon` afterwards, and the nine in `public`
-- were.
--
-- `for role postgres` is load-bearing, and CI run 1947 is the evidence.
-- A default ACL governs only what ONE role creates, and a check that
-- reads `pg_default_acl` without filtering on `defaclrole` reads
-- somebody else's: `supabase start` has a row for functions in `public`
-- that mentions `authenticated`, under a role that is not the one
-- applying the migrations, and a new function there is still callable
-- by nobody. The note about `supabase_admin` above says the same thing
-- about TABLES and `0498` is the migration that learned it. So a test
-- that wants to know what a new function arrives with must CREATE one
-- and look, which is what `function_grants.sql` now does.

-- The second entry, which governs only what `supabase_admin` creates
-- and therefore governs nothing in this schema. Here so that a check
-- which forgets to say whose default it is asking about fails on this
-- machine rather than in CI.
alter default privileges for role supabase_admin in schema public
  grant all on tables to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- auth
--
-- The columns are the ones `pg_temp.test_user` and the demo fixtures
-- actually insert. The real table has more; a fixture that starts using
-- one will fail here and pass in CI, which is the direction to prefer.
-- ---------------------------------------------------------------------
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  encrypted_password text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  raw_app_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  confirmed_at timestamptz,
  last_sign_in_at timestamptz,
  invited_at timestamptz,
  confirmation_sent_at timestamptz,
  recovery_sent_at timestamptz,
  email_change_sent_at timestamptz,
  reauthentication_sent_at timestamptz,
  deleted_at timestamptz,
  banned_until timestamptz,
  confirmation_token text default '',
  recovery_token text default '',
  email_change_token_new text default '',
  email_change_token_current text default '',
  phone_change_token text default '',
  reauthentication_token text default '',
  email_change text default '',
  phone_change text default '',
  phone text,
  aud text default 'authenticated',
  role text default 'authenticated',
  instance_id uuid,
  is_super_admin boolean,
  is_sso_user boolean default false,
  is_anonymous boolean default false
);

-- GoTrue's own unique index on the address, by the name the real one
-- has so a violation here reads the same as a violation there.
--
-- It was missing, and that is not a detail: a seed that handed two
-- practices the same demo login passed every local run and failed in
-- CI with `duplicate key value violates unique constraint
-- "users_email_partial_key"`. This harness's whole bargain is that red
-- here means red there and green here means *probably* green there;
-- the second half only holds for the constraints it actually carries.
--
-- Partial on `is_sso_user`, as GoTrue has it: an SSO user's address
-- belongs to the identity provider and may repeat.
create unique index if not exists users_email_partial_key
  on auth.users (email) where is_sso_user = false;

create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  provider text, provider_id text,
  identity_data jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_sign_in_at timestamptz
);

create table if not exists auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  not_after timestamptz, refreshed_at timestamp,
  user_agent text, ip inet, tag text
);

create table if not exists auth.refresh_tokens (
  id bigserial primary key, token text, user_id text, revoked boolean,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  session_id uuid references auth.sessions (id) on delete cascade
);

create table if not exists auth.mfa_factors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  status text, factor_type text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists auth.audit_log_entries (
  id uuid primary key default gen_random_uuid(), instance_id uuid,
  payload json, created_at timestamptz default now(),
  ip_address varchar(64) default ''
);

-- Both spellings, in the order the real ones try them: PostgREST sets
-- `request.jwt.claim.sub` in older versions and `request.jwt.claims`
-- as a JSON document in current ones, and `pg_temp.sign_in_as` sets the
-- second.
create or replace function auth.uid() returns uuid language sql stable as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$fn$;

create or replace function auth.role() returns text language sql stable as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$fn$;

create or replace function auth.email() returns text language sql stable as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$fn$;

create or replace function auth.jwt() returns jsonb language sql stable as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), '')::jsonb,
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb)
$fn$;

-- ---------------------------------------------------------------------
-- storage
--
-- Bare tables with row level security on. Every policy over them comes
-- from our own migrations, so `logo_storage.sql` and
-- `attachments_module.sql` assert the real rules; what is approximate
-- here is only the shape of the table they are written against.
-- ---------------------------------------------------------------------
create table if not exists storage.buckets (
  id text primary key, name text, owner uuid,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  public boolean default false, file_size_limit bigint,
  allowed_mime_types text[]
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text, owner uuid, owner_id text,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb, path_tokens text[], version text
);
alter table storage.objects enable row level security;

grant all on storage.objects, storage.buckets
  to postgres, anon, authenticated, service_role;

create or replace function storage.foldername(name text)
returns text[] language sql immutable as $fn$
  select string_to_array(name, '/')
$fn$;

-- Realtime's publication. `0117` adds tables to it and cannot create it.
do $b$ begin create publication supabase_realtime;
  exception when duplicate_object then null; end $b$;

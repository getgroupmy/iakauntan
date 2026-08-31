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

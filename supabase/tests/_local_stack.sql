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
-- The FUNCTIONS question `0658` closed
--
-- There is still no default privilege for functions here, and that is
-- now the settled answer rather than the open one. `c2d2d15` added one
-- on the strength of `0165`'s comment, it made this machine more
-- generous than the hosted project, and it was reverted -- but the
-- hosted project turned out to be the generous one, not this machine.
--
-- Three pieces of evidence said so before anybody could check the
-- hosted project directly, which this machine still cannot do:
-- `0621`'s apply-time check found `public.set_sst_registration`
-- executable by `service_role` there though no migration ever granted
-- it; CI run 1941 found `0657`'s freshly dropped-and-recreated
-- `public.push_targets`, revoked `from public` alone, still executable
-- by `authenticated`. A dropped function takes its grants with it, so
-- both began life with an EXECUTE grant no statement wrote, and a
-- default privilege is the only thing that explains that.
--
-- `0658` is the look at the hosted project this file used to say the
-- question needed -- taken from inside a migration, at apply time,
-- against the database in question, the only way this repository can
-- take it. It revokes the leftover default itself, closes the
-- twenty-two functions it had opened without a matching `authenticated`
-- revoke, and sweeps `service_role` back to the named list this
-- machine's own silence about the default made it possible to read off
-- correctly. Its own self-checks are what proved it on the hosted
-- project, not this file -- but its effect is that hosted now matches
-- what this machine already modelled, rather than the other way round,
-- so nothing here needed to change to agree with it.
--
-- Every migration should still write `from public, anon, authenticated`
-- in full, as `0141` and `0143` do: `0658` closed what already existed
-- and what is created after it, not what a future migration forgets to
-- say for itself.
-- ---------------------------------------------------------------------

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

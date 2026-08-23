-- What `supabase start` would have created, for a machine without Docker.
--
-- CI uses the real thing (`supabase start`), and CI is the authority.
-- This exists so the SQL suite can be run locally in environments where
-- Docker is unavailable — it is a development convenience, never a
-- substitute for the CI run.
create extension if not exists "pgcrypto";
create extension if not exists "citext";
create extension if not exists "pg_trgm";
create extension if not exists "btree_gist";

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then
    create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then
    create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then
    create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then
    create role supabase_auth_admin nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then
    create role authenticator noinherit login; end if;
end $$;
grant anon, authenticated, service_role to authenticator;
grant anon, authenticated, service_role, supabase_auth_admin to postgres;

create schema if not exists auth;
create schema if not exists extensions;
create schema if not exists graphql_public;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text, created_at timestamptz, updated_at timestamptz,
  confirmation_token text not null default '',
  recovery_token text not null default '',
  email_change_token_new text not null default '',
  email_change_token_current text not null default '',
  phone_change_token text not null default '',
  reauthentication_token text not null default '',
  email_change text not null default '',
  phone_change text not null default '',
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  raw_app_meta_data jsonb not null default '{}'::jsonb,
  encrypted_password text, phone text, is_super_admin boolean,
  last_sign_in_at timestamptz, email_confirmed_at timestamptz,
  banned_until timestamptz, deleted_at timestamptz, instance_id uuid,
  aud varchar(255), role varchar(255),
  recovery_sent_at timestamptz, confirmation_sent_at timestamptz,
  email_change_sent_at timestamptz, invited_at timestamptz,
  confirmed_at timestamptz, phone_confirmed_at timestamptz,
  is_sso_user boolean not null default false,
  is_anonymous boolean not null default false);

-- 0196 updates this alongside auth.users, and relies on `email` being
-- generated from identity_data.
create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  identity_data jsonb not null default '{}'::jsonb,
  provider text not null default 'email', provider_id text,
  email text generated always as (lower(identity_data ->> 'email')) stored,
  last_sign_in_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now());

-- GoTrue writes a session row per sign-in; 0235 hangs its audit
-- triggers here.
create table if not exists auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  ip inet, user_agent text,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  not_after timestamptz);
create table if not exists auth.refresh_tokens (
  id bigserial primary key, session_id uuid, user_id uuid, token text,
  revoked boolean default false, created_at timestamptz default now());
create table if not exists auth.audit_log_entries (
  id uuid primary key default gen_random_uuid(), payload jsonb,
  created_at timestamptz default now(), ip_address varchar(64) default '');

-- The `nullif` must run BEFORE the jsonb cast: an unset claim is the
-- empty string, and ''::jsonb raises rather than yielding null. Getting
-- that backwards fails every test that queries while signed out.
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text $$;
create or replace function auth.email() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))::text $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), ''))::jsonb $$;

create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table if not exists storage.buckets (
  id text primary key, name text not null, owner uuid,
  public boolean not null default false, file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(), updated_at timestamptz default now());
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text, owner uuid, metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  last_accessed_at timestamptz default now());
alter table storage.objects enable row level security;
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;
create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $$ select string_to_array(name, '/'); $$;
create or replace function storage.filename(name text) returns text
  language sql immutable as $$ select (string_to_array(name,'/'))[array_length(string_to_array(name,'/'),1)]; $$;
create or replace function storage.extension(name text) returns text
  language sql immutable as $$ select substring(name from '\.([^.]*)$'); $$;

-- 0117, 0124, 0204 and 0302 add tables to this; live_updates.sql
-- asserts its contents.
do $$ begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime')
  then create publication supabase_realtime; end if;
end $$;

-- Supabase's own defaults. 0299 exists because of them: every table
-- reaches production with writes granted whatever its migration asked
-- for, and RLS is what refuses. Without these the local harness
-- diverges from production in the direction that hides bugs.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

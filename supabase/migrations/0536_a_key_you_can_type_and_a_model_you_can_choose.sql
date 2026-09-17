-- =====================================================================
-- The AI key nobody could type, and the model nobody could choose
--
-- `supabase/functions/ask/index.ts` reads `AI_ANTHROPIC_API_KEY` out of
-- the environment and calls one model, named in a `const` at the top of
-- the file. Which means:
--
--   * there is nowhere in the platform console to key in an API key.
--     Turning the assistant on requires a deployment, and changing the
--     key requires another one;
--   * there is one provider and one model for every tenant on the
--     deployment, and no company can bring its own;
--   * a model name is a code change. The one in that file is already
--     the second one it has had.
--
-- OCR solved the same problem in 0111 and this follows it exactly,
-- because the shape was right: a settings row per company that says
-- whether the thing is on and whose key pays for it, a credentials
-- table with RLS on and NO POLICIES so the service role is its only
-- reader, and a `key_source` of 'platform' or 'own'.
--
-- What is new here is that the PROVIDER is data rather than code. There
-- are two wire shapes in the world worth writing adapters for — the
-- Anthropic Messages API, and the OpenAI chat-completions shape that
-- OpenRouter, Nvidia NIM, Cerebras, DeepSeek and Qwen all speak — so
-- `wire` is a column and everything else about a provider is a row. A
-- provider nobody has heard of yet is an INSERT, and 0537 seeds the
-- ones we have.
--
-- The key is never returned to a tenant, and never returned to a
-- platform administrator either. `platform_ai_providers` says whether a
-- key is ON FILE and when it was last set; the only reader of the key
-- itself is `app.ai_call_config`, whose EXECUTE is granted to the
-- service role alone.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who can be called
-- ---------------------------------------------------------------------
create table public.ai_providers (
  code       text primary key,
  name       text not null,
  -- The only thing about a provider that is code rather than data.
  wire       text not null check (wire in ('anthropic', 'openai')),
  -- Where to send it. Nullable because some providers are reached at an
  -- address the deployment chooses — a self-hosted gateway, or one
  -- whose published endpoint we have not confirmed. A provider with no
  -- base URL and no override cannot be called, and says so.
  base_url   text,
  docs_url   text,
  -- What the person keying it in is looking for, in their own words.
  key_hint   text,
  -- A provider that does not want a key at all. Rare, and the reason
  -- the column exists rather than inferring it from a blank key.
  needs_key  boolean not null default true,
  is_active  boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.ai_providers enable row level security;

comment on table public.ai_providers is
  'The AI providers this deployment knows how to call. A catalogue, not a secret: no key is stored here.';

-- Everybody may read the catalogue: choosing a provider is a thing a
-- company does for itself, and the list has nothing private in it.
create policy ai_providers_read on public.ai_providers
  for select to authenticated using (true);
-- The grant behind the policy. A policy without one is a policy nobody
-- can reach, and `table_grants.sql` fails the build for it. Reading is
-- all anybody does to this table from the app: every write goes through
-- a SECURITY DEFINER function that re-checks who is asking.
grant select on public.ai_providers to authenticated;

-- ---------------------------------------------------------------------
-- What each of them will answer to
--
-- A model list goes stale the week you write it. This is a table so a
-- platform administrator can add the one that came out on Tuesday
-- without a migration, and `is_active` so the one that was withdrawn
-- stops being offered without taking the history of who used it away.
-- ---------------------------------------------------------------------
create table public.ai_models (
  id             uuid primary key default gen_random_uuid(),
  provider_code  text not null references public.ai_providers (code)
                   on delete cascade,
  -- What goes on the wire. Not the same thing as the name a person
  -- reads, and the reason both columns are here.
  model_id       text not null,
  name           text not null,
  kind           text not null default 'chat'
                   check (kind in ('chat', 'vision', 'image')),
  -- Free at the point of use. Worth a column because it is the first
  -- thing anybody setting this up wants to filter on.
  is_free        boolean not null default false,
  context_tokens integer,
  notes          text,
  is_active      boolean not null default true,
  sort_order     integer not null default 100,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (provider_code, model_id)
);
alter table public.ai_models enable row level security;

comment on table public.ai_models is
  'The models each provider offers. A table rather than a constant so a new model is a row, not a deployment.';

create policy ai_models_read on public.ai_models
  for select to authenticated using (true);
grant select on public.ai_models to authenticated;

create index on public.ai_models (provider_code) where is_active;

-- ---------------------------------------------------------------------
-- The keys
--
-- One row per provider for the platform (org_id null), and one row per
-- provider per company that brought its own. RLS on with no policies
-- and grants revoked, exactly as `org_ocr_credentials`: the service
-- role reads these and nothing else does.
--
-- Two partial unique indexes rather than a primary key, because a null
-- org_id is the platform and a unique constraint would let the platform
-- have as many rows as it liked.
-- ---------------------------------------------------------------------
create table public.ai_provider_credentials (
  id            uuid primary key default gen_random_uuid(),
  provider_code text not null references public.ai_providers (code)
                  on delete cascade,
  org_id        uuid references public.organizations (id) on delete cascade,
  api_key       text not null,
  -- An override for the provider's own address: a gateway in front of
  -- it, or a region that is not the default one.
  base_url      text,
  updated_by    uuid references auth.users (id),
  updated_at    timestamptz not null default now()
);
alter table public.ai_provider_credentials enable row level security;
revoke all on public.ai_provider_credentials from anon, authenticated;

comment on table public.ai_provider_credentials is
  'Provider keys, the platform''s and the tenants''. RLS on with no policies and grants revoked: the service role reads these and nothing else does.';

create unique index ai_provider_credentials_platform_key
  on public.ai_provider_credentials (provider_code) where org_id is null;
create unique index ai_provider_credentials_org_key
  on public.ai_provider_credentials (provider_code, org_id)
  where org_id is not null;

-- ---------------------------------------------------------------------
-- What each company uses
--
-- Absent row means off, which is where every company starts. A null
-- provider or model means "whatever the platform is using", so a
-- company that never opens this screen follows the default and keeps
-- following it when the default changes.
-- ---------------------------------------------------------------------
create table public.org_ai_settings (
  org_id        uuid primary key references public.organizations (id)
                  on delete cascade,
  is_enabled    boolean not null default false,
  provider_code text references public.ai_providers (code) on delete set null,
  model_id      text,
  key_source    text not null default 'platform'
                  check (key_source in ('platform', 'own')),
  updated_by    uuid references auth.users (id),
  updated_at    timestamptz not null default now()
);
alter table public.org_ai_settings enable row level security;

comment on table public.org_ai_settings is
  'Per-organization assistant settings. Absent row means off. A null provider or model follows the platform default, and keeps following it.';

create policy org_ai_settings_read on public.org_ai_settings
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());
grant select on public.org_ai_settings to authenticated;

-- ---------------------------------------------------------------------
-- The platform's own choice
-- ---------------------------------------------------------------------
insert into public.platform_settings (key, value, description)
values (
  'ai_default',
  jsonb_build_object('provider', 'anthropic', 'model', 'claude-opus-5'),
  'The provider and model the assistant uses for a company that has not chosen one of its own.')
on conflict (key) do nothing;

create or replace function app.ai_default()
returns jsonb
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(
    (select value from public.platform_settings where key = 'ai_default'),
    jsonb_build_object('provider', 'anthropic', 'model', 'claude-opus-5'));
$$;

comment on function app.ai_default() is
  'The provider and model a company follows when it has not chosen. Read by name rather than joined so a deployment with no row still answers.';

-- ---------------------------------------------------------------------
-- What the platform console shows
--
-- Never the key. `has_key` and `key_set_at` are what a person setting
-- this up actually needs to know — whether they have to type one, and
-- whether the one on file is the one they think it is.
-- ---------------------------------------------------------------------
create or replace function public.platform_ai_providers()
returns table (
  code text, name text, wire text, base_url text, docs_url text,
  key_hint text, needs_key boolean, is_active boolean, sort_order integer,
  has_key boolean, key_base_url text, key_set_at timestamptz,
  models integer, free_models integer,
  is_default boolean, default_model text, tenants integer)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_def jsonb := app.ai_default();
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  return query
  select p.code, p.name, p.wire, p.base_url, p.docs_url,
         p.key_hint, p.needs_key, p.is_active, p.sort_order,
         c.id is not null,
         c.base_url,
         c.updated_at,
         (select count(*)::integer from public.ai_models m
           where m.provider_code = p.code and m.is_active),
         (select count(*)::integer from public.ai_models m
           where m.provider_code = p.code and m.is_active and m.is_free),
         p.code = (v_def ->> 'provider'),
         case when p.code = (v_def ->> 'provider')
              then v_def ->> 'model' end,
         (select count(*)::integer from public.org_ai_settings s
           where s.provider_code = p.code and s.is_enabled)
    from public.ai_providers p
    left join public.ai_provider_credentials c
      on c.provider_code = p.code and c.org_id is null
   order by p.sort_order, p.name;
end;
$$;

revoke all on function public.platform_ai_providers() from public, anon;
grant execute on function public.platform_ai_providers() to authenticated;

comment on function public.platform_ai_providers() is
  'The provider list for the platform console, with whether a key is on file and when it was set. Never the key itself.';

-- ---------------------------------------------------------------------
-- Keying one in
-- ---------------------------------------------------------------------
create or replace function public.set_platform_ai_key(
  p_provider text, p_api_key text, p_base_url text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_needs boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  select needs_key into v_needs from public.ai_providers where code = p_provider;
  if v_needs is null then
    raise exception 'No such provider.' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_api_key, '')) = '' then
    raise exception
      'A key of no characters is not a key. Use the clear button if the '
      'intention was to remove it.' using errcode = '23514';
  end if;

  insert into public.ai_provider_credentials
    (provider_code, org_id, api_key, base_url, updated_by, updated_at)
  values (p_provider, null, btrim(p_api_key),
          nullif(btrim(coalesce(p_base_url, '')), ''), auth.uid(), now())
  on conflict (provider_code) where org_id is null
  do update set api_key = excluded.api_key,
                base_url = excluded.base_url,
                updated_by = excluded.updated_by,
                updated_at = now();
end;
$$;

revoke all on function public.set_platform_ai_key(text, text, text)
  from public, anon;
grant execute on function public.set_platform_ai_key(text, text, text)
  to authenticated;

create or replace function public.clear_platform_ai_key(p_provider text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  delete from public.ai_provider_credentials
   where provider_code = p_provider and org_id is null;
end;
$$;

revoke all on function public.clear_platform_ai_key(text) from public, anon;
grant execute on function public.clear_platform_ai_key(text) to authenticated;

-- ---------------------------------------------------------------------
-- Choosing the default
--
-- A default that names a model the provider does not offer is a
-- deployment where every company that has not chosen gets an error, so
-- the pair is checked together rather than as two settings.
-- ---------------------------------------------------------------------
create or replace function public.set_platform_ai_default(
  p_provider text, p_model text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_providers
                  where code = p_provider and is_active) then
    raise exception 'That provider is not switched on.' using errcode = '23514';
  end if;
  if not exists (select 1 from public.ai_models
                  where provider_code = p_provider and model_id = p_model
                    and is_active and kind <> 'image') then
    raise exception
      'That model is not one % answers to. The assistant holds a '
      'conversation, so an image model is not one of its choices either.',
      p_provider using errcode = '23514';
  end if;

  insert into public.platform_settings (key, value, description, updated_by,
                                        updated_at)
  values ('ai_default',
          jsonb_build_object('provider', p_provider, 'model', p_model),
          'The provider and model the assistant uses for a company that '
          'has not chosen one of its own.', auth.uid(), now())
  on conflict (key) do update
    set value = excluded.value, updated_by = excluded.updated_by,
        updated_at = now();
end;
$$;

revoke all on function public.set_platform_ai_default(text, text)
  from public, anon;
grant execute on function public.set_platform_ai_default(text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Adding one the catalogue does not list
--
-- A gateway on the company's own network, or a provider that shipped
-- after this migration. Both are OpenAI-shaped nine times in ten, which
-- is why `wire` is the only thing that has to be chosen from a list.
-- ---------------------------------------------------------------------
create or replace function public.upsert_ai_provider(
  p_code text, p_name text, p_wire text, p_base_url text default null,
  p_docs_url text default null, p_key_hint text default null,
  p_needs_key boolean default true, p_is_active boolean default true,
  p_sort_order integer default 100)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_code text := lower(btrim(coalesce(p_code, '')));
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  if v_code !~ '^[a-z0-9][a-z0-9_]{1,30}$' then
    raise exception
      'A provider code is lower case letters, digits and underscores. It '
      'goes in a settings row and a log line, not on a screen.'
      using errcode = '23514';
  end if;
  insert into public.ai_providers
    (code, name, wire, base_url, docs_url, key_hint, needs_key, is_active,
     sort_order, updated_at)
  values (v_code, p_name, p_wire,
          nullif(btrim(coalesce(p_base_url, '')), ''),
          nullif(btrim(coalesce(p_docs_url, '')), ''),
          nullif(btrim(coalesce(p_key_hint, '')), ''),
          coalesce(p_needs_key, true), coalesce(p_is_active, true),
          coalesce(p_sort_order, 100), now())
  on conflict (code) do update
    set name = excluded.name, wire = excluded.wire,
        base_url = excluded.base_url, docs_url = excluded.docs_url,
        key_hint = excluded.key_hint, needs_key = excluded.needs_key,
        is_active = excluded.is_active, sort_order = excluded.sort_order,
        updated_at = now();
  return v_code;
end;
$$;

revoke all on function public.upsert_ai_provider(
  text, text, text, text, text, text, boolean, boolean, integer)
  from public, anon;
grant execute on function public.upsert_ai_provider(
  text, text, text, text, text, text, boolean, boolean, integer)
  to authenticated;

create or replace function public.upsert_ai_model(
  p_provider text, p_model_id text, p_name text,
  p_kind text default 'chat', p_is_free boolean default false,
  p_context_tokens integer default null, p_notes text default null,
  p_is_active boolean default true, p_sort_order integer default 100)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'not a platform administrator' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_providers where code = p_provider) then
    raise exception 'No such provider.' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_model_id, '')) = '' then
    raise exception 'A model has to be named to be called.'
      using errcode = '23514';
  end if;
  insert into public.ai_models
    (provider_code, model_id, name, kind, is_free, context_tokens, notes,
     is_active, sort_order, updated_at)
  values (p_provider, btrim(p_model_id),
          coalesce(nullif(btrim(coalesce(p_name, '')), ''), btrim(p_model_id)),
          coalesce(p_kind, 'chat'), coalesce(p_is_free, false),
          p_context_tokens, nullif(btrim(coalesce(p_notes, '')), ''),
          coalesce(p_is_active, true), coalesce(p_sort_order, 100), now())
  on conflict (provider_code, model_id) do update
    set name = excluded.name, kind = excluded.kind,
        is_free = excluded.is_free,
        context_tokens = excluded.context_tokens, notes = excluded.notes,
        is_active = excluded.is_active, sort_order = excluded.sort_order,
        updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.upsert_ai_model(
  text, text, text, text, boolean, integer, text, boolean, integer)
  from public, anon;
grant execute on function public.upsert_ai_model(
  text, text, text, text, boolean, integer, text, boolean, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a company chooses
-- ---------------------------------------------------------------------
create or replace function public.set_ai_settings(
  p_org_id uuid, p_enabled boolean, p_provider text default null,
  p_model text default null, p_key_source text default 'platform')
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_provider text := nullif(btrim(coalesce(p_provider, '')), '');
  v_model    text := nullif(btrim(coalesce(p_model, '')), '');
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up the assistant'
      using errcode = '42501';
  end if;
  if coalesce(p_key_source, 'platform') not in ('platform', 'own') then
    raise exception 'A key is the platform''s or the company''s own.'
      using errcode = '23514';
  end if;

  -- Naming a model without a provider is naming a model at whichever
  -- provider the platform happens to be using this week, which is a
  -- setting that changes meaning underneath the company that set it.
  if v_model is not null and v_provider is null then
    raise exception
      'A model belongs to a provider. Choose the provider as well, or '
      'leave both empty to follow the platform.' using errcode = '23514';
  end if;
  if v_provider is not null
     and not exists (select 1 from public.ai_providers
                      where code = v_provider and is_active) then
    raise exception 'That provider is not switched on.' using errcode = '23514';
  end if;
  if v_model is not null
     and not exists (select 1 from public.ai_models
                      where provider_code = v_provider and model_id = v_model
                        and is_active and kind <> 'image') then
    raise exception
      'That model is not one % answers to.', v_provider using errcode = '23514';
  end if;

  insert into public.org_ai_settings
    (org_id, is_enabled, provider_code, model_id, key_source, updated_by,
     updated_at)
  values (p_org_id, coalesce(p_enabled, false), v_provider, v_model,
          coalesce(p_key_source, 'platform'), auth.uid(), now())
  on conflict (org_id) do update
    set is_enabled = excluded.is_enabled,
        provider_code = excluded.provider_code,
        model_id = excluded.model_id,
        key_source = excluded.key_source,
        updated_by = excluded.updated_by,
        updated_at = now();
end;
$$;

revoke all on function public.set_ai_settings(
  uuid, boolean, text, text, text) from public, anon;
grant execute on function public.set_ai_settings(
  uuid, boolean, text, text, text) to authenticated;

create or replace function public.set_ai_credentials(
  p_org_id uuid, p_provider text, p_api_key text,
  p_base_url text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up the assistant'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_providers where code = p_provider) then
    raise exception 'No such provider.' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_api_key, '')) = '' then
    raise exception
      'A key of no characters is not a key. Use the clear button if the '
      'intention was to remove it.' using errcode = '23514';
  end if;

  insert into public.ai_provider_credentials
    (provider_code, org_id, api_key, base_url, updated_by, updated_at)
  values (p_provider, p_org_id, btrim(p_api_key),
          nullif(btrim(coalesce(p_base_url, '')), ''), auth.uid(), now())
  on conflict (provider_code, org_id) where org_id is not null
  do update set api_key = excluded.api_key,
                base_url = excluded.base_url,
                updated_by = excluded.updated_by,
                updated_at = now();
end;
$$;

revoke all on function public.set_ai_credentials(uuid, text, text, text)
  from public, anon;
grant execute on function public.set_ai_credentials(uuid, text, text, text)
  to authenticated;

create or replace function public.clear_ai_credentials(
  p_org_id uuid, p_provider text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up the assistant'
      using errcode = '42501';
  end if;
  delete from public.ai_provider_credentials
   where provider_code = p_provider and org_id = p_org_id;
end;
$$;

revoke all on function public.clear_ai_credentials(uuid, text)
  from public, anon;
grant execute on function public.clear_ai_credentials(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the company's own screen shows
--
-- Whether it is on, what it will call, and whether that call can
-- actually be made — which is the question a settings screen exists to
-- answer and the one an absent key makes into a runtime error.
-- ---------------------------------------------------------------------
create or replace function public.ai_status(p_org_id uuid)
returns table (
  is_enabled boolean, provider_code text, provider_name text,
  model_id text, model_name text, key_source text,
  follows_platform boolean, has_own_key boolean, own_key_set_at timestamptz,
  is_ready boolean, not_ready_reason text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_def   jsonb := app.ai_default();
  v_s     public.org_ai_settings;
  v_prov  public.ai_providers;
  v_model text;
  v_own   public.ai_provider_credentials;
  v_plat  public.ai_provider_credentials;
  v_url   text;
begin
  if not app.is_org_member(p_org_id) and not app.is_platform_admin() then
    raise exception 'not a member of this company' using errcode = '42501';
  end if;

  select * into v_s from public.org_ai_settings s where s.org_id = p_org_id;
  follows_platform := v_s.provider_code is null;
  select * into v_prov from public.ai_providers p
   where p.code = coalesce(v_s.provider_code, v_def ->> 'provider');
  v_model := coalesce(v_s.model_id, case when follows_platform
                                         then v_def ->> 'model' end);

  select * into v_own from public.ai_provider_credentials c
   where c.provider_code = v_prov.code and c.org_id = p_org_id;
  select * into v_plat from public.ai_provider_credentials c
   where c.provider_code = v_prov.code and c.org_id is null;

  is_enabled     := coalesce(v_s.is_enabled, false);
  provider_code  := v_prov.code;
  provider_name  := v_prov.name;
  model_id       := v_model;
  model_name     := (select m.name from public.ai_models m
                      where m.provider_code = v_prov.code
                        and m.model_id = v_model);
  key_source     := coalesce(v_s.key_source, 'platform');
  has_own_key    := v_own.id is not null;
  own_key_set_at := v_own.updated_at;

  v_url := coalesce(
    case when key_source = 'own' then v_own.base_url else v_plat.base_url end,
    v_prov.base_url);

  not_ready_reason := case
    when v_prov.code is null then
      'No provider is set up. A platform administrator chooses one.'
    when not v_prov.is_active then
      v_prov.name || ' is switched off on this deployment.'
    when v_model is null then
      'No model is chosen, and the platform has not named a default one.'
    when v_url is null then
      v_prov.name || ' has no address to call. It needs one keyed in '
      'beside the key.'
    when key_source = 'own' and v_prov.needs_key and v_own.id is null then
      'This company is set to use its own key and has not supplied one.'
    when key_source = 'platform' and v_prov.needs_key and v_plat.id is null then
      'The platform has no key on file for ' || v_prov.name || '.'
    end;
  is_ready := not_ready_reason is null;
  return next;
end;
$$;

revoke all on function public.ai_status(uuid) from public, anon;
grant execute on function public.ai_status(uuid) to authenticated;

comment on function public.ai_status(uuid) is
  'Whether the assistant is on, what it will call, and whether that call can be made. Never the key.';

-- ---------------------------------------------------------------------
-- The one reader of the key
--
-- It lives in `public` rather than in `app` for one reason: PostgREST
-- exposes `public`, and an edge function reaches a function by calling
-- it. Being in `public` is not being reachable — EXECUTE is revoked
-- from `authenticated` and `anon` and granted to the service role
-- alone, which is a narrower door than the schema it stands in.
--
-- `ask` holds a service client for this call and for nothing else — every tool the assistant
-- runs still goes through `public.ai_run_tool` on the CALLER's client,
-- so what the assistant may read is still decided by the caller's own
-- row policies. Reading a key and reading a ledger are different jobs
-- and this is the smaller one.
-- ---------------------------------------------------------------------
create or replace function public.ai_call_config(p_org_id uuid)
returns table (
  provider_code text, wire text, base_url text, model_id text, api_key text,
  key_source text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_prov public.ai_providers;
  v_cred public.ai_provider_credentials;
  v_def  jsonb := app.ai_default();
  v_s    public.org_ai_settings;
begin
  select * into v_s from public.org_ai_settings s where s.org_id = p_org_id;
  select * into v_prov from public.ai_providers p
   where p.code = coalesce(v_s.provider_code, v_def ->> 'provider');
  if v_prov.code is null or not v_prov.is_active then
    raise exception 'The assistant has no provider to call.'
      using errcode = 'P0002';
  end if;

  key_source := coalesce(v_s.key_source, 'platform');
  select * into v_cred from public.ai_provider_credentials c
   where c.provider_code = v_prov.code
     and (case when key_source = 'own' then c.org_id = p_org_id
               else c.org_id is null end);

  if v_prov.needs_key and v_cred.id is null then
    raise exception
      'There is no API key on file for %. Key one in under the platform '
      'console, or give this company one of its own.', v_prov.name
      using errcode = 'P0002';
  end if;

  provider_code := v_prov.code;
  wire          := v_prov.wire;
  base_url      := coalesce(v_cred.base_url, v_prov.base_url);
  model_id      := coalesce(v_s.model_id,
                            case when v_s.provider_code is null
                                 then v_def ->> 'model' end);
  api_key       := v_cred.api_key;

  if base_url is null then
    raise exception 'There is no address on file to call % at.', v_prov.name
      using errcode = 'P0002';
  end if;
  if model_id is null then
    raise exception 'No model is chosen for this company.'
      using errcode = 'P0002';
  end if;
  return next;
end;
$$;

revoke all on function public.ai_call_config(uuid)
  from public, anon, authenticated;
grant execute on function public.ai_call_config(uuid) to service_role;

comment on function public.ai_call_config(uuid) is
  'The provider, address, model and key for one company''s assistant. The only reader of an API key, and granted to the service role alone.';

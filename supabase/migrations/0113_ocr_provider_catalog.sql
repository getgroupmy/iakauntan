-- =====================================================================
-- iAkauntan :: 0113 readers as data, so the next one is a row
--
-- 0111 wrote `check (provider in ('claude', 'google'))`. 0112 rewrote it
-- to add a third. Adding ChatGPT and Grok would rewrite it again, and
-- the one after that again — a migration, a deploy and a released app
-- every time somebody wants to try a different reader. That is the wrong
-- shape for a list that is going to keep growing.
--
-- So the list becomes a table. A platform operator adds a reader in the
-- console: a name, which protocol it speaks, where to reach it, which
-- model, and what a scan costs. No migration, no deploy.
--
-- ---------------------------------------------------------------------
-- Protocol, not brand
--
-- `kind` is the only thing the edge function switches on, and there are
-- four of them, not one per vendor:
--
--   anthropic     the Messages API
--   openai        the chat-completions shape — which is what OpenAI
--                 speaks, and what xAI's Grok speaks, and what most of
--                 the rest have settled on. One handler, many readers.
--   google_docai  Document AI, which is its own thing entirely
--   device        runs in the app; the server never sees it
--
-- That is why ChatGPT and Grok arrive here as two rows and no new code:
-- they differ by endpoint and model, which are columns.
--
-- ---------------------------------------------------------------------
-- No model is invented
--
-- `model` is deliberately null on the rows seeded below for readers this
-- migration cannot know the current model of, and a reader with no model
-- cannot be switched on. Guessing an identifier would produce a
-- migration that looks finished and a 404 at the first scan, blamed on
-- the feature rather than on the guess. An operator sets it to whatever
-- their account actually has, in the console, once.
--
-- ---------------------------------------------------------------------
-- Where the platform's keys live
--
-- Still nowhere near the database. The function looks up
-- `OCR_KEY_<CODE>` in its own secrets — `OCR_KEY_OPENAI`,
-- `OCR_KEY_GROK` — so a reader added as a row needs a secret added
-- beside it and nothing else. `OCR_ANTHROPIC_API_KEY` and the
-- `OCR_GOOGLE_*` set from 0111 keep working; they are checked as
-- fallbacks so that turning this on does not turn off what was already
-- configured.
-- =====================================================================

create table public.ocr_providers (
  code            text primary key,
  name            text not null,
  kind            text not null
    check (kind in ('anthropic', 'openai', 'google_docai', 'device')),

  -- Where and what. Null on `device`, which has neither.
  endpoint        text,
  model           text,

  -- Ringgit per scan when the tenant is on the platform's key.
  price           numeric(18, 2) not null default 0,

  -- Whether an organization can bring its own. False for the on-device
  -- reader, which has no key for anybody to bring.
  takes_key       boolean not null default true,
  runs_on_device  boolean not null default false,

  -- What to tell somebody choosing it. Shown in Settings, so it is
  -- worth writing for the person picking rather than for us.
  blurb           text,

  is_active       boolean not null default true,
  sort_order      integer not null default 100,
  updated_at      timestamptz not null default now()
);
alter table public.ocr_providers enable row level security;

comment on table public.ocr_providers is
  'The readers an organization may choose. Data rather than a check constraint, so adding one is a row and not a migration.';

-- Everyone signed in may read it — the Settings screen has to draw the
-- list. Only the platform may write it, so a tenant cannot point the
-- system at an endpoint of their choosing.
create policy ocr_providers_read on public.ocr_providers
  for select to authenticated using (true);
create policy ocr_providers_write on public.ocr_providers
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

insert into public.ocr_providers
  (code, name, kind, endpoint, model, price, takes_key, runs_on_device,
   blurb, sort_order)
values
  ('claude', 'Claude', 'anthropic',
   'https://api.anthropic.com/v1/messages', 'claude-opus-5', 0.30,
   true, false,
   'Reads the document rather than the printing. Best on a long bill, '
   'and the one to use when the layout is unusual.', 10),

  ('openai', 'ChatGPT', 'openai',
   'https://api.openai.com/v1/chat/completions', null, 0.30,
   true, false,
   'OpenAI''s vision models. Set the model in the platform console '
   'before switching this on.', 20),

  ('grok', 'Grok', 'openai',
   'https://api.x.ai/v1/chat/completions', null, 0.30,
   true, false,
   'xAI, through the same chat-completions shape as ChatGPT. Set the '
   'model in the platform console before switching this on.', 30),

  ('google', 'Document AI', 'google_docai', null, null, 0.20,
   true, false,
   'Google''s purpose-built invoice and expense parsers. Steady on a '
   'printed invoice; needs a processor set up in your Google project.',
   40),

  ('mlkit', 'On this device', 'device', null, null, 0, false, true,
   'Free, and the photograph never leaves the phone. Reads the printing '
   'rather than understanding the document, and needs the phone app.',
   50)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- The constraints become a reference
--
-- `on delete restrict`: a reader an organization is using cannot be
-- deleted out from under them. Retiring one is `is_active = false`,
-- which stops it being chosen without breaking whoever already has it.
-- ---------------------------------------------------------------------
alter table public.org_ocr_settings
  drop constraint if exists org_ocr_settings_provider_check;
alter table public.org_ocr_settings
  add constraint org_ocr_settings_provider_fkey
  foreign key (provider) references public.ocr_providers (code)
  on update cascade on delete restrict;

alter table public.org_ocr_credentials
  drop constraint if exists org_ocr_credentials_provider_check;
alter table public.org_ocr_credentials
  add constraint org_ocr_credentials_provider_fkey
  foreign key (provider) references public.ocr_providers (code)
  on update cascade on delete restrict;

-- ---------------------------------------------------------------------
-- Price comes off the catalog now
--
-- One source of truth. `ocr_pricing` on `platform_settings` was the
-- other one, and leaving both would guarantee they disagree.
-- ---------------------------------------------------------------------
create or replace function app.ocr_price(p_provider text)
returns numeric language sql stable
set search_path = public, pg_temp as $$
  select coalesce(
    (select p.price from public.ocr_providers p where p.code = p_provider),
    0);
$$;

delete from public.platform_settings where key = 'ocr_pricing';

-- ---------------------------------------------------------------------
-- Choosing one
--
-- The pairing rules now come off the row rather than out of a list of
-- names in the function body: a reader that runs on the device forces
-- `device`, and one that takes no key cannot be set to `own`.
-- ---------------------------------------------------------------------
create or replace function public.set_ocr_settings(
  p_org_id     uuid,
  p_enabled    boolean,
  p_provider   text default 'claude',
  p_key_source text default 'platform')
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  pr       public.ocr_providers;
  v_source text := p_key_source;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can turn document scanning on'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers where code = p_provider;
  if pr.code is null then
    raise exception 'Unknown scanning provider %', p_provider
      using errcode = '23514';
  end if;
  if p_enabled and not pr.is_active then
    raise exception '% is not available', pr.name using errcode = '23514';
  end if;

  -- A reader with nowhere to send the document and no model to send it
  -- to is a 404 waiting for somebody to press Scan. Caught here, where
  -- an operator can still do something about it.
  if p_enabled and pr.kind in ('anthropic', 'openai')
     and coalesce(trim(coalesce(pr.model, '')), '') = '' then
    raise exception
      'No model is set for %. A platform administrator sets one in the console before it can be used.',
      pr.name using errcode = '23514';
  end if;

  if pr.runs_on_device then
    v_source := 'device';
  elsif v_source = 'device' then
    raise exception 'Only an on-device reader runs on the device; % needs a key',
      pr.name using errcode = '23514';
  elsif v_source not in ('platform', 'own') then
    raise exception 'A key comes from the platform or from you, not %',
      v_source using errcode = '23514';
  end if;

  if v_source = 'own' and not pr.takes_key then
    raise exception '% has no key for you to supply', pr.name
      using errcode = '23514';
  end if;

  if p_enabled and v_source = 'own'
     and not exists (select 1 from public.org_ocr_credentials c
                      where c.org_id = p_org_id and c.provider = p_provider) then
    raise exception
      'Add your % key before switching scanning on with it', pr.name
      using errcode = '23514';
  end if;

  insert into public.org_ocr_settings
    (org_id, is_enabled, provider, key_source, updated_by, updated_at)
  values (p_org_id, p_enabled, p_provider, v_source, auth.uid(), now())
  on conflict (org_id) do update
    set is_enabled = excluded.is_enabled,
        provider   = excluded.provider,
        key_source = excluded.key_source,
        updated_by = auth.uid(),
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------
-- Starting a scan
--
-- Now hands back the protocol, the endpoint and the model as well, so
-- the edge function dispatches on what the row says rather than on a
-- list of provider names compiled into it. Adding a reader that speaks
-- a protocol it already knows needs no deploy at all.
--
-- The key is still not among them. That is read with the service role,
-- which is the only reader `org_ocr_credentials` has.
-- ---------------------------------------------------------------------
create or replace function public.ocr_begin(
  p_org_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s        public.org_ocr_settings;
  pr       public.ocr_providers;
  v_path   text;
  v_mime   text;
  v_price  numeric(18, 2) := 0;
  v_scan   uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers where code = s.provider;
  if pr.runs_on_device then
    raise exception
      'This organization reads documents on the device, so there is nothing for the server to do. Use the app on a phone or tablet.'
      using errcode = '0A000';
  end if;

  select a.storage_path, a.mime_type into v_path, v_mime
    from public.attachments a
   where a.id = p_attachment_id and a.org_id = p_org_id;
  if v_path is null then
    raise exception 'That attachment is not on this organization'
      using errcode = '42704';
  end if;

  if s.key_source = 'own' then
    if not exists (select 1 from public.org_ocr_credentials c
                    where c.org_id = p_org_id and c.provider = s.provider) then
      raise exception 'The % key has been removed; scanning cannot run',
        pr.name using errcode = '42501';
    end if;
  else
    v_price := pr.price;
  end if;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source,
     amount_charged, requested_by)
  values (p_org_id, p_attachment_id, v_path, s.provider, s.key_source,
          v_price, auth.uid())
  returning id into v_scan;

  if v_price > 0 then
    perform app.move_credit(
      p_org_id, 'usage', -v_price,
      format('Scan of %s', split_part(v_path, '/', 4)),
      v_scan, null, true);
  end if;

  return jsonb_build_object(
    'scan_id',      v_scan,
    'provider',     s.provider,
    'provider_name', pr.name,
    'kind',         pr.kind,
    'endpoint',     pr.endpoint,
    'model',        pr.model,
    'key_source',   s.key_source,
    'storage_path', v_path,
    'mime_type',    v_mime,
    'charged',      v_price);
end;
$$;

-- ---------------------------------------------------------------------
-- Recording one that happened on the phone
--
-- Same as 0112, reading `runs_on_device` off the catalog instead of
-- comparing against the literal 'mlkit'.
-- ---------------------------------------------------------------------
create or replace function public.ocr_record_local(
  p_org_id        uuid,
  p_attachment_id uuid,
  p_extracted     jsonb default null,
  p_error         text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s      public.org_ocr_settings;
  pr     public.ocr_providers;
  v_path text;
  v_scan uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers where code = s.provider;
  if not coalesce(pr.runs_on_device, false) then
    raise exception
      'This organization reads documents with %, not on the device',
      coalesce(pr.name, s.provider) using errcode = '23514';
  end if;

  select a.storage_path into v_path
    from public.attachments a
   where a.id = p_attachment_id and a.org_id = p_org_id;
  if v_path is null then
    raise exception 'That attachment is not on this organization'
      using errcode = '42704';
  end if;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source,
     status, amount_charged, extracted, error, requested_by, finished_at)
  values (p_org_id, p_attachment_id, v_path, s.provider, 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$$;

-- ---------------------------------------------------------------------
-- What the settings screen shows
--
-- Now carries the catalog, so the screen draws whatever readers exist
-- rather than three it was written knowing about.
-- ---------------------------------------------------------------------
create or replace function public.ocr_status(p_org_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  s          public.org_ocr_settings;
  v_provider text;
  v_balance  numeric(18, 2);
begin
  if not app.can_write(p_org_id) and not app.can_read_ledger(p_org_id) then
    raise exception 'You do not have access to this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  v_provider := coalesce(s.provider, 'claude');

  select c.balance into v_balance
    from public.org_credits c where c.org_id = p_org_id;

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
    'provider',    v_provider,
    'key_source',  coalesce(s.key_source, 'platform'),
    'has_own_key', exists (select 1 from public.org_ocr_credentials c
                            where c.org_id = p_org_id
                              and c.provider = v_provider),
    'keys',        (select coalesce(jsonb_object_agg(c.provider, true), '{}'::jsonb)
                      from public.org_ocr_credentials c where c.org_id = p_org_id),
    'balance',     coalesce(v_balance, 0),
    'currency',    'MYR',
    'price',       app.ocr_price(v_provider),
    'providers',   (select coalesce(jsonb_agg(jsonb_build_object(
                        'code', p.code,
                        'name', p.name,
                        'kind', p.kind,
                        'price', p.price,
                        'takes_key', p.takes_key,
                        'runs_on_device', p.runs_on_device,
                        'ready', p.kind not in ('anthropic', 'openai')
                                 or coalesce(trim(coalesce(p.model, '')), '') <> '',
                        'blurb', p.blurb) order by p.sort_order), '[]'::jsonb)
                      from public.ocr_providers p
                     where p.is_active or p.code = v_provider),
    'updated_at',  s.updated_at);
end;
$$;

-- ---------------------------------------------------------------------
-- Editing the catalog
--
-- The console already edits `platform_settings` as loose JSON. A reader
-- has a shape worth naming, so this is an RPC rather than another blob
-- somebody has to get the keys right in.
-- ---------------------------------------------------------------------
create or replace function public.platform_set_ocr_provider(
  p_code       text,
  p_name       text default null,
  p_kind       text default null,
  p_endpoint   text default null,
  p_model      text default null,
  p_price      numeric default null,
  p_is_active  boolean default null,
  p_blurb      text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare pr public.ocr_providers;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  if coalesce(trim(coalesce(p_code, '')), '') = '' then
    raise exception 'A reader needs a code' using errcode = '23514';
  end if;

  select * into pr from public.ocr_providers where code = p_code;

  -- Null leaves what is stored alone, so correcting a price does not
  -- blank the endpoint — the trap 0107 exists to document.
  insert into public.ocr_providers
    (code, name, kind, endpoint, model, price, takes_key, runs_on_device,
     blurb, is_active, updated_at)
  values (
    p_code,
    coalesce(p_name, pr.name, p_code),
    coalesce(p_kind, pr.kind, 'openai'),
    coalesce(p_endpoint, pr.endpoint),
    coalesce(nullif(trim(coalesce(p_model, '')), ''), pr.model),
    coalesce(p_price, pr.price, 0),
    coalesce(pr.takes_key, true),
    coalesce(pr.runs_on_device, false),
    coalesce(p_blurb, pr.blurb),
    coalesce(p_is_active, pr.is_active, true),
    now())
  on conflict (code) do update
    set name       = excluded.name,
        kind       = excluded.kind,
        endpoint   = excluded.endpoint,
        model      = excluded.model,
        price      = excluded.price,
        blurb      = excluded.blurb,
        is_active  = excluded.is_active,
        updated_at = now();
end;
$$;

revoke all on function public.platform_set_ocr_provider(
  text, text, text, text, text, numeric, boolean, text) from public, anon;
grant execute on function public.platform_set_ocr_provider(
  text, text, text, text, text, numeric, boolean, text) to authenticated;

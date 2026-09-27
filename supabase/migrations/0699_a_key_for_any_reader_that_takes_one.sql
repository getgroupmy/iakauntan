-- =====================================================================
-- iAkauntan :: 0699 a key for any reader that takes one
--
-- Found while moving the scanning controls out of Settings and onto the
-- AI SmartScan screen, which was asked for as "turn off and on also
-- selection of AI model, add api key and all, move it from settings
-- leave nothing there and move everything here".
--
-- ---------------------------------------------------------------------
-- The allowlist that never learned about the catalog
--
-- `set_ocr_credentials` has refused every provider but `claude` and
-- `google` since `0111`:
--
--     if p_provider not in ('claude', 'google') then
--       raise exception 'Unknown scanning provider %', p_provider;
--
-- `0113` then made the readers a TABLE, and `0675` added Gemini. The
-- list in that function heard about none of it. So a company could
-- choose Gemini, ChatGPT or Grok, could set its key source to "my own
-- key" -- `set_ocr_settings` allows it, because it asks the catalog --
-- and then could not store a key at all. The screen offered a control
-- that raised `23514` at the save, and `ocr_begin` would have refused
-- the scan afterwards for the key that was never there.
--
-- Two hardcoded names against a table is the exact shape `0678` was
-- written about: "a default that was a name in a function body".
--
-- The rule is now the catalog's own: a reader may hold a key when it
-- SAYS it takes one. `takes_key` is false for the on-device reader and
-- true for the rest, and `set_ocr_settings` already refuses `own` for
-- a reader that takes none -- so the two agree by construction rather
-- than by both being edited.
--
-- The Google branch stays keyed on `google_docai` rather than on the
-- literal code, because a platform may add a second Document AI
-- processor under another name and it will need a project, a location
-- and a processor id just the same.
--
-- ---------------------------------------------------------------------
-- And the sentences that point at a screen these controls have left
--
-- Every refusal in this area told somebody to go to Settings. The
-- controls are not there any more, so those sentences now send people
-- to a page that no longer has what they were sent for -- which is the
-- failure `2f012feb` was written about, arriving from the database
-- side.
-- =====================================================================

create or replace function public.set_ocr_credentials(
  p_org_id       uuid,
  p_provider     text,
  p_api_key      text default null,
  p_project_id   text default null,
  p_location     text default null,
  p_processor_id text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  pr          public.ocr_providers;
  v_key       text;
  v_project   text;
  v_location  text;
  v_processor text;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can set a scanning key'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers where code = p_provider;
  if pr.code is null then
    raise exception 'Unknown scanning provider %', p_provider
      using errcode = '23514';
  end if;
  if not pr.takes_key then
    raise exception
      '% needs no key -- it reads documents on the device.', pr.name
      using errcode = '23514';
  end if;

  select c.api_key, c.project_id, c.location, c.processor_id
    into v_key, v_project, v_location, v_processor
    from public.org_ocr_credentials c
   where c.org_id = p_org_id and c.provider = p_provider;

  v_key       := coalesce(nullif(trim(coalesce(p_api_key, '')), ''), v_key);
  v_project   := coalesce(nullif(trim(coalesce(p_project_id, '')), ''), v_project);
  v_location  := coalesce(nullif(trim(coalesce(p_location, '')), ''), v_location);
  v_processor := coalesce(nullif(trim(coalesce(p_processor_id, '')), ''), v_processor);

  if v_key is null then
    raise exception 'A key is required the first time % is configured',
      p_provider using errcode = '23514';
  end if;

  -- Document AI is addressed by processor, not by project alone. A key
  -- with no processor behind it is a 404 at the first scan. Keyed on
  -- the KIND, so a second Document AI processor added under another
  -- code is asked for the same three things.
  if pr.kind = 'google_docai'
     and (v_project is null or v_location is null or v_processor is null) then
    raise exception
      'Google Document AI needs a project, a location and a processor id'
      using errcode = '23514';
  end if;

  insert into public.org_ocr_credentials
    (org_id, provider, api_key, project_id, location, processor_id,
     updated_by, updated_at)
  values (p_org_id, p_provider, v_key, v_project, v_location, v_processor,
          auth.uid(), now())
  on conflict (org_id, provider) do update
    set api_key      = excluded.api_key,
        project_id   = excluded.project_id,
        location     = excluded.location,
        processor_id = excluded.processor_id,
        updated_by   = auth.uid(),
        updated_at   = now();
end;
$$;

comment on function public.set_ocr_credentials(uuid, text, text, text, text, text) is
  'Stores a company''s own key for a reader. Any reader on the catalog '
  'that says it takes one -- not the two names `0111` hardcoded, which '
  'left Gemini, ChatGPT and Grok unable to hold a key at all. 0111, '
  '0699.';


-- ---------------------------------------------------------------------
-- The signposts, pointed at where the controls actually are
--
-- Restated from `0698` and `0682` with two sentences changed and
-- nothing else. Both told somebody to go to Settings, and the scanning
-- controls are not there any more -- so the one message a person acts
-- on would have sent them to a page that no longer holds what they
-- were sent for.
--
-- Worth saying why this is a migration rather than a string in the app:
-- these are the DATABASE's refusals, reached through PostgREST by
-- every client there is, and `2f012feb` is in the history precisely
-- because one of them arrived at a screen as a raw exception. A
-- sentence somebody is expected to act on has to be right wherever it
-- surfaces.
-- ---------------------------------------------------------------------

create or replace function public.ocr_begin(
  p_org_id        uuid,
  p_attachment_id uuid,
  -- Null means "whatever this company is set to", which is every
  -- caller that existed before this migration.
  p_provider      text default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s        public.org_ocr_settings;
  pr       public.ocr_providers;
  v_code   text;
  v_path   text;
  v_mime   text;
  v_price  numeric(18, 2) := 0;
  v_scan   uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;
  perform app.require_smartscan(p_org_id);

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on under “How it reads” on the AI SmartScan screen.'
      using errcode = '42501';
  end if;

  -- `nullif(btrim(...), '')` rather than `is not null`: an empty string
  -- arriving from a client is somebody meaning "no choice", and looking
  -- it up in the catalog would refuse it as an unknown reader.
  v_code := coalesce(nullif(btrim(coalesce(p_provider, '')), ''), s.provider);

  select * into pr from public.ocr_providers where code = v_code;
  if pr.code is null then
    raise exception 'There is no reader called %', v_code
      using errcode = '23514';
  end if;

  if pr.runs_on_device then
    raise exception
      'This organization reads documents on the device, so there is nothing for the server to do. Use the app on a phone or tablet.'
      using errcode = '0A000';
  end if;

  if not pr.is_active then
    raise exception
      '% is no longer offered. An administrator chooses another reader under “How it reads” on the AI SmartScan screen.',
      pr.name using errcode = '42501';
  end if;

  -- Only for a reader the caller NAMED. The company's own reader is
  -- allowed to be unready and fail further in, exactly as it did
  -- before this migration -- narrowing that would be a behaviour
  -- change smuggled in beside a feature.
  if v_code is distinct from s.provider and not app.ocr_provider_ready(pr) then
    raise exception
      '% has not been set up by the platform yet, so it cannot be asked to read anything.',
      pr.name using errcode = '42501';
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
                    where c.org_id = p_org_id and c.provider = v_code)
       and not exists (select 1 from public.ocr_provider_keys k
                        where k.org_id = p_org_id and k.provider = v_code)
    then
      raise exception 'The % key has been removed; scanning cannot run',
        pr.name using errcode = '42501';
    end if;
  else
    v_price := pr.price;
  end if;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source,
     amount_charged, requested_by)
  values (p_org_id, p_attachment_id, v_path, v_code, s.key_source,
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
    'provider',     v_code,
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
  perform app.require_smartscan(p_org_id);

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on under “How it reads” on the AI SmartScan screen.'
      using errcode = '42501';
  end if;

  -- `0113`'s sentence and `0113`'s errcode, unchanged. `ocr_credit.sql`
  -- asserts both, and rewording a refusal while moving a function is
  -- how a test that was protecting something starts protecting nothing.
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
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, extracted, error, requested_by, finished_at)
  values (p_org_id, p_attachment_id, v_path, s.provider, 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$$;

comment on function public.ocr_begin(uuid, uuid, text) is
  'Opens a scan: decides which reader, takes the charge, and hands the '
  'edge function everything it needs to make the call. `p_provider` '
  'names a reader for THIS scan only. Null means the company''s '
  'setting. 0111, 0678, 0682, 0698, 0699.';

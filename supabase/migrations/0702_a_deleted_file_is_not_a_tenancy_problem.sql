-- =====================================================================
-- iAkauntan :: 0702 a deleted file is not a tenancy problem
--
-- Reported from a phone, two errors on one scan of
-- `inv-2026-00001.pdf`:
--
--     That attachment is not on this organization
--
--     Could not read it on this device: StorageException(message:
--     {"statusCode":"404","error":"not_found","message":"Object not
--     found","code":"NoSuchKey"}, statusCode: 400, error: null)
--
-- The second is the client printing an exception at somebody and is
-- fixed in the app. The first is this function, and the sentence is
-- wrong for the thing that almost certainly happened.
--
-- ---------------------------------------------------------------------
-- Why it cannot usually mean what it says
--
-- `ocr_scans.attachment_id` carries a composite foreign key to
-- `attachments (org_id, id)` AND `on delete set null`. So:
--
--   * a non-null `attachment_id` had a row, and that row was on THIS
--     organization -- the composite key is what guarantees it; and
--   * if the attachment is deleted, the column goes null.
--
-- Which leaves one ordinary path to this refusal: the row was deleted
-- AFTER a screen read it. `scan_inbox` is a cached list; a document
-- removed takes its attachments with it; the id in the client's hand is
-- a minute old and names nothing. The storage object goes at the same
-- moment, which is exactly why the same scan answers 404 to "View the
-- image" -- one cause, two messages, and neither said so.
--
-- A tenancy sentence sends somebody to check which company they are
-- signed into, which is the one thing that is not wrong.
--
-- Restated from `0699` with one message changed and nothing else.
-- =====================================================================

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
    -- `0702`. This said "That attachment is not on this organization",
    -- which is a sentence about TENANCY and sends somebody to check
    -- which company they are signed into. It is almost never what
    -- happened.
    --
    -- `ocr_scans.attachment_id` carries a COMPOSITE foreign key to
    -- `attachments (org_id, id)`, so a non-null id always had a row on
    -- this organization. The ordinary way to arrive here is that the
    -- row has since been DELETED -- a document removed takes its
    -- attachments with it -- while a screen still holds the id it read
    -- a minute ago. The storage object goes at the same time, which is
    -- why the same scan also answers 404 to "View the image".
    raise exception
      'That file is no longer on file -- it was removed after this list '
      'was loaded. Refresh, and what was read off it is still kept.'
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

comment on function public.ocr_begin(uuid, uuid, text) is
  'Opens a scan: decides which reader, takes the charge, and hands the '
  'edge function everything it needs to make the call. `p_provider` '
  'names a reader for THIS scan only. Null means the company''s '
  'setting. 0111, 0678, 0682, 0698, 0699, 0702.';

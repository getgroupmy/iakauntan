-- =====================================================================
-- iAkauntan :: 0112 a reader that never leaves the phone
--
-- 0111 gave an organization two readers, both of which send the
-- photograph to somebody else's server: Claude, or Google Document AI.
-- That is the right trade for a bill with a page of line items on it. It
-- is a poor trade for a petrol receipt, and for some organizations it is
-- not a trade they will make at all.
--
-- Google ML Kit Text Recognition runs on the device. No key, no network,
-- no ringgit — the model ships inside the app and the photograph is read
-- where it was taken. That makes it the option to reach for when the
-- question is "can we do this without sending the receipt anywhere",
-- which for an accounting firm holding other people's paperwork is
-- frequently the only question.
--
-- ---------------------------------------------------------------------
-- It is not simply a third provider
--
-- Three things about it are structurally different, and each of them
-- shows up below.
--
--   * **There is nothing to pay and nothing to hold.** No key belongs to
--     anybody — not the tenant, not the platform. `key_source` has no
--     meaningful value among the two that exist, so it gains a third,
--     `device`, and choosing this reader forces it.
--
--   * **The edge function never sees it.** The recognition happens in
--     the app, so `ocr_begin` cannot serve this provider at all and says
--     so rather than starting a scan nothing will finish. What the app
--     needs instead is a way to record what happened, which is
--     `ocr_record_local` — safe to hand to an ordinary user precisely
--     because there is no money in it. `ocr_finish`, which refunds,
--     stays where it is.
--
--   * **It reads text, not fields.** ML Kit returns what is printed and
--     nothing about what it means; turning "JUMLAH 45.90" into a total
--     is done in the app and asserted there. This migration stores the
--     result the same shape either way, so an expense filled in from the
--     phone and one filled in from Claude are the same row afterwards.
--
-- The log is kept for on-device scans even though they cost nothing.
-- "Where did this figure come from" is a question an auditor asks about
-- a free reading exactly as often as a paid one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Three readers, and a source of key that admits there may be no key
-- ---------------------------------------------------------------------
alter table public.org_ocr_settings
  drop constraint if exists org_ocr_settings_provider_check;
alter table public.org_ocr_settings
  add constraint org_ocr_settings_provider_check
  check (provider in ('claude', 'google', 'mlkit'));

alter table public.org_ocr_settings
  drop constraint if exists org_ocr_settings_key_source_check;
alter table public.org_ocr_settings
  add constraint org_ocr_settings_key_source_check
  check (key_source in ('platform', 'own', 'device'));

-- A key can only ever exist for the two readers that take one. Nothing
-- could have written an `mlkit` row before this migration, but the
-- constraint is what stops one appearing later and being silently
-- ignored by a function that never looks for it.
alter table public.org_ocr_credentials
  drop constraint if exists org_ocr_credentials_provider_check;
alter table public.org_ocr_credentials
  add constraint org_ocr_credentials_provider_check
  check (provider in ('claude', 'google'));

comment on column public.org_ocr_settings.key_source is
  'platform = drawn from purchased credit; own = the organization''s own provider key; device = on-device, no key and no charge.';

-- ---------------------------------------------------------------------
-- Choosing one
--
-- The pairing is enforced here rather than left to the screen: `device`
-- means exactly one reader, and that reader means exactly `device`. A
-- row saying otherwise would send an on-device scan looking for a key,
-- or bill a tenant for a reading that cost nothing.
-- ---------------------------------------------------------------------
create or replace function public.set_ocr_settings(
  p_org_id     uuid,
  p_enabled    boolean,
  p_provider   text default 'claude',
  p_key_source text default 'platform')
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_source text := p_key_source;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can turn document scanning on'
      using errcode = '42501';
  end if;
  if p_provider not in ('claude', 'google', 'mlkit') then
    raise exception 'Unknown scanning provider %', p_provider
      using errcode = '23514';
  end if;

  -- Nobody holds a key for the on-device reader, so whatever the caller
  -- asked for, this is what it is.
  if p_provider = 'mlkit' then
    v_source := 'device';
  elsif v_source = 'device' then
    raise exception
      'Only the on-device reader runs on the device; % needs a key',
      p_provider using errcode = '23514';
  elsif v_source not in ('platform', 'own') then
    raise exception 'A key comes from the platform or from you, not %',
      v_source using errcode = '23514';
  end if;

  if p_enabled and v_source = 'own'
     and not exists (select 1 from public.org_ocr_credentials c
                      where c.org_id = p_org_id and c.provider = p_provider) then
    raise exception
      'Add your % key before switching scanning on with it', p_provider
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
-- Starting a scan the edge function can actually serve
--
-- Everything from 0111, plus a refusal that names the reason. Without
-- it, an organization on ML Kit that reached this path would have a scan
-- row created, no provider called, and nothing to settle it — a pending
-- row for a reading that was never going to happen here.
-- ---------------------------------------------------------------------
create or replace function public.ocr_begin(
  p_org_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s        public.org_ocr_settings;
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

  if s.provider = 'mlkit' then
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
        s.provider using errcode = '42501';
    end if;
  else
    v_price := app.ocr_price(s.provider);
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
    'key_source',   s.key_source,
    'storage_path', v_path,
    'mime_type',    v_mime,
    'charged',      v_price);
end;
$$;

-- ---------------------------------------------------------------------
-- Recording one that happened on the phone
--
-- Callable by an ordinary user, which `ocr_finish` deliberately is not.
-- The rule there is about money: finish hands a charge back, so letting
-- a browser reach it would be a refund button with no scan behind it.
-- Nothing here moves a balance — the row is written settled, at zero —
-- so the same rule does not apply and the log stays honest instead of
-- silently missing every free reading.
--
-- It still checks that the caller may write for this organization, that
-- scanning is on, that this is the reader chosen, and that the
-- attachment is theirs. A scan row is a claim about a document; it
-- should not be possible to make one about somebody else's.
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
  if s.provider <> 'mlkit' then
    raise exception
      'This organization reads documents with %, not on the device',
      s.provider using errcode = '23514';
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
  values (p_org_id, p_attachment_id, v_path, 'mlkit', 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$$;

revoke all on function public.ocr_record_local(uuid, uuid, jsonb, text)
  from public, anon;
grant execute on function public.ocr_record_local(uuid, uuid, jsonb, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the console charges for it
--
-- Nothing, and the row says so rather than leaving `app.ocr_price` to
-- return zero because the key happens to be absent. An operator opening
-- Service settings should be able to see that this reader is free
-- without inferring it.
-- ---------------------------------------------------------------------
update public.platform_settings
   set value = value || '{"mlkit": 0}'::jsonb,
       description =
         'Ringgit charged per document scan when the tenant uses the platform key. The on-device reader (mlkit) is free.'
 where key = 'ocr_pricing';

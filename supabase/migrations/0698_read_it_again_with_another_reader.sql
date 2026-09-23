-- =====================================================================
-- iAkauntan :: 0698 read it again, with another reader
--
-- Asked for from the SmartScan screen, looking at a scan that had come
-- back wrong: "should have option to rescan and option to rescan with
-- other option (with whatever is active for the user by admin or by
-- user)".
--
-- The file is already in the bucket and the scan row already says which
-- reader read it. What there was no way to do is read it AGAIN --
-- either with the same reader, because a vendor has bad afternoons, or
-- with a different one, because a reader that refuses PDFs or misreads
-- a letterhead is not going to do better on the second try.
--
-- ---------------------------------------------------------------------
-- A third parameter, not a second function
--
-- `ocr_begin` is dropped and recreated with `p_provider text default
-- null` rather than being overloaded, and that is not tidiness.
-- `scripts/check_ambiguous_overloads.py` exists because `0690` added an
-- overload whose named arguments overlapped an older one's, and
-- PostgREST -- which calls everything BY NAME -- answered
--
--     function public.transfer_between_matters(...) is not unique
--
-- for five commits while the positional SQL test stayed green. Two
-- `ocr_begin`s would do exactly that: `{p_org_id, p_attachment_id}`
-- fits both. So there is one, with a default, and every existing caller
-- naming two arguments still resolves -- which matters because the
-- migration applies BEFORE the edge function that calls it is
-- redeployed.
--
-- ---------------------------------------------------------------------
-- What an explicit reader is allowed to be
--
-- Everything the org's own reader has to be, checked again rather than
-- trusted from the request:
--
--   * on the catalog, ACTIVE, and READY -- `app.ocr_provider_ready`, so
--     this cannot offer a reader `set_ocr_settings` would refuse;
--   * not one that runs on the device, because there is nothing for the
--     server to do with it;
--   * and, where the company brings its OWN KEY, a key for THAT reader.
--     This is the one that would otherwise be a real hole: a company on
--     its own Claude key could name Gemini and have the platform's pool
--     pay for it.
--
-- The price charged is the price of the reader ACTUALLY USED. A company
-- on a free reader that asks for a chargeable one is charged for it,
-- which is why the app shows the price on the button rather than beside
-- it.
-- =====================================================================

drop function if exists public.ocr_begin(uuid, uuid);

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
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
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
      '% is no longer offered. An administrator chooses another reader in Settings.',
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

revoke all on function public.ocr_begin(uuid, uuid, text) from public, anon;
grant execute on function public.ocr_begin(uuid, uuid, text) to authenticated;

comment on function public.ocr_begin(uuid, uuid, text) is
  'Opens a scan: decides which reader, takes the charge, and hands the '
  'edge function everything it needs to make the call. `p_provider` '
  'names a reader for THIS scan only -- reading the same file again '
  'with a different one -- and is checked against the same rules the '
  'company''s own reader is, plus readiness and, where the company '
  'brings its own key, a key for that reader. Null means the '
  'company''s setting. 0111, 0678, 0682, 0698.';


-- ---------------------------------------------------------------------
-- And the inbox says what kind of file it is
--
-- Restated from `0697`, adding `mime_type` off the attachment. The
-- screen that offers to read a document again has to leave out the
-- readers that cannot open it, and for a PDF that is every
-- chat-completions reader -- `app.reader_reads_pdf`, `0697`. Without
-- this the screen would offer Gemini for a PDF and the person would
-- spend a scan finding out.
--
-- Dropped and recreated rather than replaced: Postgres will not change
-- a returning function's signature in place. `or replace` is left on
-- the create after the drop, where it is a no-op, so
-- `scripts/mutate_sql.py` can still find the block.
-- ---------------------------------------------------------------------

drop function if exists public.scan_inbox(uuid, integer, text);

create or replace function public.scan_inbox(
  p_org_id uuid,
  p_limit integer default 100,
  p_only text default 'all')
returns table (
  scan_id       uuid,
  attachment_id uuid,
  file_name     text,
  storage_path  text,
  -- `0698`. What KIND of file it is, so the screen offering to read
  -- it again can leave out the readers that cannot open it -- which
  -- for a PDF is most of them. Off the attachment, because the scan
  -- row never recorded it.
  mime_type     text,
  scanned_at    timestamptz,
  provider      text,
  status        text,
  error         text,
  log_ref       text,
  document_kind text,
  kind_label    text,
  target        text,
  posted_table  text,
  posted_id     uuid,
  posted_at     timestamptz,
  posted_label  text,
  posted_date   date,
  reviewed_at   timestamptz,
  corrected     boolean)
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select s.id,
         s.attachment_id,
         -- The attachment's name, falling back to the object's. A
         -- document deleted later takes its attachment with it --
         -- `delete_attachments_of_row` -- and `ocr_scans.attachment_id`
         -- is `on delete set null`, so the scan survives with nothing
         -- to name it. `storage_path` is on the SCAN, so the last
         -- segment is still the file somebody photographed.
         coalesce(a.file_name,
                  nullif(split_part(s.storage_path, '/', -1), '')),
         -- The LIVE key, not the one the reader was handed. `0697`.
         -- `refileAttachment` moves the object onto the record once
         -- that record exists and updates the ATTACHMENT's path; the
         -- scan keeps the placeholder key it was read under. So the
         -- scan's own path is a historical note, and opening it 404s
         -- for every scan that became something -- which was every
         -- scan that worked.
         coalesce(a.storage_path, s.storage_path),
         a.mime_type,
         s.created_at,
         s.provider,
         s.status,
         s.error,
         s.log_ref,
         s.document_kind,
         k.label,
         s.extracted ->> 'target',
         s.posted_table,
         s.posted_id,
         s.posted_at,
         -- One left join per destination, and a null label where the
         -- record has since been deleted: "this became a bill that no
         -- longer exists" is the answer, and dropping the row would
         -- read as a scan that never happened.
         case s.posted_table
           when 'sales_documents'    then sd.doc_no
           when 'purchase_documents' then pd.doc_no
           when 'expenses'           then e.expense_no
           when 'contacts'           then c.name
           when 'bank_transactions'  then 'Statement lines'
           else null
         end,
         case s.posted_table
           when 'sales_documents'    then sd.doc_date
           when 'purchase_documents' then pd.doc_date
           when 'expenses'           then e.expense_date
           else null
         end,
         s.reviewed_at,
         s.corrected is not null
    from public.ocr_scans s
    left join public.attachments a on a.id = s.attachment_id
    left join public.scan_document_kinds k on k.code = s.document_kind
    left join public.sales_documents sd
           on s.posted_table = 'sales_documents' and sd.id = s.posted_id
    left join public.purchase_documents pd
           on s.posted_table = 'purchase_documents' and pd.id = s.posted_id
    left join public.expenses e
           on s.posted_table = 'expenses' and e.id = s.posted_id
    left join public.contacts c
           on s.posted_table = 'contacts' and c.id = s.posted_id
   where s.org_id = p_org_id
     and app.is_org_member(p_org_id)
     and case p_only
           when 'posted'   then s.posted_table is not null
           when 'unposted' then s.posted_table is null
           else true
         end
   order by s.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

revoke all on function public.scan_inbox(uuid, integer, text) from public;
grant execute on function public.scan_inbox(uuid, integer, text)
  to authenticated;

comment on function public.scan_inbox(uuid, integer, text) is
  'Every reading this company has taken, newest first, with the record '
  'it became resolved to something a person recognises, the reference a '
  'failed one was given, the key the file is at NOW rather than the one '
  'it was read under, and what kind of file it is. `p_only` is all, '
  'posted or unposted. 0694, 0695, 0697, 0698.';

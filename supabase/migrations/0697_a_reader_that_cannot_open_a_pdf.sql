-- =====================================================================
-- iAkauntan :: 0697 a reader that cannot open a pdf
--
-- From a report, with the PDF attached. A supplier bill was uploaded
-- into AI SmartScan and the inbox came back
--
--     This reader takes photographs, not PDFs. Photograph the
--     document, or switch to Claude, which reads PDFs.
--
-- That sentence is `supabase/functions/ocr/index.ts` refusing by name
-- inside `readOpenAiShaped`, and it is RIGHT: chat-completions takes an
-- image part, a PDF would need a different endpoint on every one of
-- those vendors, and sending it anyway would be a misreading rather
-- than a refusal.
--
-- What is wrong is WHEN it is said. The app knows the reader the
-- company is on before the file is chosen, and it knows the file is a
-- PDF before it uploads it -- so the refusal arrives after an upload,
-- after a charge, and after a refund, for a question that could have
-- been answered with nothing spent.
--
-- ---------------------------------------------------------------------
-- The fact belongs to the KIND, and the kind is already on the wire
--
-- `ocr_status` has sent `kind` per provider since `0682`, and the app
-- has never looked at it. Rather than teach the app which kinds refuse
-- a PDF -- a rule it would then hold a second copy of, free to drift
-- from the edge function -- the answer is computed HERE, once, by
-- `app.reader_reads_pdf`, and sent beside the kind.
--
-- `device` answers null on purpose, because the database genuinely
-- does not know: the on-device reader is `pdf.js` in a browser and ML
-- Kit on a phone, and one of those opens a PDF and the other does not.
-- `onDeviceReadsPdf` in the app is the only thing that can say, so the
-- database declines to guess rather than sending a `true` that is a
-- lie on every phone.
--
-- ---------------------------------------------------------------------
-- And the picture the inbox could not open
--
-- Reported in the same breath: "View the image" on a scan answered
--
--     StorageException(message: Object not found, statusCode: 404)
--
-- `ocr_scans.storage_path` is where the object was AT THE MOMENT IT WAS
-- READ. `Repo.refileAttachment` then MOVES that object -- a capture is
-- parked against a placeholder and moved onto the bill once the bill
-- has an id -- and updates `attachments.storage_path` and not the
-- scan's. So every scan that successfully became something pointed at
-- a key that had been vacated, and only the ones that became nothing
-- could be opened.
--
-- The attachment's path is the live one and the scan's is the
-- historical one, so the inbox prefers the attachment and falls back.
-- The fallback is not decoration: deleting a document deletes its
-- attachment, and `ocr_scans.attachment_id` is `on delete set null`,
-- so an orphaned scan has nothing but its own path left.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which readers open a PDF
-- ---------------------------------------------------------------------
create or replace function app.reader_reads_pdf(p_kind text)
returns boolean
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select case p_kind
           -- `readClaude` sets `media_type: application/pdf` and sends
           -- a `document` part rather than an `image` one.
           when 'anthropic'   then true
           -- `readOpenAiShaped` refuses it by name. Chat-completions
           -- takes images; a document would be a different endpoint on
           -- every vendor wearing this shape -- Gemini, ChatGPT, Grok.
           when 'openai'      then false
           -- Document AI is a document reader. A PDF is its first case.
           when 'google_docai' then true
           -- Handed the bytes and the mime type, and it answers for
           -- itself. A platform that stood one up and pointed the
           -- catalog at it knows what it accepts; refusing on its
           -- behalf here would refuse the reader that most likely
           -- does.
           when 'self_hosted' then true
           -- Not the database's to say; see the header.
           when 'device'      then null
           -- A kind this migration has not heard of. Null rather than
           -- false: the app treats unknown as "try it", and the edge
           -- function is the real gate.
           else null
         end;
$$;

comment on function app.reader_reads_pdf(text) is
  'Whether a reader of this kind opens a PDF, or null where the answer '
  'is not the database''s to give. Mirrors the dispatch in '
  'supabase/functions/ocr/index.ts, which is where the refusal actually '
  'happens -- this exists so the app can predict it rather than pay for '
  'an upload, a charge and a refund to be told. `device` is null '
  'because a browser reads a PDF and a phone does not, and only the app '
  'knows which it is. 0697.';

-- ---------------------------------------------------------------------
-- `ocr_status`, with the answer beside the kind
--
-- Restated from `0682` with one key added to the `providers` array.
-- Everything else is that function unchanged.
-- ---------------------------------------------------------------------
create or replace function public.ocr_status(p_org_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  s          public.org_ocr_settings;
  v_default  text;
  v_provider text;
  v_balance  numeric(18, 2);
  v_fb       public.ocr_providers;
begin
  if not app.can_write(p_org_id) and not app.can_read_ledger(p_org_id) then
    raise exception 'You do not have access to this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  v_default  := app.default_ocr_provider();
  v_provider := coalesce(s.provider, v_default);

  select c.balance into v_balance
    from public.org_credits c where c.org_id = p_org_id;

  select * into v_fb from public.ocr_providers p
   where p.code = v_default
     and p.code <> v_provider
     and p.is_active
     and app.ocr_provider_ready(p)
     and not p.runs_on_device
     and coalesce(p.price, 0) = 0;

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
    'has_module',  app.has_module(p_org_id, 'smartscan'),
    'provider',    v_provider,
    'default_provider', v_default,
    'chosen',      s.provider is not null,
    'fallback',      v_fb.code,
    'fallback_name', v_fb.name,
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
                        -- 0697. Null where the database cannot say, and
                        -- `jsonb_build_object` keeps the key with a
                        -- json null in it -- which is what the app
                        -- reads as "ask this device".
                        'reads_pdf', app.reader_reads_pdf(p.kind),
                        'price', p.price,
                        'takes_key', p.takes_key,
                        'runs_on_device', p.runs_on_device,
                        'is_active', p.is_active,
                        'ready', app.ocr_provider_ready(p),
                        'blurb', p.blurb) order by p.sort_order), '[]'::jsonb)
                      from public.ocr_providers p
                     where p.is_active or p.code = v_provider),
    'updated_at',  s.updated_at);
end;
$$;

-- ---------------------------------------------------------------------
-- `scan_inbox`, pointing at where the file IS
--
-- Restated from `0695`. One `coalesce` changed; the signature is
-- untouched, so `create or replace` is enough and no drop is needed.
-- ---------------------------------------------------------------------
create or replace function public.scan_inbox(
  p_org_id uuid,
  p_limit integer default 100,
  p_only text default 'all')
returns table (
  scan_id       uuid,
  attachment_id uuid,
  file_name     text,
  storage_path  text,
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

comment on function public.scan_inbox(uuid, integer, text) is
  'Every reading this company has taken, newest first, with the record '
  'it became resolved to something a person recognises, the reference a '
  'failed one was given, and the key the file is at NOW rather than the '
  'one it was read under. `p_only` is all, posted or unposted. 0694, '
  '0695, 0697.';

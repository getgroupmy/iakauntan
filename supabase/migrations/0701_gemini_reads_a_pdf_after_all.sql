-- =====================================================================
-- iAkauntan :: 0701 gemini reads a pdf after all
--
-- Asked, twice: "why AI SmartScan when using google gemini cant read
-- pdf".
--
-- Because of the road we took to it, and not because of the model.
--
-- `0113` and `0675` pointed the Gemini reader at Google's
-- OPENAI-COMPATIBILITY endpoint:
--
--     https://generativelanguage.googleapis.com/v1beta/openai/chat/completions
--
-- which puts it on `kind = 'openai'` and through `readOpenAiShaped`.
-- The parts a chat-completions message may carry are text and
-- `image_url`; there is no document part in that shape. So a PDF was
-- refused BY NAME -- correctly, given that endpoint -- and every
-- company on Gemini was told
--
--     This reader takes photographs, not PDFs. Photograph the
--     document, or switch to Claude, which reads PDFs.
--
-- That sentence is true of our integration and false of Gemini.
-- `generateContent` takes `inline_data` with `application/pdf` and
-- reads the document rather than a picture of it.
--
-- `0697` built the machinery to PREDICT that refusal before the upload
-- and the charge, which was the right fix for a reader that genuinely
-- cannot. It was the wrong fix for this one, and predicting a refusal
-- politely is still a refusal.
--
-- ---------------------------------------------------------------------
-- A kind of its own, not a repurposed one
--
-- `google_docai` is already taken and is a different product: Document
-- AI is a processor you set up in a Google project, addressed by
-- processor id, and it answers with typed entities rather than a shape
-- we asked for. This is the Gemini API, addressed by model, answering
-- the schema we send. One name each.
--
-- The endpoint becomes the BASE. `generateContent` puts the model and
-- the method in the path, and the model is already configuration --
-- so a catalog row carrying the whole URL would carry the model twice
-- and disagree with itself the first time somebody changed one.
-- ---------------------------------------------------------------------

alter table public.ocr_providers
  drop constraint ocr_providers_kind_check;

alter table public.ocr_providers
  add constraint ocr_providers_kind_check
  check (kind = any (array['anthropic'::text, 'openai'::text,
    'google_gemini'::text, 'google_docai'::text,
    'self_hosted'::text, 'device'::text]));

comment on column public.ocr_providers.kind is
  'Which wire shape this reader speaks, and therefore which function in '
  'supabase/functions/ocr/index.ts is asked to call it. A shape is a '
  'row rather than a release. `google_gemini` is Gemini''s own API, '
  'added by 0701 because the OpenAI-compatibility endpoint it used to '
  'be on cannot carry a document part -- which is the whole reason '
  'Gemini appeared not to read PDFs. 0586, 0701.';

update public.ocr_providers
   set kind     = 'google_gemini',
       endpoint = 'https://generativelanguage.googleapis.com/v1beta',
       blurb    =
         'Google''s Gemini, through its own API. Reads PDFs as '
         'documents rather than as pictures, and is quick and cheap on '
         'an ordinary bill. Needs a key from aistudio.google.com.'
 where code = 'gemini';

-- ---------------------------------------------------------------------
-- And the prediction stops predicting a refusal that will not happen
--
-- `app.reader_reads_pdf` is what `pdfBlock` and `rescanChoices` read.
-- Restated from `0697` with one arm added; everything else is that
-- function unchanged.
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
           -- `readGemini` sends `inline_data` with whatever mime type
           -- the file has. `0701`.
           when 'google_gemini' then true
           -- `readOpenAiShaped` refuses it by name. Chat-completions
           -- takes images; a document would be a different endpoint on
           -- every vendor wearing this shape -- ChatGPT and Grok, and
           -- Gemini until `0701` moved it off this shape onto its own.
           when 'openai'      then false
           -- Document AI is a document reader. A PDF is its first case.
           when 'google_docai' then true
           -- Handed the bytes and the mime type, and it answers for
           -- itself. A platform that stood one up and pointed the
           -- catalog at it knows what it accepts; refusing on its
           -- behalf here would refuse the reader that most likely
           -- does.
           when 'self_hosted' then true
           -- Not the database's to say; see `0697`.
           when 'device'      then null
           -- A kind this function has not heard of. Null rather than
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
  'knows which. 0697, 0701.';

-- =====================================================================
-- And the capability stops being a rule and becomes a fact
--
-- Asked for straight after the above: "i want all ai for ai smartscan
-- to also accept pdf and all possible format".
--
-- Which a `case` on the KIND cannot deliver, and the reason is worth
-- stating. What a vendor accepts is not a property of the wire shape;
-- it is a property of that vendor, on that day. ChatGPT and Grok both
-- speak chat-completions, and that shape now carries a `file` part --
-- OpenAI's own SDK types spell it `{ type: "file", file: { filename,
-- file_data } }`, so `readOpenAiShaped` sends one for a PDF instead of
-- refusing. Whether xAI honours the same part is xAI's answer and not
-- ours, and the day it does, nobody should have to wait for a release.
--
-- So `reads_pdf` is a COLUMN a platform operator sets per reader, and
-- the kind is only the default when nobody has said. Null means "ask
-- the shape", which is every row until somebody decides otherwise --
-- so this changes no behaviour by itself.
-- =====================================================================

alter table public.ocr_providers
  add column if not exists reads_pdf boolean;

comment on column public.ocr_providers.reads_pdf is
  'Whether THIS reader opens a PDF, overriding what its kind implies. '
  'Null means the kind decides -- `app.reader_reads_pdf` -- which is '
  'the answer for every reader nobody has had a reason to override. '
  'Set it when a vendor ships document support ahead of its shape, or '
  'withdraws it. 0701.';

create or replace function app.provider_reads_pdf(p public.ocr_providers)
returns boolean
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select coalesce(p.reads_pdf, app.reader_reads_pdf(p.kind));
$$;

comment on function app.provider_reads_pdf(public.ocr_providers) is
  'What `ocr_status` sends the app as `reads_pdf`: the reader''s own '
  'answer where the platform has given one, and the shape''s answer '
  'otherwise. One expression, named, because `ocr_status` reports it '
  'and anything that refuses on it has to agree -- three copies of a '
  'test is three chances for a reader to be offered by one and refused '
  'by another. 0701.';

-- ChatGPT, on the evidence rather than on the shape. The `file` part is
-- in OpenAI's published SDK types; Grok is left to inherit `false` from
-- the shape, because xAI documents no such part and a promise nobody
-- has checked is worse than the sentence it replaces.
update public.ocr_providers set reads_pdf = true where code = 'openai';

-- ---------------------------------------------------------------------
-- `ocr_status`, asking the reader rather than the shape
--
-- Restated from `0697` with one call changed.
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
                        -- The READER's answer, not the shape's. 0701.
                        'reads_pdf', app.provider_reads_pdf(p),
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

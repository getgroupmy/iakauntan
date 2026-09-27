-- =====================================================================
-- iAkauntan :: 0703 the reader that is here when the one you chose is not
--
-- Two reports, one sentence: "why csnt read with local and when the ai
-- model is not reachable it should read with local".
--
-- ---------------------------------------------------------------------
-- Why it could not read with Local Read
--
-- `0700` put the on-device reader on the "Read it with" list, which was
-- right: the app can read the file here, with no key and no charge, and
-- the list had been built out of what the SERVER would accept rather
-- than out of what can actually read a document.
--
-- The reading then worked and the RECORDING was refused:
--
--     PostgrestException(message: This organization reads documents
--     with Gemini, not on the device, code: 23514)
--
-- `ocr_record_local` has asked one question since `0113`: is the
-- COMPANY'S reader an on-device one? That was the whole of the truth
-- when the only way to read locally was to be set to the local reader.
-- `0700` made it a per-document choice, and the guard went on answering
-- the question nobody was asking any more.
--
-- The guard was never about money. It exists so a server reader cannot
-- be logged as a free local one -- and the reading this refuses really
-- did happen on the device, which is why `0682`'s own header says "It
-- costs the platform nothing". What protects the platform here is the
-- module (`app.require_smartscan`) and the company's own switch, and
-- both stay exactly where they were.
--
-- So the question changes from "is the company set to a device reader"
-- to "is there a device reader for this to be recorded against", and
-- the row records THAT reader rather than the one in the settings. A
-- company on Gemini that read one bill here has a scan row saying
-- Gemini, which is the inbox stating as fact something that did not
-- happen.
--
-- ---------------------------------------------------------------------
-- Which reader the row names
--
-- `app.device_ocr_reader()` rather than a parameter. The app does not
-- name the reader it used because there is one to name: the catalog has
-- had a single `runs_on_device` row since `0113` and the engine behind
-- it is chosen by the platform the app is running on -- ML Kit on a
-- phone, Tesseract and `pdf.js` in a browser. The day the platform
-- stands up a second on-device engine is the day this wants an argument
-- rather than a lookup, and it is not today: a parameter added now
-- would be a signature change, a PostgREST overload pair and a grant to
-- keep, in exchange for choosing between one thing.
--
-- ---------------------------------------------------------------------
-- And the second half: when the chosen reader will not answer
--
-- The fallback the app now makes is not written here on purpose.
-- `0679`'s `ocr_fallback` deliberately excludes device readers -- `and
-- not p.runs_on_device` -- because the edge function cannot run one:
-- the file would have to come back to the machine that sent it. So
-- "read it here instead" is a decision only the app can make, and it
-- makes it on a STATUS rather than on the wording of a message. What
-- this migration owes that path is the thing it was missing: somewhere
-- to record the reading when it works.
-- =====================================================================

-- The reader that is this machine, as far as the catalog knows.
--
-- Null when the platform has retired it, which is a real answer and not
-- an error: `ocr_record_local` says what it means by it.
create or replace function app.device_ocr_reader()
returns text
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
  select p.code
    from public.ocr_providers p
   where p.is_active
     and coalesce(p.runs_on_device, false)
   -- Deterministic, so two readings of the same document on the same
   -- day cannot disagree about which reader made them. `sort_order` is
   -- the platform's own ordering and `code` settles a tie.
   order by p.sort_order, p.code
   limit 1;
$$;

comment on function app.device_ocr_reader() is
  'The code of the reader that runs in the app, or null if the platform '
  'has retired it. One row today; an argument the day there are two. 0703.';

revoke all on function app.device_ocr_reader() from public;
grant execute on function app.device_ocr_reader() to authenticated;

-- ---------------------------------------------------------------------
-- The phone's door, and the browser's, and the laptop's
-- ---------------------------------------------------------------------
--
-- Everything above the reader question is `0699`'s, unchanged and
-- deliberately so: the module, the company's switch, the tenancy of the
-- attachment and the sentence each of them refuses with are all
-- asserted elsewhere, and rewording a refusal while moving a function
-- is how a test that was protecting something starts protecting
-- nothing.
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
  v_code text;
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

  -- The company's own reader first, because a company set to Local Read
  -- must keep recording against Local Read whatever else the catalog
  -- holds -- and because that is the only case this function had before
  -- `0700`, and it has to behave identically.
  select * into pr from public.ocr_providers where code = s.provider;
  if coalesce(pr.runs_on_device, false) then
    v_code := s.provider;
  else
    -- A reading made HERE by a company whose setting points at a
    -- server: "Read it with → Local Read", or the app rescuing a
    -- document its reader would not answer for. Refused until `0703`
    -- with `0113`'s sentence, after the file had already been read.
    v_code := app.device_ocr_reader();
  end if;

  -- `0113`'s errcode, and the only thing that can still raise it: the
  -- platform has no reader that runs in the app at all, so there is
  -- nothing to file this against. Nobody should reach it -- the app
  -- offers Local Read off the same catalog -- and it is a refusal
  -- rather than a row naming a reader that did not read.
  if v_code is null then
    raise exception
      'This platform has no reader that runs on the device, so there is nothing to record this reading against'
      using errcode = '23514';
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
  values (p_org_id, p_attachment_id, v_path, v_code, 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$$;

comment on function public.ocr_record_local(uuid, uuid, jsonb, text) is
  'Records a reading that happened in the app: no key, no charge, and '
  'the file never left the machine. The row names the DEVICE reader, '
  'not the company''s setting, because a company on a server reader may '
  'read one document here -- "Read it with → Local Read", or the app '
  'falling back when its reader will not answer. Needs can_write, the '
  'module, and scanning switched on. 0112, 0113, 0682, 0699, 0703.';

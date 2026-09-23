-- =====================================================================
-- iAkauntan :: which readers open a PDF
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reader_reads_pdf.sql
--
-- `0697`. From a report, with the PDF attached: a supplier bill was
-- uploaded into AI SmartScan by a company on Gemini and the inbox came
-- back "This reader takes photographs, not PDFs." That refusal is
-- correct and lives in `supabase/functions/ocr/index.ts` -- the
-- complaint is that it arrives after an upload, after a charge and
-- after a refund, for a question the app could have answered before
-- the file was chosen.
--
-- So the answer is sent to the app, and what has to be true of it:
--
--   * THE OPENAI SHAPE SAYS NO. Gemini, ChatGPT and Grok are all
--     `kind = openai` -- three vendors wearing one shape -- and
--     `readOpenAiShaped` refuses a PDF by name for all three. A `true`
--     here is a promise the edge function will break.
--   * CLAUDE SAYS YES, or the sentence the refusal offers as the way
--     out leads somewhere that refuses too.
--   * DEVICE SAYS NEITHER. `pdf.js` in a browser opens one and ML Kit
--     on a phone does not, so the database declines rather than
--     sending a `true` that is a lie on every phone.
--   * AND IT REACHES THE APP. A rule computed correctly and left in
--     the database is the state this commit found.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org  uuid;
  v_rows jsonb;
  v_one  jsonb;
  v_n    integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kertas PDF Sdn Bhd');

  -- -------------------------------------------------------------------
  -- 1. The function, per kind
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'the anthropic shape opens a PDF',
    app.reader_reads_pdf('anthropic') is true);

  perform pg_temp.check_true(
    'the chat-completions shape does not',
    app.reader_reads_pdf('openai') is false);

  perform pg_temp.check_true(
    'Document AI opens one',
    app.reader_reads_pdf('google_docai') is true);

  perform pg_temp.check_true(
    'a reader run in-house answers for itself',
    app.reader_reads_pdf('self_hosted') is true);

  -- Null, not false. A false would put "this reader takes photographs,
  -- not PDFs" in front of somebody in a BROWSER, where the PDF reader
  -- is `pdf.js` and works -- so the database has to decline rather
  -- than guess, and `is null` is the assertion that keeps it declining.
  perform pg_temp.check_true(
    'the on-device reader is not the database''s to answer for',
    app.reader_reads_pdf('device') is null);

  -- A kind added to the catalog before this function hears of it.
  -- Null again: the app treats unknown as "try it", and the edge
  -- function is the real gate. A false would silently withdraw a
  -- reader the platform had just added.
  perform pg_temp.check_true(
    'a kind this function has not heard of is not refused on a guess',
    app.reader_reads_pdf('something_new') is null);

  -- -------------------------------------------------------------------
  -- 2. Every seeded reader, against its own kind
  --
  -- Not a restatement of part 1: this walks the actual catalog, so a
  -- reader added with a kind nobody wired up shows here rather than in
  -- a snackbar.
  -- -------------------------------------------------------------------
  select count(*) into v_n from public.ocr_providers p
   where p.kind = 'openai' and app.reader_reads_pdf(p.kind) is not false;
  if v_n <> 0 then
    raise exception
      '% chat-completions readers claim to open a PDF', v_n;
  end if;

  -- And there is more than one of them, or the assertion above is
  -- about a catalog with nothing in it. Gemini, ChatGPT and Grok.
  select count(*) into v_n from public.ocr_providers where kind = 'openai';
  if v_n < 3 then
    raise exception
      'only % readers wear the chat-completions shape; the assertion '
      'above is about an empty catalog', v_n;
  end if;

  -- -------------------------------------------------------------------
  -- 3. It reaches the app
  -- -------------------------------------------------------------------
  update public.ocr_providers set is_active = true
   where code in ('claude', 'gemini', 'mlkit');

  v_rows := public.ocr_status(v_org) -> 'providers';

  select p into v_one from jsonb_array_elements(v_rows) p
   where p ->> 'code' = 'gemini';
  if v_one is null then
    raise exception 'the status does not list Gemini at all';
  end if;
  if (v_one -> 'reads_pdf') is distinct from to_jsonb(false) then
    raise exception
      'the status says Gemini reads_pdf = %', v_one -> 'reads_pdf';
  end if;

  select p into v_one from jsonb_array_elements(v_rows) p
   where p ->> 'code' = 'claude';
  if (v_one -> 'reads_pdf') is distinct from to_jsonb(true) then
    raise exception
      'the status says Claude reads_pdf = %', v_one -> 'reads_pdf';
  end if;

  -- The on-device reader carries the KEY with a json null in it, not a
  -- missing key. The app reads "the key is absent" and "the answer is
  -- null" the same way, but a missing key would mean the migration had
  -- dropped the field rather than declined to answer, and only one of
  -- those is on purpose.
  select p into v_one from jsonb_array_elements(v_rows) p
   where p ->> 'code' = 'mlkit';
  if not (v_one ? 'reads_pdf') then
    raise exception 'the on-device reader has no reads_pdf key at all';
  end if;
  if (v_one -> 'reads_pdf') is distinct from 'null'::jsonb then
    raise exception
      'the on-device reader answers reads_pdf = %', v_one -> 'reads_pdf';
  end if;

  raise notice 'reader_reads_pdf: the app can predict the refusal';
end $$;

rollback;

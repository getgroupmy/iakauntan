-- =====================================================================
-- iAkauntan :: 0586 a reader you run yourself
--
-- Asked to use MinerU, PaddleOCR, OCRmyPDF and Tesseract to improve
-- document scanning. Two of those were already answered and the other
-- two could not be embedded, so what this adds is the way in for all of
-- them at once.
--
--   * TESSERACT is already the free on-device reader: `text_reader_web`
--     runs tesseract.js in the browser and the file never leaves the
--     machine.
--   * OCRMYPDF's job is already done on web. The browser pulls text out
--     of a PDF with the bundled pdf.js and, when the text is thin
--     enough to mean the page is a photograph in a wrapper, renders it
--     and reads it. Its remaining trick is writing a searchable layer
--     back INTO the PDF, which this product does not want: it keeps the
--     fields, not a rewritten file.
--   * MINERU and PADDLEOCR are real improvements -- Paddle for Chinese
--     text and receipt tables, MinerU for PDFs with structure. Neither
--     can be embedded: both are Python with model weights, and the edge
--     function is Deno.
--
-- So the useful thing is not three integrations. It is one protocol.
--
-- ---------------------------------------------------------------------
-- One kind, not one per project
--
-- `ocr_providers.kind` is what the edge function switches on, and it
-- has been the vendor's protocol: anthropic, openai, google_docai.
-- `self_hosted` is a fourth, and it is the first that names no vendor
-- at all -- it means "an endpoint the operator runs, answering the
-- shape in docs/ocr-self-hosted.md".
--
-- The four projects differ in how they read a page, not in what this
-- system needs back. A branch each would be four ways of saying the
-- same thing, and the fifth project would need a fifth. A container
-- that honours the contract is a catalog row and no code at all.
--
-- Everything else already works unchanged, which is the point of having
-- had a catalog: `ocr_begin` still takes the charge before a byte
-- leaves, `ocr_finish` still refunds a failure, the permission is still
-- the caller's, and the key still lives in a secret or the
-- organization's own credential rather than here.
--
-- ---------------------------------------------------------------------
-- The three rows ship INACTIVE and with no endpoint
--
-- A reader nobody has deployed is a reader that cannot work, and a row
-- offering it in the console would be a door with nothing behind it --
-- the same mistake as a passkey button with no way to enrol. The
-- operator sets the endpoint and switches the row on, in that order.
--
-- Price is 0 on all three, and that is not a placeholder: the whole
-- reason to run one of these is that the marginal cost of a scan is
-- your own electricity. An operator who wants to charge for it can.
-- =====================================================================

alter table public.ocr_providers
  drop constraint ocr_providers_kind_check;

alter table public.ocr_providers
  add constraint ocr_providers_kind_check
  check (kind = any (array[
    'anthropic'::text, 'openai'::text, 'google_docai'::text,
    'self_hosted'::text, 'device'::text]));

comment on column public.ocr_providers.kind is
  'The protocol the edge function speaks to this reader, and the only '
  'thing it switches on — never the code, so a new reader of a known '
  'shape is a row rather than a release. `self_hosted` is the one that '
  'names no vendor: it means an endpoint the operator runs, answering '
  'the shape in `docs/ocr-self-hosted.md`, which is how MinerU, '
  'PaddleOCR, OCRmyPDF or anything else gets used.';

comment on column public.ocr_providers.endpoint is
  'Where to reach the reader. Null for a vendor whose address is fixed '
  'and known to the function. REQUIRED for `self_hosted`, where there '
  'is no sensible default and the function refuses without one.';

insert into public.ocr_providers
  (code, name, kind, endpoint, model, price, takes_key, runs_on_device,
   blurb, is_active, sort_order)
values
  ('mineru', 'MinerU (self-hosted)', 'self_hosted', null, null, 0,
   true, false,
   'Layout-aware reading for PDFs with real table structure. Runs on '
   'your own machine, so nothing is sent to a vendor and a scan costs '
   'your electricity. Set the endpoint before switching it on.',
   false, 300),
  ('paddleocr', 'PaddleOCR (self-hosted)', 'self_hosted', null, null, 0,
   true, false,
   'Strong on Chinese text and on receipt tables, where a general '
   'reader tends to lose columns. Runs on your own machine. Set the '
   'endpoint before switching it on.',
   false, 310),
  ('ocrmypdf', 'OCRmyPDF (self-hosted)', 'self_hosted', null, null, 0,
   true, false,
   'Reads scanned PDFs that carry no text. The browser already does '
   'this for most files; this is for volume, and for the phone, which '
   'cannot open a PDF at all. Set the endpoint before switching it on.',
   false, 320)
on conflict (code) do nothing;

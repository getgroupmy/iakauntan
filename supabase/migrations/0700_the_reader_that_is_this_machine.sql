-- =====================================================================
-- iAkauntan :: 0700 the reader that is this machine
--
-- Asked for from the SmartScan screen: "also add in the reader list
-- Local Read".
--
-- The on-device reader has been on the catalog since `0113` under the
-- name "On this device", and the list this request is about -- the
-- readers a scan can be sent to AGAIN, `0698` -- left it out. That was
-- deliberate and it was wrong in one direction: `ocr_begin` refuses a
-- device reader because there is nothing for the SERVER to do with one,
-- and the list was built from what the server would accept rather than
-- from what can actually read the file. The app can read it here,
-- without the server, and that is the whole point of the reader.
--
-- What this migration changes is only the NAME, because the name is
-- what the request was about and because "On this device" reads as a
-- statement about where rather than as a thing you can choose.
--
-- ---------------------------------------------------------------------
-- And the blurb was wrong twice over
--
-- It said "needs the phone app". A browser reads too -- Tesseract for a
-- photograph, `pdf.js` for a PDF -- and the browser is the side that
-- reads PDFs, which is the opposite of what the sentence implied. A
-- company reading the blurb on a laptop was being told the reader in
-- front of them would not work.
--
-- Updated rather than left, because `ocr_status` carries this string to
-- the tenant settings screen and it is the only description of this
-- reader anybody sees.
--
-- `update` and not `insert ... on conflict`: the row has existed since
-- `0113` and a company may be on it right now.
-- =====================================================================

update public.ocr_providers
   set name = 'Local Read',
       blurb =
         'Free, and the file never leaves this machine. Reads the '
         'printing rather than understanding the document, so it is '
         'best on a clear photograph. A browser also reads a typed '
         'PDF; a phone reads photographs only.'
 where code = 'mlkit';

comment on column public.ocr_providers.runs_on_device is
  'The reading happens in the app, not on a server: no key, no charge, '
  'and the file is never sent anywhere. `ocr_begin` refuses one of '
  'these because there is nothing for the server to do -- but the APP '
  'can be asked for it directly, which is what "Read it with" offers '
  'since 0700.';

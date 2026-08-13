-- =====================================================================
-- iAkauntan :: 0114 the free reader now runs in a browser too
--
-- The on-device reader was ML Kit and therefore the phone app only, and
-- the catalog row said so. Tesseract compiled to WebAssembly fills the
-- other half: same bargain — open source, no key, no per-scan charge,
-- and the photograph decoded on the machine in front of the person —
-- and now it holds wherever the app is opened.
--
-- Nothing structural changes, and that is the point of having made the
-- readers data in 0113. One row's name and description, because what
-- was true of it stopped being true. The paid readers are untouched:
-- this is the free option sitting beside them, not instead of them.
--
-- The engine and its language model are served from our own origin
-- rather than a CDN — see `app/web/tesseract/`. A reader that phoned a
-- third party on every scan would give away the thing it exists to
-- protect.
-- =====================================================================

update public.ocr_providers
   set name = 'On this device (free)',
       blurb =
         'Free, and the photograph never leaves the machine it was taken '
         'on — ML Kit in the phone app, Tesseract in a browser, both '
         'served from us. No key, no credit, no third party. Reads the '
         'printing rather than understanding the document, and cannot '
         'open a PDF.',
       updated_at = now()
 where code = 'mlkit';

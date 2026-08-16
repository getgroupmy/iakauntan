-- The `logos` bucket takes images, and only images.
--
-- It is the one public bucket — `logos_read` is `for select using
-- (bucket_id = 'logos')` with no further condition, because a logo has
-- to render in an invoice PDF and in a share link opened by somebody
-- with no account. That is right. What was not right is that it accepted
-- **any** content type, and Supabase Storage serves an object back with
-- the content type it was stored under.
--
-- `uploadOrgLogo(bytes, contentType)` passes the type straight from the
-- picked file, so the value is the client's to choose. A modified client
-- belonging to any company on the platform could store an
-- `image/svg+xml` — SVG carries `<script>` — or a `text/html`, and get a
-- stable public URL for it on `<project>.supabase.co`.
--
-- The bound on that is worth being accurate about: it is *not* stored
-- XSS against this application. The bundle is served from the app's own
-- domain and the storage host is a different origin, so script running
-- there reaches no session, no token and no localStorage of ours. What
-- it does give is an attacker-controlled page on a hostname that looks
-- like part of this service — a phishing page for the app's own sign-in
-- screen is the obvious use — and that is worth closing for the cost of
-- one column.
--
-- The three types below are exactly what the picker in
-- `company_card.dart` offers: png, jpg/jpeg, webp. SVG is deliberately
-- not among them; it is the one image format that is also a program.
--
-- The 5 MB cap was already set, and the private buckets — `attachments`
-- and `chat` — are left as they are: they take whatever a business
-- genuinely files, from a supplier's PDF to a photograph of a receipt,
-- and they are not public, so the same reasoning does not apply.

update storage.buckets
   set allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']
 where id = 'logos';

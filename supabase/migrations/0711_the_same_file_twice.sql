-- =====================================================================
-- iAkauntan :: 0711 the same file, twice
--
-- Asked for as "when the bank statement or ai scan or any file is
-- uploaded it should keep a copy of the file in storage so it can be
-- used back as[well as] will prevent duplicate upload of same file".
--
-- The first half was already true. `attachments` has kept every upload
-- since `0010`, the bytes live in the `attachments` bucket, and `0708`
-- refuses to DELETE a file once a reading or a posting has been built
-- from it. Nothing has ever been thrown away.
--
-- The second half was not true at all, because nothing anywhere knew
-- what a file CONTAINED. Upload the same statement twice and it became
-- a second row, a second object in the bucket, and a second scan --
-- which is a second charge to whichever reader the organization pays
-- for. `import_bank_transactions` still refuses to post a line it has
-- already posted, so the books stayed right; what was wasted was money
-- and what was lost was the person's confidence that anything had been
-- noticed.
--
-- ---------------------------------------------------------------------
-- Why a hash and not a name
--
-- `file_name` is already stamped with a timestamp by `0708`, so two
-- uploads of one file never share a name. `file_size` alone is a
-- coincidence waiting to happen. The only question worth asking is
-- whether the BYTES are the same, and SHA-256 answers exactly that:
-- identical content, or not, with no judgement in between and no false
-- positive to explain to somebody whose two statements happen to be the
-- same length.
--
-- ---------------------------------------------------------------------
-- NULLABLE, and it stays nullable
--
-- Every row that exists today has no hash and cannot be given one
-- without downloading every stored object and reading it back, which is
-- a job this migration deliberately does not do: it would be a long
-- read over a bucket, in a migration, to populate a column whose whole
-- purpose is to help with uploads that have not happened yet.
--
-- So the column is nullable for good, the index is partial, and every
-- lookup is written to find nothing rather than to fail when the hash
-- is absent. Deduplication applies to what is uploaded from here on.
-- Saying that plainly is better than a backfill that looks complete and
-- is not.
--
-- ---------------------------------------------------------------------
-- NOT UNIQUE, on purpose
--
-- A unique index would make the database refuse the second upload, and
-- refusing is wrong. Somebody re-uploads the same file when the first
-- scan went badly and they want another go at it -- which is a thing
-- they are entitled to do, on their own document, for a reason they
-- understand better than this system does. The index is for LOOKING UP,
-- so the app can say "this file is already here, from <date>, filed
-- against <record>" and let the person decide.
-- =====================================================================

alter table public.attachments
  add column if not exists content_sha256 text;

comment on column public.attachments.content_sha256 is
  'SHA-256 of the file''s bytes, lowercase hex, computed by the client '
  'before upload. NULL on every row uploaded before 0711 and on any '
  'upload whose hash could not be taken -- callers must treat NULL as '
  '"unknown", never as "no duplicate".';

-- 64 lowercase hex characters or nothing. A column that quietly accepts
-- an uppercase digest, or a truncated one, is a column where two
-- spellings of the same file do not match each other.
alter table public.attachments
  drop constraint if exists attachments_content_sha256_shape;
alter table public.attachments
  add constraint attachments_content_sha256_shape
  check (content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$');

-- Partial, because most rows will never have one and an index over a
-- column that is mostly null is mostly wasted pages.
--
-- Scoped to the organization: two companies on this platform uploading
-- the same public form is not a duplicate of anything, and one org must
-- never be told a file "already exists" on the strength of a row it is
-- not allowed to see.
create index if not exists attachments_org_content_sha256_idx
  on public.attachments (org_id, content_sha256)
  where content_sha256 is not null;

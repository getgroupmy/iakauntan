-- =====================================================================
-- iAkauntan :: the same file, twice (0711)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/attachment_content_hash.sql
--
-- `content_sha256` is what lets the app say "this file is already here"
-- instead of paying a reader to look at the same statement again. The
-- column is only as good as its shape: a digest stored in a second
-- spelling is a digest that matches nothing, and the failure is silent
-- -- every upload simply looks new for ever.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The column exists, and is nullable for good
-- ---------------------------------------------------------------------
do $$
declare
  v_nullable text;
begin
  select is_nullable into v_nullable
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'attachments'
     and column_name = 'content_sha256';

  perform pg_temp.check_true(
    'attachments.content_sha256 exists', v_nullable is not null);

  -- NOT a mistake and not a TODO. Every row uploaded before `0711` has
  -- no hash and cannot be given one without downloading the object back
  -- out of storage. Making this NOT NULL would either fail on the
  -- existing rows or force a backfill that reads the whole bucket --
  -- and the column exists to help with uploads that have not happened
  -- yet, not to describe the ones that have.
  perform pg_temp.check_eq(
    'content_sha256 stays nullable, for the rows that predate 0711',
    v_nullable, 'YES');
end $$;

-- ---------------------------------------------------------------------
-- 64 lowercase hex characters, or nothing at all
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_ok boolean;
begin
  v_org := pg_temp.test_org('Hash Co');

  -- The shape rule, asserted directly. Two spellings of one digest is
  -- two files that never match each other, and nothing anywhere would
  -- report it.
  select repeat('a', 64) ~ '^[0-9a-f]{64}$' into v_ok;
  perform pg_temp.check_true('a real digest satisfies the shape', v_ok);

  perform pg_temp.check_true(
    'an UPPERCASE digest does not satisfy the shape',
    not (repeat('A', 64) ~ '^[0-9a-f]{64}$'));

  perform pg_temp.check_true(
    'a TRUNCATED digest does not satisfy the shape',
    not (repeat('a', 63) ~ '^[0-9a-f]{64}$'));

  perform pg_temp.check_true(
    'arbitrary text does not satisfy the shape',
    not ('not-a-digest' ~ '^[0-9a-f]{64}$'));
end $$;

-- ---------------------------------------------------------------------
-- And the constraint is actually ON the table, not merely plausible
-- ---------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conname = 'attachments_content_sha256_shape';

  perform pg_temp.check_true(
    'the shape constraint is on attachments', v_def is not null);
  perform pg_temp.check_true(
    'the shape constraint checks hex', v_def ~ '0-9a-f');
  perform pg_temp.check_true(
    'the shape constraint checks length', v_def ~ '64');
end $$;

-- ---------------------------------------------------------------------
-- The index is scoped to the organization, and is NOT unique
-- ---------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select indexdef into v_def
    from pg_indexes
   where schemaname = 'public'
     and indexname = 'attachments_org_content_sha256_idx';

  perform pg_temp.check_true(
    'the lookup index exists', v_def is not null);

  -- ORG FIRST. Two companies on this platform uploading the same public
  -- form are not duplicates of each other, and one org must never be
  -- told a file "already exists" on the strength of a row it is not
  -- allowed to see.
  perform pg_temp.check_true(
    'the index is scoped to the org, so one company is never told a file '
    'already exists on the strength of a row it may not see',
    v_def ~ 'org_id');

  -- NOT UNIQUE, deliberately. A unique index would make the database
  -- REFUSE the second upload -- and somebody re-uploads a file when the
  -- first scan went badly and they want another go, which is a thing
  -- they are entitled to do on their own document. The index is for
  -- looking up so the app can say "this is already here" and let the
  -- person decide.
  perform pg_temp.check_true(
    'the index is NOT unique, so a re-upload is not refused',
    v_def !~* 'unique');

  -- Partial, so the mostly-null column does not cost mostly-wasted
  -- pages.
  perform pg_temp.check_true(
    'the index is partial on the mostly-null column',
    v_def ~ 'content_sha256 IS NOT NULL');
end $$;

rollback;

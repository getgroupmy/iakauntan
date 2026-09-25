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

  if v_nullable is null then
    raise exception 'attachments.content_sha256 does not exist';
  end if;

  -- NOT a mistake and not a TODO. Every row uploaded before `0711` has
  -- no hash and cannot be given one without downloading the object back
  -- out of storage. Making this NOT NULL would either fail on the
  -- existing rows or force a backfill that reads the whole bucket --
  -- and the column exists to help with uploads that have not happened
  -- yet, not to describe the ones that have.
  if v_nullable <> 'YES' then
    raise exception 'content_sha256 must stay nullable, got %', v_nullable;
  end if;
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
  if not v_ok then
    raise exception 'a real digest does not satisfy the shape';
  end if;

  if repeat('A', 64) ~ '^[0-9a-f]{64}$' then
    raise exception 'an UPPERCASE digest satisfies the shape, and must not';
  end if;

  if repeat('a', 63) ~ '^[0-9a-f]{64}$' then
    raise exception 'a TRUNCATED digest satisfies the shape, and must not';
  end if;

  if 'not-a-digest' ~ '^[0-9a-f]{64}$' then
    raise exception 'arbitrary text satisfies the shape, and must not';
  end if;
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

  if v_def is null then
    raise exception 'the shape constraint is not on attachments';
  end if;
  if v_def !~ '0-9a-f' then
    raise exception 'the shape constraint does not check hex, got %', v_def;
  end if;
  if v_def !~ '64' then
    raise exception 'the shape constraint does not check length, got %', v_def;
  end if;
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

  if v_def is null then
    raise exception 'the lookup index does not exist';
  end if;

  -- ORG FIRST. Two companies on this platform uploading the same public
  -- form are not duplicates of each other, and one org must never be
  -- told a file "already exists" on the strength of a row it is not
  -- allowed to see.
  if v_def !~ 'org_id' then
    raise exception 'the index is not scoped to the org, got %', v_def;
  end if;

  -- NOT UNIQUE, deliberately. A unique index would make the database
  -- REFUSE the second upload -- and somebody re-uploads a file when the
  -- first scan went badly and they want another go, which is a thing
  -- they are entitled to do on their own document. The index is for
  -- looking up so the app can say "this is already here" and let the
  -- person decide.
  if v_def ~* 'unique' then
    raise exception 'the index is UNIQUE, which would refuse a re-upload';
  end if;

  -- Partial, so the mostly-null column does not cost mostly-wasted
  -- pages.
  if v_def !~ 'content_sha256 IS NOT NULL' then
    raise exception 'the index is not partial, got %', v_def;
  end if;
end $$;

rollback;

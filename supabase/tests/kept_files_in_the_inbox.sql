-- =====================================================================
-- iAkauntan :: a file kept for later, and the list that has to show it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/kept_files_in_the_inbox.sql
--
-- `0714`. The upload button promises a document is "saved for later
-- use". A file uploaded without being read has no `ocr_scans` row, and
-- `scan_inbox` -- the list behind the whole AI SmartScan screen --
-- selected `from public.ocr_scans` alone. So the promise was kept in
-- the bucket and broken in the product: the bytes were safe and the
-- person could not find them anywhere.
--
-- Four things, and the last two are the ones that go wrong quietly:
--
--   1. a kept file appears, with a NULL `scan_id` and nothing invented
--      in the columns that describe a reading
--   2. an ordinary attachment -- one filed against a bill -- does NOT,
--      because unioning `attachments` wholesale would bury the inbox
--      under every file in the system
--   3. a kept file that has SINCE been read appears once, as its scan,
--      not twice
--   4. `posted` excludes it and `unposted` includes it, because a kept
--      file has become nothing by definition
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A file in the bucket, as `uploadAttachment` writes one.
create or replace function pg_temp.a_file(
  p_org uuid, p_name text, p_kept boolean, p_table text default 'expenses')
returns uuid language plpgsql as $$
declare v_id uuid; v_rec uuid := gen_random_uuid();
begin
  -- A trigger refuses a row whose object key disagrees with its
  -- columns, so the path is built from them rather than made up.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size, kept_at)
  values (p_org, p_table, v_rec, p_name,
          p_org || '/' || p_table || '/' || v_rec || '/' || p_name,
          'application/pdf',
          1024, case when p_kept then now() else null end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. A kept file is in the pile, and claims nothing about a reading
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Simpan Dulu Sdn Bhd');
  v_att uuid;
  r     record;
begin
  v_att := pg_temp.a_file(v_org, 'august-statement.pdf', true);

  select * into r from public.scan_inbox(v_org, 100, 'all');

  perform pg_temp.check_eq('the kept file is in the inbox',
    r.attachment_id, v_att);
  perform pg_temp.check_true('and its scan id is null, because there is no scan',
    r.scan_id is null);
  perform pg_temp.check_eq('it is named by its own file name',
    r.file_name, 'august-statement.pdf');
  -- Every column that describes a READING. A provider or a status
  -- invented here would answer "why was I charged" about something
  -- nobody was charged for.
  perform pg_temp.check_true('no provider is claimed', r.provider is null);
  perform pg_temp.check_true('no status is claimed', r.status is null);
  perform pg_temp.check_true('no error is claimed', r.error is null);
  perform pg_temp.check_true('and it became nothing',
    r.posted_table is null);
  -- What the list sorts by.
  perform pg_temp.check_true('it is dated by when it was kept',
    r.scanned_at is not null);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. An ordinary attachment stays out of it
--
-- The failure this prevents is the inbox filling with every e-Invoice
-- PDF, every bill's scan and every logo anybody ever uploaded.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Lampiran Biasa Sdn Bhd');
  v_n   integer;
begin
  perform pg_temp.a_file(v_org, 'a-bill.pdf', false);
  perform pg_temp.a_file(v_org, 'a-logo.png', false);

  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'all');
  perform pg_temp.check_eq('an attachment nobody kept is not in the inbox',
    v_n, 0);

  perform pg_temp.a_file(v_org, 'kept.pdf', true);
  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'all');
  perform pg_temp.check_eq('and only the kept one arrives', v_n, 1);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Read since, and it is one row rather than two
--
-- `kept_at` is not cleared when a file is finally read -- it is a
-- record of how the file arrived, and clearing it would be rewriting
-- that. So the union has to exclude it, and forgetting to would show
-- one sheet of paper twice with two different stories about it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Dibaca Kemudian Sdn Bhd');
  v_att uuid;
  v_n   integer;
  r     record;
begin
  v_att := pg_temp.a_file(v_org, 'statement.pdf', true);

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status)
  values (v_org, v_att, 'x/y/z', 'gemini', 'platform', 'ok');

  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'all');
  perform pg_temp.check_eq('one sheet of paper, one row', v_n, 1);

  select * into r from public.scan_inbox(v_org, 100, 'all');
  perform pg_temp.check_true('and it is the scan, which knows more',
    r.scan_id is not null);
  perform pg_temp.check_eq('with the reader that read it',
    r.provider, 'gemini');
  perform pg_temp.check_true('the file is still marked as kept',
    (select kept_at is not null from public.attachments where id = v_att));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. The filters
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tapisan Sdn Bhd');
  v_n   integer;
begin
  perform pg_temp.a_file(v_org, 'kept.pdf', true);

  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'unposted');
  perform pg_temp.check_eq('a kept file became nothing, so it is unposted',
    v_n, 1);

  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'posted');
  perform pg_temp.check_eq('and never posted', v_n, 0);

  select count(*)::integer into v_n from public.scan_inbox(v_org, 100, 'all');
  perform pg_temp.check_eq('and Everything means everything', v_n, 1);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Another company's kept file is not in this one's pile
-- ---------------------------------------------------------------------
do $$
declare
  v_mine  uuid := pg_temp.test_org('Saya Sdn Bhd');
  v_other uuid := pg_temp.test_org('Orang Lain Sdn Bhd');
  v_n     integer;
begin
  perform pg_temp.a_file(v_other, 'theirs.pdf', true);
  select count(*)::integer into v_n from public.scan_inbox(v_mine, 100, 'all');
  perform pg_temp.check_eq('somebody else''s kept file is not mine', v_n, 0);
end;
$$;

rollback;

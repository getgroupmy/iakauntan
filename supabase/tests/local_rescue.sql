-- =====================================================================
-- iAkauntan :: reading it here, when the reader you chose is elsewhere
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/local_rescue.sql
--
-- `0703`. Two things reach `ocr_record_local` that could not reach it
-- before:
--
--   * "Read it with → Local Read" on a company whose setting points at
--     a server reader (`0700` put it on the list; the recording still
--     refused it, AFTER the file had been read);
--   * the app falling back to this machine when the chosen reader will
--     not answer.
--
-- Both are the same question to the database: a reading happened on the
-- device and there is nowhere to put it. What must NOT change with them
-- is everything that was protecting the platform -- the module, the
-- company's switch, `can_write`, the tenancy of the attachment, and the
-- fact that a local reading moves no money. Those are asserted here
-- alongside the new behaviour, because the way this goes wrong is a
-- guard being dropped along with the one that was in the way.
--
-- And the row has to name the reader that ACTUALLY READ IT. A company
-- on Gemini that read one bill here must not have a scan row saying
-- Gemini; that is the inbox stating as fact something that did not
-- happen.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_receipt(p_org uuid, p_file text)
returns uuid language plpgsql as $$
declare
  v_entity uuid := gen_random_uuid();
  v_id     uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'expenses', v_entity, p_file,
          format('%s/expenses/%s/%s', p_org, v_entity, p_file),
          'image/jpeg', 120000)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. A company on a server reader may read one document here
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_file   uuid;
  v_scan   uuid;
  v_code   text;
  v_source text;
  v_paid   numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Baca Sendiri Sdn Bhd');
  v_file := pg_temp.a_receipt(v_org, 'resit.jpg');

  update public.ocr_providers
     set is_active = true, model = 'x', endpoint = 'https://e'
   where code = 'gemini';
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');

  -- The refusal this migration exists to remove. Before `0703` this
  -- raised `23514` -- 'This organization reads documents with Gemini,
  -- not on the device' -- and it raised it after the app had already
  -- read the file, so the reading was thrown away rather than filed.
  v_scan := public.ocr_record_local(v_org, v_file,
    '{"supplier_name":"99 Speedmart","total_amount":33.91}'::jsonb);
  perform pg_temp.check_true('a local reading is filed on a server company',
    v_scan is not null);

  select provider, key_source, amount_charged
    into v_code, v_source, v_paid
    from public.ocr_scans where id = v_scan;

  -- The reader that read it, not the one in the settings.
  perform pg_temp.check_eq('and names the reader that actually read it',
    v_code, 'mlkit');
  perform pg_temp.check_eq('as a reading made on the device',
    v_source, 'device');
  perform pg_temp.check_eq('costing nothing, because it cost nothing',
    v_paid, 0);
  perform pg_temp.check_eq('and moving no money',
    (select count(*) from public.credit_ledger where org_id = v_org), 0);

  -- Reading one document here is not changing the reader. The next
  -- capture still goes to Gemini, and a company that came back to find
  -- itself switched to Local Read would have been switched by us.
  perform pg_temp.check_eq('reading here does not change the setting',
    public.ocr_status(v_org) ->> 'provider', 'gemini');

  -- A company already ON the device reader is the case that worked
  -- before `0703`, and it has to go on working identically.
  perform public.set_ocr_settings(v_org, true, 'mlkit', 'platform');
  v_scan := public.ocr_record_local(v_org, v_file, '{}'::jsonb);
  perform pg_temp.check_eq('a company set to Local Read is unchanged',
    (select provider from public.ocr_scans where id = v_scan), 'mlkit');

  raise notice 'local rescue: a reading made here is filed against the reader that made it';
end $$;

-- ---------------------------------------------------------------------
-- 2. A failed local reading is still a row
-- ---------------------------------------------------------------------
--
-- "Why is this figure blank" and "why was nothing read" are the same
-- question asked twice, and the row is what answers both. The app
-- records a failure on the fallback path too -- a machine that could
-- not read the file it rescued is exactly what somebody would want to
-- find later.
do $$
declare
  v_org  uuid;
  v_file uuid;
  v_scan uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Gagal Baca Sdn Bhd');
  v_file := pg_temp.a_receipt(v_org, 'kabur.jpg');

  update public.ocr_providers
     set is_active = true, model = 'x', endpoint = 'https://e'
   where code = 'claude';
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');

  v_scan := public.ocr_record_local(v_org, v_file, null, 'nothing legible');
  perform pg_temp.check_eq('a failed local reading is filed as failed',
    (select status from public.ocr_scans where id = v_scan), 'failed');
  perform pg_temp.check_eq('against the device reader',
    (select provider from public.ocr_scans where id = v_scan), 'mlkit');
  perform pg_temp.check_eq('and still costs nothing',
    (select amount_charged from public.ocr_scans where id = v_scan), 0);
end $$;

-- ---------------------------------------------------------------------
-- 3. Everything that was still protecting the platform
-- ---------------------------------------------------------------------
--
-- The guard `0703` removes was in the way of a real reading. These were
-- never in the way of anything, and the way this change goes wrong is
-- one of them leaving with it.
do $$
declare
  v_org     uuid;
  v_file    uuid;
  v_other   uuid;
  v_theirs  uuid;
  v_stranger uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Pagar Sdn Bhd');
  v_file := pg_temp.a_receipt(v_org, 'resit.jpg');
  update public.ocr_providers
     set is_active = true, model = 'x', endpoint = 'https://e'
   where code = 'gemini';
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');

  -- The company's own switch. Off is off, whoever is reading and
  -- wherever the reading happened.
  perform public.set_ocr_settings(v_org, false);
  perform pg_temp.check_refused(
    'scanning switched off still refuses a local reading',
    format('select public.ocr_record_local(%L, %L)', v_org, v_file),
    '%switched off%', '42501');
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');

  -- The module. `smartscan_module.sql` asserts this too, and it is
  -- repeated here because this file is the one that moved the guard
  -- next to it.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'smartscan';
  perform pg_temp.check_refused(
    'and so does a lapsed module',
    format('select public.ocr_record_local(%L, %L)', v_org, v_file),
    '%AI SmartScan is not switched on%', '42501');
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'smartscan';

  -- Somebody else's attachment, on a company they are a member of.
  -- `0702` made this the message it is; the refusal is older.
  v_other  := pg_temp.test_org('Pagar Lain Sdn Bhd');
  v_theirs := pg_temp.a_receipt(v_other, 'bukan-saya.jpg');
  perform pg_temp.check_refused(
    'an attachment from another organization is refused',
    format('select public.ocr_record_local(%L, %L)', v_org, v_theirs),
    '%not on this organization%', '42704');

  -- And a stranger, who is a member of neither.
  v_stranger := pg_temp.another_user('penyusup@contoh.my');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused(
    'and a stranger cannot file a reading at all',
    format('select public.ocr_record_local(%L, %L)', v_org, v_file),
    '%cannot record documents%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- ---------------------------------------------------------------------
-- 4. When the platform has no reader that runs in the app
-- ---------------------------------------------------------------------
--
-- `0113`'s errcode, and the only thing that can still raise it. Nobody
-- should reach it -- the app offers Local Read off this same catalog --
-- and a row naming a reader that did not read would be worse than a
-- refusal.
do $$
declare
  v_org  uuid;
  v_file uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Tiada Tempatan Sdn Bhd');
  v_file := pg_temp.a_receipt(v_org, 'resit.jpg');
  update public.ocr_providers
     set is_active = true, model = 'x', endpoint = 'https://e'
   where code = 'gemini';
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');

  perform pg_temp.check_eq('the device reader is the one on the catalog',
    app.device_ocr_reader(), 'mlkit');

  update public.ocr_providers set is_active = false where code = 'mlkit';
  perform pg_temp.check_true('retiring it leaves nothing to name',
    app.device_ocr_reader() is null);
  perform pg_temp.check_refused(
    'and a local reading is refused rather than filed against nothing',
    format('select public.ocr_record_local(%L, %L)', v_org, v_file),
    '%no reader that runs on the device%', '23514');
  update public.ocr_providers set is_active = true where code = 'mlkit';
end $$;

rollback;

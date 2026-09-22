-- =====================================================================
-- iAkauntan :: what the reader got wrong
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_corrections.sql
--
-- `0684`. The correction a person makes to a reading is the only ground
-- truth this system produces, and the thing that decides whether a
-- cheaper reader is actually cheaper. What has to be true of it:
--
--   * A reading accepted UNCHANGED must be distinguishable from one
--     nobody ever looked at. Those are opposite facts about a reader
--     and the obvious single-column design makes them both null.
--   * A trailing zero is not a correction. `1900` and `1900.00` are the
--     same money, and a reader marked wrong for writing one would bury
--     the real signal under noise that scales with volume.
--   * Neither is a null against an empty string: "the page does not
--     print it" and "I cleared the box" are the same statement.
--   * And the count has to be per FIELD, because readers do not fail
--     evenly. A reader that reads totals perfectly and dates badly
--     wants a better sentence in that field's description, not
--     replacing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.make_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

-- A scan on an attachment, with a reading. Returns the attachment id,
-- because that is what the app is holding when it calls the function.
create or replace function pg_temp.scanned(
  p_org uuid, p_provider text, p_extracted jsonb)
returns uuid language plpgsql as $$
declare
  v_att uuid;
  v_rec uuid := gen_random_uuid();
begin
  -- The path is checked on the way IN, and its third segment must be
  -- the entity id -- so the id is minted first rather than patched up
  -- afterwards.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size, uploaded_by)
  values (p_org, 'purchase_documents', v_rec, 'bill.jpg',
          p_org || '/purchase_documents/' || v_rec || '/bill.jpg',
          'image/jpeg', 100, auth.uid())
  returning id into v_att;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     extracted)
  select p_org, v_att, storage_path, p_provider, 'platform', 'ok',
         p_extracted
    from public.attachments where id = v_att;
  return v_att;
end;
$$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_att   uuid;
  v_diff  text[];
  v_row   record;
  v_rec   uuid;
begin
  perform pg_temp.make_platform_admin(v_owner);
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Corrections Sdn Bhd');

  -- -------------------------------------------------------------------
  -- Three states, not two
  -- -------------------------------------------------------------------
  v_att := pg_temp.scanned(v_org, 'claude', jsonb_build_object(
    'supplier_name', 'Lim Hardware', 'total_amount', 120.00));

  perform pg_temp.check_true(
    'a scan nobody has looked at is unreviewed',
    (select reviewed_at is null from public.ocr_scans
      where attachment_id = v_att));

  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'supplier_name', 'Lim Hardware', 'total_amount', 120.00));

  perform pg_temp.check_eq(
    'accepting it unchanged reports no changed fields',
    cardinality(v_diff), 0);
  perform pg_temp.check_true(
    'and is recorded as reviewed',
    (select reviewed_at is not null from public.ocr_scans
      where attachment_id = v_att));
  perform pg_temp.check_true(
    'with nothing in `corrected`, which is the reader being RIGHT',
    (select corrected is null from public.ocr_scans
      where attachment_id = v_att));
  perform pg_temp.check_true(
    'and by whom',
    (select reviewed_by = v_owner from public.ocr_scans
      where attachment_id = v_att));

  -- -------------------------------------------------------------------
  -- A trailing zero is not a correction
  --
  -- The failure this prevents scales with volume: every reader that
  -- writes `1900` where the dialog shows `1900.00` would be counted
  -- wrong on every scan, and the real corrections would be invisible
  -- underneath.
  -- -------------------------------------------------------------------
  v_att := pg_temp.scanned(v_org, 'claude', jsonb_build_object(
    'total_amount', 1900, 'subtotal', 1792.45));
  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'total_amount', 1900.00, 'subtotal', 1792.4500));
  perform pg_temp.check_eq(
    'the same money written two ways is not a correction',
    cardinality(v_diff), 0);

  -- Nor is a null against an empty string, nor case, nor spacing.
  v_att := pg_temp.scanned(v_org, 'claude', jsonb_build_object(
    'supplier_name', ' Lim Hardware ', 'supplier_email', null));
  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'supplier_name', 'LIM HARDWARE', 'supplier_email', ''));
  perform pg_temp.check_eq(
    'case, spacing and an emptied box are not corrections',
    cardinality(v_diff), 0);

  -- A date written two ways is one date.
  v_att := pg_temp.scanned(v_org, 'claude',
    jsonb_build_object('document_date', '2026-09-03'));
  v_diff := public.ocr_note_correction(v_org, v_att,
    jsonb_build_object('document_date', '2026-09-03'));
  perform pg_temp.check_eq(
    'and neither is the same date', cardinality(v_diff), 0);

  -- -------------------------------------------------------------------
  -- A real correction, named
  -- -------------------------------------------------------------------
  v_att := pg_temp.scanned(v_org, 'gemini', jsonb_build_object(
    'supplier_name', 'Lim Hardware',
    'document_date', '2026-09-03',
    'total_amount', 120.00));
  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'supplier_name', 'Lim Hardware',
    'document_date', '2026-03-09',
    'total_amount', 126.00));

  perform pg_temp.check_eq(
    'a changed date and a changed total are two changed fields',
    cardinality(v_diff), 2);
  perform pg_temp.check_true(
    'named, so a reader that is bad at ONE thing is visible as that',
    v_diff @> array['document_date', 'total_amount']);
  perform pg_temp.check_true(
    'and the field that was right is not among them',
    not (v_diff @> array['supplier_name']));
  perform pg_temp.check_true(
    'the accepted reading is kept',
    (select (corrected ->> 'total_amount')::numeric = 126.00
       from public.ocr_scans where attachment_id = v_att));

  -- The reader's own transcription is not stored twice.
  v_att := pg_temp.scanned(v_org, 'gemini',
    jsonb_build_object('total_amount', 10.00));
  perform public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'total_amount', 11.00, 'raw_text', 'the whole receipt, again'));
  perform pg_temp.check_true(
    'and `raw_text` is stripped rather than stored twice',
    (select corrected ? 'raw_text' = false from public.ocr_scans
      where attachment_id = v_att));

  -- -------------------------------------------------------------------
  -- Lines
  -- -------------------------------------------------------------------
  v_att := pg_temp.scanned(v_org, 'claude', jsonb_build_object('lines',
    jsonb_build_array(
      jsonb_build_object('description', 'Cement', 'quantity', 2,
                         'unit_price', 18.50, 'amount', 37.00))));
  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'cement', 'quantity', 2.0,
                         'unit_price', 18.5, 'amount', 37.0))));
  perform pg_temp.check_eq(
    'the same line written differently is not a corrected line',
    cardinality(v_diff), 0);

  v_att := pg_temp.scanned(v_org, 'claude', jsonb_build_object('lines',
    jsonb_build_array(
      jsonb_build_object('description', 'Cement', 'amount', 37.00))));
  v_diff := public.ocr_note_correction(v_org, v_att, jsonb_build_object(
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Cement', 'amount', 37.00),
      jsonb_build_object('description', 'Sand', 'amount', 12.00))));
  perform pg_temp.check_true(
    'a line the reader missed entirely is a corrected reading',
    v_diff @> array['lines']);

  -- -------------------------------------------------------------------
  -- Nothing to write on
  -- -------------------------------------------------------------------
  v_rec := gen_random_uuid();
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size, uploaded_by)
  values (v_org, 'purchase_documents', v_rec, 'x.jpg',
          v_org || '/purchase_documents/' || v_rec || '/x.jpg',
          'image/jpeg', 1, v_owner)
  returning id into v_att;
  perform pg_temp.check_true(
    'a capture that was never read answers null rather than raising',
    public.ocr_note_correction(v_org, v_att, '{}'::jsonb) is null);

  -- -------------------------------------------------------------------
  -- The question it was all for
  -- -------------------------------------------------------------------
  select * into v_row from public.platform_scan_accuracy(90)
   where provider = 'gemini';
  perform pg_temp.check_eq(
    'the report counts what a person checked', v_row.reviewed, 2::bigint);
  perform pg_temp.check_eq(
    'and what they had to change', v_row.corrected, 2::bigint);
  perform pg_temp.check_eq(
    'so a reader corrected every time reads 0% accurate',
    v_row.accuracy, 0.00);

  select * into v_row from public.platform_scan_accuracy(90)
   where provider = 'claude';
  perform pg_temp.check_true(
    'a reader mostly accepted as read scores above one mostly corrected',
    v_row.accuracy > 0);
  perform pg_temp.check_true(
    'and the field it gets wrong most is named',
    v_row.worst_field = 'lines');
end $$;

-- ---------------------------------------------------------------------
-- The guard is a WHERE clause, so a non-admin gets no rows
-- ---------------------------------------------------------------------
do $$
declare
  v_other uuid := pg_temp.another_user('nobody@example.com');
  v_n     integer;
begin
  perform pg_temp.sign_in_as(v_other);
  select count(*) into v_n from public.platform_scan_accuracy(90);
  perform pg_temp.check_eq(
    'somebody who is not a platform admin sees no readers at all',
    v_n, 0);
end $$;

rollback;

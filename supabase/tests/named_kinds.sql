-- =====================================================================
-- iAkauntan :: a kind of paper the list has never heard of
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/named_kinds.sql
--
-- `0709`. A reading that came back empty is the most valuable thing in
-- this module: a document the product cannot yet handle, in the hands
-- of somebody who knows what it is. Until now there was nowhere for
-- them to say so.
--
-- What is asserted:
--
--   * a typed name is kept beside the scan;
--   * `scan_document_kinds` IS STILL THE VOCABULARY -- a typed name is
--     not a code and cannot become one by being typed. That guard is
--     the reason the column is separate and it must not have been
--     loosened to make room for this;
--   * the name is not cleared by the next call that says nothing about
--     it, because the kind is chosen every time the sheet opens and the
--     name is answered once;
--   * a stranger cannot write on this company's scan;
--   * and the platform list folds names case-insensitively, which is
--     the whole reason for collecting them.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_them  uuid;
  v_exp   uuid := gen_random_uuid();
  v_file  uuid;
  v_scan  uuid;
  v_out   uuid;
  v_named text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Perkakas Sdn Bhd');

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'expenses', v_exp, 'baucar.jpg',
          format('%s/expenses/%s/baucar.jpg', v_org, v_exp),
          'image/jpeg', 90000)
  returning id into v_file;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged)
  values (v_org, v_file, format('%s/expenses/%s/baucar.jpg', v_org, v_exp),
          'gemini', 'platform', 'ok', 0)
  returning id into v_scan;

  -- Nothing on the list fitted, so somebody typed what it is.
  v_out := public.set_scan_document_kind(v_org, v_file, null,
                                         '  Baucar Bayaran  ');
  perform pg_temp.check_eq('the call finds the scan', v_out, v_scan);
  perform pg_temp.check_eq('the typed name is kept, trimmed',
    (select document_kind_named from public.ocr_scans where id = v_scan),
    'Baucar Bayaran');
  perform pg_temp.check_eq('and it is NOT a kind',
    (select document_kind from public.ocr_scans where id = v_scan),
    null::text);

  -- The guard that makes the separate column necessary. A typed name
  -- cannot become a code by being typed into the code.
  perform pg_temp.check_refused(
    'a name nobody added to the vocabulary is still refused as a kind',
    format('select public.set_scan_document_kind(%L, %L, %L)',
           v_org, v_file, 'Baucar Bayaran'),
    '%No such kind of document%', 'P0002');

  -- Choosing a real kind afterwards keeps the name: the kind is
  -- answered every time the sheet opens, the name once.
  v_out := public.set_scan_document_kind(v_org, v_file, 'receipt');
  perform pg_temp.check_eq('a later choice sets the kind',
    (select document_kind from public.ocr_scans where id = v_scan),
    'receipt');
  perform pg_temp.check_eq('and does not clear the name',
    (select document_kind_named from public.ocr_scans where id = v_scan),
    'Baucar Bayaran');

  -- An empty name says nothing and clears nothing.
  perform public.set_scan_document_kind(v_org, v_file, 'receipt', '   ');
  perform pg_temp.check_eq('an empty name changes nothing',
    (select document_kind_named from public.ocr_scans where id = v_scan),
    'Baucar Bayaran');

  -- A paragraph pasted in is capped rather than refused: somebody
  -- describing their document at length has still answered.
  perform public.set_scan_document_kind(v_org, v_file, null,
                                        repeat('a', 400));
  select document_kind_named into v_named
    from public.ocr_scans where id = v_scan;
  perform pg_temp.check_eq('a very long name is capped rather than refused',
    length(v_named), 120);

  -- ------------------------------------------------------------------
  -- The platform list, which is the reason for collecting any of it.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('an ordinary member sees no platform list',
    not exists (select 1 from public.platform_named_kinds(90)));

  -- ------------------------------------------------------------------
  -- And somebody from outside cannot write on it at all.
  -- ------------------------------------------------------------------
  v_them := pg_temp.another_user('penyusup@contoh.my');
  perform pg_temp.sign_in_as(v_them);
  perform pg_temp.check_refused(
    'a stranger cannot name this company''s document',
    format('select public.set_scan_document_kind(%L, %L, null, %L)',
           v_org, v_file, 'anything'),
    '%Insufficient privileges%', '42501');

  raise notice 'named kinds: what the list has never heard of';
end $$;

rollback;

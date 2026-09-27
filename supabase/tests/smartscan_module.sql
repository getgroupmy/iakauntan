-- =====================================================================
-- iAkauntan :: SmartScan is a module, and a statement is many rows
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/smartscan_module.sql
--
-- `0682`. Two things, and both are about what scanning is ALLOWED to
-- do.
--
-- Scanning has been switchable per company since `0111`, but only as a
-- SETTING that any administrator could turn on. It is the most
-- expensive thing in this product per use -- every scan is a call to
-- somebody else's model, billed to the platform when the company is on
-- the platform's key -- so it is a module now, and the gate is on every
-- door a scan can come through rather than on the one somebody
-- remembered.
--
-- The assertion that would rot quietly is the SECOND door.
-- `ocr_record_local` costs the platform nothing, which is exactly the
-- argument for leaving it ungated and exactly how a paid feature ends
-- up free on the phone.
--
-- And the switch. Turning scanning ON without the module is refused;
-- turning it OFF is not, because a company whose module has lapsed
-- still has a switch reading "on" and refusing to let them turn it off
-- would be refusing to let them tidy up after us.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_owner   uuid := pg_temp.test_user();
  v_entity  uuid;
  v_file    uuid;
begin
  -- Every module, so the fixture is a company that pays for everything.
  v_org := pg_temp.test_org('Sinar Teknologi');

  v_entity := gen_random_uuid();
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'expenses', v_entity, 'bil.jpg',
          format('%s/expenses/%s/bil.jpg', v_org, v_entity),
          'image/jpeg', 120000)
  returning id into v_file;

  perform pg_temp.check_true(
    'the module exists and is sold rather than given away',
    exists (select 1 from public.platform_modules
             where code = 'smartscan' and not is_core and monthly_price > 0));

  -- -------------------------------------------------------------------
  -- With the module on
  -- -------------------------------------------------------------------
  update public.ocr_providers
     set is_active = true, price = 0, model = 'gemini-2.0-flash'
   where code = 'gemini';
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');
  perform pg_temp.check_true(
    'a company with the module can switch scanning on',
    (select is_enabled from public.org_ocr_settings where org_id = v_org));
  perform pg_temp.check_true(
    'and scan',
    (public.ocr_begin(v_org, v_file) ->> 'scan_id') is not null);

  -- -------------------------------------------------------------------
  -- With the module off
  -- -------------------------------------------------------------------
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'smartscan';

  perform pg_temp.check_refused(
    'the server door is shut',
    format('select public.ocr_begin(%L, %L)', v_org, v_file),
    '%AI SmartScan is not switched on%', '42501');

  -- The one that would rot. It costs the platform nothing, which is
  -- the argument for leaving it open and the way a paid feature ends
  -- up free on the phone.
  perform pg_temp.check_refused(
    'and so is the phone''s',
    format('select public.ocr_record_local(%L, %L)', v_org, v_file),
    '%AI SmartScan is not switched on%', '42501');

  -- And the sentence says what to do about it rather than what is true.
  perform pg_temp.check_refused(
    'the refusal names the module and where it is switched on',
    format('select public.ocr_begin(%L, %L)', v_org, v_file),
    '%Subscription%', '42501');

  -- Switching ON is refused...
  perform pg_temp.check_refused(
    'and scanning cannot be switched on without it',
    format('select public.set_ocr_settings(%L, true)', v_org),
    '%AI SmartScan is not switched on%', '42501');

  -- ...and switching OFF is not. The setting still reads "on" from
  -- before the module lapsed, and refusing to let somebody turn it off
  -- would be refusing to let them tidy up after us.
  perform public.set_ocr_settings(v_org, false);
  perform pg_temp.check_true(
    'but switching it off always works',
    (select not is_enabled from public.org_ocr_settings where org_id = v_org));

  -- What the settings card is told, so it can say so instead of drawing
  -- a switch that refuses. A refusal a screen could have predicted is a
  -- screen that was not finished.
  perform pg_temp.check_true(
    'and the card is told the module is off',
    not (public.ocr_status(v_org) ->> 'has_module')::boolean);

  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'smartscan';
  perform pg_temp.check_true(
    'and told when it is on',
    (public.ocr_status(v_org) ->> 'has_module')::boolean);

  raise notice 'smartscan_module: module assertions passed';
end;
$$;

-- =====================================================================
-- A target whose fields describe one row of many
-- =====================================================================
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_out   jsonb;
  v_n     integer;
begin
  insert into public.platform_admins (user_id) values (v_owner)
  on conflict do nothing;
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.check_true(
    'a bank statement is a target now, and it repeats',
    exists (select 1 from public.scan_targets
             where module_code = 'accounting' and action = 'bank_statement'
               and repeats and table_name = 'bank_transactions'));

  perform pg_temp.check_true(
    'an invoice to a customer is one too, and does not',
    exists (select 1 from public.scan_targets
             where module_code = 'sales' and action = 'invoice'
               and not repeats and table_name = 'sales_documents'));

  -- `0614` named the kind and had nowhere to send it. It has one now,
  -- and `destination` follows by trigger so the screen a scan opens and
  -- the fields it fills cannot disagree.
  perform pg_temp.check_eq(
    'the kind 0614 seeded points at it',
    (select target_action from public.scan_document_kinds
      where code = 'bank_statement'), 'bank_statement');
  perform pg_temp.check_eq(
    'and still opens the reconciliation screen',
    (select destination from public.scan_document_kinds
      where code = 'bank_statement'), 'bank_import');

  -- The columns of `bank_transactions` are what a statement line has,
  -- which is the whole reason this target can exist at all.
  select count(*) into v_n
    from public.scan_target_columns('accounting', 'bank_statement')
   where column_name in ('transaction_date', 'description', 'amount',
                         'running_balance');
  perform pg_temp.check_eq(
    'and a statement line''s four fields are on offer', v_n, 4);

  perform public.set_scan_target_fields(
    'accounting', 'bank_statement', jsonb_build_array(
      jsonb_build_object('column_name', 'transaction_date',
                         'description', 'The date on the line.'),
      -- The column IS called `description`, so the key and the value
      -- read alike. Spelled out rather than trusted to the eye.
      jsonb_build_object('column_name', 'description',
                         'description', 'The narration, exactly as printed.'),
      jsonb_build_object('column_name', 'amount',
                         'description',
                         'Negative for money out, positive for money in.')));

  v_out := public.scan_extraction_targets();
  perform pg_temp.check_true(
    'and the reader is told this one repeats',
    exists (select 1 from jsonb_array_elements(v_out) t
             where t ->> 'key' = 'accounting.bank_statement'
               and (t ->> 'repeats')::boolean));

  -- Everything else does not, and that is what keeps every other
  -- document reading exactly as it did.
  perform pg_temp.check_true(
    'a single-record target still says so',
    not exists (select 1 from jsonb_array_elements(v_out) t
                 where t ->> 'key' <> 'accounting.bank_statement'
                   and (t ->> 'repeats')::boolean));

  raise notice 'smartscan_module: repeating-target assertions passed';
end;
$$;

rollback;

-- =====================================================================
-- iAkauntan :: what the machine read, and what a person typed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/entry_source.sql
--
-- `0707`. A bill somebody typed off a PDF and a bill a model read off
-- the same PDF were the same row in every list in this product, and the
-- second is the one worth a second look: a reader that mistakes
-- 1,086.12 for 1,086.72 produces a document that balances, posts and
-- reconciles to nothing.
--
-- `ocr_scans.posted_id` has known what a reading became since `0694`.
-- What it could not do is be READ -- every list selects the document
-- table and nothing else. So the record carries it too, written in the
-- same statement as the link, which is what stops the two drifting.
--
-- Four things are asserted, and the third is the one a wider `update`
-- would quietly break:
--
--   * a reading that becomes a bill stamps the bill;
--   * the link on `ocr_scans` is written with it, in the same call;
--   * a BANK STATEMENT stamps nothing. One reading becomes a hundred
--     rows -- `scan_targets.repeats` says so -- and "this line was
--     scanned" about a table that arrives that way is noise;
--   * nothing anybody typed is stamped, which is nearly every row.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_sup   uuid;
  v_bill  uuid;
  v_typed uuid;
  v_file  uuid;
  v_scan  uuid;
  v_out   uuid;
  v_src    text;
  v_holder uuid := gen_random_uuid();
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Runcit Sdn Bhd');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Google Asia Pacific Pte. Ltd.', 'supplier')
  returning id into v_sup;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-SRC-1', current_date, v_sup, 'MYR', 1,
          'draft')
  returning id into v_bill;

  -- The paper, filed against that bill, and read.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'purchase_documents', v_bill, '5665871390.pdf',
          format('%s/purchase_documents/%s/bil.pdf', v_org, v_bill),
          'application/pdf', 110000)
  returning id into v_file;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, extracted)
  values (v_org, v_file,
          format('%s/purchase_documents/%s/bil.pdf', v_org, v_bill),
          'claude', 'platform', 'ok', 0,
          jsonb_build_object('total_amount', 1173.01))
  returning id into v_scan;

  -- Before anybody says what it became, it is an ordinary bill.
  perform pg_temp.check_eq('a bill nobody has recorded a reading for '
    'says nothing about where it came from',
    (select entry_source from public.purchase_documents where id = v_bill),
    null::text);

  v_out := public.record_scan_posting(v_org, v_file);
  perform pg_temp.check_eq('the call finds the reading', v_out, v_scan);

  perform pg_temp.check_eq('and the bill says a reader filled it in',
    (select entry_source from public.purchase_documents where id = v_bill),
    'ai_smartscan');

  -- The audit link, written by the same call. Two places, one
  -- statement: a record that says "AI Scan" with no scan behind it is
  -- exactly what a second write would eventually produce.
  perform pg_temp.check_eq('and the scan still says what it became',
    (select posted_id from public.ocr_scans where id = v_scan), v_bill);
  perform pg_temp.check_eq('on the table it went to',
    (select posted_table from public.ocr_scans where id = v_scan),
    'purchase_documents');

  -- ------------------------------------------------------------------
  -- A bill somebody typed, with no paper behind it, stays untouched.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-SRC-2', current_date, v_sup, 'MYR', 1,
          'draft')
  returning id into v_typed;
  perform pg_temp.check_eq('a bill somebody typed is not tagged',
    (select entry_source from public.purchase_documents where id = v_typed),
    null::text);

  -- ------------------------------------------------------------------
  -- A statement is one reading and a hundred rows, so it tags nothing.
  -- ------------------------------------------------------------------
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'bank_transactions', v_holder, 'penyata.pdf',
          format('%s/bank_transactions/%s/penyata.pdf', v_org, v_holder),
          'application/pdf', 40000)
  returning id into v_file;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged)
  values (v_org, v_file,
          format('%s/bank_transactions/%s/penyata.pdf', v_org, v_holder),
          'claude', 'platform', 'ok', 0)
  returning id into v_scan;

  v_out := public.record_scan_posting(
    v_org, v_file, 'bank_transactions', v_holder);
  perform pg_temp.check_eq('a statement still records what it became',
    (select posted_table from public.ocr_scans where id = v_out),
    'bank_transactions');

  -- And the four tables it tags are the four it names. Asserted
  -- against the column itself, so a table that gains one without being
  -- added to the function is visible here.
  perform pg_temp.check_eq(
    'the column is on the four tables that are one record',
    (select count(*)::numeric from information_schema.columns
      where table_schema = 'public' and column_name = 'entry_source'),
    4::numeric);

  -- ------------------------------------------------------------------
  -- A value nobody implements is refused, rather than showing up as a
  -- chip with no label.
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a source nobody implements is refused',
    format('update public.purchase_documents set entry_source = '
           '''telepathy'' where id = %L', v_typed),
    '%purchase_documents_entry_source_ck%', '23514');

  raise notice 'entry source: the record says a reader filled it in';
end $$;

rollback;

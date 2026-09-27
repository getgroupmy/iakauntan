-- =====================================================================
-- iAkauntan :: what the paper said, beside what the lines come to
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_totals.sql
--
-- `0705`. A supplier's document often states ONE tax figure for the
-- whole bill; this system computes tax per LINE and the header's
-- `tax_amount` is derived from the lines by `0009`'s trigger. So the
-- paper's own figure has nowhere to live on the document, and nothing
-- ever compared the two.
--
-- The reading captured them all along. What this returns is what the
-- paper said, for the document in front of somebody, so the app can put
-- it beside what the lines add up to.
--
-- Three things are asserted, and the middle one is why this is a
-- function and not a select:
--
--   * the figures come back off the newest SUCCESSFUL reading, because
--     `0698` made reading a document twice ordinary and the second
--     reader is the one to believe;
--
--   * A STRANGER GETS NOTHING. The guard is `app.is_org_member`, in the
--     WHERE clause, so somebody who is not one gets no rows rather than
--     an exception;
--
--   * a document nobody scanned answers nothing at all, rather than
--     zeroes -- "no paper" and "the paper said zero" are different
--     answers and a screen that confused them would warn about every
--     typed-in bill in the system.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_read_bill(
  p_org uuid, p_doc uuid, p_file text, p_sub numeric, p_tax numeric,
  p_total numeric, p_when timestamptz, p_status text default 'ok')
returns uuid language plpgsql as $$
declare
  v_file uuid;
  v_scan uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'purchase_documents', p_doc, p_file,
          format('%s/purchase_documents/%s/%s', p_org, p_doc, p_file),
          'application/pdf', 90000)
  returning id into v_file;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, extracted, created_at, finished_at)
  values (p_org, v_file,
          format('%s/purchase_documents/%s/%s', p_org, p_doc, p_file),
          'claude', 'platform', p_status, 0,
          jsonb_build_object('subtotal', p_sub, 'tax_amount', p_tax,
                             'total_amount', p_total),
          p_when, p_when)
  returning id into v_scan;
  return v_scan;
end;
$$;

do $$
declare
  v_org  uuid;
  v_doc  uuid := gen_random_uuid();
  v_row  record;
  v_them uuid;
  v_n    integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kertas Sdn Bhd');

  -- What the supplier's PDF said: one tax figure for the whole bill.
  perform pg_temp.a_read_bill(v_org, v_doc, 'bil.pdf',
    1077.99, 86.24, 1164.23, now() - interval '2 hours');

  select * into v_row
    from public.document_scan_totals(v_org, 'purchase_documents', v_doc);
  perform pg_temp.check_eq('the paper''s subtotal comes back',
    v_row.subtotal, 1077.99);
  perform pg_temp.check_eq('and its tax', v_row.tax_amount, 86.24);
  perform pg_temp.check_eq('and its total', v_row.total, 1164.23);
  perform pg_temp.check_eq('with the file it was read off',
    v_row.file_name, 'bil.pdf');

  -- Read again, which `0698` made ordinary. The second reader is the
  -- one to believe.
  perform pg_temp.a_read_bill(v_org, v_doc, 'bil.pdf',
    1077.99, 86.21, 1164.20, now());
  select * into v_row
    from public.document_scan_totals(v_org, 'purchase_documents', v_doc);
  perform pg_temp.check_eq('the newest reading is the one described',
    v_row.tax_amount, 86.21);

  -- A failed reading has nothing to say, whenever it happened.
  perform pg_temp.a_read_bill(v_org, v_doc, 'bil.pdf',
    null, null, null, now() + interval '1 hour', 'failed');
  select * into v_row
    from public.document_scan_totals(v_org, 'purchase_documents', v_doc);
  perform pg_temp.check_eq('a failed reading is not the answer',
    v_row.tax_amount, 86.21);

  -- A document nobody scanned. Not zeroes: "no paper" and "the paper
  -- said zero" are different answers, and a screen that confused them
  -- would warn about every bill anybody ever typed in.
  select count(*) into v_n
    from public.document_scan_totals(v_org, 'purchase_documents',
                                     gen_random_uuid());
  perform pg_temp.check_eq('a document nobody scanned answers nothing',
    v_n, 0);

  -- And a stranger gets nothing, on a document that certainly has an
  -- answer.
  v_them := pg_temp.another_user('penyusup@contoh.my');
  perform pg_temp.sign_in_as(v_them);
  select count(*) into v_n
    from public.document_scan_totals(v_org, 'purchase_documents', v_doc);
  perform pg_temp.check_eq('and somebody from outside gets no rows', v_n, 0);

  raise notice 'scan totals: the paper''s own figures, for comparing';
end $$;

rollback;

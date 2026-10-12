-- =====================================================================
-- iAkauntan :: the paper stays where it was filed (0848)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/evidence_stays_filed.sql
--
-- `0708` refused deleting the row of a file a posting or a reading was
-- built from. Before `0848` the row could still be pointed at another
-- file or moved off its record, and the file itself could be renamed or
-- deleted in storage, the row naming nothing. Asked as the owner with
-- the role `authenticated`, as the app and the Storage API ask.
--
-- `storage.allow_delete_query` is set because the Storage API sets it:
-- Supabase's own `protect_objects_delete` refuses a delete without it,
-- before this file's question is reached. The local stack has no such
-- trigger and ignores the setting.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

select set_config('storage.allow_delete_query', 'true', true);

create temporary table t_ev (org uuid, posted uuid, draft uuid, placeholder uuid,
  att_ev uuid, att_draft uuid, att_cap uuid, p_ev text, p_draft text, p_cap text);
grant select on t_ev to authenticated;

do $$
declare r t_ev; v_cust uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kertas Kekal Sdn Bhd', array['attachments']);
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (r.org, 'invoice', 'INV-1', pg_temp.today(), pg_temp.today(), v_cust, 'draft', 'MYR', 1)
  returning id into r.posted;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (r.org, r.posted, 1, 'item', 'Work', 1, 1000);
  perform public.post_sales_document(r.posted);
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (r.org, 'invoice', 'INV-2', pg_temp.today(), pg_temp.today(), v_cust, 'draft', 'MYR', 1)
  returning id into r.draft;
  -- A capture is parked against a record that does not exist yet.
  r.placeholder := gen_random_uuid();

  r.p_ev    := r.org || '/sales_documents/' || r.posted || '/1-signed-po.pdf';
  r.p_draft := r.org || '/sales_documents/' || r.draft || '/2-quote.pdf';
  r.p_cap   := r.org || '/expenses/' || r.placeholder || '/3-receipt.jpg';

  insert into public.attachments (org_id, entity_table, entity_id, file_name, storage_path, content_sha256)
  values (r.org, 'sales_documents', r.posted, '1-signed-po.pdf', r.p_ev, repeat('a', 64))
  returning id into r.att_ev;
  insert into public.attachments (org_id, entity_table, entity_id, file_name, storage_path)
  values (r.org, 'sales_documents', r.draft, '2-quote.pdf', r.p_draft)
  returning id into r.att_draft;
  insert into public.attachments (org_id, entity_table, entity_id, file_name, storage_path)
  values (r.org, 'expenses', r.placeholder, '3-receipt.jpg', r.p_cap)
  returning id into r.att_cap;

  insert into storage.objects (bucket_id, name, version, metadata)
  select 'attachments', p, 'v1', '{"eTag": "\"e1\""}'::jsonb
    from unnest(array[r.p_ev, r.p_draft, r.p_cap]) p;
  -- And a logo that happens to carry the evidence's name, in a bucket
  -- that is not this one.
  insert into storage.objects (bucket_id, name) values ('logos', r.p_ev);
  insert into t_ev select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ev; n int;
begin
  select * into d from t_ev;
  perform pg_temp.check_true('the owner, asking as a client who may write',
    current_user = 'authenticated' and app.can_write(d.org));
  perform pg_temp.check_eq('the premise: the posted invoice''s page is evidence, the draft''s and a capture''s are not',
    concat_ws(' / ', app.attachment_is_evidence(d.att_ev), app.attachment_is_evidence(d.att_draft),
                     app.attachment_is_evidence(d.att_cap)),
    't / f / f');

  -- The row. What was measured.
  perform pg_temp.check_refused('the posted invoice''s page is not pointed at another file',
    format($q$update public.attachments
                 set file_name = 'blank.pdf', storage_path = %L, content_sha256 = %L
               where id = %L$q$,
           d.org || '/sales_documents/' || d.posted || '/9-blank.pdf', repeat('b', 64), d.att_ev),
    '1-signed-po.pdf is what this record was built from -- it is posted, or its figures were '
    'read off this page -- so it stays filed where it is, as the file it is. Section 82 of the '
    'Income Tax Act 1967 asks for the paperwork behind a return to be kept for seven years. '
    'A file nothing was built from can still be moved.',
    '42501');
  perform pg_temp.check_refused('nor moved off it onto a draft',
    format('update public.attachments set entity_id = %L, storage_path = %L where id = %L',
           d.draft, d.org || '/sales_documents/' || d.draft || '/1-signed-po.pdf', d.att_ev),
    '1-signed-po.pdf is what this record was built from%', '42501');
  perform pg_temp.check_refused('nor changed in anything else',
    format('update public.attachments set kept_at = now() where id = %L', d.att_ev),
    '1-signed-po.pdf is what this record was built from%', '42501');
  update public.attachments set file_name = file_name where id = d.att_ev;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('a statement that changes nothing on it is not a change', n::text, '1');

  -- The file. What was measured.
  perform pg_temp.check_refused('the posted invoice''s file is not deleted from storage',
    format($q$delete from storage.objects where bucket_id = 'attachments' and name = %L$q$, d.p_ev),
    '1-signed-po.pdf is what a record was built from -- it is posted, or its figures were read '
    'off this page -- so the file is not deleted, moved or written over. Section 82 of the '
    'Income Tax Act 1967 asks for the paperwork behind a return to be kept for seven years.',
    '42501');
  perform pg_temp.check_refused('nor renamed',
    format($q$update storage.objects set name = %L where bucket_id = 'attachments' and name = %L$q$,
           d.org || '/sales_documents/' || d.draft || '/1-signed-po.pdf', d.p_ev),
    '1-signed-po.pdf is what a record was built from%', '42501');
  -- Into a bucket the owner may also write: the policies allow it.
  perform pg_temp.check_refused('nor moved to another bucket',
    format($q$update storage.objects set bucket_id = 'logos' where bucket_id = 'attachments' and name = %L$q$,
           d.p_ev),
    '1-signed-po.pdf is what a record was built from%', '42501');
  perform pg_temp.check_refused('nor written over with a new version',
    format($q$update storage.objects set version = 'v2' where bucket_id = 'attachments' and name = %L$q$,
           d.p_ev),
    '1-signed-po.pdf is what a record was built from%', '42501');
  perform pg_temp.check_refused('nor with new bytes under the same version',
    format($q$update storage.objects set metadata = '{"eTag": "\"e2\""}' where bucket_id = 'attachments' and name = %L$q$,
           d.p_ev),
    '1-signed-po.pdf is what a record was built from%', '42501');
  update storage.objects
     set last_accessed_at = now() - interval '1 day',
         metadata = metadata || '{"cacheControl": "max-age=3600"}'
   where bucket_id = 'attachments' and name = d.p_ev;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('but a timestamp, or what it is served with, still moves', n::text, '1');

  -- What the app does is as before: a capture refiled from its
  -- placeholder onto the record it became, the object first and then
  -- the row; and a file nothing was built from, removed.
  update storage.objects set name = d.org || '/sales_documents/' || d.draft || '/3-receipt.jpg'
   where bucket_id = 'attachments' and name = d.p_cap;
  get diagnostics n = row_count;
  update public.attachments
     set entity_table = 'sales_documents', entity_id = d.draft,
         storage_path = d.org || '/sales_documents/' || d.draft || '/3-receipt.jpg'
   where id = d.att_cap;
  perform pg_temp.check_eq('a capture is still refiled onto the record it became',
    n::text || ' / ' || (select entity_id::text from public.attachments where id = d.att_cap),
    '1 / ' || d.draft);
  delete from storage.objects where bucket_id = 'attachments' and name = d.p_draft;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('and a file nothing was built from is still deleted', n::text, '1');
  delete from storage.objects where bucket_id = 'logos' and name = d.p_ev;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('and another bucket is not asked', n::text, '1');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- Each guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives
-- as an equivalent one: nothing writes either table from inside a
-- trigger as a client.
do $$
declare d t_ev; n int;
begin
  select * into d from t_ev;
  update public.attachments set kept_at = now() where id = d.att_ev;
  delete from storage.objects where bucket_id = 'attachments' and name = d.p_ev;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select (kept_at is not null)::text from public.attachments where id = d.att_ev) || ' / ' || n,
    'true / 1');
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: who filed it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/who_filed_it.sql
--
-- `attachments.uploaded_by` has been a column since `0008` and the
-- client's insert leaves it out. `attachments` is the general store —
-- every entity hangs files off it — so it is the table where "which of
-- our people put this here" matters most and the one where nothing
-- answered it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid := pg_temp.test_org('Fail Lampiran Sdn Bhd');
  v_me    uuid := pg_temp.test_user();
  v_other uuid;
  v_doc   uuid;
  v_att   uuid;
  v_emp   uuid;
  v_ed    uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer');
  select id into v_doc from public.contacts where org_id = v_org limit 1;

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'contacts', v_doc, 'receipt.pdf',
          v_org || '/contacts/' || v_doc || '/receipt.pdf')
  returning id into v_att;

  perform pg_temp.check_eq('the person who filed it is recorded',
    (select uploaded_by from public.attachments where id = v_att), v_me);

  -- Frozen on update, and asserted by writing the column directly: an
  -- update that never mentions it leaves it alone by itself, so editing
  -- only the file name would prove nothing about the rule.
  v_other := pg_temp.another_user('other@wf.test');
  perform pg_temp.sign_in_as(v_other);
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_other, 'admin', 'active')
  on conflict (org_id, user_id) do update set role = 'admin';
  update public.attachments
     set file_name = 'receipt-2.pdf', uploaded_by = auth.uid()
   where id = v_att;
  perform pg_temp.check_eq('and is not replaced by whoever edits it next',
    (select uploaded_by from public.attachments where id = v_att), v_me);
  perform pg_temp.sign_in_as(v_me);

  -- A caller that names somebody is believed: an import or a backfill
  -- knows who filed the original better than `auth.uid()` does.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, uploaded_by)
  values (v_org, 'contacts', v_doc, 'old.pdf',
          v_org || '/contacts/' || v_doc || '/old.pdf', v_other)
  returning id into v_att;
  perform pg_temp.check_eq('a stated filer is kept',
    (select uploaded_by from public.attachments where id = v_att), v_other);

  -- `0388`'s table keeps its behaviour, now through the shared function.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth)
  values (v_org, 'E1', 'Encik Sam', date '2020-01-01', 3000,
          date '1990-01-01')
  returning id into v_emp;
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title)
  values (v_org, v_emp, 'contract', 'Letter of appointment')
  returning id into v_ed;
  perform pg_temp.check_eq('and the HR document store still records it',
    (select uploaded_by from public.employee_documents where id = v_ed),
    v_me);

  perform pg_temp.sign_out();
end $$;

rollback;

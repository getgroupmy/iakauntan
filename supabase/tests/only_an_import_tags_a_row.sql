-- =====================================================================
-- iAkauntan :: only an import tags a row (0910)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/only_an_import_tags_a_row.sql
--
-- `rollback_import_batch` deletes every row whose `import_batch_id` is
-- the batch's. Before `0910` an accounts clerk -- who may not start or
-- roll back an import -- could tag a contact and an item the company
-- had typed itself with the owner's open batch, and the owner's
-- rollback deleted them. As the clerk with the role `authenticated`,
-- as the app writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_it (org uuid, owner uuid, clerk uuid, batch uuid,
                             cust uuid, item uuid);
grant select on t_it to authenticated;

do $$
declare r t_it;
begin
  r.owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.owner);
  r.org := pg_temp.test_org('Tanda Import Sdn Bhd');
  r.clerk := pg_temp.another_user('kerani@tanda-import.test');
  insert into public.org_members (org_id, user_id, role)
  values (r.org, r.clerk, 'accounts_clerk') on conflict do nothing;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'ASLI', 'Pelanggan Asli', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'ASLI', 'Barang Asli', 'service', false, 'C62', 10) returning id into r.item;
  r.batch := public.start_import_batch(r.org, 'autocount', 'Migrasi');
  insert into t_it select r.*;
end $$;

set local role authenticated;

do $$
declare d t_it;
begin
  select * into d from t_it;
  perform pg_temp.sign_in_as(d.clerk);
  perform pg_temp.check_eq('the clerk can see the open import',
    (select count(*) from public.import_batches where id = d.batch)::int, 1);

  -- -------------------------------------------------------------------
  -- An existing row is not tagged by hand
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a contact the company typed is not tagged into the import',
    format('update public.contacts set import_batch_id = %L where id = %L', d.batch, d.cust),
    'import_batch_id records which import brought this row in, and is written by the import alone (null -> %',
    '42501');
  perform pg_temp.check_refused('nor an item',
    format('update public.items set import_batch_id = %L where id = %L', d.batch, d.item),
    'import_batch_id records which import brought this row in%', '42501');
  perform pg_temp.check_refused('nor given a source and a reference that would collide with one',
    format('update public.contacts set import_source = %L, import_ref = %L where id = %L',
           'autocount', 'C-0001', d.cust),
    'import_source records which import brought this row in%', '42501');
  perform pg_temp.check_refused('nor a date it was imported on',
    format('update public.contacts set imported_at = now() where id = %L', d.cust),
    'imported_at records which import brought this row in%', '42501');

  -- -------------------------------------------------------------------
  -- Nor does a row arrive tagged
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a contact does not arrive in the import',
    format('insert into public.contacts (org_id, code, name, contact_type, import_batch_id)
            values (%L, %L, %L, %L, %L)', d.org, 'BARU', 'Pelanggan Baru', 'customer', d.batch),
    'A row is tagged as imported by an import alone, and this one arrived saying import_batch_id = %',
    '42501');
  perform pg_temp.check_refused('nor an invoice with an import''s reference',
    format('insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status,
               import_source, import_ref)
            values (%L, %L, %L, %L, %L, %L, 1, %L, %L, %L)',
           d.org, 'invoice', 'INV-IMP', pg_temp.today(), d.cust, 'MYR', 'draft', 'autocount', 'IV-0001'),
    'A row is tagged as imported by an import alone, and this one arrived saying import_source = autocount%',
    '42501');

  -- The rest of the row is written as it was.
  update public.contacts set name = 'Pelanggan Asli Bhd' where id = d.cust;
  perform pg_temp.check_eq('the rest of a contact is still written',
    (select name from public.contacts where id = d.cust), 'Pelanggan Asli Bhd');

  -- -------------------------------------------------------------------
  -- So the import's rollback takes only what the import brought
  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(d.owner);
  perform public.rollback_import_batch(d.batch);
  perform pg_temp.check_eq('rolled back, the import leaves the company''s own contact and item',
    (select count(*) from public.contacts where id = d.cust)::int
      + (select count(*) from public.items where id = d.item)::int, 2);
end $$;

-- The importers run as the owner and write the tag.
reset role;
update public.contacts set import_source = 'autocount', import_ref = 'C-0001'
 where id = (select cust from t_it);
select pg_temp.check_eq('the owner still tags a row',
  (select import_source || ' / ' || import_ref from public.contacts where id = (select cust from t_it)),
  'autocount / C-0001');

-- Every table the rollback reaches that a client can write carries it.
select pg_temp.check_eq('every client-writable table an import reaches is guarded',
  (select count(*)::int
     from unnest(app.import_target_tables()) t
    where (has_table_privilege('authenticated', 'public.' || t, 'insert')
        or has_table_privilege('authenticated', 'public.' || t, 'update'))
      and not exists (select 1 from pg_trigger g
                       where g.tgrelid = ('public.' || t)::regclass
                         and g.tgname = 'provenance_is_the_imports')), 0);

rollback;

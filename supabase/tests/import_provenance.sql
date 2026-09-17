-- =====================================================================
-- iAkauntan :: where every imported row came from
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/import_provenance.sql
--
-- `docs/migrating-from-autocount.md` calls this the first change to
-- make, before any importer exists, and says why:
--
--   > an import cannot be re-run -- a second attempt either duplicates
--   > everything or collides on the natural key, and there is no way to
--   > tell "already imported" from "coincidentally same code".
--
-- So the assertion this file exists for is the re-run: import the same
-- thing twice and get one row, and a DIFFERENT row that happens to
-- share a code is not the same row. Everything else here supports that
-- one.
--
-- The second is the rollback. A failed import that can only be unpicked
-- by hand is a migration nobody rehearses, and a migration nobody
-- rehearses happens once, on live data, with nothing to compare against
-- when a balance is wrong on Monday.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- =====================================================================
-- Every table an import can write to carries the triple
--
-- Read from the catalog against `app.import_target_tables()`, which is
-- the list the migration itself looped over. That is not circular: the
-- migration could have failed on any one of them and left the column
-- off, and `add column if not exists` is exactly the statement that
-- does so silently.
-- =====================================================================
do $$
declare
  v_table text;
  v_miss  text[] := '{}';
begin
  foreach v_table in array app.import_target_tables() loop
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = v_table
         and column_name = 'import_source') then
      v_miss := v_miss || v_table;
    end if;
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = v_table
         and column_name = 'import_ref') then
      v_miss := v_miss || (v_table || '.import_ref');
    end if;
    if not exists (
      select 1 from pg_indexes
       where schemaname = 'public' and tablename = v_table
         and indexname = v_table || '_import_key') then
      v_miss := v_miss || (v_table || ' (no unique index)');
    end if;
  end loop;

  perform pg_temp.check_eq(
    'every table an import writes to can say where the row came from',
    array_to_string(v_miss, ', '), '');

  -- CONTROL. A table nothing imports into does not carry it, so the
  -- assertion above is about a chosen list rather than about every
  -- table in the schema having been swept.
  perform pg_temp.check_true(
    'and a table nothing imports into does not',
    not exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and table_name = 'live_changes'
                   and column_name = 'import_source'));
end $$;

-- =====================================================================
-- Not `source_id`, which already meant something else
--
-- `gl_entries.source_id` and `stock_movements.source_id` have existed
-- since `0013` and say which document the entry or movement came FROM,
-- inside this system. `add column if not exists` does nothing against a
-- column that is already there, so a provenance pair named that way
-- would have read the existing column and refused every journal this
-- product writes. It did, in five test files, the first time the
-- migration ran.
-- =====================================================================
do $$
declare v_type text;
begin
  select data_type into v_type from information_schema.columns
   where table_schema = 'public' and table_name = 'gl_entries'
     and column_name = 'source_id';
  perform pg_temp.check_eq(
    'gl_entries.source_id is still the document it came from',
    v_type, 'uuid');

  perform pg_temp.check_true(
    'and the provenance key is a different column entirely',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'gl_entries'
               and column_name = 'import_ref' and data_type = 'text'));
end $$;

-- =====================================================================
-- A row that half-remembers where it came from is refused
--
-- A row with an `import_ref` and no `import_source` sits outside the
-- partial unique index and is therefore duplicable, which is the exact
-- state the index exists to prevent.
-- =====================================================================
do $$
declare v_org uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Separuh Ingat Sdn Bhd');

  perform pg_temp.check_refused(
    'a reference with no system is refused',
    format($q$ insert into public.contacts
                 (org_id, code, name, contact_type, import_ref)
               values (%L, 'C-1', 'Sesiapa', 'customer', 'DEBTOR-1') $q$,
           v_org),
    '%contacts_import_pair%', '23514');

  perform pg_temp.check_refused(
    'and a system with no reference is refused too',
    format($q$ insert into public.contacts
                 (org_id, code, name, contact_type, import_source)
               values (%L, 'C-2', 'Sesiapa', 'customer', 'autocount') $q$,
           v_org),
    '%contacts_import_pair%', '23514');

  -- CONTROL. Neither is fine -- which is every row a company types.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-3', 'Ditaip', 'customer');
  perform pg_temp.check_eq(
    'while a row nobody imported carries neither',
    (select count(*)::integer from public.contacts
      where org_id = v_org and import_source is null), 1);
end $$;

-- =====================================================================
-- THE assertion: the same import, run twice
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_batch uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Ulang Import Sdn Bhd');
  v_batch := public.start_import_batch(v_org, 'AutoCount', 'Trial run 1');

  perform pg_temp.check_eq(
    'the source is normalised, so AutoCount and autocount are one system',
    (select import_source from public.import_batches where id = v_batch),
    'autocount');

  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_org, 'D-1', 'Pelanggan Lama', 'customer', 'autocount',
          'DEBTOR-1', v_batch, now());

  -- The second run of the same importer. `on conflict do nothing` is a
  -- correct and complete answer to "what happens if I run it twice"
  -- only because the index exists.
  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_org, 'D-1', 'Pelanggan Lama', 'customer', 'autocount',
          'DEBTOR-1', v_batch, now())
  on conflict (org_id, import_source, import_ref)
    where import_source is not null do nothing;

  select count(*)::integer into v_n from public.contacts
   where org_id = v_org and import_ref = 'DEBTOR-1';
  perform pg_temp.check_eq(
    'importing the same customer twice leaves one customer', v_n, 1);

  -- And the distinction the document asks for: "already imported" is
  -- not the same as "coincidentally same code".
  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_org, 'D-2', 'Pelanggan Lain', 'customer', 'autocount',
          'DEBTOR-2', v_batch, now());

  select count(*)::integer into v_n from public.contacts
   where org_id = v_org and import_source = 'autocount';
  perform pg_temp.check_eq(
    'while a different row from the same system is a different row',
    v_n, 2);

  -- A DIFFERENT system's row with the same reference is also different.
  -- Without `import_source` in the key, migrating from two systems
  -- would silently merge whatever their keys happened to share.
  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_org, 'S-1', 'Dari Sistem Lain', 'customer', 'sql_acc',
          'DEBTOR-1', v_batch, now());
  select count(*)::integer into v_n from public.contacts
   where org_id = v_org and import_ref = 'DEBTOR-1';
  perform pg_temp.check_eq(
    'and two systems that happen to share a key are not one customer',
    v_n, 2);
end $$;

-- =====================================================================
-- Another company's DEBTOR-1 is another company's
-- =====================================================================
do $$
declare
  v_a record;
  v_b uuid;
  v_ba uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.test_org('Syarikat Kedua Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_ba := public.start_import_batch(v_b, 'autocount');

  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_b, 'D-1', 'Pelanggan Syarikat Kedua', 'customer', 'autocount',
          'DEBTOR-1', v_ba, now());

  perform pg_temp.check_eq(
    'the key is per company, so two tenants may both import DEBTOR-1',
    (select count(*)::integer from public.contacts
      where import_ref = 'DEBTOR-1' and import_source = 'autocount'), 2);
end $$;

-- =====================================================================
-- One import at a time
-- =====================================================================
do $$
declare
  v_org uuid;
  v_b1  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Satu Pada Satu Masa Sdn Bhd');
  v_b1 := public.start_import_batch(v_org, 'autocount', 'First');

  perform pg_temp.check_refused(
    'a second import cannot start while one is staging',
    format($q$ select public.start_import_batch(%L, 'autocount') $q$, v_org),
    '%already in progress%', '55006');

  perform pg_temp.check_true(
    'once the first is finished, another may start',
    public.finish_import_batch(v_b1, 'failed', 'Gave up'));
  perform pg_temp.check_true(
    'and it does',
    public.start_import_batch(v_org, 'autocount', 'Second') is not null);

  perform pg_temp.check_refused(
    'a source nobody can spell is refused, in words',
    format($q$ select public.start_import_batch(%L, 'Auto Count!') $q$,
           v_org),
    '%lower-case letters, digits and underscores%', '23514');
end $$;

-- =====================================================================
-- Rolling one back
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_batch uuid;
  v_rows  integer;
  r       record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Batal Import Sdn Bhd');
  v_batch := public.start_import_batch(v_org, 'autocount', 'Rehearsal');

  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref,
     import_batch_id, imported_at)
  values (v_org, 'D-9', 'Akan Dibuang', 'customer', 'autocount',
          'DEBTOR-9', v_batch, now());
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     import_source, import_ref, import_batch_id, imported_at)
  values (v_org, 'I-9', 'Barang', 'stock', true, 'C62',
          'autocount', 'ITEM-9', v_batch, now());
  insert into public.import_rows
    (org_id, batch_id, resource, import_ref, payload)
  values (v_org, v_batch, 'Debtor', 'DEBTOR-9', '{"name":"Akan Dibuang"}');

  select count(*)::integer into v_rows
    from public.import_batch_summary(v_batch);
  perform pg_temp.check_eq(
    'the summary counts what the batch wrote, from the rows themselves',
    v_rows, 2);

  perform public.rollback_import_batch(v_batch);

  perform pg_temp.check_eq(
    'rolling back removes the customer it imported',
    (select count(*)::integer from public.contacts
      where org_id = v_org and import_ref = 'DEBTOR-9'), 0);
  perform pg_temp.check_eq(
    'and the item',
    (select count(*)::integer from public.items
      where org_id = v_org and import_ref = 'ITEM-9'), 0);
  perform pg_temp.check_eq(
    'and the staged payloads with them',
    (select count(*)::integer from public.import_rows
      where batch_id = v_batch), 0);
  perform pg_temp.check_eq(
    'while the batch itself stays, saying what happened to it',
    (select status from public.import_batches where id = v_batch),
    'rolled_back');

  perform pg_temp.check_refused(
    'and it cannot be rolled back twice',
    format($q$ select * from public.rollback_import_batch(%L) $q$, v_batch),
    '%already been rolled back%', '55000');
end $$;

-- =====================================================================
-- What a rollback will not do
--
-- A rollback is for an import that went wrong before anybody worked on
-- top of it. Once the books have it, deleting the import is not undoing
-- it.
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_batch uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Sudah Pos Sdn Bhd');
  v_batch := public.start_import_batch(v_org, 'autocount');
  perform public.finish_import_batch(v_batch, 'posted', 'Went live');

  perform pg_temp.check_refused(
    'a posted import is reversed with a journal, not deleted',
    format($q$ select * from public.rollback_import_batch(%L) $q$, v_batch),
    '%Reverse it with a journal%', '55000');
end $$;

-- =====================================================================
-- Who may import
--
-- An import rewrites the books. Somebody who can raise an invoice is
-- not somebody who should be able to stage twelve thousand of them.
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_me    uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Siapa Import Sdn Bhd');
  v_me := pg_temp.test_user();
  v_other := pg_temp.another_user('jurujual@siapaimport.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_other, 'sales', 'active')
  on conflict (org_id, user_id) do update set role = 'sales';

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a salesperson cannot start an import',
    format($q$ select public.start_import_batch(%L, 'autocount') $q$, v_org),
    '%needs an administrator%', '42501');

  -- CONTROL. An administrator can, so the refusal is about the role.
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_true(
    'while an administrator can',
    public.start_import_batch(v_org, 'autocount') is not null);
end $$;

rollback;

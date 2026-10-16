-- =====================================================================
-- iAkauntan :: 0910 only an import tags a row
--
-- `0610` put `import_source`, `import_ref`, `import_batch_id` and
-- `imported_at` on every table an import writes to, and
-- `rollback_import_batch` undoes an import by deleting, table by
-- table, every row whose `import_batch_id` is the batch's. The tag is
-- the whole of how a rollback knows what is its to delete.
--
-- The importers -- `import_sales_transactions`,
-- `import_purchase_transactions`, `import_journals`,
-- `import_bank_transactions` -- run as their owner and write the tag.
-- The app reads the four columns and never writes them. But they were
-- ordinary columns to a client, on fifteen of the nineteen tables.
--
-- Measured on 16 October 2026, locally: an accounts clerk -- who may
-- write contacts and items and may not start, finish or roll back an
-- import -- set the `import_batch_id` of a contact and an item the
-- company had typed in itself to the owner's open import batch, which
-- every staff member can read. The owner rolled the import back, and
-- both were deleted.
--
-- Production on 16 October: no import batches, and no row anywhere
-- with an import tag.
--
-- Answered "only imports tag rows": a client may not insert a row with
-- any of the four set, nor change any of them, on any table the
-- rollback reaches and a client can write. The importers run as their
-- owner and are not asked. The tables are taken from
-- `app.import_target_tables()` and the grants rather than written out,
-- and the block at the end refuses to finish if one is missed.
-- =====================================================================

create or replace function app.provenance_is_the_imports()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb := to_jsonb(new);
begin
  -- NOT security definer, for 0781's reason: the question is who runs
  -- the statement. The importers run as their owner.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  foreach v_col in array array['import_batch_id', 'import_source',
                               'import_ref', 'imported_at'] loop
    if tg_op = 'INSERT' and (v_new ->> v_col) is not null then
      raise exception
        'A row is tagged as imported by an import alone, and this one '
        'arrived saying % = %. Rolling an import back deletes every row '
        'it tagged.',
        v_col, v_new ->> v_col
        using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        '% records which import brought this row in, and is written by '
        'the import alone (% -> %). Rolling an import back deletes every '
        'row it tagged, so a tag set by hand deletes what it was set on.',
        v_col, coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.provenance_is_the_imports() from public, anon, authenticated;

comment on function app.provenance_is_the_imports() is
  'Refuses a client''s insert of a row with an import tag (import_batch_id, '
  'import_source, import_ref, imported_at) and a client''s change of one. '
  'rollback_import_batch deletes what an import tagged; the importers run '
  'as their owner and write the tag. 0910.';

-- Every table the rollback reaches that a client may insert into or
-- update.
do $do$
declare
  v_table text;
  v_count integer := 0;
begin
  foreach v_table in array app.import_target_tables() loop
    if has_table_privilege('authenticated', format('public.%I', v_table), 'insert')
       or has_table_privilege('authenticated', format('public.%I', v_table), 'update') then
      execute format(
        'create trigger provenance_is_the_imports
           before insert or update on public.%I
           for each row execute function app.provenance_is_the_imports()',
        v_table);
      v_count := v_count + 1;
    end if;
  end loop;

  -- The measured count on 16 October. A table that gains or loses a
  -- client grant changes it, and the person changing it should look.
  if v_count <> 15 then
    raise exception
      '0910 expected fifteen client-writable import tables and found %.',
      v_count;
  end if;
end
$do$;

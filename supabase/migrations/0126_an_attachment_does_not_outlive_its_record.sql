-- =====================================================================
-- iAkauntan :: an attachment does not outlive the record it is about
--
-- Deleting a draft bill left its attachment row behind, pointing at a
-- document that no longer exists. Thirteen of them had accumulated
-- before anybody looked, around 11 MB of receipts belonging to nothing.
-- They are invisible in the app — every screen reaches an attachment
-- through its parent — so they are not a bug anyone reports. They are a
-- bug somebody finds years later while trying to work out what a
-- storage bill is for.
--
-- ---------------------------------------------------------------------
-- Why this is not a foreign key
--
-- Asked for one, and it cannot be written. `attachments` is polymorphic:
-- `entity_table` names the parent and `entity_id` points into it, which
-- is what lets one table carry the paperwork for bills, claims, expenses
-- and companies alike. A foreign key needs one parent table named at
-- definition time, and there are ten. This is the same guarantee — a
-- child cannot outlive its parent — enforced the only way the shape
-- allows.
--
-- One trigger function, installed on each table that can be a parent.
-- `TG_TABLE_NAME` means the function does not need to know which table
-- it is running for, so adding a parent later is one `create trigger`
-- and no new logic.
--
-- ---------------------------------------------------------------------
-- Why an explicit list rather than every table
--
-- Every table in `public` with an `id` would need no maintenance and
-- would be worse: deleting an organization cascades to thousands of
-- rows, and each one would fire a delete against `attachments` looking
-- for something that was never there. Attachments only ever hang off
-- document-like records, so those are the ones that carry the trigger.
--
-- `supabase/tests/attachment_lifecycle.sql` asserts that every
-- `entity_table` actually present in `attachments` has its trigger, so
-- attaching to something new without one fails CI rather than quietly
-- growing the next pile of orphans.
-- =====================================================================

create or replace function app.delete_attachments_of_row()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  -- `TG_TABLE_NAME` is the table the trigger is installed on, which is
  -- exactly what `entity_table` holds.
  delete from public.attachments
   where entity_table = TG_TABLE_NAME
     and entity_id = old.id;
  return old;
end; $$;

-- A trigger function needs no EXECUTE grant — it runs as part of the
-- table operation, not through a caller's privilege — and left at the
-- default it would be executable by PUBLIC, which `anon` inherits.
-- `statutory.sql` guards exactly that, and caught this same omission on
-- `claim_chain_trigger` two migrations ago.
revoke all on function app.delete_attachments_of_row()
  from public, anon, authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'purchase_documents',
    'sales_documents',
    'expenses',
    'expense_claims',
    'corp_entities',
    'employees',
    'employee_documents',
    'leave_requests',
    'payslips',
    'contacts'
  ]
  loop
    execute format(
      'drop trigger if exists attachments_follow_the_record on public.%I',
      v_table);
    execute format(
      'create trigger attachments_follow_the_record
         after delete on public.%I
         for each row execute function app.delete_attachments_of_row()',
      v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The ones already stranded
--
-- Written as a join rather than a list of ids so it clears whatever is
-- actually orphaned when this runs, on any database, rather than the
-- thirteen that happened to exist when it was written.
--
-- The storage objects behind them are not touched. Deleting those needs
-- the storage API rather than SQL, and a migration that silently dropped
-- files would be a worse thing to have written than one that leaves a
-- known, findable remainder.
-- ---------------------------------------------------------------------
-- One pass per distinct `entity_table`, because "is the parent still
-- there" is a different query for each of them and the table name only
-- exists as a string. Written as a loop rather than one clever
-- statement: a single predicate mixing tables is the kind of thing that
-- reads fine and deletes the wrong rows.
do $$
declare
  v_entity text;
  v_gone int;
  v_total int := 0;
begin
  for v_entity in
    select distinct entity_table from public.attachments
  loop
    if to_regclass('public.' || v_entity) is null then
      -- The parent table itself is gone. Nothing can own these.
      delete from public.attachments where entity_table = v_entity;
    else
      execute format(
        'delete from public.attachments a
          where a.entity_table = %L
            and not exists (select 1 from public.%I p where p.id = a.entity_id)',
        v_entity, v_entity);
    end if;
    get diagnostics v_gone = row_count;
    v_total := v_total + v_gone;
  end loop;

  raise notice 'cleared % orphaned attachment rows', v_total;
end $$;

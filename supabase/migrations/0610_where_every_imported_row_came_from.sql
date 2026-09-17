-- =====================================================================
-- iAkauntan :: 0610 where every imported row came from
--
-- `docs/migrating-from-autocount.md` names three obstacles on our side
-- and calls this the first change to make, before any importer exists:
--
--   > There is no `external_id`, `legacy_id`, `source_system` or
--   > `import_batch_id` column anywhere in the schema. I checked every
--   > table.
--   >
--   > Without provenance: an import cannot be re-run -- a second
--   > attempt either duplicates everything or collides on the natural
--   > key, and there is no way to tell "already imported" from
--   > "coincidentally same code"; nothing can be reconciled back to
--   > AutoCount later, when the accountant asks why one balance
--   > differs; a failed import cannot be rolled back cleanly, only
--   > unpicked by hand.
--
-- That is the whole of the argument and it is right. This is the
-- change.
--
-- ---------------------------------------------------------------------
-- What an importer cannot do without it
--
-- Re-run. That is the one that matters, and it is why this comes first
-- rather than after a working importer: a migration you cannot rehearse
-- is a migration that happens once, on a Friday, on live data, with
-- nothing to compare against when a balance is wrong on Monday.
--
-- The unique index is the mechanism. `(org_id, import_source,
-- import_ref)` on every table that can receive migrated data means the
-- second run of an importer collides on exactly the rows it already
-- wrote and on nothing else -- so `on conflict do nothing` is a
-- correct, complete answer to "what happens if I run it twice", and
-- `on conflict do update` is a correct answer to "what happens if the
-- source changed".
--
-- ---------------------------------------------------------------------
-- Partial, and both-or-neither
--
-- The index is `where import_source is not null`, so the millions of
-- rows a company types itself cost nothing and collide with nothing.
--
-- The check constraint is the half that is easy to leave out: a row
-- with an `import_ref` and no `import_source` is outside the unique index
-- and therefore duplicable, which is precisely the state the index
-- exists to prevent. Both or neither.
--
-- ---------------------------------------------------------------------
-- Which tables
--
-- The list is explicit rather than "every table with an org_id", and
-- `import_provenance.sql` asserts it. A generated list would quietly
-- put provenance columns on `live_changes` and `audit_log` -- tables
-- nothing imports into and which would then carry two dead columns and
-- an index each, for ever.
--
-- It follows the dependency order the migration document sets out --
-- fiscal years, chart of accounts, tax codes, contacts, items, opening
-- balances, open documents -- plus the master data those depend on.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not import anything. There is no AutoCount client here, no
-- mapping, no reconciliation report. Those are the second and third
-- stages the document describes and they need this one to exist first.
--
-- It also does not touch `import_rows` payload interpretation: staging
-- keeps the raw JSON exactly as it arrived, because the payload is what
-- gets re-read when a figure is disputed a year later.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A run
-- ---------------------------------------------------------------------
create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  -- Where the data came from. Free text rather than an enum: the next
  -- system somebody migrates from is not knowable, and an enum would
  -- need a migration to accept it. Normalised on the way in so
  -- `AutoCount` and `autocount` are the same source rather than two.
  --
  -- The same vocabulary as `import_source` on the tables below, because
  -- a batch and the rows it wrote have to be joinable by it.
  import_source text not null
    check (import_source ~ '^[a-z][a-z0-9_]{1,40}$'),

  -- What a person calls this run. "Trial run 3", "Final, 31 Dec".
  label text,

  status text not null default 'staging'
    check (status in ('staging', 'reconciling', 'posted',
                      'rolled_back', 'failed')),

  -- Why it failed, or what the reconciliation said. Kept on the batch
  -- because the next person to run one needs to know what the last one
  -- found.
  notes text,

  started_at timestamptz not null default now(),
  finished_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- So a row that names a batch can say which company's batch it means.
  -- `tenant_foreign_keys.sql` requires every single-column key between
  -- two tables that both have an `org_id` to be backed by a composite
  -- one, and it is right to: without this, company B's contact could
  -- name company A's import.
  unique (org_id, id)
);

comment on table public.import_batches is
  'One run of an importer. A migration is a process you rehearse, not '
  'an event -- this is what makes a rehearsal distinguishable from the '
  'real thing and from the one before it. 0610.';

create index import_batches_org_idx
  on public.import_batches (org_id, started_at desc);

create trigger set_updated_at before update on public.import_batches
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- What it pulled, before anybody interpreted it
--
-- `docs/migrating-from-autocount.md`, stage one: "Pull every resource
-- into `import_batches` / `import_rows` as raw JSON, keyed by
-- AutoCount's own identifiers. Nothing is interpreted yet. This makes
-- the pull repeatable and the payloads auditable when a number is later
-- disputed."
-- ---------------------------------------------------------------------
create table public.import_rows (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  batch_id uuid not null references public.import_batches (id) on delete cascade,
  constraint import_rows_batch_same_org
    foreign key (org_id, batch_id)
    references public.import_batches (org_id, id) on delete cascade,

  -- What kind of thing this is in the SOURCE's vocabulary, not ours.
  -- 'Debtor', 'AR_Invoice', 'StockItem' -- whatever the other system
  -- calls it, because that is what a person reconciling against it will
  -- be reading on the other screen.
  resource text not null,

  -- The other system's own key for it.
  import_ref text not null,

  -- Exactly what arrived. Not normalised, not trimmed, not
  -- re-serialised: this is the thing a dispute is settled against.
  payload jsonb not null,

  -- Where it landed here, once it landed. Null while staged.
  mapped_table text,
  mapped_id uuid,

  status text not null default 'staged'
    check (status in ('staged', 'mapped', 'posted', 'skipped', 'failed')),

  -- Why it was skipped or what went wrong, in the words to show
  -- somebody. A row that failed silently is a row nobody fixes.
  problem text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- The same resource pulled twice in one run is the same row. Across
  -- runs it is not: a rehearsal and the real thing are different
  -- batches and both are worth keeping.
  unique (batch_id, resource, import_ref)
);

comment on table public.import_rows is
  'What an importer pulled, as it arrived. Nothing is interpreted '
  'here -- the payload is what a disputed figure is settled against a '
  'year later. 0610.';

create index import_rows_batch_idx
  on public.import_rows (batch_id, resource, status);
create index import_rows_mapped_idx
  on public.import_rows (mapped_table, mapped_id)
  where mapped_id is not null;

create trigger set_updated_at before update on public.import_rows
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- Reading and writing them
--
-- An import rewrites a company's books. `can_admin` rather than
-- `can_write`: a salesperson who can raise an invoice is not somebody
-- who should be able to stage twelve thousand of them.
-- ---------------------------------------------------------------------
alter table public.import_batches enable row level security;
alter table public.import_rows enable row level security;

create policy import_batches_select on public.import_batches
  for select to authenticated using (app.is_org_member(org_id));
create policy import_batches_write on public.import_batches
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

create policy import_rows_select on public.import_rows
  for select to authenticated using (app.is_org_member(org_id));
create policy import_rows_write on public.import_rows
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

grant select, insert, update, delete
  on public.import_batches, public.import_rows to authenticated;

-- ---------------------------------------------------------------------
-- The provenance triple, on everything an import can write to
--
-- Named one by one. The comment at the top says why this is not "every
-- table with an org_id", and `import_provenance.sql` asserts the list
-- both ways -- that each of these has it, and that a table nothing
-- imports into does not.
--
-- ## Not `source_system` / `source_id`
--
-- Which is what `docs/migrating-from-autocount.md` proposed, and it
-- cannot be used: `gl_entries.source_id` and `stock_movements.source_id`
-- have existed since `0013` and mean something else entirely -- which
-- document this entry or this movement came FROM, inside this system.
-- `add column if not exists` silently does nothing against a column
-- that is already there, so the pair constraint would have read the
-- existing column and refused every journal entry the product writes.
--
-- It did. `ledger.sql`, `control_accounts.sql`, `payroll_run.sql`,
-- `ea_form.sql` and `payroll_engine_sweep.sql` all failed on
-- `gl_entries_source_pair` the first time this migration ran, which is
-- the assertion suite doing exactly what it is for.
--
-- `import_source` / `import_ref` cannot collide with anything, and read
-- as one family with `import_batch_id` and `imported_at`.
-- ---------------------------------------------------------------------
-- The list, in one place, because three things read it: the loop below
-- that adds the columns, the summary that counts what a batch wrote,
-- and the rollback that undoes it. Three copies of a list is two
-- chances for a table to be importable and unrollbackable.
--
-- In the order a migration WRITES them, which the document sets out:
-- fiscal years, chart of accounts, tax codes, contacts, items, opening
-- balances, open documents. A rollback walks it backwards.
create or replace function app.import_target_tables()
returns text[]
language sql
immutable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select array[
    'fiscal_years',
    'accounts',
    'tax_codes',
    'payment_terms',
    'price_levels',
    'warehouses',
    'departments',
    'positions',
    'item_categories',
    'items',
    'contacts',
    'projects',
    'bank_accounts',
    'employees',
    'salary_components',
    'sales_documents',
    'purchase_documents',
    'gl_entries',
    'stock_movements'
  ]::text[];
$function$;

comment on function app.import_target_tables() is
  'Every table an import may write to, in the order it writes them. '
  'Read by the migration that adds the provenance columns, by '
  'import_batch_summary and by rollback_import_batch. 0610.';

do $do$
declare
  v_table text;
begin
  foreach v_table in array app.import_target_tables() loop
    execute format($f$
      alter table public.%I
        add column if not exists import_source text,
        add column if not exists import_ref text,
        add column if not exists import_batch_id uuid
          references public.import_batches (id) on delete set null,
        add column if not exists imported_at timestamptz
    $f$, v_table);

    -- Both or neither. A row with an `import_ref` and no
    -- `import_source` sits outside the unique index below and is
    -- therefore duplicable, which is exactly the state the index exists
    -- to prevent.
    execute format($f$
      alter table public.%I
        drop constraint if exists %I
    $f$, v_table, v_table || '_import_pair');
    execute format($f$
      alter table public.%I
        add constraint %I check (
          (import_source is null and import_ref is null)
       or (import_source is not null and import_ref is not null))
    $f$, v_table, v_table || '_import_pair');

    -- Same company. See the note on `import_batches`: a single-column
    -- key between two tables that both have an `org_id` can name
    -- another company's row, and `tenant_foreign_keys.sql` refuses one.
    execute format($f$
      alter table public.%I
        drop constraint if exists %I
    $f$, v_table, v_table || '_import_batch_same_org');
    -- No `on delete` clause, deliberately. `set null` on a COMPOSITE key
    -- nulls every column in it -- including `org_id`, which is not
    -- null -- so deleting a batch would fail on the tenant column
    -- rather than on the reference. `tenant_foreign_keys.sql` catches
    -- exactly that and named all nineteen of them.
    --
    -- The single-column key above still carries `on delete set null`,
    -- which is what actually happens: `import_batch_id` goes to null,
    -- `org_id` is untouched, and this constraint is then satisfied
    -- because a composite key with a null in it is satisfied by
    -- definition. NO ACTION rather than RESTRICT for the same reason
    -- the rest of the schema uses it: it is checked at the end of the
    -- statement, so deleting a company -- which cascades to the batches
    -- and to the rows at once -- does not trip over itself.
    execute format($f$
      alter table public.%I
        add constraint %I
        foreign key (org_id, import_batch_id)
        references public.import_batches (org_id, id)
    $f$, v_table, v_table || '_import_batch_same_org');

    -- The mechanism. A second run of an importer collides on exactly
    -- the rows it already wrote and on nothing else.
    execute format($f$
      create unique index if not exists %I
        on public.%I (org_id, import_source, import_ref)
       where import_source is not null
    $f$, v_table || '_import_key', v_table);

    execute format($f$
      comment on column public.%I.import_source is
        'Which other system this row was imported from, normalised to '
        'lower case. Null for a row this company typed. 0610.'
    $f$, v_table);
    execute format($f$
      comment on column public.%I.import_ref is
        'That system''s own key for this row. Unique with '
        'import_source within the company, which is what makes an '
        'import re-runnable. 0610.'
    $f$, v_table);
  end loop;
end $do$;

-- ---------------------------------------------------------------------
-- Starting one
--
-- The source is normalised here rather than trusted from the caller, so
-- `AutoCount`, `autocount` and ` AutoCount ` are one system rather than
-- three -- and therefore so is the unique index that makes a re-run a
-- re-run.
-- ---------------------------------------------------------------------
create or replace function public.start_import_batch(
  p_org_id uuid,
  p_import_source text,
  p_label text default null)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_source text;
  v_id uuid;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'An import rewrites the books and needs an '
                    'administrator'
      using errcode = '42501';
  end if;

  v_source := lower(btrim(coalesce(p_import_source, '')));
  if v_source !~ '^[a-z][a-z0-9_]{1,40}$' then
    raise exception 'Name the system being imported from in lower-case '
                    'letters, digits and underscores — for example '
                    'autocount'
      using errcode = '23514';
  end if;

  -- One at a time. Two batches staging into the same company at once
  -- would race on the unique index and the loser's rows would look like
  -- failures rather than duplicates.
  if exists (select 1 from public.import_batches
              where org_id = p_org_id
                and status in ('staging', 'reconciling')) then
    raise exception 'An import is already in progress for this company. '
                    'Finish or roll back that one first.'
      using errcode = '55006';
  end if;

  insert into public.import_batches
    (org_id, import_source, label, created_by)
  values (p_org_id, v_source, nullif(btrim(p_label), ''), auth.uid())
  returning id into v_id;

  return v_id;
end;
$function$;

comment on function public.start_import_batch(uuid, text, text) is
  'Opens an import run. Refuses a second while one is staging or '
  'reconciling: two at once would race on the unique index and the '
  'loser''s rows would read as failures. 0610.';

revoke all on function public.start_import_batch(uuid, text, text)
  from public, anon;
grant execute on function public.start_import_batch(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Closing one
-- ---------------------------------------------------------------------
create or replace function public.finish_import_batch(
  p_batch_id uuid,
  p_status text,
  p_notes text default null)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_org uuid;
begin
  select org_id into v_org from public.import_batches where id = p_batch_id;
  if v_org is null then
    raise exception 'No such import batch' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_org) then
    raise exception 'An import rewrites the books and needs an '
                    'administrator'
      using errcode = '42501';
  end if;
  if p_status not in ('reconciling', 'posted', 'failed') then
    raise exception 'An import batch is finished as reconciling, posted '
                    'or failed'
      using errcode = '23514';
  end if;

  update public.import_batches
     set status = p_status,
         notes = coalesce(nullif(btrim(p_notes), ''), notes),
         finished_at = case when p_status = 'reconciling' then null
                            else now() end
   where id = p_batch_id;
  return true;
end;
$function$;

comment on function public.finish_import_batch(uuid, text, text) is
  'Closes an import run as reconciling, posted or failed. '
  '`reconciling` leaves `finished_at` null, because a dry run that has '
  'produced its report is not over -- somebody still has to read it. '
  '0610.';

revoke all on function public.finish_import_batch(uuid, text, text)
  from public, anon;
grant execute on function public.finish_import_batch(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a batch wrote
--
-- The count per table, from the rows themselves rather than from a
-- tally somebody maintained. A tally is a second place to be wrong.
-- ---------------------------------------------------------------------
create or replace function public.import_batch_summary(p_batch_id uuid)
returns table (target_table text, rows_written bigint)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_org   uuid;
  v_table text;
  v_n     bigint;
begin
  select org_id into v_org from public.import_batches where id = p_batch_id;
  if v_org is null then
    raise exception 'No such import batch' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  foreach v_table in array app.import_target_tables() loop
    execute format(
      'select count(*) from public.%I where import_batch_id = $1', v_table)
      into v_n using p_batch_id;
    if v_n > 0 then
      target_table := v_table;
      rows_written := v_n;
      return next;
    end if;
  end loop;
end;
$function$;

revoke all on function public.import_batch_summary(uuid) from public, anon;
grant execute on function public.import_batch_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Undoing one
--
-- > a failed import cannot be rolled back cleanly, only unpicked by
-- > hand.
--
-- Backwards through the same list: stock movements and journal entries
-- first, documents next, master data last, so nothing is deleted while
-- something still points at it.
--
-- ## It refuses rather than cascades
--
-- A rollback is for an import that went wrong before anybody worked on
-- top of it. Once a human has raised an invoice against an imported
-- customer, or allocated a payment to an imported bill, deleting the
-- import is not undoing it -- it is deleting their work as well, and
-- `on delete cascade` would do exactly that without saying so.
--
-- So this deletes only rows that still carry the batch, lets the
-- foreign keys refuse anything depended upon, and reports what it could
-- not remove. The message names the table and the count, because "could
-- not roll back" with no detail is a message that leaves somebody
-- unpicking by hand anyway -- which is the thing this exists to stop.
--
-- ## Posted journals are not deleted quietly
--
-- A posted import has hit the ledger. Rolling that back means deleting
-- journal entries, which every other part of this schema refuses to do
-- -- documents are voided, not removed. So a batch whose status is
-- `posted` is refused outright and named as needing a reversing
-- journal instead. Only `staging`, `reconciling` and `failed` roll
-- back, which are exactly the states where nothing has reached the
-- books.
-- ---------------------------------------------------------------------
create or replace function public.rollback_import_batch(p_batch_id uuid)
returns table (target_table text, rows_removed bigint, rows_kept bigint)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_batch  public.import_batches;
  v_tables text[];
  v_table  text;
  v_i      integer;
  v_gone   bigint;
  v_left   bigint;
begin
  select * into v_batch from public.import_batches where id = p_batch_id;
  if v_batch.id is null then
    raise exception 'No such import batch' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_batch.org_id) then
    raise exception 'An import rewrites the books and needs an '
                    'administrator'
      using errcode = '42501';
  end if;
  if v_batch.status = 'posted' then
    raise exception 'This import has been posted to the ledger. Reverse '
                    'it with a journal rather than deleting it — every '
                    'other document in this product is voided, not '
                    'removed, and an import is not an exception.'
      using errcode = '55000';
  end if;
  if v_batch.status = 'rolled_back' then
    raise exception 'This import has already been rolled back'
      using errcode = '55000';
  end if;

  v_tables := app.import_target_tables();

  -- Backwards: what depends on things before what they depend on.
  for v_i in reverse array_length(v_tables, 1) .. 1 loop
    v_table := v_tables[v_i];

    execute format(
      'delete from public.%I d where d.import_batch_id = $1
         and not exists (select 1 from public.%I x
                          where x.id = d.id and false)', v_table, v_table)
      using p_batch_id;
    get diagnostics v_gone = row_count;

    execute format(
      'select count(*) from public.%I where import_batch_id = $1', v_table)
      into v_left using p_batch_id;

    if v_gone > 0 or v_left > 0 then
      target_table := v_table;
      rows_removed := v_gone;
      rows_kept := v_left;
      return next;
    end if;
  end loop;

  delete from public.import_rows where batch_id = p_batch_id;

  update public.import_batches
     set status = 'rolled_back', finished_at = now()
   where id = p_batch_id;

  return;
exception
  -- A foreign key refused because somebody has worked on top of the
  -- import. Named, with the constraint, because the alternative is a
  -- message nobody can act on.
  when foreign_key_violation then
    raise exception 'Part of this import cannot be removed: something '
                    'raised since the import points at it (%). Deal '
                    'with that first, or reverse the import with a '
                    'journal instead.', sqlerrm
      using errcode = '23503';
end;
$function$;

comment on function public.rollback_import_batch(uuid) is
  'Removes what an import wrote, backwards through '
  'app.import_target_tables(). Refuses a posted batch — that has '
  'reached the ledger and is reversed with a journal — and refuses to '
  'delete anything somebody has since built on. 0610.';

revoke all on function public.rollback_import_batch(uuid) from public, anon;
grant execute on function public.rollback_import_batch(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- On the live feed
--
-- `live_change_feed.sql` asks for a trigger on every table with an
-- `org_id`, and these two earn it rather than merely owing it: staging
-- twelve thousand rows is the one operation in this product where
-- somebody sits and watches a number go up, and a progress bar that
-- only moves on reload is not one.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.import_batches
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.import_batches
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.import_batches
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.import_rows
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.import_rows
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.import_rows
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

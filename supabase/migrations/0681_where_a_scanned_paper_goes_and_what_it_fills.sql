-- =====================================================================
-- iAkauntan :: 0681 where a scanned paper goes, and what it fills
--
-- `0614` gave a scanned document a KIND -- "Supplier's bill", "Bank
-- statement" -- and a `destination` that is free text, because "the
-- destinations are screens, and a screen is not a row". That was true
-- and it left two things undone.
--
-- The destination named a screen and nothing else. It could not say
-- which module the screen belongs to, and it could not say what that
-- screen has ROOM for -- so the reader was asked the same eleven
-- questions about every document ever scanned, out of one hard-coded
-- schema in `supabase/functions/ocr/index.ts`, whether the paper was a
-- bill, a bank statement or a name card.
--
-- ---------------------------------------------------------------------
-- Discovered, then ticked
--
-- The fields on offer are the REAL COLUMNS of the table the target
-- writes, read out of `information_schema` at the moment the console
-- asks. Not a list somebody typed: a list somebody typed goes stale
-- the first time a column is renamed, and goes stale silently, and the
-- symptom is a reader being asked for a field that no longer exists
-- and a bookkeeper wondering why it never fills in.
--
-- What is stored is the TICK -- which of those real columns the reader
-- should be asked for, and the sentence to ask it with. A tick on a
-- column that does not exist is refused at the moment it is saved, so
-- the stored set cannot outlive the schema it describes.
--
-- The fields belong to the TARGET and not to the kind. A delivery
-- order and a supplier's bill both land in purchasing; configuring the
-- same columns twice is two lists that will disagree by Thursday.
--
-- ---------------------------------------------------------------------
-- What is deliberately NOT discovered
--
-- `id`, `org_id`, the four audit columns and anything generated. A
-- reader cannot supply them, and a schema that asked for them would
-- spend tokens inviting a model to invent a uuid.
--
-- Foreign keys ARE offered, and are marked. `purchase_documents.
-- contact_id` cannot be read off a bill -- what is printed is a
-- supplier's NAME -- but it is the honest place to hang "the supplier
-- as printed, which will be matched to a contact", and hiding it would
-- leave the one field every bill has no way of being asked for.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A target: one module, one action, one table
-- ---------------------------------------------------------------------
create table public.scan_targets (
  module_code text not null
    references public.platform_modules (code) on update cascade,
  action      text not null check (action ~ '^[a-z][a-z0-9_]{1,40}$'),

  label       text not null check (btrim(label) <> ''),

  -- The table the action writes. Checked against the catalog when a
  -- field is saved, which is what stops the field list describing a
  -- table nobody has had for a year.
  table_name  text not null,

  -- Kept so `0614`'s free-text destination keeps working unchanged.
  -- The app still routes on it; this column is how a target says which
  -- of those screens it is.
  destination text,

  hint        text,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  primary key (module_code, action)
);

comment on table public.scan_targets is
  'Where a scanned document can be turned into a record: a module, an '
  'action within it, and the table that action writes. The table name '
  'is load-bearing -- the console reads its real columns out of '
  '`information_schema` to offer them, so a target naming a table that '
  'does not exist offers nothing rather than offering a lie. 0681.';

-- Readable by anybody signed in -- it is a list of screens, not a
-- secret -- and writable by nobody. Every write goes through
-- `set_scan_target_fields` and `set_scan_kind_target`, which are
-- SECURITY DEFINER and check `is_platform_admin` themselves. A write
-- POLICY as well would be a second gate nothing can reach: no INSERT
-- or UPDATE is granted, so the policy would never be consulted, and
-- `table_grants.sql` calls that out by name.
alter table public.scan_targets enable row level security;
create policy scan_targets_read on public.scan_targets
  for select to authenticated using (true);
grant select on public.scan_targets to authenticated;

create trigger set_updated_at_scan_targets before update
  on public.scan_targets for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- A tick: this column, asked for in these words
-- ---------------------------------------------------------------------
create table public.scan_target_fields (
  module_code text not null,
  action      text not null,
  column_name text not null,

  -- What the reader is told to look for. The column name is what the
  -- answer comes back under; this is what makes the question
  -- answerable, and a field with none is a field the model guesses at.
  description text,

  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (module_code, action, column_name),
  foreign key (module_code, action)
    references public.scan_targets (module_code, action) on delete cascade
);

comment on table public.scan_target_fields is
  'Which of a target''s real columns the reader is asked to fill, and '
  'the sentence it is asked with. A row here is a tick on the console''s '
  'checklist; unticking deletes it. `set_scan_target_fields` refuses a '
  'column the target''s table does not have, so this set cannot outlive '
  'the schema it describes. 0681.';

alter table public.scan_target_fields enable row level security;
create policy scan_target_fields_read on public.scan_target_fields
  for select to authenticated using (true);
grant select on public.scan_target_fields to authenticated;

create trigger set_updated_at_scan_target_fields before update
  on public.scan_target_fields for each row
  execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- The kind points at a target
--
-- Added beside `destination` rather than instead of it. The app routes
-- on `destination` today and a migration that took it away would stop
-- every scan reaching a screen; the trigger below keeps the two in
-- step so neither can be edited into disagreeing with the other.
-- ---------------------------------------------------------------------
alter table public.scan_document_kinds
  add column if not exists target_module text,
  add column if not exists target_action text;

alter table public.scan_document_kinds
  drop constraint if exists scan_document_kinds_target_fkey;
-- `set null (target_module, target_action)` spelled out rather than a
-- bare `set null`. On a two-column key the bare form nulls EVERY
-- referencing column, which is the same thing here and would stop
-- being the same thing the day somebody adds a third column to this
-- key. `tenant_foreign_keys.sql` refuses the bare form for exactly
-- that reason.
alter table public.scan_document_kinds
  add constraint scan_document_kinds_target_fkey
  foreign key (target_module, target_action)
  references public.scan_targets (module_code, action)
  on delete set null (target_module, target_action);

create or replace function app.scan_kind_destination()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  -- The target is the answer when there is one. `destination` stays the
  -- column the app reads, so pointing a kind at a target moves it
  -- without anybody having to edit two fields and get them to match.
  if new.target_module is not null and new.target_action is not null then
    select t.destination into new.destination
      from public.scan_targets t
     where t.module_code = new.target_module and t.action = new.target_action;
  end if;
  return new;
end;
$$;

create trigger scan_kind_destination
  before insert or update on public.scan_document_kinds
  for each row execute function app.scan_kind_destination();

-- ---------------------------------------------------------------------
-- The targets this ships with
--
-- One per destination `0614` already named, so every existing kind can
-- be pointed at one without inventing anything. `bank_import` is left
-- out on purpose: a statement becomes MANY rows, and a field list that
-- describes one record cannot describe it.
-- ---------------------------------------------------------------------
insert into public.scan_targets
  (module_code, action, label, table_name, destination, hint, sort_order)
values
  ('purchases', 'bill', 'A supplier''s bill', 'purchase_documents',
   'purchase_document',
   'Becomes a bill, with the supplier and the lines filled in.', 10),
  ('purchases', 'purchase_order', 'A purchase order', 'purchase_documents',
   'purchase_document',
   'Becomes an order once somebody accepts the price.', 20),
  ('purchases', 'goods_received', 'A goods received note',
   'purchase_documents', 'goods_received',
   'Becomes a receipt of goods against an order.', 30),
  ('accounting', 'expense', 'An expense claim', 'expenses', 'expense',
   'Becomes an expense you can attach to a payment.', 40),
  ('contacts', 'contact', 'A contact', 'contacts', 'contact',
   'Becomes a customer or a supplier.', 50)
on conflict (module_code, action) do nothing;

-- The kinds that already name one of those destinations get the target
-- that matches. Nothing is guessed: only an exact match moves.
update public.scan_document_kinds k
   set target_module = t.module_code, target_action = t.action
  from public.scan_targets t
 where k.destination = t.destination
   and k.target_module is null
   and t.action in ('bill', 'expense', 'goods_received', 'contact');

-- ---------------------------------------------------------------------
-- What the console offers: the real columns, with the ticks beside them
--
-- One call, because the checklist is one screen. A column the target's
-- table does not have cannot appear here, which is the whole point --
-- and a ticked column that has since been dropped appears with
-- `exists` false rather than vanishing, so somebody can see what
-- happened instead of wondering where their configuration went.
-- ---------------------------------------------------------------------
create or replace function public.scan_target_columns(
  p_module text, p_action text)
returns table (
  column_name text,
  data_type   text,
  is_required boolean,
  is_foreign  boolean,
  is_asked    boolean,
  description text,
  sort_order  integer,
  still_there boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_table text;
begin
  if not app.is_platform_admin() then
    return;
  end if;

  select t.table_name into v_table from public.scan_targets t
   where t.module_code = p_module and t.action = p_action;
  if v_table is null then
    return;
  end if;

  return query
  with real_columns as (
    select c.column_name::text as name,
           c.data_type::text   as kind,
           c.is_nullable = 'NO' and c.column_default is null as required,
           exists (
             select 1
               from information_schema.key_column_usage k
               join information_schema.table_constraints tc
                 on tc.constraint_name = k.constraint_name
                and tc.constraint_schema = k.constraint_schema
              where k.table_schema = 'public'
                and k.table_name = v_table
                and k.column_name = c.column_name
                and tc.constraint_type = 'FOREIGN KEY') as foreign_key
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name = v_table
       -- Plumbing a reader cannot supply. Asking for them would spend
       -- tokens inviting a model to invent a uuid.
       and c.column_name not in (
             'id', 'org_id', 'created_at', 'created_by',
             'updated_at', 'updated_by', 'deleted_at')
       and c.is_generated = 'NEVER'
       and c.is_identity = 'NO'
  )
  select coalesce(rc.name, f.column_name),
         coalesce(rc.kind, 'gone'),
         coalesce(rc.required, false),
         coalesce(rc.foreign_key, false),
         f.column_name is not null,
         f.description,
         coalesce(f.sort_order, 100),
         rc.name is not null
    from real_columns rc
    full outer join public.scan_target_fields f
      on f.column_name = rc.name
     and f.module_code = p_module
     and f.action = p_action
   order by (f.column_name is not null) desc, coalesce(f.sort_order, 100),
            coalesce(rc.name, f.column_name);
end;
$$;

comment on function public.scan_target_columns(text, text) is
  'The real columns of the table a target writes, read out of '
  '`information_schema`, with a tick beside the ones the reader is '
  'asked for. A FULL OUTER JOIN on purpose: a column that was ticked '
  'and has since been dropped comes back with `still_there` false '
  'rather than disappearing, so an operator sees what happened instead '
  'of wondering where the configuration went. Platform administrators '
  'only, and no rows rather than an exception for anybody else.';

revoke all on function public.scan_target_columns(text, text)
  from public, anon;
grant execute on function public.scan_target_columns(text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Saving the ticks
--
-- Replaces the set rather than merging it: the console sends what is
-- ticked, and a merge would make unticking impossible.
-- ---------------------------------------------------------------------
create or replace function public.set_scan_target_fields(
  p_module text, p_action text, p_fields jsonb)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_table text;
  v_bad   text;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  select t.table_name into v_table from public.scan_targets t
   where t.module_code = p_module and t.action = p_action;
  if v_table is null then
    raise exception 'No such target: % / %', p_module, p_action
      using errcode = '23514';
  end if;

  -- The honesty check, and the reason this is a function rather than a
  -- pair of policies. A tick on a column the table does not have is a
  -- field the reader would be asked for for ever and that could never
  -- be filled in, and nothing downstream would ever complain.
  select string_agg(x.name, ', ') into v_bad
    from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) e
    cross join lateral (select e ->> 'column_name' as name) x
   where not exists (
     select 1 from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = v_table
        and c.column_name = x.name);
  if v_bad is not null then
    raise exception '% has no column called %', v_table, v_bad
      using errcode = '23514';
  end if;

  delete from public.scan_target_fields
   where module_code = p_module and action = p_action;

  insert into public.scan_target_fields
    (module_code, action, column_name, description, sort_order)
  select p_module, p_action,
         e ->> 'column_name',
         nullif(btrim(coalesce(e ->> 'description', '')), ''),
         coalesce((e ->> 'sort_order')::integer, 100)
    from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) e
   where coalesce(btrim(e ->> 'column_name'), '') <> ''
  on conflict (module_code, action, column_name) do update
    set description = excluded.description,
        sort_order  = excluded.sort_order,
        updated_at  = now();
end;
$$;

comment on function public.set_scan_target_fields(text, text, jsonb) is
  'Replaces which of a target''s columns the reader is asked to fill. '
  'REPLACES rather than merges, because the console sends what is '
  'ticked and a merge would make unticking impossible. Refuses a '
  'column the target''s table does not have -- a tick on a column that '
  'is not there is a field asked for for ever and never filled, and '
  'nothing downstream would complain. Platform administrators only.';

revoke all on function public.set_scan_target_fields(text, text, jsonb)
  from public, anon;
grant execute on function public.set_scan_target_fields(text, text, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- What goes to the reader with the document
--
-- Every active target that has fields ticked, each with the kinds of
-- paper that land there, so the model has both halves of the question:
-- what this could be, and what each of those needs.
--
-- Only targets with fields. A target nobody has configured contributes
-- an empty object to a prompt and a choice the model can make and
-- never fill, which is worse than not offering it.
-- ---------------------------------------------------------------------
create or replace function public.scan_extraction_targets()
returns jsonb
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x order by x ->> 'key'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'key', t.module_code || '.' || t.action,
               'label', t.label,
               'hint', t.hint,
               'kinds', (select coalesce(jsonb_agg(k.label order by k.sort_order), '[]'::jsonb)
                           from public.scan_document_kinds k
                          where k.target_module = t.module_code
                            and k.target_action = t.action
                            and k.is_active),
               'fields', (select jsonb_agg(jsonb_build_object(
                              'name', f.column_name,
                              'description', f.description)
                              order by f.sort_order, f.column_name)
                            from public.scan_target_fields f
                           where f.module_code = t.module_code
                             and f.action = t.action)) as x
        from public.scan_targets t
       where t.is_active
         and exists (select 1 from public.scan_target_fields f
                      where f.module_code = t.module_code
                        and f.action = t.action)
    ) s;
$$;

comment on function public.scan_extraction_targets() is
  'What the reader is sent with the document: every configured target, '
  'the kinds of paper that land there, and the fields each one wants '
  'filled. The model answers with a target and a value per field, '
  'which is what lets one read decide both WHAT the paper is and WHERE '
  'it goes. Only targets with fields ticked -- an empty one is a choice '
  'the model can make and never fill.';

revoke all on function public.scan_extraction_targets() from public, anon;
grant execute on function public.scan_extraction_targets()
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Pointing a kind at a target
--
-- Its own function rather than two more arguments on
-- `platform_save_scan_kind`, whose signature `0614` published and
-- whose seven-argument form is already written down in a comment and
-- in `docs/api`. Adding to it would create an overload, and two
-- functions of one name taking almost the same arguments is the next
-- person calling the wrong one.
--
-- Null for both clears the target, which is how a kind goes back to
-- being filed and nothing else. `destination` follows either way --
-- the trigger above sets it from the target, and clearing the target
-- leaves whatever destination was last chosen, because a kind that
-- pointed at the purchases screen should not stop opening it merely
-- because somebody unpicked the field mapping.
-- ---------------------------------------------------------------------
create or replace function public.set_scan_kind_target(
  p_code text, p_module text default null, p_action text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'What a scan can be recognised as is the whole '
                    'platform''s list and may only be changed by a '
                    'platform administrator'
      using errcode = '42501';
  end if;

  if (p_module is null) <> (p_action is null) then
    raise exception 'A target is a module AND an action, or neither'
      using errcode = '23514';
  end if;

  if p_module is not null and not exists (
       select 1 from public.scan_targets t
        where t.module_code = p_module and t.action = p_action) then
    raise exception 'No such target: % / %', p_module, p_action
      using errcode = '23514';
  end if;

  update public.scan_document_kinds
     set target_module = p_module,
         target_action = p_action,
         updated_at = now()
   where code = p_code;

  if not found then
    raise exception 'No kind of document called %', p_code
      using errcode = '42704';
  end if;
end;
$$;

comment on function public.set_scan_kind_target(text, text, text) is
  'Points a kind of document at the module and action a scan of it '
  'becomes, or at neither. Its own function rather than two more '
  'arguments on `platform_save_scan_kind`, whose signature is already '
  'published -- an overload taking almost the same arguments is the '
  'next person calling the wrong one. `destination` follows from the '
  'target by trigger, so the screen a scan opens and the fields it '
  'fills cannot be edited into disagreeing.';

revoke all on function public.set_scan_kind_target(text, text, text)
  from public, anon;
grant execute on function public.set_scan_kind_target(text, text, text)
  to authenticated;

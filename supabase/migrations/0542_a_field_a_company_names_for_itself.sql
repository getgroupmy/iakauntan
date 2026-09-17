-- =====================================================================
-- 0542. A field a company names for itself
--
-- ELEVEN TABLES HAVE CARRIED `custom_fields jsonb` SINCE 0003, 0008 AND
-- 0021, AND NOTHING HAS EVER WRITTEN ONE. Not a screen, not an RPC, not
-- an importer. The column is on contacts, employees, items, leads,
-- matters, opportunities, tickets, both document headers and both
-- document line tables — the eleven records a business actually keeps —
-- and in the whole life of this product it has held `{}` on every row.
--
-- So this is not a storage problem. The storage was always there. What
-- was missing is a definition of what may go in it, a rule that says so
-- at the moment somebody writes, and a name a person chose.
--
-- WHAT THIS MIGRATION IS
--
--   `custom_field_entities`  where a field may be attached, and what a
--                            lookup may point at. Platform-seeded, not
--                            user-editable: a twelfth carrier needs the
--                            jsonb column AND this trigger, and both of
--                            those are a migration.
--
--   `custom_fields_def`      one company's fields. Name, kind, whether
--                            it must be filled in, and for a lookup,
--                            what it points at.
--
--   `app.custom_fields_guard()`  one trigger function on all eleven
--                            tables. A rule enforced only in Dart is
--                            not enforced.
--
-- THE LOOKUP IS THE POINT, AND IT IS WHY THIS BELONGS IN SQL. A lookup
-- field holds the id of another record — a supplier on an item, a
-- responsible employee on a ticket. jsonb has no foreign keys, so
-- nothing stops a company storing the id of ANOTHER COMPANY'S contact
-- in there and reading a name back across the wall. The guard checks
-- existence AND `org_id`, exactly as 0512 had to for every column that
-- names a contact. That check cannot live in a form.
--
-- THREE DECISIONS WORTH READING
--
-- A KEY IS FOREVER, A LABEL IS NOT. The label is what a person sees and
-- may be changed whenever they like. The key is the jsonb key the value
-- is stored under, derived from the first label and then frozen —
-- renaming it would orphan every value already written beneath it. So
-- there is no rename: `(org_id, entity, key)` is the identity.
--
-- A NEW REQUIRED FIELD DOES NOT LOCK THE PAST. On UPDATE, a row whose
-- `custom_fields` is untouched is not re-validated. Otherwise marking a
-- field required would freeze every record written before it existed —
-- a company would add "Cost centre" on Monday and find on Tuesday that
-- it could not edit an invoice from March without inventing one. A
-- required field applies to what is written next.
--
-- AN UNKNOWN KEY IS REFUSED RATHER THAN KEPT. A key with no definition
-- behind it is a typo that would otherwise sit in the row for ever,
-- invisible to every screen and every report. Archiving a field leaves
-- its definition in place, so an archived field's values stay readable
-- and stay writable — it is only a key that was never defined at all
-- that is refused.
--
-- AND THE ONE THING THAT COULD HAVE BROKEN PRODUCTION, CHECKED RATHER
-- THAN ASSUMED. Refusing an unknown key would freeze any row that
-- already held one: the next write of it would be refused for carrying
-- a key nobody had defined. The hosted project was counted before this
-- was written — every one of the eleven tables, rows where
-- `custom_fields <> '{}'` — and the answer is nought on all eleven.
-- Nothing has ever written one, which is what made a strict rule safe
-- to start with rather than something to phase in.
--
-- The one caller that carries them is the recurring engine, and it only
-- ever copies what was already on the template it was made from. So a
-- standing order made after today carries fields that were defined, and
-- there are no standing orders from before today that carry any.
--
-- WHAT IS DELIBERATELY NOT HERE. `transfer_document` does not carry
-- custom fields from a quotation to the invoice, and this migration
-- does not change that. It is a real question — a quotation's "Site
-- contact" probably should land on the invoice — but it is the same
-- class of fault a sweep found in 0538 and 09e214d, and it deserves
-- its own decision and its own assertion rather than being smuggled in
-- beside the schema. The recurring engine, for what it is worth,
-- already carries them: 0097 puts `custom_fields` in its snapshot and
-- reads it back out when it raises the document.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where a field may live, and what a lookup may point at
-- ---------------------------------------------------------------------
create table if not exists public.custom_field_entities (
  entity          text primary key,
  table_name      text not null,
  label           text not null,
  -- May carry custom fields: has the jsonb column and the guard below.
  can_carry       boolean not null default false,
  -- May be pointed at by a lookup field.
  can_target      boolean not null default false,
  -- A line on a document rather than the document itself. The value is
  -- filled in once per line, which is a different thing to ask of
  -- somebody, and the setup screen says so.
  is_line_level   boolean not null default false,
  -- What a picker shows, and what a report prints, for a row of this
  -- kind. Not every table calls it `name`: an employee has `full_name`,
  -- a lead has `company_name`, a ticket has `subject`.
  label_column    text not null default 'name',
  -- The column that retires a row, where there is one. A lookup must
  -- not point at a record somebody has since deleted.
  deleted_column  text,
  sort_order      integer not null default 100
);

comment on table public.custom_field_entities is
  'Where a custom field may be attached, and what a lookup field may point at. Platform-seeded: a new carrier needs a jsonb column and the guard trigger, which is a migration.';

alter table public.custom_field_entities enable row level security;

-- A catalogue with nothing private in it. Readable by anybody signed
-- in; written by migrations alone, so there is no insert or update
-- policy and none is wanted.
create policy custom_field_entities_read on public.custom_field_entities
  for select to authenticated using (true);

-- The grant beside the policy, every time. A policy without its grant
-- is a policy nobody can reach — the read is refused before the policy
-- is ever consulted, which is what 62c5bb0 was about.
grant select on public.custom_field_entities to authenticated;

insert into public.custom_field_entities
  (entity, table_name, label, can_carry, can_target, is_line_level,
   label_column, deleted_column, sort_order)
values
  ('contact',   'contacts',   'Contact',   true,  true,  false, 'name',        'deleted_at', 10),
  ('item',      'items',      'Item',      true,  true,  false, 'name',        'deleted_at', 20),
  ('employee',  'employees',  'Employee',  true,  true,  false, 'full_name',   null,         30),
  ('lead',      'leads',      'Lead',      true,  true,  false, 'company_name','deleted_at', 40),
  ('opportunity','opportunities','Opportunity', true, true, false, 'name',     'deleted_at', 50),
  ('matter',    'matters',    'Matter',    true,  true,  false, 'name',        'deleted_at', 60),
  ('ticket',    'tickets',    'Ticket',    true,  true,  false, 'subject',     'deleted_at', 70),
  ('sales_document', 'sales_documents', 'Sales document',
                                          true,  true,  false, 'doc_no',      'deleted_at', 80),
  ('sales_document_line', 'sales_document_lines', 'Sales document line',
                                          true,  false, true,  'description', null,         90),
  ('purchase_document', 'purchase_documents', 'Purchase document',
                                          true,  true,  false, 'doc_no',      'deleted_at', 100),
  ('purchase_document_line', 'purchase_document_lines', 'Purchase document line',
                                          true,  false, true,  'description', null,         110),

  -- Pointed at, but carrying nothing of their own: these have no
  -- `custom_fields` column, so a field cannot be attached to them until
  -- a migration gives them one.
  ('account',      'accounts',      'Account',      false, true, false, 'name', 'deleted_at', 200),
  ('warehouse',    'warehouses',    'Warehouse',    false, true, false, 'name', null,         210),
  ('branch',       'branches',      'Branch',       false, true, false, 'name', null,         220),
  ('project',      'projects',      'Project',      false, true, false, 'name', null,         230),
  ('salesperson',  'salespeople',   'Salesperson',  false, true, false, 'name', null,         240),
  ('payment_term', 'payment_terms', 'Payment term', false, true, false, 'name', null,         250),
  ('tax_code',     'tax_codes',     'Tax code',     false, true, false, 'name', null,         260)
on conflict (entity) do nothing;

-- ---------------------------------------------------------------------
-- One company's fields
-- ---------------------------------------------------------------------
create table if not exists public.custom_fields_def (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  entity        text not null references public.custom_field_entities(entity),
  -- The jsonb key. Derived from the first label and then frozen: see
  -- the header. This is the identity, which is why there is no rename.
  key           text not null,
  label         text not null,
  help_text     text,
  kind          text not null default 'text'
                  check (kind in ('text','number','date','boolean','select','lookup')),
  is_required   boolean not null default false,
  is_active     boolean not null default true,
  -- For 'select': the values that may be chosen, as a jsonb array of
  -- strings. For every other kind: null.
  options       jsonb,
  -- For 'lookup': what it points at. For every other kind: null.
  target_entity text references public.custom_field_entities(entity),
  min_value     numeric,
  max_value     numeric,
  max_length    integer,
  -- Whether it earns a column on the list as well as a box on the form.
  show_on_list  boolean not null default false,
  sort_order    integer not null default 100,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint custom_fields_def_org_entity_key_key unique (org_id, entity, key),
  constraint custom_fields_def_options_only_for_select
    check ((kind = 'select') = (options is not null)),
  constraint custom_fields_def_target_only_for_lookup
    check ((kind = 'lookup') = (target_entity is not null)),
  constraint custom_fields_def_key_shape
    check (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  constraint custom_fields_def_label_not_blank
    check (btrim(label) <> '')
);

comment on table public.custom_fields_def is
  'The custom fields one company has defined. The key is frozen at creation because renaming it would orphan every value stored beneath it; the label may change whenever they like.';

create index if not exists custom_fields_def_lookup_idx
  on public.custom_fields_def (org_id, entity, is_active);

alter table public.custom_fields_def enable row level security;

-- Anybody in the company may READ the definitions, because everybody
-- who fills a form in needs to know what the boxes are. Only an
-- administrator may write them, and only through the function below,
-- which is where the shape is checked.
create policy custom_fields_def_read on public.custom_fields_def
  for select to authenticated using (app.is_org_member(org_id));

grant select on public.custom_fields_def to authenticated;

-- ---------------------------------------------------------------------
-- The key, derived from the name a person typed
-- ---------------------------------------------------------------------
create or replace function app.custom_field_key(p_label text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(
    left(
      btrim(
        regexp_replace(
          regexp_replace(lower(btrim(coalesce(p_label, ''))), '[^a-z0-9]+', '_', 'g'),
          '^_+|_+$', '', 'g'),
        '_'),
      40),
    '');
$$;

comment on function app.custom_field_key(text) is
  'The jsonb key for a label somebody typed. Lower case, one underscore between words, forty characters at most.';

-- ---------------------------------------------------------------------
-- The guard
-- ---------------------------------------------------------------------
-- One function, eleven tables, and the entity comes in as the trigger's
-- own argument so that the function does not have to work out which
-- table it is standing on.
create or replace function app.custom_fields_guard()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entity text := tg_argv[0];
  v_ent    public.custom_field_entities;
  d        record;
  v_val    jsonb;
  v_empty  boolean;
  v_txt    text;
  v_id     uuid;
  v_ok     boolean;
  v_key    text;
begin
  -- A row whose custom fields nobody touched is a row that was already
  -- checked when they were written. Skipping it is what stops a field
  -- marked required today from freezing every record written before it
  -- existed. See the header: a required field applies to what is
  -- written next, not backwards over the year.
  if tg_op = 'UPDATE' and new.custom_fields is not distinct from old.custom_fields then
    return new;
  end if;

  if new.custom_fields is null then
    new.custom_fields := '{}'::jsonb;
  end if;
  if jsonb_typeof(new.custom_fields) <> 'object' then
    raise exception
      'The custom fields on a % are a set of named values, not a %.',
      v_entity, jsonb_typeof(new.custom_fields) using errcode = '22023';
  end if;

  -- The cheap way out, which is the common one: nothing filled in and
  -- nothing that has to be.
  if new.custom_fields = '{}'::jsonb
     and not exists (select 1 from public.custom_fields_def f
                      where f.org_id = new.org_id and f.entity = v_entity
                        and f.is_active and f.is_required) then
    return new;
  end if;

  -- A key nobody defined is a typo that would sit in the row for ever.
  for v_key in select jsonb_object_keys(new.custom_fields) loop
    if not exists (select 1 from public.custom_fields_def f
                    where f.org_id = new.org_id and f.entity = v_entity
                      and f.key = v_key) then
      raise exception
        '% is not a field on a % for this company.', v_key, v_entity
        using errcode = '23514';
    end if;
  end loop;

  for d in
    select * from public.custom_fields_def f
     where f.org_id = new.org_id and f.entity = v_entity
     order by f.sort_order, f.key
  loop
    v_val := new.custom_fields -> d.key;
    v_empty := v_val is null
            or jsonb_typeof(v_val) = 'null'
            or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '');

    if v_empty then
      if d.is_required and d.is_active then
        raise exception '% has to be filled in.', d.label
          using errcode = '23514';
      end if;
      continue;
    end if;

    if d.kind = 'text' then
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% is written in words.', d.label using errcode = '22023';
      end if;
      if d.max_length is not null
         and length(v_val #>> '{}') > d.max_length then
        raise exception
          '% is longer than the % characters allowed.', d.label, d.max_length
          using errcode = '22001';
      end if;

    elsif d.kind = 'number' then
      if jsonb_typeof(v_val) <> 'number' then
        raise exception
          '% is a number. Quotation marks round it make it words.', d.label
          using errcode = '22023';
      end if;
      if d.min_value is not null and (v_val #>> '{}')::numeric < d.min_value then
        raise exception '% cannot be less than %.', d.label, d.min_value
          using errcode = '23514';
      end if;
      if d.max_value is not null and (v_val #>> '{}')::numeric > d.max_value then
        raise exception '% cannot be more than %.', d.label, d.max_value
          using errcode = '23514';
      end if;

    elsif d.kind = 'boolean' then
      if jsonb_typeof(v_val) <> 'boolean' then
        raise exception '% is yes or no.', d.label using errcode = '22023';
      end if;

    elsif d.kind = 'date' then
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% is a date, written as text.', d.label
          using errcode = '22023';
      end if;
      begin
        perform (v_val #>> '{}')::date;
      exception when others then
        raise exception
          '% is a date. "%" is not one — write it as YYYY-MM-DD.',
          d.label, v_val #>> '{}' using errcode = '22007';
      end;

    elsif d.kind = 'select' then
      if jsonb_typeof(v_val) <> 'string'
         or not exists (select 1 from jsonb_array_elements_text(d.options) o
                         where o = v_val #>> '{}') then
        raise exception
          '"%" is not one of the choices for %.', v_val #>> '{}', d.label
          using errcode = '23514';
      end if;

    elsif d.kind = 'lookup' then
      -- THE ONE THAT CANNOT LIVE IN A FORM. jsonb has no foreign keys,
      -- so without this a company could store another company's
      -- contact id and read its name back through the picker. 0512 had
      -- to hold every column that names a contact to one company's
      -- contacts; this is that rule for a column the company invented.
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% names a record, by its id.', d.label
          using errcode = '22023';
      end if;
      v_txt := v_val #>> '{}';
      begin
        v_id := v_txt::uuid;
      exception when others then
        raise exception '"%" is not a record id for %.', v_txt, d.label
          using errcode = '22P02';
      end;

      select * into v_ent from public.custom_field_entities
       where entity = d.target_entity;
      execute format(
        'select exists (select 1 from public.%I t'
        '                where t.id = $1 and t.org_id = $2 %s)',
        v_ent.table_name,
        case when v_ent.deleted_column is null then ''
             else format('and t.%I is null', v_ent.deleted_column) end)
        into v_ok using v_id, new.org_id;

      if not v_ok then
        raise exception
          '% points at a % this company does not have.', d.label, v_ent.label
          using errcode = '23503';
      end if;
    end if;
  end loop;

  return new;
end;
$$;

comment on function app.custom_fields_guard() is
  'Holds one company''s custom field values to the definitions it wrote: required, typed, chosen from the list, and for a lookup, pointing at a record of this company''s that still exists.';

do $$
declare r record;
begin
  for r in select entity, table_name from public.custom_field_entities
            where can_carry order by sort_order
  loop
    execute format(
      'drop trigger if exists custom_fields_are_the_ones_defined on public.%I',
      r.table_name);
    execute format(
      'create trigger custom_fields_are_the_ones_defined '
      'before insert or update on public.%I '
      'for each row execute function app.custom_fields_guard(%L)',
      r.table_name, r.entity);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Defining one
-- ---------------------------------------------------------------------
create or replace function public.upsert_custom_field(
  p_org_id uuid, p_entity text, p_label text,
  p_key text default null,
  p_kind text default 'text',
  p_is_required boolean default false,
  p_options jsonb default null,
  p_target_entity text default null,
  p_help_text text default null,
  p_min_value numeric default null,
  p_max_value numeric default null,
  p_max_length integer default null,
  p_show_on_list boolean default false,
  p_sort_order integer default 100)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_ent   public.custom_field_entities;
  v_tgt   public.custom_field_entities;
  v_key   text;
  v_old   public.custom_fields_def;
  v_used  boolean;
  v_id    uuid;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up custom fields'
      using errcode = '42501';
  end if;

  select * into v_ent from public.custom_field_entities where entity = p_entity;
  if v_ent.entity is null or not v_ent.can_carry then
    raise exception 'A custom field cannot be added to a %.', p_entity
      using errcode = '23514';
  end if;
  if btrim(coalesce(p_label, '')) = '' then
    raise exception 'A field needs a name somebody can read.'
      using errcode = '23514';
  end if;
  if p_kind not in ('text','number','date','boolean','select','lookup') then
    raise exception 'There is no such kind of field as %.', p_kind
      using errcode = '23514';
  end if;

  -- The key is derived from the label the first time and frozen after.
  v_key := coalesce(app.custom_field_key(p_key), app.custom_field_key(p_label));
  if v_key is null then
    raise exception
      'A name of punctuation alone leaves nothing to store the value '
      'under. Give the field a name with a letter in it.'
      using errcode = '23514';
  end if;

  if p_kind = 'select' then
    if p_options is null or jsonb_typeof(p_options) <> 'array'
       or jsonb_array_length(p_options) = 0 then
      raise exception
        'A field somebody chooses from needs something to choose.'
        using errcode = '23514';
    end if;
    if exists (select 1 from jsonb_array_elements(p_options) o
                where jsonb_typeof(o) <> 'string'
                   or btrim(o #>> '{}') = '') then
      raise exception 'Every choice is a line of text, and none of them blank.'
        using errcode = '23514';
    end if;
  elsif p_options is not null then
    raise exception 'Only a field somebody chooses from has choices.'
      using errcode = '23514';
  end if;

  if p_kind = 'lookup' then
    select * into v_tgt from public.custom_field_entities
     where entity = p_target_entity;
    if v_tgt.entity is null or not v_tgt.can_target then
      raise exception
        'A lookup points at a record this product keeps. % is not one.',
        coalesce(p_target_entity, 'nothing') using errcode = '23514';
    end if;
  elsif p_target_entity is not null then
    raise exception 'Only a lookup points at another record.'
      using errcode = '23514';
  end if;

  if p_min_value is not null and p_max_value is not null
     and p_min_value > p_max_value then
    raise exception 'The smallest allowed is larger than the largest.'
      using errcode = '23514';
  end if;

  select * into v_old from public.custom_fields_def
   where org_id = p_org_id and entity = p_entity and key = v_key;

  -- CHANGING WHAT A FIELD IS, ONCE IT HOLDS SOMETHING, IS NOT AN EDIT.
  -- Every value already written was written under the old rule, and
  -- turning words into a number or moving a lookup to another kind of
  -- record leaves them all meaning something the definition no longer
  -- describes. Archive it and make another.
  if v_old.id is not null
     and (v_old.kind <> p_kind
          or v_old.target_entity is distinct from p_target_entity) then
    execute format(
      'select exists (select 1 from public.%I t'
      '                where t.org_id = $1 and t.custom_fields ? $2)',
      v_ent.table_name) into v_used using p_org_id, v_key;
    if v_used then
      raise exception
        '% is already filled in on records of this company. What a field '
        'holds cannot change underneath the values already in it — '
        'archive this one and add another.', v_old.label
        using errcode = '23514';
    end if;
  end if;

  insert into public.custom_fields_def
    (org_id, entity, key, label, help_text, kind, is_required, options,
     target_entity, min_value, max_value, max_length, show_on_list,
     sort_order, created_by, updated_at)
  values (p_org_id, p_entity, v_key, btrim(p_label), p_help_text, p_kind,
          coalesce(p_is_required, false), p_options, p_target_entity,
          p_min_value, p_max_value, p_max_length,
          coalesce(p_show_on_list, false), coalesce(p_sort_order, 100),
          auth.uid(), now())
  on conflict (org_id, entity, key) do update
    set label = excluded.label,
        help_text = excluded.help_text,
        kind = excluded.kind,
        is_required = excluded.is_required,
        options = excluded.options,
        target_entity = excluded.target_entity,
        min_value = excluded.min_value,
        max_value = excluded.max_value,
        max_length = excluded.max_length,
        show_on_list = excluded.show_on_list,
        sort_order = excluded.sort_order,
        is_active = true,
        updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.upsert_custom_field(
  uuid, text, text, text, text, boolean, jsonb, text, text, numeric,
  numeric, integer, boolean, integer) from public, anon;
grant execute on function public.upsert_custom_field(
  uuid, text, text, text, text, boolean, jsonb, text, text, numeric,
  numeric, integer, boolean, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Putting one away, and bringing it back
-- ---------------------------------------------------------------------
-- Archived rather than deleted, and the definition stays. Values
-- already written under an archived field are still readable, still
-- writable, and still refuse to become the wrong shape — which is the
-- whole reason an unknown key is refused and an archived one is not.
create or replace function public.set_custom_field_active(
  p_org_id uuid, p_entity text, p_key text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up custom fields'
      using errcode = '42501';
  end if;
  update public.custom_fields_def
     set is_active = coalesce(p_active, false), updated_at = now()
   where org_id = p_org_id and entity = p_entity and key = p_key;
  if not found then
    raise exception 'There is no field % on a % here.', p_key, p_entity
      using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.set_custom_field_active(uuid, text, text, boolean)
  from public, anon;
grant execute on function public.set_custom_field_active(uuid, text, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a lookup may be filled in with
-- ---------------------------------------------------------------------
-- The picker's list, read as the company. One function rather than a
-- read of each of the seven target tables, so that the app does not
-- have to know which table a lookup points at — and so that the same
-- `org_id` and `deleted_at` narrowing the guard applies is the one the
-- list is drawn from. A picker that offers what the guard refuses is
-- how a form comes to argue with the database.
create or replace function public.custom_field_lookup_options(
  p_org_id uuid, p_target_entity text, p_search text default null,
  p_limit integer default 50)
returns table (id uuid, label text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_ent public.custom_field_entities;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'not a member of this company' using errcode = '42501';
  end if;
  select * into v_ent from public.custom_field_entities
   where entity = p_target_entity;
  if v_ent.entity is null or not v_ent.can_target then
    raise exception 'Nothing points at a %.', coalesce(p_target_entity, 'nothing')
      using errcode = 'P0002';
  end if;

  return query execute format(
    'select t.id, t.%I::text from public.%I t'
    ' where t.org_id = $1 %s'
    '   and ($2 is null or t.%I::text ilike ''%%'' || $2 || ''%%'')'
    ' order by t.%I limit $3',
    v_ent.label_column, v_ent.table_name,
    case when v_ent.deleted_column is null then ''
         else format('and t.%I is null', v_ent.deleted_column) end,
    v_ent.label_column, v_ent.label_column)
    using p_org_id, nullif(btrim(coalesce(p_search, '')), ''),
          greatest(coalesce(p_limit, 50), 1);
end;
$$;

revoke all on function public.custom_field_lookup_options(uuid, text, text, integer)
  from public, anon;
grant execute on function public.custom_field_lookup_options(uuid, text, text, integer)
  to authenticated;

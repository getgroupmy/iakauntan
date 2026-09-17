-- =====================================================================
-- iAkauntan :: 0605 the kinds of business there are
--
-- `app.entity_type` has been a Postgres enum since `0001`: ten values,
-- fixed at deploy time. A platform administrator who needed an
-- eleventh -- a co-operative, a trust, a foreign branch -- could not
-- add one without a migration.
--
-- This makes the list a table. `contacts.entity_type` moves onto it
-- here; `organizations.entity_type` follows separately, because that
-- one has a statutory reader and deserves its own commit.
--
-- ---------------------------------------------------------------------
-- What could break, and what could not
--
-- The question worth answering before touching this: does anything
-- STATUTORY read it? Two things looked like they might, and only one
-- of them does.
--
--   * The SSM deadline rules do NOT. `0063` matches
--     `e.entity_type = any (t.applies_to)` on `corp_entities`, whose
--     column is `app.corp_entity_type` -- a DIFFERENT enum, with
--     different members, belonging to the corporate secretarial
--     module. Adding a kind of business here cannot move a filing
--     deadline, because nothing here is what that reads.
--
--   * MBRS DOES. `0172` decides whether a company files as public with
--     `o.entity_type = 'bhd'`, a string comparison against one member
--     of this list. That is the one place a new value would be
--     silently wrong: an administrator adding `berhad_public` would
--     get a company that MBRS files as private.
--
-- So `is_public_company` is a column on the row rather than a string
-- somebody remembers to compare against. It is not used yet -- the
-- organizations column is still the enum -- and it is populated
-- correctly now so that the commit which moves that column has an
-- answer already recorded for every one of the ten.
--
-- ---------------------------------------------------------------------
-- The enum is not dropped
--
-- `organizations.entity_type`, `create_organization`, `my_orgs` and
-- `signup_entity_type` all still use it. Dropping it here would be a
-- migration that breaks four things to tidy one.
-- =====================================================================

create table public.entity_types (
  -- The value that was in the enum. Text, and the primary key, so a
  -- row already saying `sdn_bhd` needs nothing done to it.
  code text primary key
    check (code ~ '^[a-z][a-z0-9_]{1,40}$'),

  label text not null,

  -- Bahasa Malaysia, where somebody has written one. The app falls
  -- back to `label`, which is what every other translated string here
  -- does.
  label_my text,

  -- Lower comes first, the same convention as every other ordered list
  -- in this schema.
  sort_order integer not null default 100,

  -- Retired rather than deleted. A contact filed under a kind that is
  -- no longer offered is still filed under it, and deleting the row
  -- would make that contact unreadable.
  is_active boolean not null default true,

  -- ------------------------------------------------------------------
  -- The MBRS answer
  --
  -- `0172` asks `o.entity_type = 'bhd'` to decide whether a company
  -- files its accounts as a public company. That is a string
  -- comparison against one member of a list somebody can now add to,
  -- so the answer moves onto the row: a new kind must SAY whether it
  -- is a public company, and the default is the safe one.
  --
  -- Nothing reads this yet. It is recorded now so the commit that
  -- moves `organizations.entity_type` has an answer for all ten
  -- already in place rather than having to invent them.
  -- ------------------------------------------------------------------
  is_public_company boolean not null default false,

  -- Where the kind may be chosen. A contact can be an individual; a
  -- company registering itself cannot be one of those in the same
  -- sense, and the two forms have never offered quite the same list.
  for_contacts boolean not null default true,
  for_organizations boolean not null default true,

  -- One of the ten this shipped with. Built-in rows may be renamed and
  -- retired but not deleted: `organizations.entity_type` is still the
  -- enum and still holds these values, so a delete would leave a
  -- company pointing at a kind that no longer exists.
  is_builtin boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.entity_types is
  'The kinds of business a contact or a company can be. Was the '
  '`app.entity_type` enum until 0605. Read by anybody signed in '
  '(it is a dropdown); written only by a platform administrator. '
  '`is_public_company` is the MBRS answer, carried on the row so a '
  'new kind has to state it rather than being compared against the '
  'string ''bhd''.';

create index entity_types_order_idx
  on public.entity_types (sort_order, code) where is_active;

create trigger set_updated_at before update on public.entity_types
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- The ten, exactly as the enum had them
--
-- `is_public_company` is true for `bhd` alone, which is what
-- `o.entity_type = 'bhd'` means today. `sort_order` puts the common
-- Malaysian forms first, because a dropdown in alphabetical order puts
-- `association` above `sdn_bhd` and almost every contact is the latter.
-- ---------------------------------------------------------------------
insert into public.entity_types
  (code, label, sort_order, is_public_company, is_builtin, for_contacts,
   for_organizations)
values
  ('sdn_bhd',         'Sdn Bhd',          10, false, true, true,  true),
  ('bhd',             'Berhad',           20, true,  true, true,  true),
  ('llp',             'LLP (PLT)',        30, false, true, true,  true),
  ('enterprise',      'Enterprise',       40, false, true, true,  true),
  ('sole_proprietor', 'Sole Proprietor',  50, false, true, true,  true),
  ('partnership',     'Partnership',      60, false, true, true,  true),
  ('association',     'Association',      70, false, true, true,  true),
  ('government',      'Government',       80, false, true, true,  true),
  -- A person, which a company registering itself is not.
  ('individual',      'Individual',       90, false, true, true,  false),
  ('other',           'Other',           999, false, true, true,  true)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Reading it
--
-- Everybody signed in, because it is a dropdown on the contact form and
-- on registration. There is nothing tenant-shaped on the row.
-- ---------------------------------------------------------------------
alter table public.entity_types enable row level security;

create policy entity_types_read on public.entity_types
  for select to authenticated using (true);

grant select on public.entity_types to authenticated;

-- ---------------------------------------------------------------------
-- Contacts move onto it
--
-- `contacts.entity_type` was `app.entity_type not null default
-- 'sdn_bhd'`. Nothing reads it for meaning -- it is descriptive, and
-- `0589` gave the registry's own answer its own column,
-- `ssm_entity_type`, precisely so the two could not be confused.
--
-- The cast is exact: every existing value is a member of the enum and
-- every member is a row above, so no contact changes its kind.
--
-- The foreign key is `on delete restrict` rather than cascade, and the
-- RPC below refuses a delete that would hit it. A kind is retired by
-- switching it off, never by removing it from under the contacts
-- filed as it.
-- ---------------------------------------------------------------------
alter table public.contacts
  alter column entity_type drop default;

alter table public.contacts
  alter column entity_type type text using entity_type::text;

alter table public.contacts
  alter column entity_type set default 'sdn_bhd';

alter table public.contacts
  add constraint contacts_entity_type_fkey
  foreign key (entity_type) references public.entity_types (code)
  on update cascade on delete restrict;

comment on column public.contacts.entity_type is
  'What kind of business this contact is, from `entity_types`. '
  'Descriptive: nothing reads it for meaning. What the REGISTRY said '
  'is `ssm_entity_type`, which 0589 kept separate for that reason.';

-- ---------------------------------------------------------------------
-- No live_change_* trigger
--
-- `live_change_feed.sql` asks for one on every table with an `org_id`.
-- This one has none: the list belongs to the platform rather than to a
-- company, and a change to it is an administrator's, not a colleague's.
-- The console invalidates what it needs the way the other platform
-- tables do.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Writing one
-- ---------------------------------------------------------------------
create or replace function public.platform_save_entity_type(
  p_code text,
  p_label text,
  p_label_my text default null,
  p_sort_order integer default null,
  p_is_active boolean default null,
  p_is_public_company boolean default null,
  p_for_contacts boolean default null,
  p_for_organizations boolean default null)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_code text;
  v_existing public.entity_types%rowtype;
begin
  if not app.is_platform_admin() then
    raise exception 'The kinds of business are the whole platform''s list '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  v_code := lower(btrim(coalesce(p_code, '')));
  if v_code = '' then
    raise exception 'A kind of business needs a code' using errcode = '23514';
  end if;
  if coalesce(btrim(p_label), '') = '' then
    raise exception 'A kind of business needs a name' using errcode = '23514';
  end if;

  select * into v_existing from public.entity_types where code = v_code;

  if v_existing.code is null then
    -- The check constraint says what a code may look like; this says it
    -- in words, because an administrator typing "Sdn Bhd" into the code
    -- box should be told what is wrong rather than shown a constraint
    -- name.
    if v_code !~ '^[a-z][a-z0-9_]{1,40}$' then
      raise exception 'A code is lower-case letters, digits and '
                      'underscores, starting with a letter — for example '
                      'co_operative'
        using errcode = '23514';
    end if;
    insert into public.entity_types
      (code, label, label_my, sort_order, is_active, is_public_company,
       for_contacts, for_organizations, is_builtin, updated_by)
    values
      (v_code, btrim(p_label), nullif(btrim(p_label_my), ''),
       coalesce(p_sort_order, 100),
       coalesce(p_is_active, true),
       coalesce(p_is_public_company, false),
       coalesce(p_for_contacts, true),
       coalesce(p_for_organizations, true),
       false, auth.uid());
    return v_code;
  end if;

  -- An absent argument means "leave it", the same shape
  -- `platform_save_landing_section` uses. Correcting a label must not
  -- silently switch a kind off.
  update public.entity_types set
    label             = coalesce(nullif(btrim(p_label), ''), label),
    label_my          = coalesce(nullif(btrim(p_label_my), ''), label_my),
    sort_order        = coalesce(p_sort_order, sort_order),
    is_active         = coalesce(p_is_active, is_active),
    is_public_company = coalesce(p_is_public_company, is_public_company),
    for_contacts      = coalesce(p_for_contacts, for_contacts),
    for_organizations = coalesce(p_for_organizations, for_organizations),
    updated_by        = auth.uid()
   where code = v_code;

  return v_code;
end;
$function$;

comment on function public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean) is
  'Adds or amends a kind of business. Platform administrators only. An '
  'absent argument means leave it alone, so correcting a label cannot '
  'switch a kind off. `p_is_public_company` is the MBRS answer and a '
  'new kind must state it; the default is the safe one.';

grant execute on function public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- Removing one, and mostly refusing to
--
-- Three refusals, and each is a different way of losing information:
-- a built-in is still held by `organizations.entity_type`, which is
-- still the enum; one in use is what a contact is filed as; and the
-- rest is the ordinary case, where switching it off is what was
-- actually wanted.
-- ---------------------------------------------------------------------
create or replace function public.platform_delete_entity_type(p_code text)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_used bigint;
  v_builtin boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'The kinds of business are the whole platform''s list '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  select is_builtin into v_builtin
    from public.entity_types where code = p_code;
  if v_builtin is null then
    raise exception 'No such kind of business' using errcode = 'P0002';
  end if;
  if v_builtin then
    raise exception 'The kinds this shipped with cannot be removed, only '
                    'switched off — a company''s own record still holds '
                    'them'
      using errcode = '23503';
  end if;

  select count(*) into v_used
    from public.contacts where entity_type = p_code;
  if v_used > 0 then
    raise exception 'Switch it off instead: % contact(s) are filed as this '
                    'kind, and removing it would leave them pointing at '
                    'nothing', v_used
      using errcode = '23503';
  end if;

  delete from public.entity_types where code = p_code;
  return true;
end;
$function$;

comment on function public.platform_delete_entity_type(text) is
  'Removes a kind of business that nothing is filed as. Refuses a '
  'built-in one and refuses one in use, naming how many — both are '
  'cases where switching it off is what was wanted.';

grant execute on function public.platform_delete_entity_type(text)
  to authenticated;

-- ---------------------------------------------------------------------
-- On the platform's own live channel
--
-- `0302` put the platform's tables into `supabase_realtime` so a change
-- made in the console reaches every open tab without a reload. This
-- list belongs there for the same reason `module_promotions` does: an
-- administrator adding a kind of business is doing it FOR somebody,
-- usually somebody on the telephone with a contact form open, and
-- "log out and back in" is not an answer to give them.
--
-- `live_changes` cannot carry it. That feed is keyed on `org_id` and
-- this table has none — it is the platform's list, not a company's.
--
-- Both halves or neither: `platform_live.dart` names the tables the
-- client subscribes to and `platform_live_test.dart` asserts the two
-- lists agree, because a table in the publication that nothing listens
-- for is changes nobody reads, and a table listened for that is not
-- published subscribes to nothing. That test is what caught this
-- missing.
-- ---------------------------------------------------------------------
do $do$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'entity_types'
  ) then
    alter publication supabase_realtime add table public.entity_types;
  end if;
end $do$;

-- =====================================================================
-- iAkauntan :: 0603 what the institute says about an accountant
--
-- The Malaysian Institute of Accountants publishes a members and firms
-- register. This records what it said about somebody, and when it was
-- looked up.
--
-- ---------------------------------------------------------------------
-- Why this is a table and not three columns
--
-- `0589` made the opposite call for SSM, and the difference is worth
-- stating because the two look alike. There, `contacts.name` and
-- `registration_no` already existed, so a lookup FILLED them and the
-- migration added only provenance. Here there is nothing to fill: a
-- member type, a practising-certificate flag, a firm's audit or
-- non-audit classification and its registered contact details have no
-- column anywhere in this schema.
--
-- `corp_officers.licence_no` is the near miss, and it is genuinely
-- near: `0061` put it there because "a secretary must be a member of a
-- prescribed body or hold a licence from the Registrar under s.20G of
-- the Companies Commission Act", and MIA membership is exactly one of
-- those prescribed memberships. It is not enough on its own — one text
-- column cannot hold a member number AND the firm number AND whether
-- the certificate is current — and it is not replaced. An officer may
-- carry a licence from the Registrar and no MIA membership at all.
--
-- And the same subject can hold two credentials at once: an engagement
-- partner is a MEMBER, and the audit firm they sign for is a FIRM.
-- That is two rows about one appointment, which no set of columns on
-- `corp_officers` would express.
--
-- ---------------------------------------------------------------------
-- Two owners, because a practice is not a company
--
-- A corporate officer belongs to a company and is reached through
-- `app.can_write(org_id)`. A firm belongs to nobody's company: `0450`
-- gives it `app.is_firm_member` and `app.can_manage_firm`, and a
-- practice keeping other people's books is deliberately outside the
-- org tree.
--
-- So exactly one of `org_id` and `firm_id` is set, and the policies ask
-- whichever question applies. Forcing a firm's credential to borrow an
-- org id would put a practice's own registration inside a client's
-- company, where ending the appointment would delete it.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not fetch anything from mia.org.my. The register is a
-- WordPress form behind Cloudflare's managed bot challenge with no API
-- and no CORS allowance, so neither the browser nor an edge function
-- can read it, and working around a bot challenge is not something this
-- product does. `verified_via` carries `mia_api` as a value so that a
-- row written by a real integration is distinguishable from one typed
-- in, on the day MIA grants one. Nothing writes it yet.
--
-- It also stores no part of the register beyond the subjects this
-- application already records. There is no bulk import of MIA's
-- membership list here and there should not be one.
--
-- ---------------------------------------------------------------------
-- What a row does not prove
--
-- MIA membership is not approval as a company auditor, which is the
-- Accountant General's Department under s.263 of the Companies Act
-- 2016, and it is not a licensed tax agent, which is LHDN under s.153
-- of the Income Tax Act. The application says so where the credential
-- is shown; it is repeated here because a column called `verified_at`
-- invites more weight than it can carry.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A grant that was missing, found by being the first to need it
--
-- `app.is_firm_member` has never been executable by `authenticated`.
-- `0450` declared it without a grant; `0568` re-declared its sibling
-- `can_manage_firm` five lines later and granted THAT one, and the
-- asymmetry went unnoticed because nothing ever called it as a
-- signed-in user: `my_firms()` is SECURITY DEFINER, so the app reads a
-- practice through the function and never through the table.
--
-- Which means `firms_select` -- `0450`'s own read policy on
-- `public.firms`, whose first clause is `app.is_firm_member(id)` -- has
-- been unusable the whole time. A direct select on that table raises
-- `permission denied for function is_firm_member`. The policy has been
-- dead rather than wrong, and the day something selected from `firms`
-- it would have stopped being either.
--
-- The read policy below is the first thing to call it, which is how
-- this surfaced.
-- ---------------------------------------------------------------------
grant execute on function app.is_firm_member(uuid)
  to authenticated, service_role;

create type app.mia_credential_kind as enum ('member', 'firm');

-- How the row was obtained. `mia_website_manual` is somebody reading
-- the register and copying the row; `mia_api` is reserved.
create type app.mia_verified_via as enum ('mia_website_manual', 'mia_api');

create table public.mia_credentials (
  id uuid primary key default gen_random_uuid(),

  -- Exactly one of these. See the note above.
  org_id  uuid references public.organizations (id) on delete cascade,
  firm_id uuid references public.firms (id) on delete cascade,

  subject_type text not null
    check (subject_type in ('corp_officer', 'firm')),
  subject_id uuid not null,

  kind app.mia_credential_kind not null,

  -- A member
  member_no   text,
  member_name text,
  -- 'CA', 'LA', 'AM' as the register prints them. Not an enum: the
  -- register is somebody else's list and a category added to it should
  -- arrive as itself rather than as a failed insert.
  member_type text,
  pc_holder   boolean,

  -- A firm
  firm_no   text,   -- normalised to 'AF 0759'
  firm_name text,
  firm_type text check (firm_type is null or firm_type in ('A', 'NA')),
  address   text,
  tel       text,
  fax       text,
  email     text,
  website   text,

  state text,       -- the register's own display name, e.g. 'Selangor'

  verified_via app.mia_verified_via not null default 'mia_website_manual',
  verified_at  timestamptz not null default now(),
  verified_by  uuid references public.profiles (id) on delete set null,

  -- Exactly what was pasted. An audit wants to see what the screen was
  -- shown, not only what was parsed out of it.
  raw_text text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint mia_credentials_one_owner
    check ((org_id is not null) <> (firm_id is not null)),

  -- The owner has to be the kind of owner the subject has, or a
  -- corporate officer's credential could be filed against a practice.
  constraint mia_credentials_owner_matches_subject check (
    (subject_type = 'corp_officer' and org_id is not null)
    or (subject_type = 'firm' and firm_id is not null)),

  -- One member credential and one firm credential per subject. An
  -- engagement partner holds both; nobody holds two of either.
  unique (subject_type, subject_id, kind)
);

create index mia_credentials_subject_idx
  on public.mia_credentials (subject_type, subject_id);
create index mia_credentials_org_idx
  on public.mia_credentials (org_id) where org_id is not null;
create index mia_credentials_firm_idx
  on public.mia_credentials (firm_id) where firm_id is not null;

create trigger set_updated_at before update on public.mia_credentials
  for each row execute function app.set_updated_at();

alter table public.mia_credentials enable row level security;

-- Reading follows the owner. Everything else goes through the two
-- functions below, so there is no insert, update or delete policy.
create policy mia_credentials_read on public.mia_credentials
  for select using (
    (org_id is not null and app.is_org_member(org_id))
    or (firm_id is not null and app.is_firm_member(firm_id))
  );

grant select on public.mia_credentials to authenticated;

-- ---------------------------------------------------------------------
-- The live feed
--
-- The handoff this came from said no `live_change_*` trigger was
-- needed. `supabase/tests/live_change_feed.sql` disagrees and is right:
-- the rule there is "every org-scoped table whose writes are CHANGES",
-- with read-receipt tables the only exception, "because a glance is not
-- a change". Recording what the register said about a company's auditor
-- is a change, and a colleague with the entity open should see it
-- arrive rather than find it on the next reload.
--
-- All three, as `0567` attaches them: an upsert that replaces last
-- year's answer is an update, and withdrawing one is a delete.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.mia_credentials
  referencing new table as new_rows
  for each statement execute function app.note_live_change();

create trigger live_change_update after update on public.mia_credentials
  referencing new table as new_rows old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_delete after delete on public.mia_credentials
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- Writing one
--
-- The owner is looked UP from the subject rather than taken from the
-- caller. A caller who could name the org would be choosing which
-- company's permission check to face, which is the whole check.
-- ---------------------------------------------------------------------
create or replace function public.upsert_mia_credential(
  p_subject_type text,
  p_subject_id uuid,
  p_kind app.mia_credential_kind,
  p_fields jsonb default '{}'::jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_org   uuid;
  v_firm  uuid;
  v_id    uuid;
  v_firm_no text;
begin
  if p_subject_type = 'corp_officer' then
    select o.org_id into v_org
      from public.corp_officers o where o.id = p_subject_id;
    if v_org is null then
      raise exception 'No such officer.' using errcode = 'P0002';
    end if;
    if not app.can_write(v_org) then
      raise exception 'not permitted to write for this organization'
        using errcode = '42501';
    end if;
  elsif p_subject_type = 'firm' then
    select f.id into v_firm from public.firms f where f.id = p_subject_id;
    if v_firm is null then
      raise exception 'No such firm.' using errcode = 'P0002';
    end if;
    if not app.can_manage_firm(v_firm) then
      raise exception 'not permitted to manage this firm'
        using errcode = '42501';
    end if;
  else
    raise exception 'A credential is recorded against an officer or a firm.'
      using errcode = '22023';
  end if;

  -- 'AF0759' and 'af 0759' are the same firm. Normalised on the way in
  -- so two spellings cannot sit in the column looking like two firms.
  v_firm_no := nullif(btrim(coalesce(p_fields ->> 'firm_no', '')), '');
  if v_firm_no is not null then
    v_firm_no := regexp_replace(upper(v_firm_no), '^([A-Z]{1,3})\s*', '\1 ');
  end if;

  insert into public.mia_credentials as m (
    org_id, firm_id, subject_type, subject_id, kind,
    member_no, member_name, member_type, pc_holder,
    firm_no, firm_name, firm_type, address, tel, fax, email, website,
    state, verified_via, verified_at, verified_by, raw_text)
  values (
    v_org, v_firm, p_subject_type, p_subject_id, p_kind,
    nullif(btrim(coalesce(p_fields ->> 'member_no', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'member_name', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'member_type', '')), ''),
    case when p_fields ? 'pc_holder'
         then (p_fields ->> 'pc_holder')::boolean end,
    v_firm_no,
    nullif(btrim(coalesce(p_fields ->> 'firm_name', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'firm_type', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'address', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'tel', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'fax', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'email', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'website', '')), ''),
    nullif(btrim(coalesce(p_fields ->> 'state', '')), ''),
    -- NOT taken from the caller. A row typed in by hand that claimed to
    -- have come from an API would be a lie the schema helped tell.
    'mia_website_manual',
    now(),
    auth.uid(),
    nullif(btrim(coalesce(p_fields ->> 'raw_text', '')), ''))
  on conflict (subject_type, subject_id, kind) do update set
    member_no = excluded.member_no,
    member_name = excluded.member_name,
    member_type = excluded.member_type,
    pc_holder = excluded.pc_holder,
    firm_no = excluded.firm_no,
    firm_name = excluded.firm_name,
    firm_type = excluded.firm_type,
    address = excluded.address,
    tel = excluded.tel,
    fax = excluded.fax,
    email = excluded.email,
    website = excluded.website,
    state = excluded.state,
    verified_via = excluded.verified_via,
    verified_at = excluded.verified_at,
    verified_by = excluded.verified_by,
    raw_text = excluded.raw_text,
    updated_at = now()
  returning m.id into v_id;

  return v_id;
end;
$function$;

comment on function public.upsert_mia_credential(text, uuid, app.mia_credential_kind, jsonb) is
  'Records what MIA''s members and firms register said about a corporate '
  'officer or a practice, and stamps who looked it up and when. The '
  'owning organization or firm is read FROM THE SUBJECT, never taken '
  'from the caller. `verified_via` is always `mia_website_manual`: '
  'nothing fetches mia.org.my, and a row that claimed otherwise would '
  'be a lie the schema helped tell. Needs `can_write` on the officer''s '
  'company, or `can_manage_firm` on the firm.';

grant execute on function public.upsert_mia_credential(text, uuid, app.mia_credential_kind, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Taking one off
-- ---------------------------------------------------------------------
create or replace function public.delete_mia_credential(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_org uuid;
  v_firm uuid;
begin
  select m.org_id, m.firm_id into v_org, v_firm
    from public.mia_credentials m where m.id = p_id;
  if v_org is null and v_firm is null then
    raise exception 'No such credential.' using errcode = 'P0002';
  end if;

  if v_org is not null and not app.can_write(v_org) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_firm is not null and not app.can_manage_firm(v_firm) then
    raise exception 'not permitted to manage this firm'
      using errcode = '42501';
  end if;

  delete from public.mia_credentials where id = p_id;
end;
$function$;

comment on function public.delete_mia_credential(uuid) is
  'Removes a recorded MIA credential. Asks the same question of the '
  'same owner as `upsert_mia_credential`.';

grant execute on function public.delete_mia_credential(uuid) to authenticated;

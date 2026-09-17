-- =====================================================================
-- iAkauntan :: 0589 who the registry says they are
--
-- Looking a company up at SSM by name and keeping what the registry
-- answered, rather than what somebody typed off a letterhead.
--
-- The point is narrow and worth stating. `contacts.registration_no` is
-- a number somebody keyed, and it is what MyInvois validates a party
-- against — one transposed digit is a submission LHDN rejects, or
-- worse, attributes to another company. A number that came back from a
-- registry search is a different kind of fact, and this migration is
-- about being able to tell the two apart.
--
-- ---------------------------------------------------------------------
-- What this deliberately does NOT add
--
-- The package this came from adds `ssm_name`, `ssm_reg_no` and
-- `ssm_reg_no_old` to the contact. This schema already has `name`,
-- `registration_no` and `old_registration_no`, so those three would be
-- exact duplicates — two columns holding the same fact, and nothing to
-- say which one a report should believe. A lookup FILLS the existing
-- columns.
--
-- What is genuinely new is provenance: `ssm_verified_at` says the
-- registry confirmed these on a date, and `ssm_entity_type` and
-- `ssm_slug` are things the registry knows that this schema had no
-- column for. The same shape as `corp_persons.id_verified_on`, and for
-- the same reason.
--
-- It also does not add a platform-admin table or predicate. `app
-- .is_platform_admin()` already exists, and a second list of who is an
-- administrator is a second list to get wrong.
--
-- And it stores no credentials. The ssmsearch.com login lives in the
-- Supabase dashboard as an edge-function secret, like `OCR_KEY_*`,
-- `RESEND_API_KEY` and every other secret here — never in this
-- repository, this database, or any payload the app can read.
--
-- ---------------------------------------------------------------------
-- A caution that belongs in the schema and not only in a README
--
-- The interim provider signs in to ssmsearch.com the way its own
-- website does and calls its search endpoint from a server. Their terms
-- of service prohibit reaching the service "on another website or
-- server … through … any other technological means", and prohibit
-- sharing login credentials. This is running while the official SSM
-- Corporate API is arranged; `docs/ssm-lookup.md` says so where an
-- operator will read it. Keep volumes modest — the cache and the
-- per-user limit below are part of that — and switch providers when
-- the API is available.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The session the edge function holds
-- ---------------------------------------------------------------------

create table if not exists public.ssm_session (
  id              integer primary key default 1 check (id = 1),
  provider        text not null default 'ssmsearch_web',
  token           text,
  logged_in_as    text,
  obtained_at     timestamptz,
  last_used_at    timestamptz,
  last_error      text,
  last_error_at   timestamptz,
  refresh_lock_at timestamptz,
  updated_at      timestamptz not null default now()
);

comment on table public.ssm_session is
  'The one live ssmsearch.com login the ssm-search edge function holds, '
  'so a search does not sign in again every time. SERVICE ROLE ONLY: it '
  'carries a bearer token, and RLS is on with no policies so nothing '
  'else can reach it. Not a credential store — the email and password '
  'are edge-function secrets in the Supabase dashboard.';

insert into public.ssm_session (id) values (1) on conflict (id) do nothing;

alter table public.ssm_session enable row level security;
revoke all on public.ssm_session from anon, authenticated;

-- ---------------------------------------------------------------------
-- The cache, which is also a courtesy to the upstream
-- ---------------------------------------------------------------------

create table if not exists public.ssm_search_cache (
  cache_key  text primary key,
  provider   text not null,
  payload    jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

comment on table public.ssm_search_cache is
  'Searches already answered, keyed on the normalised query. Service '
  'role only. Two reasons and the second is the important one: a repeat '
  'search is instant, and a company that is looked up by six people in '
  'a morning reaches the upstream once — which is part of keeping the '
  'volume modest while the interim provider is in use.';

create index if not exists ssm_search_cache_expires_idx
  on public.ssm_search_cache (expires_at);

alter table public.ssm_search_cache enable row level security;
revoke all on public.ssm_search_cache from anon, authenticated;

-- ---------------------------------------------------------------------
-- The log, which is the rate limit
-- ---------------------------------------------------------------------

create table if not exists public.ssm_search_log (
  id           bigint generated by default as identity primary key,
  -- `searched_by` and not `user_id`, and no `org_id` at all. Both are
  -- this schema's own rules rather than taste:
  -- `a_colleague_not_a_stranger.sql` reads a `user_id` beside an
  -- `org_id` as work HANDED to somebody and wants a trigger checking
  -- they belong, and `live_change_feed.sql` wants every table with an
  -- `org_id` to wake the clients watching it. Neither is true here.
  -- This is an audit row naming who acted, which is what the `_by`
  -- suffix means everywhere else in this schema, and nobody watches it
  -- because nobody may read it.
  --
  -- The company adds nothing either: the limit is per person, and a
  -- search is made by a human rather than on behalf of a tenant.
  searched_by  uuid references auth.users (id) on delete set null,
  query        text,
  provider     text,
  cached       boolean not null default false,
  result_count integer,
  error_code   text,
  created_at   timestamptz not null default now()
);

comment on table public.ssm_search_log is
  'Every search, who made it and whether it was answered from cache. '
  'Service role only. Doubles as the rate limit: the per-minute count '
  'is a count of these rows, so the record and the limit cannot '
  'disagree with each other.';

create index if not exists ssm_search_log_actor_time_idx
  on public.ssm_search_log (searched_by, created_at desc);

alter table public.ssm_search_log enable row level security;
revoke all on public.ssm_search_log from anon, authenticated;

-- ---------------------------------------------------------------------
-- What the registry calls the kinds of entity
-- ---------------------------------------------------------------------

create table if not exists public.ssm_entity_types (
  id       integer primary key,
  title    text not null,
  title_my text
);

comment on table public.ssm_entity_types is
  'The four kinds of entity SSM registers, as the search returns them. '
  'Readable by any signed-in user because it is a picker''s contents '
  'and nothing about it is anybody''s business but the registry''s.';

insert into public.ssm_entity_types (id, title, title_my) values
  (1,  'Company',                        'Syarikat'),
  (2,  'Business',                       'Perniagaan'),
  (3,  'Audit Firm',                     'Firma Audit'),
  (25, 'Limited Liability Partnership',  'Perkongsian Liabiliti Terhad')
on conflict (id) do update
  set title = excluded.title, title_my = excluded.title_my;

alter table public.ssm_entity_types enable row level security;
drop policy if exists ssm_entity_types_read on public.ssm_entity_types;
create policy ssm_entity_types_read on public.ssm_entity_types
  for select to authenticated using (true);
grant select on public.ssm_entity_types to authenticated;

-- ---------------------------------------------------------------------
-- The lock, so two function instances do not both sign in
-- ---------------------------------------------------------------------

create or replace function public.ssm_session_try_lock(p_seconds integer default 30)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare v_got boolean;
begin
  update public.ssm_session
     set refresh_lock_at = now()
   where id = 1
     and (refresh_lock_at is null
          or refresh_lock_at < now() - make_interval(secs => p_seconds))
  returning true into v_got;
  return coalesce(v_got, false);
end;
$function$;

comment on function public.ssm_session_try_lock(integer) is
  'Takes the sign-in lock for a few seconds, returning whether this '
  'caller got it. Two edge-function instances noticing an expired token '
  'at the same moment would otherwise both sign in, and ssmsearch.com '
  'is one shared account — the second login can invalidate the first '
  'one''s token, which is a loop rather than a race. The lock EXPIRES '
  'rather than being released, so an instance that dies holding it '
  'blocks the next sign-in for seconds and not for ever. Service role '
  'only.';

revoke all on function public.ssm_session_try_lock(integer) from public, anon, authenticated;
grant execute on function public.ssm_session_try_lock(integer) to service_role;

-- ---------------------------------------------------------------------
-- What a contact keeps from a lookup
-- ---------------------------------------------------------------------

alter table public.contacts
  add column if not exists ssm_entity_type text,
  add column if not exists ssm_slug text,
  add column if not exists ssm_verified_at timestamptz;

comment on column public.contacts.ssm_verified_at is
  'When SSM''s register last confirmed this contact''s name and '
  'registration number. The difference between a number somebody typed '
  'and one the registry returned — which is the whole point of the '
  'lookup, because `registration_no` is what MyInvois validates a party '
  'against and a transposed digit is a submission rejected or '
  'attributed to another company. Null means nobody has checked.';

comment on column public.contacts.ssm_entity_type is
  'Company, Business, Audit Firm or Limited Liability Partnership, as '
  'the registry classifies it. Not a field this schema had before, and '
  'not one a letterhead reliably states.';

comment on column public.contacts.ssm_slug is
  'The registry''s own handle for the entity, kept so a later lookup '
  'can go straight back to the same record rather than searching the '
  'name again and hoping.';

create index if not exists contacts_ssm_verified_idx
  on public.contacts (org_id) where ssm_verified_at is not null;

-- ---------------------------------------------------------------------
-- Recording what was chosen
-- ---------------------------------------------------------------------

create or replace function public.set_contact_ssm_entity(
  p_contact uuid,
  p_name text,
  p_reg_no text,
  p_reg_no_old text default null,
  p_entity_type text default null,
  p_slug text default null)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_org uuid;
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact;
  if v_org is null then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A registry match has a name.' using errcode = '23514';
  end if;

  update public.contacts set
    name                = btrim(p_name),
    registration_no     = nullif(btrim(coalesce(p_reg_no, '')), ''),
    old_registration_no = coalesce(
      nullif(btrim(coalesce(p_reg_no_old, '')), ''), old_registration_no),
    -- The SSM number is also what identifies the party on an e-Invoice,
    -- and the whole reason to do this is to get that right. Only when
    -- the contact is not already identified some other way: a TIN
    -- somebody entered deliberately is not ours to overwrite.
    id_value = case
      when nullif(btrim(coalesce(id_value, '')), '') is null
        then nullif(btrim(coalesce(p_reg_no, '')), '')
      else id_value end,
    id_type = case
      when nullif(btrim(coalesce(id_value, '')), '') is null
           and nullif(btrim(coalesce(p_reg_no, '')), '') is not null
        then coalesce(id_type, 'BRN')
      else id_type end,
    ssm_entity_type = nullif(btrim(coalesce(p_entity_type, '')), ''),
    ssm_slug        = nullif(btrim(coalesce(p_slug, '')), ''),
    ssm_verified_at = now(),
    updated_at      = now()
  where id = p_contact;

  return p_contact;
end;
$function$;

comment on function public.set_contact_ssm_entity(uuid, text, text, text, text, text) is
  'Writes what SSM''s register answered onto a contact, and stamps '
  '`ssm_verified_at`. OVERWRITES THE NAME AND THE REGISTRATION NUMBER: '
  'that is the point — the registry is the authority on both, and a '
  'lookup somebody confirmed is worth more than what was typed off a '
  'letterhead. Does NOT overwrite `id_value` when the contact already '
  'has one, because a TIN entered deliberately for e-Invoice is not '
  'this function''s to replace; it only fills an empty one, as BRN. '
  'The old registration number is kept when the registry does not '
  'return one, since an older number that was already recorded is '
  'still true. Needs `can_write`.';

grant execute on function public.set_contact_ssm_entity(uuid, text, text, text, text, text) to authenticated;

-- =====================================================================
-- iAkauntan :: 0719 support access, and a company made for somebody
--
-- Asked for, in the console: view/add/edit users, add and edit an
-- organisation, and "access user and organisation". On the last one the
-- answer to what it should do was SUPPORT ACCESS -- a platform
-- administrator entering a customer's account to see what they see.
--
-- This migration is the database half of support access and of making
-- a company for somebody else. The users half needs an edge function,
-- because minting an auth user takes the service role key and that key
-- is never in the app.
--
-- ---------------------------------------------------------------------
-- What support access is NOT
--
-- It is not logging in as the customer. Nothing here mints a session as
-- somebody else, and no administrator ever holds a customer's
-- credentials.
--
-- That is a deliberate refusal, and the reason is this product. If an
-- administrator could act AS a customer, then a journal posted during a
-- support call would be recorded as the customer's own -- and a set of
-- books whose audit trail says somebody posted an entry they did not
-- post is not a set of books. An accounting system's trail is the one
-- thing that must never lie about who acted.
--
-- So: the administrator stays themselves, and is granted a TEMPORARY
-- ROLE in the customer's organisation. Every row they can see is the
-- row the customer sees; every row they could write would carry their
-- own name -- except that they cannot write at all, which is the next
-- section.
--
-- ---------------------------------------------------------------------
-- The role is `auditor`, and that is the whole safety argument
--
-- This schema already has a role that reads everything and writes
-- nothing. `can_read_ledger` lists `auditor`; `can_write`, `can_post`
-- and `can_admin` do not. So a support grant does not need a new
-- permission model, a new set of policies, or a list of what is
-- allowed -- it reuses the one already written, and write is impossible
-- BY CONSTRUCTION rather than by a check somebody has to remember.
--
-- Read-only was not asked for and is being decided here, so it is said
-- plainly: a support session can look at anything and change nothing.
-- If changing something turns out to be needed, that is a separate
-- decision with a separate migration, and it should be made on purpose
-- rather than inherited from a convenience.
--
-- ---------------------------------------------------------------------
-- Three seams, and they are the only three
--
-- `app.org_role` is what every `can_*` guard resolves through, so the
-- grant is honoured there and the rest follows without being touched.
-- A REAL membership always wins: an administrator who genuinely owns a
-- company is not demoted to auditor of it by a grant somebody left
-- open.
--
-- `app.is_org_member` reads `org_members` directly rather than through
-- `org_role`, so it needs its own line. It is what most RLS select
-- policies call.
--
-- `public.my_organizations` is the switcher. Without it the grant would
-- be real and the company would be invisible -- access nobody can
-- reach, which is the failure mode of every half-wired feature in this
-- repository.
--
-- Anything else that reads `org_members` by hand is NOT covered, and
-- that is stated rather than hoped: the assertions walk the ledger, the
-- documents and the member list to show the three seams carry it, but a
-- policy written tomorrow against `org_members` would not be.
--
-- ---------------------------------------------------------------------
-- It expires, it is announced, and the customer can see it
--
-- An expiry, capped, because access that has to be remembered to be
-- revoked is access that never is.
--
-- A reason, required, in `platform_force_transfer`'s words: a grant
-- with no reason recorded is not distinguishable from a back door.
--
-- And a row in `audit_logs` WITH THE ORG ID SET, so it appears in the
-- CUSTOMER's own trail and not only in ours. Somebody reading their own
-- audit trail should be able to see that support was in their books,
-- when, for how long and why. A support feature visible only to the
-- people using it is surveillance with a nicer name.
-- =====================================================================

create table if not exists public.support_access (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  admin_id    uuid not null references auth.users (id) on delete cascade,
  reason      text not null,
  granted_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  ended_at    timestamptz,
  ended_by    uuid references auth.users (id),
  constraint support_access_window_ck check (expires_at > granted_at),
  constraint support_access_reason_ck check (btrim(reason) <> '')
);

create index if not exists support_access_open_idx
  on public.support_access (admin_id, org_id)
  where ended_at is null;

comment on table public.support_access is
  'A platform administrator temporarily reading one organisation, with '
  'a reason and an expiry. Grants the `auditor` role and nothing more, '
  'so a support session can look at anything and change nothing. '
  '`0719`.';

alter table public.support_access enable row level security;

-- The customer sees grants over their own books; platform staff see
-- all of them. Nobody writes this table directly -- the functions below
-- are the only way in, which is why there is no insert policy.
drop policy if exists support_access_read on public.support_access;
create policy support_access_read on public.support_access
  for select to authenticated
  using (app.is_platform_admin() or app.is_org_member(org_id));

-- ---------------------------------------------------------------------
-- Is there one open right now
-- ---------------------------------------------------------------------
create or replace function app.support_access_active(p_org_id uuid)
returns boolean language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
    select 1 from public.support_access s
     where s.org_id = p_org_id
       and s.admin_id = auth.uid()
       and s.ended_at is null
       and s.expires_at > now());
$$;

-- SELECT only, and only that. A policy without the privilege to reach
-- it is a policy nobody can use -- `table_grants.sql` caught exactly
-- that here -- and the write privileges are deliberately absent:
-- `grant_support_access` and `end_support_access` are SECURITY DEFINER
-- and are the only way a row is written, so nothing needs to be able to
-- insert into this table through PostgREST.
grant select on public.support_access to authenticated;

-- The realtime feed, on the same rule as every other table with an
-- `org_id`: a company watching its own screens should see a support
-- session open and close without reloading. `live_change_feed.sql`
-- checks that every such table is attached, and it caught this one.
drop trigger if exists live_change_insert on public.support_access;
create trigger live_change_insert after insert on public.support_access
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
drop trigger if exists live_change_update on public.support_access;
create trigger live_change_update after update on public.support_access
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
drop trigger if exists live_change_delete on public.support_access;
create trigger live_change_delete after delete on public.support_access
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

comment on function app.support_access_active(uuid) is
  'Whether the caller holds an unexpired, unrevoked support grant over '
  'this organisation. Read by `app.org_role`, `app.is_org_member` and '
  '`public.my_organizations` — the three seams support access travels '
  'through. `0719`.';

-- ---------------------------------------------------------------------
-- The three seams, restated whole
-- ---------------------------------------------------------------------
create or replace function app.org_role(p_org_id uuid)
returns app.member_role
language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(
    -- A REAL membership first and always. An administrator who owns a
    -- company is not demoted to auditor of it by a grant left open.
    (select m.role from public.org_members m
       join public.organizations o on o.id = m.org_id
      where m.org_id = p_org_id
        and m.user_id = auth.uid()
        and m.status = 'active'
        and o.deleted_at is null
        and not exists (select 1 from public.profiles p
                         where p.id = m.user_id and p.deleted_at is not null)
      limit 1),
    -- `0719`. Reads everything, writes nothing: `can_read_ledger` lists
    -- `auditor` and `can_write`, `can_post` and `can_admin` do not, so
    -- the read-only half of support access needs no rules of its own.
    (select 'auditor'::app.member_role
      where app.support_access_active(p_org_id)));
$$;

create or replace function app.is_org_member(p_org_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.org_members m
      join public.organizations o on o.id = m.org_id
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active'
       and o.deleted_at is null
       and not exists (select 1 from public.profiles p
                        where p.id = m.user_id and p.deleted_at is not null)
  )
  -- `0719`: this reads `org_members` directly rather than through
  -- `org_role`, so the grant needs saying twice. It is what most RLS
  -- select policies in this schema call.
  or app.support_access_active(p_org_id);
$$;

create or replace function public.my_organizations()
returns setof public.organizations
language sql stable security definer
set search_path = public, pg_temp as $$
  select o.* from public.organizations o
    join public.org_members m on m.org_id = o.id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and o.deleted_at is null
     and not exists (select 1 from public.profiles p
                      where p.id = m.user_id and p.deleted_at is not null)
  union
  -- `0719`. Without this the grant would be real and the company
  -- invisible -- access nobody can reach, which is how a half-wired
  -- feature looks from the outside.
  select o.* from public.organizations o
   where o.deleted_at is null
     and app.support_access_active(o.id)
   order by 2;
$$;

-- ---------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------
create or replace function public.grant_support_access(
  p_org_id uuid, p_reason text, p_minutes integer default 60)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id      uuid;
  v_minutes integer;
  v_name    text;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  -- `platform_force_transfer`'s rule and very nearly its words. The
  -- reason is the difference between support and a back door.
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception
      'Say why. Reading somebody''s books with no reason recorded is '
      'not distinguishable from a back door.'
      using errcode = '23514';
  end if;

  select o.name into v_name from public.organizations o
   where o.id = p_org_id and o.deleted_at is null;
  if v_name is null then
    raise exception 'No such company.' using errcode = 'P0002';
  end if;

  -- Capped at a working day. Access that has to be remembered to be
  -- revoked is access that never is, and eight hours is longer than any
  -- support call.
  v_minutes := least(greatest(coalesce(p_minutes, 60), 5), 480);

  -- One open grant per administrator per company. Asking twice extends
  -- rather than stacks, so ending it ends it.
  update public.support_access
     set ended_at = now(), ended_by = auth.uid()
   where org_id = p_org_id and admin_id = auth.uid() and ended_at is null;

  insert into public.support_access (org_id, admin_id, reason, expires_at)
  values (p_org_id, auth.uid(), btrim(p_reason),
          now() + make_interval(mins => v_minutes))
  returning id into v_id;

  -- WITH THE ORG ID, so it lands in the customer's own audit trail and
  -- not only in the platform's. Somebody reading their trail should see
  -- that support was in their books, when, for how long and why.
  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, new_data)
  -- `action` is a closed vocabulary on this table -- insert, update,
  -- delete, post, void, submit -- and a grant IS an insert into
  -- `support_access`. What KIND of event it was goes in the payload
  -- rather than widening a constraint the whole ledger depends on.
  values (p_org_id, auth.uid(), 'support_access', v_id, 'insert',
          jsonb_build_object(
            'event', 'support_granted',
            'reason', btrim(p_reason),
            'minutes', v_minutes,
            'read_only', true));

  return v_id;
end;
$$;

revoke all on function public.grant_support_access(uuid, text, integer)
  from public, anon;
grant execute on function public.grant_support_access(uuid, text, integer)
  to authenticated;

comment on function public.grant_support_access(uuid, text, integer) is
  'Lets a platform administrator read one organisation for a while. '
  'Requires a reason, expires within eight hours, grants `auditor` and '
  'nothing more, and is written into the CUSTOMER''s audit trail. '
  '`0719`.';

-- ---------------------------------------------------------------------
-- Ending one
-- ---------------------------------------------------------------------
create or replace function public.end_support_access(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare s public.support_access;
begin
  select * into s from public.support_access where id = p_id;
  if not found then
    raise exception 'No such support session.' using errcode = 'P0002';
  end if;

  -- The administrator who holds it, any platform administrator, or an
  -- ADMINISTRATOR OF THE COMPANY ITSELF. The last one matters: being
  -- able to see that somebody is in your books and not being able to
  -- show them out is not a control, it is a notification.
  if not (s.admin_id = auth.uid()
          or app.is_platform_admin()
          or app.can_admin(s.org_id)) then
    raise exception 'That is not yours to end' using errcode = '42501';
  end if;

  if s.ended_at is not null then
    return;
  end if;

  update public.support_access
     set ended_at = now(), ended_by = auth.uid()
   where id = p_id;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, new_data)
  values (s.org_id, auth.uid(), 'support_access', p_id, 'update',
          jsonb_build_object('event', 'support_ended',
                             'by_the_customer', app.can_admin(s.org_id)));
end;
$$;

revoke all on function public.end_support_access(uuid) from public, anon;
grant execute on function public.end_support_access(uuid) to authenticated;

comment on function public.end_support_access(uuid) is
  'Ends a support session. The administrator holding it, any platform '
  'administrator, or an administrator of the company being read — '
  'seeing somebody in your books without being able to show them out '
  'is a notification, not a control. `0719`.';

-- ---------------------------------------------------------------------
-- What is open, for the banner and for the console
-- ---------------------------------------------------------------------
create or replace function public.my_support_access()
returns table (
  id uuid, org_id uuid, org_name text, reason text,
  granted_at timestamptz, expires_at timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select s.id, s.org_id, o.name, s.reason, s.granted_at, s.expires_at
    from public.support_access s
    join public.organizations o on o.id = s.org_id
   where s.admin_id = auth.uid()
     and s.ended_at is null
     and s.expires_at > now()
   order by s.granted_at desc;
$$;

revoke all on function public.my_support_access() from public, anon;
grant execute on function public.my_support_access() to authenticated;

comment on function public.my_support_access() is
  'The support sessions the caller currently holds, so the app can say '
  'so on every screen while one is open. `0719`.';

create or replace function public.org_support_access(p_org_id uuid)
returns table (
  id uuid, admin_name text, reason text,
  granted_at timestamptz, expires_at timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) and not app.is_platform_admin() then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  return query
    select s.id,
           coalesce(p.full_name, p.email::text, 'Support'),
           s.reason, s.granted_at, s.expires_at
      from public.support_access s
      left join public.profiles p on p.id = s.admin_id
     where s.org_id = p_org_id
       and s.ended_at is null
       and s.expires_at > now()
     order by s.granted_at desc;
end;
$$;

revoke all on function public.org_support_access(uuid) from public, anon;
grant execute on function public.org_support_access(uuid) to authenticated;

comment on function public.org_support_access(uuid) is
  'Who is reading this company''s books right now, for the company to '
  'see. `0719`.';

create or replace function public.platform_support_access(p_limit integer default 100)
returns table (
  id uuid, org_id uuid, org_name text, admin_name text, reason text,
  granted_at timestamptz, expires_at timestamptz, ended_at timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  return query
    select s.id, s.org_id, o.name,
           coalesce(p.full_name, p.email::text, 'Support'),
           s.reason, s.granted_at, s.expires_at, s.ended_at
      from public.support_access s
      join public.organizations o on o.id = s.org_id
      left join public.profiles p on p.id = s.admin_id
     order by s.granted_at desc
     limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.platform_support_access(integer) from public, anon;
grant execute on function public.platform_support_access(integer) to authenticated;

comment on function public.platform_support_access(integer) is
  'Every support session, open and closed, for the console. `0719`.';

-- ---------------------------------------------------------------------
-- A company made for somebody else
--
-- Composed rather than rewritten. `create_organization` seeds a chart
-- of accounts, eight tax codes, eight payment terms, a warehouse and
-- the price levels; `app.hand_company_over` moves ownership and is what
-- `platform_force_transfer` already uses. A second copy of either would
-- be a second set of rules to drift.
--
-- The administrator is the owner for the length of one statement, and
-- the handover is recorded with the reason, exactly as a forced
-- transfer is.
-- ---------------------------------------------------------------------
create or replace function public.platform_create_organization(
  p_owner_email text,
  p_name text,
  p_entity_type text default 'sdn_bhd',
  p_registration_no text default null,
  p_tin text default null,
  p_state_code text default null,
  p_city text default null,
  p_phone text default null,
  p_email text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_owner uuid;
  v_org   uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A company needs a name.' using errcode = '23514';
  end if;

  select u.id into v_owner from auth.users u
   where lower(u.email) = lower(btrim(coalesce(p_owner_email, '')));
  if v_owner is null then
    raise exception
      'Nobody here has that address. Add the person first, then the '
      'company — a company with no owner is a company nobody can open.'
      using errcode = 'P0002';
  end if;

  v_org := public.create_organization(
    p_name => btrim(p_name),
    p_entity_type => p_entity_type,
    p_registration_no => p_registration_no,
    p_tin => p_tin,
    p_state_code => p_state_code,
    p_city => p_city,
    p_phone => p_phone,
    p_email => p_email);

  perform app.hand_company_over(
    v_org, v_owner, auth.uid(), null, auth.uid(),
    format('Company created in the console for %s', btrim(p_owner_email)));

  -- AND STRAIGHT BACK OUT AGAIN.
  --
  -- `app.hand_company_over` leaves the outgoing owner as an `admin` --
  -- "steps down rather than out", and for a handover between two people
  -- that is right, because somebody has to still be able to open the
  -- books. Here the administrator was never a participant, only the
  -- mechanism. Left alone, this would quietly make them an
  -- administrator of every company they ever set up for a customer, and
  -- standing access accumulated that way is exactly what support access
  -- exists so that nobody needs.
  delete from public.org_members m
   where m.org_id = v_org and m.user_id = auth.uid();

  return v_org;
end;
$$;

revoke all on function public.platform_create_organization(
  text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.platform_create_organization(
  text, text, text, text, text, text, text, text, text) to authenticated;

comment on function public.platform_create_organization(
  text, text, text, text, text, text, text, text, text) is
  'Creates a fully seeded company and hands it to the named owner. '
  'Composed from `create_organization` and `app.hand_company_over` so '
  'there is one chart of accounts to seed and one handover to record. '
  '`0719`.';

-- ---------------------------------------------------------------------
-- Editing one
--
-- The fields a support call actually asks about. Deliberately NOT the
-- tax defaults, the fiscal year or the books start date: those change
-- what the ledger does, they have their own screens with their own
-- guards, and a console that could quietly move a year end is a console
-- that can break a filing.
-- ---------------------------------------------------------------------
create or replace function public.platform_update_organization(
  p_org_id uuid,
  p_name text default null,
  p_legal_name text default null,
  p_registration_no text default null,
  p_tin text default null,
  p_phone text default null,
  p_email text default null,
  p_city text default null,
  p_state_code text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_before jsonb;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  select to_jsonb(o) into v_before from public.organizations o
   where o.id = p_org_id and o.deleted_at is null;
  if v_before is null then
    raise exception 'No such company.' using errcode = 'P0002';
  end if;

  -- `nullif(btrim(...), '')` throughout, so a field left alone is left
  -- alone and a field cleared on purpose is a separate act. A blank
  -- box in a form is "I did not type here", not "delete this".
  update public.organizations o
     set name             = coalesce(nullif(btrim(coalesce(p_name, '')), ''), o.name),
         legal_name       = coalesce(nullif(btrim(coalesce(p_legal_name, '')), ''), o.legal_name),
         registration_no  = coalesce(nullif(btrim(coalesce(p_registration_no, '')), ''), o.registration_no),
         tin              = coalesce(nullif(btrim(coalesce(p_tin, '')), ''), o.tin),
         phone            = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), o.phone),
         email            = coalesce(nullif(btrim(coalesce(p_email, '')), ''), o.email),
         city             = coalesce(nullif(btrim(coalesce(p_city, '')), ''), o.city),
         state_code       = coalesce(nullif(btrim(coalesce(p_state_code, '')), ''), o.state_code),
         updated_at       = now()
   where o.id = p_org_id;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data)
  select p_org_id, auth.uid(), 'organizations', p_org_id, 'update',
         v_before, to_jsonb(o) || jsonb_build_object('event', 'platform_update')
    from public.organizations o where o.id = p_org_id;
end;
$$;

revoke all on function public.platform_update_organization(
  uuid, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.platform_update_organization(
  uuid, text, text, text, text, text, text, text, text) to authenticated;

comment on function public.platform_update_organization(
  uuid, text, text, text, text, text, text, text, text) is
  'Edits a company''s name and contact details from the console, and '
  'writes the before and after into that company''s own audit trail. '
  'Not the tax defaults, the fiscal year or the books start date — '
  'those change what the ledger does. `0719`.';

-- =====================================================================
-- iAkauntan :: 0619 gone from the product, not gone from the record
--
-- Asked for in one sentence: "add options delete accounts for normal
-- and multi accounts (don't permanently delete, keep records, but only
-- console admin can see; for users it is deleted)."
--
-- Three things in this product are called an account and all three were
-- asked about, so all three are here:
--
--   * a **login** -- the person who signs in;
--   * an **organization** -- a company, its books and everything in
--     them, which is the "multi" half of the question: one login can
--     hold several, and closing one is not closing the login;
--   * a **ledger account** -- a line of the chart of accounts.
--
-- ---------------------------------------------------------------------
-- What changes, and what 0158 got right
--
-- `0158` already closed a login, and its reasoning about the audit
-- trail stands: `auth.users` is referenced by about a hundred columns
-- that record who posted a journal, approved a payroll or signed a
-- resolution, and deleting the row destroys records the Companies Act
-- 2016 s.245 and the Income Tax Act 1967 s.82 require kept for seven
-- years. Nothing here undoes that.
--
-- What it did with the identity is what changes. `0158` **scrubbed**
-- it: full_name overwritten, email and phone set to null, membership
-- rows deleted. Irreversible, and irreversible in a way that answers no
-- question anyone can ask afterwards -- not "who was this", not "put
-- them back", not "how many accounts have been closed this year".
--
-- Now the identity **moves** rather than dying. `account_closures`
-- keeps it, that table has row level security on and **not one policy**,
-- and the only way to a row is a SECURITY DEFINER function that asks
-- `app.is_platform_admin()` first. So:
--
--   * to the person, to their colleagues, to every screen and every
--     query the app makes -- it is gone;
--   * to the platform console -- it is there, with who it was, when it
--     went, why, and whether it came back;
--   * only the console can bring it back.
--
-- That is a different trade than 0158 made. 0158 chose destruction
-- because destruction is the strongest privacy guarantee there is; this
-- chooses a locked drawer, because a closure nobody can undo and nobody
-- can account for is not a feature, it is a hole in the operator's
-- records. Said plainly here rather than buried: the address and phone
-- number of a closed account STILL EXIST in this database. They are
-- reachable by a platform operator and by nothing else.
--
-- ---------------------------------------------------------------------
-- Membership is suspended, not deleted
--
-- 0158 deleted `org_members` rows, which is the one part of it that was
-- losing a record rather than protecting one: after it ran, nothing
-- could say which companies the person had belonged to. They are now
-- set to `suspended` -- an enum value that already exists and that every
-- guard in the schema already treats as no access, because every one of
-- them asks for `status = 'active'` -- and the previous status is kept
-- in the closure so a restore puts each row back exactly as it was.
--
-- ---------------------------------------------------------------------
-- The guards do the hiding
--
-- `app.is_org_member` and `app.org_role` are what every RLS policy in
-- this schema reaches for. Both now refuse a closed login and a closed
-- company, which is why closing a company needs no policy changes
-- anywhere: one function, and the company's entire tenant -- ledger,
-- payroll, documents, everything -- stops being visible to its own
-- members at once.
--
-- Replacing them is not free. Both predate `0165`, whose event trigger
-- strips PUBLIC and anon from every function at CREATE -- and CREATE OR
-- REPLACE carries the same command tag. Their only grant was the
-- implicit PUBLIC one Postgres attaches at creation, so replacing them
-- without restating it would revoke the schema's central guard from
-- `authenticated` and every policy that calls it would start raising
-- `42501`. Restated below, and asserted at the bottom of this file --
-- the same shape of hole `0618` was written to close.
--
-- ---------------------------------------------------------------------
-- The sole owner, and the "multi" case
--
-- 0158 refused to close the last owner of a company, because doing so
-- orphans a tenant nobody can administer. That refusal stays and is
-- still the default. What is added is the other answer: close the
-- companies with me. A person holding four companies alone can now
-- leave in one action, and what happens to the four is recorded as four
-- closures of their own rather than as a side effect of one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The drawer
-- ---------------------------------------------------------------------
create table public.account_closures (
  id uuid primary key default gen_random_uuid(),

  -- Which of the three kinds of account this is.
  subject_kind text not null
    check (subject_kind in ('user', 'organization', 'ledger_account')),

  -- The row that was closed: auth.users.id, organizations.id or
  -- accounts.id. Deliberately not three nullable foreign keys -- the
  -- three point at three different tables and a closure is one row
  -- whichever it was.
  subject_id uuid not null,

  -- The company this belongs to, where there is one. An organization's
  -- own closure names itself here; a login's names nothing.
  org_id uuid references public.organizations (id) on delete set null,

  -- What it was called, at the moment it was closed. Kept flat rather
  -- than joined for: the name in the live row has been scrubbed by the
  -- time anybody reads this.
  label text not null,

  -- Everything needed to put it back, and everything a platform
  -- operator would need to answer a question about it afterwards. This
  -- is where the personal data of a closed login lives.
  detail jsonb not null default '{}'::jsonb,

  reason text,
  closed_by uuid references auth.users (id),
  closed_via text not null check (closed_via in ('self_service', 'console')),
  closed_at timestamptz not null default now(),

  -- Only the console writes these three.
  restored_by uuid references auth.users (id),
  restored_at timestamptz,
  restore_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.account_closures is
  'Every login, company and ledger account that has been closed, with '
  'the identity that was hidden from the product when it went. RLS is '
  'on and there is no policy: the only way in is a SECURITY DEFINER '
  'function that asks app.is_platform_admin() first. 0619.';

comment on column public.account_closures.detail is
  'What was hidden, and what a restore puts back. For a login this '
  'holds the name, email and phone -- personal data, reachable by a '
  'platform operator and by nobody else.';

-- One open closure per subject. Closing something twice is a bug, and
-- a second open row would make "which one does a restore undo" a
-- question with no answer.
create unique index account_closures_open_idx
  on public.account_closures (subject_kind, subject_id)
  where restored_at is null;

create index account_closures_recent_idx
  on public.account_closures (closed_at desc);

create trigger set_updated_at before update on public.account_closures
  for each row execute function app.set_updated_at();

-- Row level security on and not one policy: the shape this schema
-- already uses for `einvoice_credentials` and `org_ocr_credentials` to
-- mean "nobody's". There is nothing to permit, so every role is denied
-- and the SECURITY DEFINER console functions are the only way in.
alter table public.account_closures enable row level security;

-- And the privilege that would let PostgREST ask at all. A new table in
-- `public` arrives with Supabase's default SELECT for `anon` already
-- attached -- the trap `0496` fell into and `0498` swept up after -- so
-- taking it off is not belt and braces, it is the only thing standing
-- between a dropped policy and a list of every closed account's email
-- address.
revoke all on table public.account_closures from anon, authenticated;

-- ---------------------------------------------------------------------
-- A login that has been closed
-- ---------------------------------------------------------------------
alter table public.profiles add column deleted_at timestamptz;

comment on column public.profiles.deleted_at is
  'Set when the login was closed. The row stays -- a hundred audit '
  'columns point at it -- but every membership guard refuses it. 0619.';

-- ---------------------------------------------------------------------
-- The guards
--
-- Written as NOT EXISTS against profiles rather than as a join, so a
-- user with no profile row keeps the access they have today. A join
-- would quietly revoke it, and "the schema stopped working for anybody
-- whose profile trigger had not fired" is not a failure this should be
-- able to cause.
-- ---------------------------------------------------------------------
create or replace function app.is_org_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.org_members m
      join public.organizations o on o.id = m.org_id
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active'
       and o.deleted_at is null
       and not exists (select 1 from public.profiles p
                        where p.id = m.user_id and p.deleted_at is not null)
  );
$$;

create or replace function app.org_role(p_org_id uuid)
returns app.member_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.role from public.org_members m
    join public.organizations o on o.id = m.org_id
   where m.org_id = p_org_id
     and m.user_id = auth.uid()
     and m.status = 'active'
     and o.deleted_at is null
     and not exists (select 1 from public.profiles p
                      where p.id = m.user_id and p.deleted_at is not null)
   limit 1;
$$;

create or replace function public.my_organizations()
returns setof public.organizations
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select o.* from public.organizations o
    join public.org_members m on m.org_id = o.id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and o.deleted_at is null
     and not exists (select 1 from public.profiles p
                      where p.id = m.user_id and p.deleted_at is not null)
   order by o.name;
$$;

-- The grants these three had before this migration replaced them. See
-- the header: 0165's event trigger fires on CREATE OR REPLACE too, so
-- replacing a function silently resets who may call it.
--
-- `authenticated, service_role` and NOT `anon`, which is what the ACL
-- on the deployed schema actually says rather than what the implicit
-- PUBLIC grant at creation would suggest: `0023` swept every function
-- in `app` and `public`, stripped PUBLIC, and granted those two. A
-- stranger has never been able to call the membership guard, and
-- `statutory.sql`'s allowlist of what `anon` may execute is what keeps
-- it that way -- it fails the build on a SECURITY DEFINER function that
-- arrives reachable by nobody in particular, which is exactly what an
-- `anon` in these three lines would have been.
grant execute on function app.is_org_member(uuid)
  to authenticated, service_role;
grant execute on function app.org_role(uuid)
  to authenticated, service_role;
grant execute on function public.my_organizations()
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Writing one down
-- ---------------------------------------------------------------------
create or replace function app.record_closure(
  p_kind text, p_subject uuid, p_org uuid, p_label text,
  p_detail jsonb, p_reason text, p_via text, p_by uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  -- An open closure for something that is being closed now means it came
  -- back without going through the console, and there is exactly one way
  -- that happens: `0532` and `0539` gave thirteen posting helpers the job
  -- of REVIVING a retired ledger account rather than raising on its
  -- unique code or quietly posting to it while retired. A company
  -- retires 2145, the next withholding posting brings it back, and the
  -- closure written when it was retired is describing an account that is
  -- alive.
  --
  -- Closed out rather than raised on. Raising would refuse the second
  -- retirement of an account that has been revived, which is a normal
  -- thing to do; and leaving the row open would have the console
  -- offering to restore something already restored. Every caller has
  -- checked that the subject is not currently closed before reaching
  -- here, so this branch can only be the revived case.
  update public.account_closures
     set restored_at = now(),
         restore_note = 'Reopened by the ledger rather than by the '
                        'console. Superseded by the closure that follows.'
   where subject_kind = p_kind and subject_id = p_subject
     and restored_at is null;

  insert into public.account_closures
    (subject_kind, subject_id, org_id, label, detail, reason, closed_via,
     closed_by)
  values
    (p_kind, p_subject, p_org, coalesce(nullif(btrim(p_label), ''), '(unnamed)'),
     coalesce(p_detail, '{}'::jsonb), nullif(btrim(p_reason), ''), p_via, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Closing a company
--
-- Everything in it stays exactly where it is. What changes is that
-- `is_org_member` stops saying yes, and every policy in the schema is
-- built on that -- so the tenant goes dark in one step rather than in
-- four hundred.
-- ---------------------------------------------------------------------
create or replace function app.close_organization_internal(
  p_org_id uuid, p_reason text, p_via text, p_by uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org public.organizations;
  v_id  uuid;
begin
  select * into v_org from public.organizations o where o.id = p_org_id;
  if v_org.id is null then
    raise exception 'No such company.' using errcode = '22023';
  end if;
  if v_org.deleted_at is not null then
    raise exception 'That company is already closed.' using errcode = '23505';
  end if;

  v_id := app.record_closure(
    'organization', v_org.id, v_org.id, v_org.name,
    jsonb_build_object(
      'slug', v_org.slug,
      'status', v_org.status,
      'entity_type', v_org.entity_type,
      'registration_no', v_org.registration_no,
      'members', (select count(*) from public.org_members m
                   where m.org_id = v_org.id)),
    p_reason, p_via, p_by);

  update public.organizations
     set deleted_at = now(), status = 'archived', updated_at = now()
   where id = v_org.id;

  return v_id;
end $$;

create or replace function public.close_organization(
  p_org_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  -- Asked before anything is written: once `deleted_at` is set this
  -- same question answers false, so a second attempt would be refused
  -- by the guard rather than by the "already closed" sentence.
  if not app.has_org_role(p_org_id, array['owner']::app.member_role[]) then
    raise exception
      'Only an owner of this company may close it.' using errcode = '42501';
  end if;

  v_id := app.close_organization_internal(
    p_org_id, p_reason, 'self_service', auth.uid());

  return jsonb_build_object('closed', true, 'closure_id', v_id);
end $$;

revoke all on function public.close_organization(uuid, text) from public, anon;
grant execute on function public.close_organization(uuid, text) to authenticated;

comment on function public.close_organization(uuid, text) is
  'Closes a company. Nothing is deleted: the books stay exactly where '
  'they are and stop being visible to anybody but the platform '
  'console, which is also the only way back. Owner only. 0619.';

-- ---------------------------------------------------------------------
-- What stands in the way
--
-- 0158's list, with one clause added: a company that has already been
-- closed needs nobody to administer it, so it is not a reason to refuse
-- a login. Without the clause, somebody whose only company was closed
-- last month could never close their own account, and the sentence they
-- would be given names a company the product no longer shows them.
-- ---------------------------------------------------------------------
create or replace function public.my_account_deletion_blockers()
returns table (organization text, reason text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.name,
         'You are the only owner. Make somebody else an owner first, or '
         'the company is left with nobody who can administer it.'
    from public.org_members m
    join public.organizations o on o.id = m.org_id
   where m.user_id = auth.uid() and m.role = 'owner'
     and o.deleted_at is null
     and (select count(*) from public.org_members x
           where x.org_id = m.org_id and x.role = 'owner') = 1
   order by o.name;
$$;

revoke all on function public.my_account_deletion_blockers() from public, anon;
grant execute on function public.my_account_deletion_blockers()
  to authenticated;

-- ---------------------------------------------------------------------
-- Closing a login
-- ---------------------------------------------------------------------
create or replace function app.close_user_internal(
  p_user uuid, p_reason text, p_via text, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p       public.profiles;
  v_auth    text;
  v_tag     text;
  v_members jsonb;
  v_tokens  integer;
  v_id      uuid;
begin
  select * into v_p from public.profiles p where p.id = p_user;
  if v_p.id is null then
    raise exception 'No such account.' using errcode = '22023';
  end if;
  if v_p.deleted_at is not null then
    raise exception 'That account is already closed.' using errcode = '23505';
  end if;

  select u.email into v_auth from auth.users u where u.id = p_user;

  -- Every membership as it stands, so a restore puts each row back at
  -- the status it actually had rather than at 'active' for all of them.
  select coalesce(jsonb_agg(jsonb_build_object(
           'org_id', m.org_id, 'status', m.status)), '[]'::jsonb)
    into v_members
    from public.org_members m
   where m.user_id = p_user and m.status <> 'suspended';

  delete from public.device_tokens where user_id = p_user;
  get diagnostics v_tokens = row_count;
  delete from public.chat_presence where user_id = p_user;
  delete from public.chat_typing where user_id = p_user;

  -- Unique, non-routable and obviously not a real address. `.invalid`
  -- is reserved by RFC 2606 precisely so it can never resolve, which
  -- matters because auth.users keeps a UNIQUE constraint on email and
  -- the real address has to come off it -- otherwise the address can
  -- never be used to sign up again, which for a closed account is the
  -- wrong answer.
  v_tag := 'closed-' || replace(p_user::text, '-', '') || '@deleted.invalid';

  v_id := app.record_closure(
    'user', p_user, null, coalesce(v_p.full_name, v_auth, '(unnamed)'),
    jsonb_build_object(
      'full_name', v_p.full_name,
      'email', v_p.email::text,
      'phone', v_p.phone,
      'avatar_url', v_p.avatar_url,
      'auth_email', v_auth,
      'memberships', v_members,
      'devices_forgotten', v_tokens),
    p_reason, p_via, p_by);

  -- Membership is suspended rather than removed: every guard in this
  -- schema asks for 'active', so this is already no access everywhere,
  -- and the row survives to say the person was here.
  update public.org_members
     set status = 'suspended', updated_at = now()
   where user_id = p_user and status <> 'suspended';

  -- What the product shows. The real values are in the closure above.
  update public.profiles
     set full_name = 'Closed account',
         email = null,
         phone = null,
         avatar_url = null,
         deleted_at = now(),
         updated_at = now()
   where id = p_user;

  update auth.users
     set email = v_tag,
         phone = null,
         email_change = '',
         phone_change = '',
         raw_user_meta_data = '{}'::jsonb,
         banned_until = 'infinity'::timestamptz,
         updated_at = now()
   where id = p_user;

  delete from auth.sessions where user_id = p_user;
  delete from auth.refresh_tokens where user_id = p_user::text;

  return jsonb_build_object(
    'closed', true,
    'closure_id', v_id,
    'memberships_kept', jsonb_array_length(v_members),
    'devices_forgotten', v_tokens);
end $$;

create or replace function public.close_my_account(
  p_reason text default null,
  p_close_sole_owned boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_user    uuid := auth.uid();
  v_blocked text;
  v_orgs    integer := 0;
  v_org     uuid;
  v_res     jsonb;
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  select string_agg(b.organization, ', ') into v_blocked
    from public.my_account_deletion_blockers() b;

  if v_blocked is not null and not coalesce(p_close_sole_owned, false) then
    raise exception
      'You are the only owner of %. Closing your account would leave the '
      'company with nobody who can administer it. Make somebody else an '
      'owner first, or ask for those companies to be closed with you.',
      v_blocked
      using errcode = '23514';
  end if;

  -- The companies nobody else can hold, closed first and each recorded
  -- as its own closure. Collected before the login goes: afterwards the
  -- membership is suspended and this query finds nothing.
  if v_blocked is not null then
    for v_org in
      -- The same set `my_account_deletion_blockers` reports, written
      -- the same way. Two queries that were meant to agree and did not
      -- would leave a company closed that nothing warned about, or
      -- refuse a closure over a company nothing closed.
      select m.org_id from public.org_members m
        join public.organizations o on o.id = m.org_id
       where m.user_id = v_user and m.role = 'owner'
         and o.deleted_at is null
         and (select count(*) from public.org_members x
               where x.org_id = m.org_id and x.role = 'owner') = 1
    loop
      perform app.close_organization_internal(
        v_org, coalesce(p_reason, 'Closed with the last owner''s account'),
        'self_service', v_user);
      v_orgs := v_orgs + 1;
    end loop;
  end if;

  v_res := app.close_user_internal(v_user, p_reason, 'self_service', v_user);
  return v_res || jsonb_build_object('organizations_closed', v_orgs);
end $$;

revoke all on function public.close_my_account(text, boolean) from public, anon;
grant execute on function public.close_my_account(text, boolean) to authenticated;

comment on function public.close_my_account(text, boolean) is
  'Closes the signed-in login. The identity moves into '
  'account_closures, where only the platform console can read it; the '
  'user row, the audit trail and every membership row stay. Pass '
  'p_close_sole_owned to take companies nobody else owns with it. 0619.';

-- The name 0158 gave it, kept because the app and the tests call it and
-- because what it does has not changed -- only where the identity goes.
create or replace function public.delete_my_account()
returns jsonb
language sql
security definer
set search_path = public, app, pg_temp
as $$
  select public.close_my_account(null, false);
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  '0158''s name for close_my_account(). Kept so callers do not have to '
  'change; the closure it performs is 0619''s, which keeps the record '
  'rather than scrubbing it.';

-- ---------------------------------------------------------------------
-- Closing a ledger account
--
-- 0459 deleted one outright when nothing had ever been posted to it.
-- That was the right answer to the question it was asked -- an account
-- nobody used is clutter -- and it is the wrong answer to this one:
-- "don't permanently delete". So the delete goes and every retirement
-- is now a closure, recorded, with a way back.
-- ---------------------------------------------------------------------
create or replace function public.retire_account(p_id uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a public.accounts;
begin
  select * into v_a from public.accounts a where a.id = p_id;
  if v_a.id is null then
    raise exception 'No such account.' using errcode = '22023';
  end if;
  if not app.can_post(v_a.org_id) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;
  if v_a.deleted_at is not null then
    raise exception 'Account % is already closed.', v_a.code
      using errcode = '23505';
  end if;

  if exists (select 1 from app.posting_account_codes() c
              where c.code = v_a.code) then
    raise exception
      'Account % is one the ledger posts to by number. It can be renamed '
      'but not removed.', v_a.code
      using errcode = '23514';
  end if;

  if exists (select 1 from public.accounts a
              where a.parent_id = p_id and a.deleted_at is null) then
    raise exception
      'Account % still has accounts under it.', v_a.code
      using errcode = '23514';
  end if;

  perform app.record_closure(
    'ledger_account', v_a.id, v_a.org_id, v_a.code || ' ' || v_a.name,
    jsonb_build_object(
      'code', v_a.code,
      'name', v_a.name,
      'account_type', v_a.account_type,
      'account_subtype', v_a.account_subtype,
      'was_active', v_a.is_active,
      'posted_lines', (select count(*) from public.gl_lines l
                        where l.account_id = v_a.id)),
    null, 'self_service', auth.uid());

  update public.accounts
     set is_active = false, deleted_at = now()
   where id = p_id;

  return 'closed';
end $$;

revoke all on function public.retire_account(uuid) from public, anon;
grant execute on function public.retire_account(uuid) to authenticated;

comment on function public.retire_account(uuid) is
  'Closes a ledger account: switched off, hidden from the chart, and '
  'kept. 0619 took out 0459''s outright delete -- nothing in this '
  'product deletes an account any more, and the platform console is '
  'the only way back.';

-- ---------------------------------------------------------------------
-- The console
-- ---------------------------------------------------------------------
create or replace function public.platform_closed_accounts(
  p_kind text default null,
  p_include_restored boolean default false)
returns table (
  id uuid,
  subject_kind text,
  subject_id uuid,
  org_id uuid,
  org_name text,
  label text,
  detail jsonb,
  reason text,
  closed_via text,
  closed_at timestamptz,
  closed_by_name text,
  restored_at timestamptz,
  restored_by_name text,
  restore_note text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  return query
    select c.id, c.subject_kind, c.subject_id, c.org_id,
           o.name, c.label, c.detail, c.reason, c.closed_via, c.closed_at,
           cb.full_name, c.restored_at, rb.full_name, c.restore_note
      from public.account_closures c
      left join public.organizations o on o.id = c.org_id
      left join public.profiles cb on cb.id = c.closed_by
      left join public.profiles rb on rb.id = c.restored_by
     where (p_kind is null or c.subject_kind = p_kind)
       and (coalesce(p_include_restored, false) or c.restored_at is null)
     order by c.closed_at desc;
end $$;

revoke all on function public.platform_closed_accounts(text, boolean)
  from public, anon;
grant execute on function public.platform_closed_accounts(text, boolean)
  to authenticated;

comment on function public.platform_closed_accounts(text, boolean) is
  'Every closed login, company and ledger account, with the identity '
  'the product no longer shows. Platform operators only. 0619.';

create or replace function public.platform_close_account(
  p_kind text, p_subject_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a  public.accounts;
  v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  if p_kind = 'user' then
    if p_subject_id = auth.uid() then
      raise exception
        'Close your own account from Settings rather than from the '
        'console -- closing it here would take the console with it.'
        using errcode = '23514';
    end if;
    return app.close_user_internal(
      p_subject_id, p_reason, 'console', auth.uid());

  elsif p_kind = 'organization' then
    v_id := app.close_organization_internal(
      p_subject_id, p_reason, 'console', auth.uid());
    return jsonb_build_object('closed', true, 'closure_id', v_id);

  elsif p_kind = 'ledger_account' then
    select * into v_a from public.accounts a where a.id = p_subject_id;
    if v_a.id is null then
      raise exception 'No such account.' using errcode = '22023';
    end if;
    if v_a.deleted_at is not null then
      raise exception 'Account % is already closed.', v_a.code
        using errcode = '23505';
    end if;
    v_id := app.record_closure(
      'ledger_account', v_a.id, v_a.org_id, v_a.code || ' ' || v_a.name,
      jsonb_build_object('code', v_a.code, 'name', v_a.name,
                         'was_active', v_a.is_active),
      p_reason, 'console', auth.uid());
    update public.accounts
       set is_active = false, deleted_at = now() where id = v_a.id;
    return jsonb_build_object('closed', true, 'closure_id', v_id);
  end if;

  raise exception 'Unknown kind of account: %', p_kind
    using errcode = '22023';
end $$;

revoke all on function public.platform_close_account(text, uuid, text)
  from public, anon;
grant execute on function public.platform_close_account(text, uuid, text)
  to authenticated;

comment on function public.platform_close_account(text, uuid, text) is
  'Closes a login, a company or a ledger account on the operator''s '
  'side -- the half of 0619 that answers a request made by email '
  'rather than pressed in Settings.';

-- ---------------------------------------------------------------------
-- And the only way back
-- ---------------------------------------------------------------------
create or replace function public.platform_restore_account(
  p_closure_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c public.account_closures;
  v_m jsonb;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  select * into v_c from public.account_closures c where c.id = p_closure_id;
  if v_c.id is null then
    raise exception 'No such closure.' using errcode = '22023';
  end if;
  if v_c.restored_at is not null then
    raise exception 'That was already restored, on %.',
      to_char(v_c.restored_at, 'YYYY-MM-DD') using errcode = '23505';
  end if;

  if v_c.subject_kind = 'user' then
    -- The address may have been taken by somebody else in the meantime,
    -- and auth.users keeps it unique. Said as a sentence rather than
    -- left to a constraint name.
    if exists (select 1 from auth.users u
                where lower(u.email) = lower(v_c.detail ->> 'auth_email')
                  and u.id <> v_c.subject_id) then
      raise exception
        'Somebody else has signed up with % since this account was '
        'closed. It cannot be restored under that address.',
        v_c.detail ->> 'auth_email'
        using errcode = '23505';
    end if;

    update public.profiles
       set full_name = v_c.detail ->> 'full_name',
           email = nullif(v_c.detail ->> 'email', '')::citext,
           phone = v_c.detail ->> 'phone',
           avatar_url = v_c.detail ->> 'avatar_url',
           deleted_at = null,
           updated_at = now()
     where id = v_c.subject_id;

    update auth.users
       set email = v_c.detail ->> 'auth_email',
           banned_until = null,
           updated_at = now()
     where id = v_c.subject_id;

    -- Each membership back at the status it actually had.
    for v_m in
      select * from jsonb_array_elements(
        coalesce(v_c.detail -> 'memberships', '[]'::jsonb))
    loop
      update public.org_members
         set status = (v_m ->> 'status')::app.member_status,
             updated_at = now()
       where user_id = v_c.subject_id
         and org_id = (v_m ->> 'org_id')::uuid;
    end loop;

  elsif v_c.subject_kind = 'organization' then
    update public.organizations
       set deleted_at = null,
           status = coalesce(v_c.detail ->> 'status', 'active'),
           updated_at = now()
     where id = v_c.subject_id;

  elsif v_c.subject_kind = 'ledger_account' then
    update public.accounts
       set deleted_at = null,
           is_active = coalesce((v_c.detail ->> 'was_active')::boolean, true)
     where id = v_c.subject_id;
  end if;

  update public.account_closures
     set restored_at = now(),
         restored_by = auth.uid(),
         restore_note = nullif(btrim(p_note), '')
   where id = v_c.id;

  return jsonb_build_object(
    'restored', true, 'subject_kind', v_c.subject_kind, 'label', v_c.label);
end $$;

revoke all on function public.platform_restore_account(uuid, text)
  from public, anon;
grant execute on function public.platform_restore_account(uuid, text)
  to authenticated;

comment on function public.platform_restore_account(uuid, text) is
  'Brings a closed login, company or ledger account back. The only way '
  'back there is, and it is on the operator''s side by design. 0619.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
--
-- The first two are the ones worth having. Replacing a function that
-- predates 0165 silently revokes PUBLIC from it, and the failure that
-- causes is not visible until a signed-in user reads a table -- which
-- is to say, in production, on every screen at once.
-- ---------------------------------------------------------------------
do $do$
begin
  if not has_function_privilege('authenticated',
       'app.is_org_member(uuid)', 'execute') then
    raise exception
      'app.is_org_member lost its EXECUTE to authenticated -- every RLS '
      'policy in this schema calls it.';
  end if;
  if not has_function_privilege('authenticated',
       'app.org_role(uuid)', 'execute') then
    raise exception 'app.org_role lost its EXECUTE to authenticated.';
  end if;
  if has_function_privilege('anon', 'app.is_org_member(uuid)', 'execute') then
    raise exception
      'app.is_org_member is reachable by anon. 0023 took that away and '
      'statutory.sql''s allowlist fails the build over it.';
  end if;
  if not has_function_privilege('authenticated',
       'public.my_organizations()', 'execute') then
    raise exception 'public.my_organizations lost its EXECUTE -- the org '
      'switcher is the whole of the app''s entry.';
  end if;

  -- The drawer is shut.
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'account_closures') then
    raise exception
      'account_closures has a policy. It is meant to have none: the '
      'console RPCs are SECURITY DEFINER and ask is_platform_admin() '
      'themselves.';
  end if;
  if not (select relrowsecurity from pg_class
           where oid = 'public.account_closures'::regclass) then
    raise exception 'account_closures has row level security off.';
  end if;

  -- And nothing deletes an account any more.
  if pg_get_functiondef(to_regprocedure('public.retire_account(uuid)'))
       ~* 'delete\s+from\s+public\.accounts' then
    raise exception
      'retire_account still deletes. 0619 exists to stop it.';
  end if;
end
$do$;

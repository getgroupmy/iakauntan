-- ---------------------------------------------------------------------
-- 0450  The firm that keeps other people's books
-- ---------------------------------------------------------------------
-- Asked of the schema: can an accounting practice create companies,
-- work on them, and later hand one over as a standalone business?
--
-- Measured, the multi-company half was already there and is good. Any
-- authenticated user may call `create_organization` any number of
-- times; it seeds a chart of accounts, eight tax codes, payment terms,
-- a warehouse, price levels, a pipeline and a fiscal year, and
-- `add_creator_as_owner` makes the caller owner. Every table carries
-- `org_id`, every policy runs through `app.is_org_member`, so a company
-- a firm creates **is already standalone** -- it was never inside the
-- firm's books and there is nothing to disentangle.
--
-- What was missing is the firm.
--
--   * There was no such thing as a practice. A firm was a set of users
--     who happened to be members of many companies: no portfolio, no
--     staff list, no way to give a new joiner the forty clients the
--     rest of the office already has.
--   * `corp_entities` is not this. That is the register of companies
--     you *file for* -- which is why the Amanah demo has client
--     entities and no books for them.
--
-- ### The one design decision that mattered
--
-- Every one of the ~300 org-scoped policies funnels through
-- `app.is_org_member(org_id)`, which reads `org_members`. The tempting
-- move is to widen that function so firm staff pass it everywhere. It
-- would be four lines and it would silently change what every policy in
-- the database means.
--
-- So this does the opposite. **Attaching a company to a firm creates
-- real `org_members` rows** -- one per active member of staff, at a
-- role the client chooses -- and detaching removes exactly those rows.
-- Nothing about RLS changes. The consequences are all good ones:
--
--   * every existing policy keeps working, untouched and unre-tested;
--   * the client's own Team screen shows precisely who at the firm can
--     see their books, by name. Access that a client cannot see is not
--     access anybody should have;
--   * `org_members` has carried an audit trigger since 0055, so a firm
--     gaining or losing access is already in the trail;
--   * revocation is a delete, not a policy change.
--
-- The rows are marked `via_firm_id` so detaching can remove its own and
-- nothing else. A person who was already a member in their own right
-- keeps that membership: the column records *why* the row exists, and
-- the firm may only take away what it gave.
--
-- ### What a firm may not do
--
-- Attaching does not make the firm an owner. `p_role` is refused if it
-- is `owner`, so a practice cannot quietly take possession of a
-- client's company through the door marked "bookkeeping". Ownership
-- moves only through the transfer in 0451, which the owner has to
-- start.
--
-- ### Mutants
--
--   * `attach_company_to_firm` allowed to grant `owner` -- killed by
--     "a firm cannot make itself the owner";
--   * detaching removing every row rather than its own -- killed by
--     "detaching leaves the client's own people alone";
--   * a member of staff joining after the client was attached getting
--     no access -- killed by "a new joiner gets the firm's clients";
--   * the firm guard dropped from `attach_company_to_firm`, so any
--     admin could attach a company to a firm they have nothing to do
--     with -- killed by "a stranger cannot attach a company to a firm".
-- ---------------------------------------------------------------------

create type app.firm_role as enum ('partner', 'manager', 'staff');

-- ---------------------------------------------------------------------
-- The practice
-- ---------------------------------------------------------------------
create table public.firms (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  slug            text not null unique,
  registration_no text,
  email           text,
  phone           text,
  is_active       boolean not null default true,
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.firm_members (
  id                uuid primary key default gen_random_uuid(),
  firm_id           uuid not null references public.firms (id) on delete cascade,
  user_id           uuid references auth.users (id) on delete cascade,
  invited_email     text,
  role              app.firm_role not null default 'staff',
  status            app.member_status not null default 'invited',
  invited_by        uuid references auth.users (id) on delete set null,
  invite_token      text unique,
  invite_expires_at timestamptz,
  joined_at         timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (firm_id, user_id),
  constraint firm_member_has_somebody
    check (user_id is not null or invited_email is not null)
);

create index firm_members_user_idx on public.firm_members (user_id)
  where user_id is not null;

alter table public.organizations
  add column firm_id uuid references public.firms (id) on delete set null;

create index organizations_firm_idx on public.organizations (firm_id)
  where firm_id is not null;

-- Why a membership row exists. Null means the person was invited to
-- this company in their own right, and no firm may take that away.
alter table public.org_members
  add column via_firm_id uuid references public.firms (id) on delete set null;

comment on column public.org_members.via_firm_id is
  'The firm whose attachment created this row. Null means the person '
  'belongs to this company in their own right; detaching a firm never '
  'touches those. See 0450.';

create trigger set_updated_at before update on public.firms
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.firm_members
  for each row execute function app.set_updated_at();

create trigger audit_changes
  after insert or delete or update on public.firms
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- Who is who
-- ---------------------------------------------------------------------
create or replace function app.is_firm_member(p_firm_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.firm_members m
     where m.firm_id = p_firm_id
       and m.user_id = auth.uid()
       and m.status = 'active');
$$;

create or replace function app.can_manage_firm(p_firm_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.firm_members m
     where m.firm_id = p_firm_id
       and m.user_id = auth.uid()
       and m.status = 'active'
       and m.role in ('partner', 'manager'));
$$;

alter table public.firms enable row level security;
alter table public.firm_members enable row level security;

create policy firms_select on public.firms
  for select using (
    app.is_firm_member(id)
    or app.is_platform_admin()
    -- A client may see the firm that keeps its books, and no other.
    or exists (select 1 from public.organizations o
                where o.firm_id = firms.id and app.is_org_member(o.id)));

create policy firms_update on public.firms
  for update using (app.can_manage_firm(id))
  with check (app.can_manage_firm(id));

create policy firm_members_select on public.firm_members
  for select using (
    user_id = auth.uid()
    or app.is_firm_member(firm_id)
    or app.is_platform_admin());

create policy firm_members_write on public.firm_members
  for all using (app.can_manage_firm(firm_id))
  with check (app.can_manage_firm(firm_id));

revoke all on public.firms from public;
revoke all on public.firm_members from public;
grant select, insert, update, delete on public.firms to authenticated;
grant select, insert, update, delete on public.firm_members to authenticated;

-- ---------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------
create or replace function public.create_firm(
  p_name text,
  p_registration_no text default null,
  p_email text default null,
  p_phone text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_base   text;
  v_slug   text;
  v_suffix integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A firm needs a name.' using errcode = '23514';
  end if;

  v_base := trim(both '-' from
    regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'firm'; end if;
  v_slug := v_base;
  while exists (select 1 from public.firms f where f.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.firms (name, slug, registration_no, email, phone,
                            created_by)
  values (btrim(p_name), v_slug, p_registration_no, p_email, p_phone,
          auth.uid())
  returning id into v_id;

  -- The person who starts a practice is a partner in it, or nobody can
  -- do anything with it afterwards.
  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_id, auth.uid(), 'partner', 'active', now());

  return v_id;
end;
$$;

create or replace function public.my_firms()
returns setof public.firms
language sql stable security definer
set search_path = public, pg_temp
as $$
  select f.* from public.firms f
    join public.firm_members m on m.firm_id = f.id
   where m.user_id = auth.uid() and m.status = 'active' and f.is_active
   order by f.name;
$$;

-- ---------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------
create or replace function public.invite_firm_member(
  p_firm_id uuid, p_email text, p_role app.firm_role default 'staff')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id    uuid;
  v_user  uuid;
  v_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if not app.can_manage_firm(p_firm_id) then
    raise exception 'Only a partner or manager may invite'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_email, '')), '') is null then
    raise exception 'An invitation needs an address.' using errcode = '23514';
  end if;

  select u.id into v_user from auth.users u
   where lower(u.email) = lower(btrim(p_email));

  insert into public.firm_members
    (firm_id, user_id, invited_email, role, status, invited_by,
     invite_token, invite_expires_at, joined_at)
  values (p_firm_id, v_user, lower(btrim(p_email)), p_role,
          case when v_user is null then 'invited' else 'active' end,
          auth.uid(), v_token, now() + interval '14 days',
          case when v_user is null then null else now() end)
  on conflict (firm_id, user_id) do update
     set role = excluded.role, status = 'active'
  returning id into v_id;

  -- Somebody who joins the office gets the office's clients. Doing this
  -- here rather than leaving it to be noticed is the whole point of a
  -- portfolio: a new joiner with forty clients to be invited to one at
  -- a time is how people end up sharing a login.
  if v_user is not null then
    perform app.sync_firm_access(p_firm_id);
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The access itself, which is ordinary membership and nothing new
-- ---------------------------------------------------------------------
create or replace function app.sync_firm_access(p_firm_id uuid)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_n integer := 0;
begin
  -- Every active member of staff, on every company the firm keeps, at
  -- the role that company agreed to. `on conflict do nothing` is what
  -- protects a person who is already a member in their own right: their
  -- row stands, `via_firm_id` stays null, and the firm cannot later
  -- take it away.
  insert into public.org_members
    (org_id, user_id, role, status, joined_at, via_firm_id)
  select o.id, m.user_id, coalesce(o.firm_member_role, 'accountant'),
         'active', now(), p_firm_id
    from public.organizations o
    join public.firm_members m on m.firm_id = o.firm_id
   where o.firm_id = p_firm_id
     and o.deleted_at is null
     and m.status = 'active'
     and m.user_id is not null
  on conflict (org_id, user_id) do nothing;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- The role the firm's people get on this company. The client chooses
-- it, and it is never `owner`.
alter table public.organizations
  add column firm_member_role app.member_role not null default 'accountant';

alter table public.organizations
  add constraint firm_role_is_not_owner
  check (firm_member_role <> 'owner');

create or replace function public.attach_company_to_firm(
  p_org_id uuid,
  p_firm_id uuid,
  p_role app.member_role default 'accountant')
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_n integer;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may appoint a firm'
      using errcode = '42501';
  end if;
  -- And the person doing it has to be at the firm. Otherwise an admin
  -- could hand their books to a practice that has never heard of them.
  if not app.is_firm_member(p_firm_id) then
    raise exception
      'You are not a member of that firm, so you cannot appoint it'
      using errcode = '42501';
  end if;
  if p_role = 'owner' then
    raise exception
      'A firm keeps the books; it does not own the company. Transfer '
      'ownership deliberately if that is what is meant.'
      using errcode = '23514';
  end if;

  update public.organizations
     set firm_id = p_firm_id, firm_member_role = p_role
   where id = p_org_id;

  v_n := app.sync_firm_access(p_firm_id);
  return v_n;
end;
$$;

create or replace function public.detach_company_from_firm(p_org_id uuid)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_firm uuid;
  v_n    integer := 0;
begin
  select firm_id into v_firm from public.organizations where id = p_org_id;
  if v_firm is null then
    return 0;
  end if;
  -- Either side may end it: the client, or the practice.
  if not (app.can_admin(p_org_id) or app.can_manage_firm(v_firm)) then
    raise exception 'Only the company or the firm may end the appointment'
      using errcode = '42501';
  end if;

  -- Exactly the rows the attachment created. A person the client
  -- invited themselves keeps their place.
  delete from public.org_members m
   where m.org_id = p_org_id and m.via_firm_id = v_firm;
  get diagnostics v_n = row_count;

  update public.organizations set firm_id = null where id = p_org_id;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- The portfolio
-- ---------------------------------------------------------------------
create or replace function public.firm_portfolio(p_firm_id uuid)
returns table (
  org_id uuid,
  name text,
  entity_type text,
  fiscal_year_end_month smallint,
  is_sst_registered boolean,
  member_role app.member_role,
  people integer,
  unposted_documents integer,
  last_activity timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_firm_member(p_firm_id) then
    raise exception 'Not your firm' using errcode = '42501';
  end if;

  return query
  select o.id, o.name, o.entity_type::text, o.fiscal_year_end_month,
         o.is_sst_registered, o.firm_member_role,
         (select count(*)::integer from public.org_members m
           where m.org_id = o.id and m.status = 'active'),
         (select count(*)::integer from public.sales_documents d
           where d.org_id = o.id and d.status = 'draft'
             and d.deleted_at is null),
         (select max(e.created_at) from public.gl_entries e
           where e.org_id = o.id)
    from public.organizations o
   where o.firm_id = p_firm_id and o.deleted_at is null
   order by o.name;
end;
$$;

revoke all on function public.create_firm(text, text, text, text) from public;
revoke all on function public.my_firms() from public;
revoke all on function public.invite_firm_member(uuid, text, app.firm_role)
  from public;
revoke all on function public.attach_company_to_firm(uuid, uuid, app.member_role)
  from public;
revoke all on function public.detach_company_from_firm(uuid) from public;
revoke all on function public.firm_portfolio(uuid) from public;

grant execute on function public.create_firm(text, text, text, text)
  to authenticated;
grant execute on function public.my_firms() to authenticated;
grant execute on function public.invite_firm_member(uuid, text, app.firm_role)
  to authenticated;
grant execute on function public.attach_company_to_firm(uuid, uuid, app.member_role)
  to authenticated;
grant execute on function public.detach_company_from_firm(uuid) to authenticated;
grant execute on function public.firm_portfolio(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_attach text := pg_get_functiondef(to_regprocedure(
    'public.attach_company_to_firm(uuid, uuid, app.member_role)'));
  v_detach text := pg_get_functiondef(
    to_regprocedure('public.detach_company_from_firm(uuid)'));
  v_member text := pg_get_functiondef(
    to_regprocedure('app.is_org_member(uuid)'));
begin
  -- The decision this migration is built on: RLS is untouched.
  if position('firm' in v_member) > 0 then
    raise exception
      '0450: is_org_member knows about firms, which is what this '
      'migration exists to avoid';
  end if;

  if position('p_role = ''owner''' in v_attach) = 0 then
    raise exception '0450: a firm can be attached as owner';
  end if;

  if position('m.via_firm_id = v_firm' in v_detach) = 0 then
    raise exception
      '0450: detaching does not limit itself to the rows it created';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'firm_role_is_not_owner') then
    raise exception '0450: a company may still record owner as the firm role';
  end if;
end
$do$;

comment on table public.firms is
  'An accounting practice. Attaching a company to one creates ordinary '
  'org_members rows for its staff rather than widening any policy, so '
  'the client can see exactly who has access and take it back. 0450.';

-- =====================================================================
-- iAkauntan :: a group of companies
--
-- Where branches share a registration they are one company (0131).
-- Where they have their own registrations they are separate legal
-- entities, each with its own SSM number, its own TIN, its own books and
-- its own statutory filings — and no amount of software should pretend
-- otherwise. What they share is an owner, and that is what a group is:
-- a name for companies that belong to the same people.
--
-- ---------------------------------------------------------------------
-- What a group deliberately does not do
--
-- It does not merge ledgers. Each company keeps its own, because each
-- files its own return. Consolidated reporting, one customer list across
-- the group, and one company invoicing another are three further pieces
-- of work, each with its own hard part — elimination of inter-company
-- balances, an owner for a shared record, and a matching bill raised on
-- the other side. None of them are here, and none of them are possible
-- without this first.
--
-- ---------------------------------------------------------------------
-- Switching between them already works
--
-- The shell has an organization switcher, and a person who is a member
-- of two companies can already move between them without signing out.
-- The group does not add that; it names the relationship, which is what
-- lets everything above be built on top, and what stops "these two
-- companies are related" living only in somebody's head.
-- =====================================================================

create table public.company_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.organizations
  add column group_id uuid references public.company_groups(id)
    on delete set null;

create index organizations_group_idx on public.organizations (group_id)
  where group_id is not null;

-- ---------------------------------------------------------------------
-- Who may see a group
--
-- Anybody who is a member of a company in it. That is a real widening
-- and worth saying out loud: joining two companies into a group lets a
-- member of one learn the *name* of the group and, through the screens
-- above, that the other company exists. It does not let them read a
-- single row of the other company's books — every other policy in this
-- schema still asks `is_org_member` of that company.
-- ---------------------------------------------------------------------
alter table public.company_groups enable row level security;

create or replace function app.is_group_member(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
    select 1 from public.organizations o
     where o.group_id = p_group_id and app.is_org_member(o.id));
$$;

revoke all on function app.is_group_member(uuid) from public, anon;
grant execute on function app.is_group_member(uuid) to authenticated;

create policy company_groups_select on public.company_groups
  for select to authenticated using (app.is_group_member(id));

-- Creating one is anybody's; it is an empty name until a company is
-- attached to it, and attaching is what needs the permission.
create policy company_groups_insert on public.company_groups
  for insert to authenticated with check (created_by = auth.uid());

create policy company_groups_update on public.company_groups
  for update to authenticated
  using (app.is_group_member(id)) with check (app.is_group_member(id));

grant select, insert, update on public.company_groups to authenticated;

-- ---------------------------------------------------------------------
-- Joining and leaving
--
-- Through a function rather than by updating `organizations.group_id`
-- directly, because the rule is about two things at once: you must
-- administer the company you are moving, and you must already be in the
-- group you are moving it into — otherwise anybody could attach their
-- company to somebody else's group and read its name.
-- ---------------------------------------------------------------------
create or replace function public.join_company_group(
  p_org_id uuid,
  p_group_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can move a company'
      using errcode = '42501';
  end if;

  if p_group_id is not null
     and not exists (select 1 from public.company_groups g where g.id = p_group_id)
  then
    raise exception 'No such group' using errcode = 'P0002';
  end if;

  -- Joining a group that already has companies in it means being able
  -- to see them, so it takes membership of one of them. A group with
  -- nothing in it yet is the one somebody just made.
  if p_group_id is not null
     and exists (select 1 from public.organizations o where o.group_id = p_group_id)
     and not app.is_group_member(p_group_id) then
    raise exception 'You are not a member of that group'
      using errcode = '42501';
  end if;

  update public.organizations set group_id = p_group_id where id = p_org_id;
end; $$;

revoke all on function public.join_company_group(uuid, uuid) from public, anon;
grant execute on function public.join_company_group(uuid, uuid) to authenticated;

-- The companies in a group that the person asking may actually reach.
-- Not every company in the group: somebody may belong to two of five.
create or replace function public.my_group_companies(p_org_id uuid)
returns table (org_id uuid, name text, registration_no text, is_current boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.id, o.name, o.registration_no, o.id = p_org_id
    from public.organizations o
   where app.is_org_member(p_org_id)
     and o.group_id is not null
     and o.group_id = (select group_id from public.organizations
                        where id = p_org_id)
     and app.is_org_member(o.id)
   order by o.name;
$$;

revoke all on function public.my_group_companies(uuid) from public, anon;
grant execute on function public.my_group_companies(uuid) to authenticated;

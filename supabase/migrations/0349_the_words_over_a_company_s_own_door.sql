-- ---------------------------------------------------------------------
-- The login page, written by the company whose door it is.
--
-- `0348` gave the platform a second page of sign-in copy for workspace
-- addresses. That is the right default and the wrong owner: the words
-- over `sinar.iakauntan.com` are Sinar's to write, not ours. An
-- operator writing one sentence for every tenant at once can only say
-- something generic, which is what the platform's `login` row now is.
--
-- So a company that holds `workspace_address` — the module that gave it
-- the address in the first place — can write its own heading and its
-- own lead-in, and what a visitor sees is theirs if they wrote one and
-- the platform's if they did not.
--
-- Carried on `workspace_by_host` rather than in a lookup of its own.
-- That function is already anon-callable, already keyed by the host,
-- already returns the company's name and mark for this exact screen,
-- and already refuses a company whose module has lapsed. A second RPC
-- would be a second round trip on the one page in the product where a
-- round trip is a visible pause, and a second place for the module
-- check to be got wrong.
--
-- `create or replace` cannot change a function's OUT parameters, so it
-- is dropped and rebuilt — and re-granted, because `0165`'s event
-- trigger strips PUBLIC and anon from anything created in `public`.
-- ---------------------------------------------------------------------

create table if not exists public.org_login_pages (
  org_id     uuid primary key
             references public.organizations(id) on delete cascade,
  -- Both nullable, and null means "use the platform's". An emptied box
  -- is stored as null for that reason: clearing a heading asks for the
  -- shipped one back rather than for a blank line above the form.
  title      text,
  body       text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

alter table public.org_login_pages enable row level security;

-- Read is for the company's own people; a visitor at the door reads it
-- through `workspace_by_host`, which is SECURITY DEFINER and does not
-- go through this policy at all.
drop policy if exists org_login_pages_read on public.org_login_pages;
create policy org_login_pages_read on public.org_login_pages
  for select to authenticated
  using (app.is_org_member(org_id));

-- Writes go through the function below, which checks the module as
-- well as the role. No policy for insert or update: a table with a
-- permissive write policy and a guarded function is a table with an
-- unguarded write.
grant select on public.org_login_pages to authenticated;
revoke all on public.org_login_pages from anon;

-- ---------------------------------------------------------------------
-- What a company writes over its own door
--
-- Two guards, and they are different questions. `can_admin` is who may
-- speak for this company; `has_module` is whether this company has a
-- door at all. An owner of a company that never bought the address
-- would otherwise be able to write copy for a page that does not
-- exist — harmless, and the kind of harmless that becomes a support
-- question about why nothing changed.
-- ---------------------------------------------------------------------
create or replace function public.org_save_login_page(
  p_org_id uuid,
  p_title text default null,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or an administrator may write the '
                    'wording on this company''s sign-in page'
      using errcode = '42501';
  end if;

  if not app.has_module(p_org_id, 'workspace_address') then
    raise exception 'This company does not have its own web address, so '
                    'there is no sign-in page of its own to write'
      using errcode = '42501';
  end if;

  insert into public.org_login_pages (org_id) values (p_org_id)
    on conflict (org_id) do nothing;

  update public.org_login_pages p set
    -- Emptied to null, like every other optional line of copy on this
    -- platform: clearing a box asks for the platform's wording back.
    title      = case when p_title is null then p.title
                      else nullif(btrim(p_title), '') end,
    body       = case when p_body is null then p.body
                      else nullif(btrim(p_body), '') end,
    updated_at = now(),
    updated_by = auth.uid()
  where p.org_id = p_org_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The door, now carrying the words the company wrote on it
-- ---------------------------------------------------------------------
drop function if exists public.workspace_by_host(text);

create function public.workspace_by_host(p_host text)
returns table (
  subdomain text,
  name text,
  logo_url text,
  module_code text,
  landing_path text,
  purpose text,
  login_title text,
  login_body text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Only the first label matters: `sinar.iakauntan.com` and
  -- `sinar.staging.iakauntan.com` are the same company's door.
  select s.subdomain,
         o.name,
         o.logo_url,
         s.module_code,
         s.landing_path,
         s.purpose,
         -- Null when the company has written nothing, which is what the
         -- screen reads as "use the platform's `login` page". Left
         -- joined so a company with no row is the same as one with an
         -- empty row rather than a company with no door.
         l.title,
         l.body
    from public.org_subdomains s
    left join public.organizations o on o.id = s.org_id
    left join public.org_login_pages l on l.org_id = s.org_id
   where s.status = 'approved'
     and s.subdomain = app.normalize_host_label(split_part(p_host, '.', 1))
     and case s.purpose
           -- A company still on trial has a door like anybody else. One
           -- that has been suspended or archived does not, and neither
           -- does one that has left: an address outliving the company
           -- it named would be a page with a stranger's mark on it.
           when 'company' then
                coalesce(o.status, 'active') in ('active', 'trial')
                and o.deleted_at is null
                and app.has_module(s.org_id, 'workspace_address')
           -- Ours. Nobody bought it, so there is nothing to have
           -- lapsed.
           when 'admin' then true
           -- Parked, which is the whole point of parked.
           else false
         end;
$$;

-- `0165` strips them; they go back on. `workspace_by_host` needs anon
-- for the reason it has always needed it: the page it draws is the one
-- nobody has signed in to yet.
revoke all on function public.workspace_by_host(text) from public;
grant execute on function public.workspace_by_host(text)
  to anon, authenticated;
revoke all on function public.org_save_login_page(uuid, text, text)
  from public;
grant execute on function public.org_save_login_page(uuid, text, text)
  to authenticated;

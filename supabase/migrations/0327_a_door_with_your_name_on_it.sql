-- A company's own front door: xxx.iakauntan.com.
--
-- Asked for as a module, so it is one. What a company buys is a name in
-- front of the platform's domain and a sign-in page that carries their
-- mark instead of ours — somebody arriving at `sinar.iakauntan.com`
-- sees their employer's name and logo, not a product they have never
-- heard of.
--
-- ## The name is scarce, so it is asked for rather than taken
--
-- There is one `iakauntan.com`, and every subdomain of it is carved out
-- of the same namespace. First come first served would let a company
-- take `support`, `billing`, `lhdn` or `ssm` — names that read as the
-- platform speaking, or as a government agency, to anybody who lands on
-- them. So a company requests a name and a platform operator decides.
-- Nothing is live until somebody has looked at it.
--
-- Two gates, not one:
--
--   * `public.reserved_names` refuses the obvious ones outright, before
--     an operator ever sees the request. It is a table rather than a
--     list in code because the next name worth refusing will be learned
--     rather than predicted, and adding a row should not need a deploy.
--   * an operator approves what survives that.
--
-- ## What the sign-in page is allowed to know
--
-- `public.workspace_by_host` is readable by anybody, signed in or not —
-- it has to be, because it answers the question "whose door is this?"
-- before anybody has signed in. So it returns exactly what a sign-in
-- page needs to look like somebody's own: the company's name, its logo
-- and its colour. No identifier, no contact, no counts, nothing about
-- who works there. A host nobody has reserved gets no row rather than
-- an error, because "this subdomain is not taken" is not a secret and
-- pretending otherwise only breaks the page.
--
-- The DNS and the certificate are not in this repository and cannot be:
-- `*.iakauntan.com` has to resolve to wherever the web app is served
-- from, with a wildcard certificate. Until that is done every row here
-- is correct and no browser can reach it.

-- ---------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('workspace_address', 'Your own web address',
   'Sign in at your name rather than ours - sinar.iakauntan.com, with '
   'your logo and your colours on the page. Requested here and switched '
   'on once we have checked the name is free and fair.',
   false, 29.00, 110, true)
on conflict (code) do update
  set name          = excluded.name,
      description   = excluded.description,
      monthly_price = excluded.monthly_price,
      is_active     = excluded.is_active;

-- ---------------------------------------------------------------------
-- Names nobody may have
-- ---------------------------------------------------------------------
-- Shared with the mailbox module, which carves names out of the same
-- domain and has exactly the same problem: `billing@iakauntan.com` in
-- a stranger's hands is worth more to them than any subdomain.
create table if not exists public.reserved_names (
  name   text primary key,

  -- 'subdomain', 'mailbox', or 'both'. A few are only dangerous in one
  -- place — `www` is meaningless as a mailbox, `postmaster` is required
  -- by RFC 5321 as one and harmless as a subdomain.
  scope  text not null default 'both'
         check (scope in ('subdomain', 'mailbox', 'both')),
  reason text not null,
  added_at timestamptz not null default now()
);

comment on table public.reserved_names is
  'Names refused before a platform operator ever sees the request. A '
  'table rather than a list in code: the next name worth refusing will '
  'be learned rather than predicted.';

insert into public.reserved_names (name, scope, reason) values
  -- The platform speaking as itself.
  ('admin',      'both',      'reads as the platform'),
  ('administrator', 'both',   'reads as the platform'),
  ('support',    'both',      'reads as the platform'),
  ('help',       'both',      'reads as the platform'),
  ('billing',    'both',      'reads as the platform'),
  ('accounts',   'both',      'reads as the platform'),
  ('security',   'both',      'reads as the platform'),
  ('abuse',      'both',      'required of a domain owner'),
  ('postmaster', 'both',      'required by RFC 5321'),
  ('hostmaster', 'both',      'required of a domain owner'),
  ('webmaster',  'both',      'required of a domain owner'),
  ('noreply',    'both',      'reads as the platform'),
  ('no-reply',   'both',      'reads as the platform'),
  ('iakauntan',  'both',      'the platform itself'),
  ('platform',   'both',      'the platform itself'),
  ('sales',      'both',      'reads as the platform'),
  ('info',       'both',      'reads as the platform'),
  ('contact',    'both',      'reads as the platform'),
  ('team',       'both',      'reads as the platform'),
  ('root',       'both',      'reads as the platform'),
  -- Government and statutory bodies. A company on this platform files
  -- with all of these, and a message appearing to come from one of them
  -- is the most valuable address on the domain to somebody dishonest.
  ('lhdn',       'both',      'reads as a government agency'),
  ('hasil',      'both',      'reads as a government agency'),
  ('ssm',        'both',      'reads as a government agency'),
  ('kwsp',       'both',      'reads as a government agency'),
  ('epf',        'both',      'reads as a government agency'),
  ('perkeso',    'both',      'reads as a government agency'),
  ('socso',      'both',      'reads as a government agency'),
  ('myinvois',   'both',      'reads as a government service'),
  ('mbrs',       'both',      'reads as a government service'),
  ('bnm',        'both',      'reads as a government agency'),
  ('customs',    'both',      'reads as a government agency'),
  ('kastam',     'both',      'reads as a government agency'),
  -- Infrastructure. These have to keep meaning what they mean.
  ('www',        'subdomain', 'the platform itself'),
  ('app',        'subdomain', 'the platform itself'),
  ('api',        'subdomain', 'the platform itself'),
  ('mail',       'subdomain', 'the mail service'),
  ('smtp',       'subdomain', 'the mail service'),
  ('imap',       'subdomain', 'the mail service'),
  ('mx',         'subdomain', 'the mail service'),
  ('ns',         'subdomain', 'the name service'),
  ('cdn',        'subdomain', 'the platform itself'),
  ('static',     'subdomain', 'the platform itself'),
  ('assets',     'subdomain', 'the platform itself'),
  ('status',     'subdomain', 'the platform itself'),
  ('docs',       'subdomain', 'the platform itself'),
  ('blog',       'subdomain', 'the platform itself'),
  ('dev',        'subdomain', 'the platform itself'),
  ('staging',    'subdomain', 'the platform itself'),
  ('test',       'subdomain', 'the platform itself'),
  ('demo',       'subdomain', 'the platform itself')
on conflict (name) do nothing;

alter table public.reserved_names enable row level security;

-- Readable by anybody who is signed in, because the screen that asks
-- for a name should be able to say why one was refused before the
-- request is made. Writable by platform staff only.
drop policy if exists reserved_names_read on public.reserved_names;
create policy reserved_names_read on public.reserved_names
  for select to authenticated using (true);

drop policy if exists reserved_names_write on public.reserved_names;
create policy reserved_names_write on public.reserved_names
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- ---------------------------------------------------------------------
-- What a company has asked for, and what it was given
-- ---------------------------------------------------------------------
create table if not exists public.org_subdomains (
  id           uuid primary key default gen_random_uuid(),

  -- One per company. A second address is a second product, and two
  -- doors into one workspace is a support call waiting to happen.
  org_id       uuid not null unique
               references public.organizations (id) on delete cascade,

  -- Stored lower case by the trigger below rather than by asking every
  -- caller to remember. Host names are case insensitive and a unique
  -- index that is not would let `Sinar` and `sinar` both exist.
  subdomain    text not null unique,

  status       text not null default 'requested'
               check (status in ('requested', 'approved', 'refused')),

  requested_by uuid references auth.users (id) on delete set null,
  requested_at timestamptz not null default now(),
  decided_by   uuid references auth.users (id) on delete set null,
  decided_at   timestamptz,

  -- Why an operator said no, shown to the company that asked. A refusal
  -- with no reason is a support ticket.
  note         text,

  constraint org_subdomains_decided
    check ((status = 'requested') = (decided_at is null))
);

create index if not exists org_subdomains_status_idx
  on public.org_subdomains (status);

comment on table public.org_subdomains is
  'One requested or granted xxx.iakauntan.com per company. Only an '
  'approved row is a door; the rest are paperwork.';

-- ---------------------------------------------------------------------
-- What makes a name a name
-- ---------------------------------------------------------------------
create or replace function app.normalize_host_label(p_name text)
returns text
language sql
immutable
as $$
  select lower(btrim(coalesce(p_name, '')));
$$;

comment on function app.normalize_host_label(text) is
  'The one place a requested name is folded to its stored form, so the '
  'unique index and the lookup agree about what two names being the '
  'same means.';

create or replace function app.check_host_label(p_name text, p_scope text)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_name   text := app.normalize_host_label(p_name);
  v_reason text;
begin
  -- RFC 1035's shape, which is also the shape of a mailbox local part
  -- narrow enough to never need quoting: letters, digits and hyphens,
  -- starting and ending with a letter or a digit.
  -- Three at least and 63 at most: the middle run is not optional,
  -- which is what stops a two-character name slipping through.
  if v_name !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
    return 'Use 3 to 63 letters, digits and hyphens, starting and '
        || 'ending with a letter or a digit.';
  end if;

  -- Two hyphens in the third and fourth position is how a punycode name
  -- announces itself. A company asking for one is either confused or
  -- spelling a name in a script this check cannot read.
  if substring(v_name from 3 for 2) = '--' then
    return 'That prefix is reserved for internationalised names.';
  end if;

  select reason into v_reason
    from public.reserved_names
   where name = v_name
     and scope in ('both', p_scope);

  if v_reason is not null then
    return 'That name is reserved: ' || v_reason || '.';
  end if;

  return null;
end;
$$;

comment on function app.check_host_label(text, text) is
  'Null when the name may be requested, otherwise the sentence to show '
  'whoever asked for it. Shared by the subdomain and the mailbox, which '
  'carve names out of the same domain.';

-- ---------------------------------------------------------------------
-- Asking, and deciding
-- ---------------------------------------------------------------------
create or replace function public.request_subdomain(
  p_org_id uuid,
  p_subdomain text
)
returns public.org_subdomains
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name    text := app.normalize_host_label(p_subdomain);
  v_problem text;
  v_row     public.org_subdomains;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or administrator can ask for a web address';
  end if;

  if not app.has_module(p_org_id, 'workspace_address') then
    raise exception 'This company does not have the web address module';
  end if;

  v_problem := app.check_host_label(v_name, 'subdomain');
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;

  -- Asking again replaces the standing request, which is what somebody
  -- who has been refused will do. An address already approved is not
  -- quietly swapped: it is a live door, and changing it is an operator's
  -- decision rather than a form submission.
  if exists (
    select 1 from public.org_subdomains
     where org_id = p_org_id and status = 'approved'
  ) then
    raise exception 'This company already has a web address. Ask us to change it.';
  end if;

  insert into public.org_subdomains (org_id, subdomain, requested_by)
  values (p_org_id, v_name, auth.uid())
  on conflict (org_id) do update
    set subdomain    = excluded.subdomain,
        status       = 'requested',
        requested_by = excluded.requested_by,
        requested_at = now(),
        decided_by   = null,
        decided_at   = null,
        note         = null
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'That name is already taken.';
end;
$$;

create or replace function public.decide_subdomain(
  p_id uuid,
  p_approve boolean,
  p_note text default null
)
returns public.org_subdomains
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.org_subdomains;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can decide a web address';
  end if;

  update public.org_subdomains
     set status     = case when p_approve then 'approved' else 'refused' end,
         decided_by = auth.uid(),
         decided_at = now(),
         note       = p_note
   where id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'No such request';
  end if;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Whose door is this?
-- ---------------------------------------------------------------------
create or replace function public.workspace_by_host(p_host text)
returns table (
  subdomain text,
  name      text,
  logo_url  text
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
         o.logo_url
    from public.org_subdomains s
    join public.organizations o on o.id = s.org_id
   where s.status = 'approved'
     and s.subdomain = app.normalize_host_label(split_part(p_host, '.', 1))
     -- A company still on trial has a door like anybody else. One that
     -- has been suspended or archived does not, and neither does one
     -- that has left: an address outliving the company it named would
     -- be a page with a stranger's mark on it.
     and coalesce(o.status, 'active') in ('active', 'trial')
     and o.deleted_at is null
     and app.has_module(s.org_id, 'workspace_address');
$$;

comment on function public.workspace_by_host(text) is
  'What a sign-in page may know before anybody has signed in: whose '
  'door this is and what their mark looks like. Nothing else - no '
  'identifier, no contact, nothing about who works there.';

-- ---------------------------------------------------------------------
-- Who may see what
-- ---------------------------------------------------------------------
alter table public.org_subdomains enable row level security;

drop policy if exists org_subdomains_read on public.org_subdomains;
create policy org_subdomains_read on public.org_subdomains
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());

-- Writes go through the two functions above and nowhere else. Both
-- re-check rights of their own, and neither is reachable by a client
-- that has not been granted it.
drop policy if exists org_subdomains_write on public.org_subdomains;
create policy org_subdomains_write on public.org_subdomains
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
-- `0165`'s event trigger strips grants from anything recreated in
-- `public` or `app`, so every function above is re-granted here.
revoke all on function public.request_subdomain(uuid, text) from public;
revoke all on function public.decide_subdomain(uuid, boolean, text) from public;
revoke all on function public.workspace_by_host(text) from public;
revoke all on function app.check_host_label(text, text) from public;
revoke all on function app.normalize_host_label(text) from public;

grant execute on function public.request_subdomain(uuid, text) to authenticated;
grant execute on function public.decide_subdomain(uuid, boolean, text) to authenticated;
grant execute on function app.check_host_label(text, text) to authenticated;
grant execute on function app.normalize_host_label(text) to authenticated;

-- The one thing here an anonymous visitor may call, because the sign-in
-- page has to draw before anybody has signed in.
grant execute on function public.workspace_by_host(text) to anon, authenticated;

-- Explicitly, rather than relying on the schema's default privileges:
-- an anonymous browser calls exactly one thing here, and reading the
-- table of who has asked for what is not it. RLS refuses it anyway;
-- this makes the refusal true at both layers.
revoke all on public.org_subdomains from anon;
revoke all on public.reserved_names from anon;

grant select on public.reserved_names to authenticated;
grant select on public.org_subdomains to authenticated;
grant insert, update, delete on public.org_subdomains to authenticated;
grant insert, update, delete on public.reserved_names to authenticated;

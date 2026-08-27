-- ---------------------------------------------------------------------
-- 0342 — a name held, and a name pointed at one thing
--
-- `Names on our domain` could do one thing: wait. A company asked for a
-- subdomain, an operator approved or refused it, and that was the whole
-- surface. Two things it could not do:
--
--   * **hold a name.** `shop`, `app`, `api`, `status` — the names an
--     operator wants kept out of the pool before anybody asks for them.
--     There was no way to say so, and the only list of such names lives
--     in a `Set` inside the Cloudflare worker, which is not somewhere
--     an operator can reach.
--   * **point a name at one part of the product.** A shop with a
--     counter tablet wants that tablet to open the till and nothing
--     else. The address was always a door into the whole app.
--
-- ## A held name has no company
--
-- `org_id` becomes nullable. That is the whole of holding a name: a row
-- with a name, no company, and `approved` on it. Nobody else can take
-- it — the unique index sees to that — and a visitor gets `0331`'s
-- "there is nothing at this address" page, because `workspace_by_host`
-- joins `organizations` and a held name joins to nothing.
--
-- The unique constraint on `org_id` stays. Postgres counts NULLs as
-- distinct, so any number of names can be held while a company still
-- has at most one — which is the rule that was already there and that
-- nobody has asked to change.
--
-- ## A pointed name is a restriction, not a shortcut
--
-- `module_code` and `landing_path` say what an address is *for*.
-- Signing in through it reaches that module, or that one screen inside
-- it, and nothing else — it is not a nicer starting point, it is the
-- extent of what that address opens. A counter tablet on
-- `till.iakauntan.com` cannot wander into payroll.
--
-- `landing_path` without `module_code` is refused: a path with no
-- module is a restriction with nothing to check entitlement against,
-- and the app would have no honest answer to "may this company use it".
--
-- What happens when the company does not hold the module is the app's
-- to say, and it says it in words rather than by failing: `0343`'s
-- screen tells them the module is not part of their subscription. The
-- database's job is only to carry which module was chosen, which is why
-- there is no join to `org_modules` here — an entitlement that lapses
-- must not silently blank an operator's setting.
-- ---------------------------------------------------------------------

alter table public.org_subdomains
  alter column org_id drop not null;

alter table public.org_subdomains
  add column if not exists module_code  text
    references public.platform_modules(code) on delete set null,
  add column if not exists landing_path text;

alter table public.org_subdomains
  drop constraint if exists org_subdomains_path_needs_module;
alter table public.org_subdomains
  add constraint org_subdomains_path_needs_module
    check (landing_path is null or module_code is not null);

comment on column public.org_subdomains.org_id is
  'The company whose door this is. Null means the name is held: nobody '
  'can take it and nothing answers on it yet.';
comment on column public.org_subdomains.module_code is
  'Confines this address to one module. Null means the whole app.';
comment on column public.org_subdomains.landing_path is
  'One screen inside that module, rather than the module''s own front '
  'door. Requires module_code.';

-- ---------------------------------------------------------------------
-- What a browser gets, with the restriction on it
--
-- Two more columns and nothing else changed. The inner join to
-- `organizations` is what makes a held name answer with nothing, which
-- is the behaviour the "nothing at this address" page was written for.
-- ---------------------------------------------------------------------
-- Dropped rather than replaced: the row type changes, and Postgres
-- refuses to redefine OUT parameters in place. The anon grant goes back
-- on below — `statutory.sql` asserts it is there, because a company's
-- own door that has stopped opening is found by their staff.
drop function if exists public.workspace_by_host(text);

create function public.workspace_by_host(p_host text)
returns table (subdomain text, name text, logo_url text,
               module_code text, landing_path text)
language sql
stable
security definer
set search_path = public, pg_temp as $$
  -- Only the first label matters: `sinar.iakauntan.com` and
  -- `sinar.staging.iakauntan.com` are the same company's door.
  select s.subdomain,
         o.name,
         o.logo_url,
         s.module_code,
         s.landing_path
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

revoke all on function public.workspace_by_host(text) from public;
grant execute on function public.workspace_by_host(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- The list an operator reads
--
-- `left join` rather than `join`, which is the whole of what held names
-- cost here: an inner join would list every name except the ones with
-- nobody behind them, and those are exactly the ones somebody opens
-- this screen to find.
-- ---------------------------------------------------------------------
-- Same reason: two more columns is a different row type.
drop function if exists public.platform_reservations();

create function public.platform_reservations()
returns table (kind text, id uuid, org_id uuid, org_name text, name text,
               status text, requested_at timestamptz, decided_at timestamptz,
               note text, module_code text, landing_path text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can see who holds which name'
      using errcode = '42501';
  end if;

  return query
    select 'subdomain'::text, s.id, s.org_id, o.name, s.subdomain,
           s.status, s.requested_at, s.decided_at, s.note,
           s.module_code, s.landing_path
      from public.org_subdomains s
      left join public.organizations o on o.id = s.org_id
    union all
    select 'mailbox'::text, m.id, m.org_id, o.name, m.local_part,
           m.status, m.requested_at, m.decided_at, m.note,
           null::text, null::text
      from public.org_mailboxes m
      left join public.organizations o on o.id = m.org_id
    order by 6, 8 desc nulls last, 7;
end;
$$;

revoke all on function public.platform_reservations() from public;
grant execute on function public.platform_reservations() to authenticated;

-- ---------------------------------------------------------------------
-- Holding a name
--
-- Approved on creation, because an operator reserving a name is the
-- decision — there is nobody to approve it after them. `decided_at` is
-- stamped for the same reason, and because `org_subdomains_decided`
-- requires it of anything that is not `requested`.
-- ---------------------------------------------------------------------
create or replace function public.platform_reserve_subdomain(
  p_name text,
  p_org_id uuid default null,
  p_module_code text default null,
  p_landing_path text default null,
  p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_name   text;
  v_error  text;
  v_module text := nullif(btrim(p_module_code), '');
  v_path   text := nullif(btrim(p_landing_path), '');
  v_id     uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can hold a name on our domain'
      using errcode = '42501';
  end if;

  v_name := app.normalize_host_label(p_name);
  v_error := app.check_host_label(v_name, 'subdomain');
  if v_error is not null then
    raise exception '%', v_error using errcode = '22023';
  end if;

  if exists (select 1 from public.org_subdomains s
              where s.subdomain = v_name) then
    raise exception 'The name % is already taken', v_name
      using errcode = '23505';
  end if;

  if p_org_id is not null
     and not exists (select 1 from public.organizations o
                      where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'There is no such company to give it to'
      using errcode = '23503';
  end if;

  if v_module is not null
     and not exists (select 1 from public.platform_modules m
                      where m.code = v_module) then
    raise exception 'There is no module called %', v_module
      using errcode = '23503';
  end if;

  if v_path is not null and v_module is null then
    raise exception 'A screen has to belong to a module. Choose the module '
                    'first, or leave the screen empty for the whole of it'
      using errcode = '22023';
  end if;

  insert into public.org_subdomains
    (org_id, subdomain, status, requested_by, decided_by, decided_at,
     note, module_code, landing_path)
  values (p_org_id, v_name, 'approved', auth.uid(), auth.uid(), now(),
          nullif(btrim(p_note), ''), v_module, v_path)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.platform_reserve_subdomain(
  text, uuid, text, text, text) from public;
grant execute on function public.platform_reserve_subdomain(
  text, uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Moving one, and pointing it
--
-- `0332`'s body with three more things it can change. The two new ones
-- are clearable, and an empty string is how: `coalesce` cannot express
-- "take this off" and a name pointed at a module the operator has
-- changed their mind about has to be un-pointable without deleting it.
--
-- `p_release` does the same job for the company, because a uuid has no
-- empty form — it is the difference between "leave the company alone"
-- and "let go of it and hold the name".
-- ---------------------------------------------------------------------
-- Dropped by its old signature rather than left beside the new one:
-- three more defaulted arguments would make an overload, and a call
-- with four arguments would then be ambiguous rather than wrong.
drop function if exists public.platform_update_reservation(
  text, uuid, uuid, text);

create function public.platform_update_reservation(
  p_kind text,
  p_id uuid,
  p_org_id uuid default null,
  p_name text default null,
  p_module_code text default null,
  p_landing_path text default null,
  p_release boolean default false)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_name   text;
  v_error  text;
  v_module text := nullif(btrim(p_module_code), '');
  v_path   text := nullif(btrim(p_landing_path), '');
  v_found  boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can move a name between companies'
      using errcode = '42501';
  end if;

  if p_kind not in ('subdomain', 'mailbox') then
    raise exception 'A reservation is a subdomain or a mailbox. Got %', p_kind
      using errcode = '22023';
  end if;

  -- A company that does not exist would otherwise be caught by the
  -- foreign key, with a message nobody outside a database reads.
  if p_org_id is not null
     and not exists (select 1 from public.organizations o
                      where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'There is no such company to give it to'
      using errcode = '23503';
  end if;

  if v_module is not null
     and not exists (select 1 from public.platform_modules m
                      where m.code = v_module) then
    raise exception 'There is no module called %', v_module
      using errcode = '23503';
  end if;

  if p_name is not null then
    v_name := app.normalize_host_label(p_name);
    v_error := app.check_host_label(v_name, p_kind);
    if v_error is not null then
      raise exception '%', v_error using errcode = '22023';
    end if;
  end if;

  if p_kind = 'subdomain' then
    update public.org_subdomains s
       set org_id    = case when p_release then null
                            else coalesce(p_org_id, s.org_id) end,
           subdomain = coalesce(v_name, s.subdomain),
           module_code = case when p_module_code is null then s.module_code
                              else v_module end,
           -- Follows the module: a screen left pointing into a module
           -- the name no longer serves is a restriction nobody can
           -- reason about. Two ways that happens — the module cleared,
           -- and the module moved without a new screen named — and both
           -- leave the path behind.
           landing_path = case
                            when p_module_code is not null and v_module is null
                              then null
                            when p_module_code is not null
                                 and v_module is distinct from s.module_code
                                 and p_landing_path is null
                              then null
                            when p_landing_path is null then s.landing_path
                            else v_path end
     where s.id = p_id;
  else
    update public.org_mailboxes m
       set org_id     = case when p_release then null
                             else coalesce(p_org_id, m.org_id) end,
           local_part = coalesce(v_name, m.local_part)
     where m.id = p_id;
  end if;

  get diagnostics v_found = row_count;
  if not v_found then
    raise exception 'No such reservation' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.platform_update_reservation(
  text, uuid, uuid, text, text, text, boolean) from public;
grant execute on function public.platform_update_reservation(
  text, uuid, uuid, text, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- What a name on our domain is *for*
--
-- `0342` gave a name two states, and told them apart by whether a
-- company was on it: a company's door, or a name held with nothing
-- behind it. That turned out to be two answers to two different
-- questions wearing one column.
--
-- The questions are:
--
--   1. Is this a company's, or ours?
--   2. If it is ours, is it parked, or is it a door we actually use?
--
-- `org_id is null` answers the first. Nothing answered the second, so
-- every name of ours was parked by definition, and an address the
-- platform wanted to run itself — a counter tablet at `pos`, a kitchen
-- screen at `kds` — had to be given to some company to work at all.
-- That is a real setup being expressed as a fake customer.
--
-- So `purpose`, with three values:
--
--   `company`   — a company's door. A company is required, and this is
--                 what every row before this migration was.
--   `reserved`  — held. Nobody may take the name and nothing answers on
--                 it; a visitor gets `0331`'s page. No company, and no
--                 module either: pointing a parked name somewhere is a
--                 setting nobody can observe.
--   `admin`     — ours, and in use. No company, and it opens: the app,
--                 confined to whatever module or screen was chosen, on
--                 the platform's own brand.
--
-- ## What `admin` does not do
--
-- It is not an authorisation, and the distinction matters because the
-- word invites the other reading. An `admin` address answers to anyone
-- who types it, exactly as `iakauntan.com` does. What arrives is the
-- ordinary sign-in page; who may then read what is decided where it has
-- always been decided — by the session, by RLS, by `app.can_*`. The
-- confinement is which screens draw, not which rows are legible.
--
-- Making it staff-only is not a variation on this migration, it is a
-- different mechanism: `workspace_by_host` is read by `anon` before
-- anybody has signed in, so a check on who is asking has nothing to ask
-- about yet. It would have to live in the router, after sign-in, beside
-- the `isPlatformAdmin` the router already has.
--
-- ## No subscription to check
--
-- A company's door is gated on that company holding `workspace_address`
-- — they bought the right to an address of their own. An `admin`
-- address has no company, so there is nobody to have bought anything,
-- and the gate is skipped rather than failed. The client skips the
-- second gate for the same reason: a platform operator with no company
-- of their own holds no modules at all, so asking whether they are
-- subscribed to `pos` refuses every admin address there could be.
-- ---------------------------------------------------------------------

alter table public.org_subdomains
  add column if not exists purpose text;

-- Every row that exists was made under the old rule, so the old rule is
-- how they are read: a company on it means it is that company's, and
-- nothing on it means it was parked.
update public.org_subdomains
   set purpose = case when org_id is null then 'reserved' else 'company' end
 where purpose is null;

alter table public.org_subdomains
  alter column purpose set default 'company',
  alter column purpose set not null;

alter table public.org_subdomains
  drop constraint if exists org_subdomains_purpose_known;
alter table public.org_subdomains
  add constraint org_subdomains_purpose_known
    check (purpose in ('company', 'reserved', 'admin'));

-- The two halves of the first question, kept from drifting apart. A
-- company on a name we called ours, or a name we called a company's
-- with nobody on it, are both rows nothing downstream could read
-- honestly.
alter table public.org_subdomains
  drop constraint if exists org_subdomains_company_iff_purpose;
alter table public.org_subdomains
  add constraint org_subdomains_company_iff_purpose
    check ((purpose = 'company') = (org_id is not null));

-- A parked name points nowhere. Not a rule for its own sake: nothing
-- answers on a reserved name, so a module on one is a setting whose
-- effect can never be seen, and the first person to read it back would
-- reasonably believe the address worked.
alter table public.org_subdomains
  drop constraint if exists org_subdomains_reserved_points_nowhere;
alter table public.org_subdomains
  add constraint org_subdomains_reserved_points_nowhere
    check (purpose <> 'reserved'
           or (module_code is null and landing_path is null));

comment on column public.org_subdomains.purpose is
  'Whose this name is and whether it is in use: company (a company''s '
  'door, org_id required), reserved (held by us, nothing answers), '
  'admin (ours and in use, opens the app with no company behind it).';

-- ---------------------------------------------------------------------
-- What a browser gets
--
-- Three changes, and the join is the one that carries them. It becomes
-- a `left join` because an `admin` row has no company to join to, and
-- the conditions that used to sit flat in the `where` move into a
-- `case` on `purpose` — a company's door still has to pass all of them,
-- an admin address has none of them to pass, and a reserved name is
-- refused outright so that `0331`'s page still answers for it.
--
-- `purpose` is returned so the client can tell an admin door from a
-- company's. It needs to: the entitlement check it makes is exactly the
-- one that has nothing to check here.
-- ---------------------------------------------------------------------
drop function if exists public.workspace_by_host(text);

create function public.workspace_by_host(p_host text)
returns table (subdomain text, name text, logo_url text,
               module_code text, landing_path text, purpose text)
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
         s.landing_path,
         s.purpose
    from public.org_subdomains s
    left join public.organizations o on o.id = s.org_id
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

-- `0165` strips grants from anything recreated here, and
-- `supabase/tests/statutory.sql` asserts this one is anon-executable by
-- name: the sign-in page has to know whose door it is standing at
-- before anybody has signed in.
revoke all on function public.workspace_by_host(text) from public;
grant execute on function public.workspace_by_host(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- The list an operator reads
-- ---------------------------------------------------------------------
drop function if exists public.platform_reservations();

create function public.platform_reservations()
returns table (kind text, id uuid, org_id uuid, org_name text, name text,
               status text, requested_at timestamptz, decided_at timestamptz,
               note text, module_code text, landing_path text, purpose text)
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
           s.module_code, s.landing_path, s.purpose
      from public.org_subdomains s
      left join public.organizations o on o.id = s.org_id
    union all
    -- A mailbox has no purpose of its own; it is always a company's.
    select 'mailbox'::text, m.id, m.org_id, o.name, m.local_part,
           m.status, m.requested_at, m.decided_at, m.note,
           null::text, null::text, 'company'::text
      from public.org_mailboxes m
      left join public.organizations o on o.id = m.org_id;
end;
$$;

revoke all on function public.platform_reservations() from public;
grant execute on function public.platform_reservations() to authenticated;

-- ---------------------------------------------------------------------
-- Holding one
--
-- `p_purpose` is appended rather than placed where the form asks it,
-- which is first. The tests call these positionally and so may anything
-- else written before today; a new argument on the end is one every
-- existing call still satisfies, and the order of a function's
-- arguments is not the order of a screen's questions.
-- ---------------------------------------------------------------------
drop function if exists public.platform_reserve_subdomain(
  text, uuid, text, text, text);

create function public.platform_reserve_subdomain(
  p_name text,
  p_org_id uuid default null,
  p_module_code text default null,
  p_landing_path text default null,
  p_note text default null,
  p_purpose text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_name    text;
  v_error   text;
  v_module  text := nullif(btrim(p_module_code), '');
  v_path    text := nullif(btrim(p_landing_path), '');
  -- Null means "read it off the company", which is what every caller
  -- written before this migration meant and could not say.
  v_purpose text := coalesce(nullif(btrim(p_purpose), ''),
                             case when p_org_id is null
                                  then 'reserved' else 'company' end);
  v_id      uuid;
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

  if v_purpose not in ('company', 'reserved', 'admin') then
    raise exception 'A name is a company''s, reserved, or ours to use'
      using errcode = '22023';
  end if;

  if v_purpose = 'company' and p_org_id is null then
    raise exception 'Choose the company this address belongs to'
      using errcode = '22023';
  end if;

  if v_purpose <> 'company' and p_org_id is not null then
    raise exception 'A name that is not a company''s cannot have one on it'
      using errcode = '22023';
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

  -- Last of the three, and the order matters. A screen with no module
  -- is wrong whoever the name belongs to, so that one keeps the
  -- sentence it has always had and answers first. This one is about
  -- what the name is for rather than the shape of the pointing, and
  -- only reaches a request that was otherwise coherent.
  --
  -- Refused rather than quietly dropped. An operator who chose a module
  -- and then parked the name has contradicted themselves, and silently
  -- keeping half of it leaves a row nobody would predict.
  if v_purpose = 'reserved' and (v_module is not null or v_path is not null) then
    raise exception 'A reserved name answers to nobody, so it cannot open '
                    'a module. Hold it, or put it to use'
      using errcode = '22023';
  end if;

  insert into public.org_subdomains
    (org_id, subdomain, status, requested_by, decided_by, decided_at,
     note, module_code, landing_path, purpose)
  values (p_org_id, v_name, 'approved', auth.uid(), auth.uid(), now(),
          nullif(btrim(p_note), ''), v_module, v_path, v_purpose)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.platform_reserve_subdomain(
  text, uuid, text, text, text, text) from public;
grant execute on function public.platform_reserve_subdomain(
  text, uuid, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Changing one
--
-- `p_purpose` null leaves it alone, like every other argument here. The
-- interesting part is what changing it drags with it, because `purpose`
-- is not free-standing — two constraints tie it to the company and to
-- the module, and an operator flipping a toggle should not have to know
-- that.
--
--   * Away from `company`, the company goes. That is what the toggle
--     means when somebody moves a name from a customer's to ours, and
--     making them press Release as well would be asking them to say it
--     twice.
--   * `p_release` on its own still means what `0342` made it mean —
--     let go of the company and hold the name — so it now implies
--     `reserved` when no purpose was named. Every call written before
--     today keeps its behaviour.
--   * To `reserved`, the module goes, the same way a screen already
--     follows the module it belonged to. Unless the same call also
--     named a module, which is not old state being tidied up but a
--     contradiction inside one submission, and is refused for the
--     reason the holder refuses it.
-- ---------------------------------------------------------------------
drop function if exists public.platform_update_reservation(
  text, uuid, uuid, text, text, text, boolean);

create function public.platform_update_reservation(
  p_kind text,
  p_id uuid,
  p_org_id uuid default null,
  p_name text default null,
  p_module_code text default null,
  p_landing_path text default null,
  p_release boolean default false,
  p_purpose text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_name    text;
  v_error   text;
  v_module  text := nullif(btrim(p_module_code), '');
  v_path    text := nullif(btrim(p_landing_path), '');
  v_purpose text := nullif(btrim(p_purpose), '');
  v_was     text;
  v_org     uuid;
  v_found   boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can move a name between companies'
      using errcode = '42501';
  end if;

  if p_kind not in ('subdomain', 'mailbox') then
    raise exception 'A reservation is a subdomain or a mailbox. Got %', p_kind
      using errcode = '22023';
  end if;

  if v_purpose is not null and v_purpose not in ('company', 'reserved', 'admin')
  then
    raise exception 'A name is a company''s, reserved, or ours to use'
      using errcode = '22023';
  end if;

  -- A mailbox is always a company's, so there is nothing here to set on
  -- one. Said rather than ignored: silently accepting it would leave a
  -- caller believing a mailbox can be ours.
  if p_kind = 'mailbox' and v_purpose is not null then
    raise exception 'A mailbox is always a company''s'
      using errcode = '22023';
  end if;

  -- Releasing without saying what it becomes is `0342`'s meaning of
  -- release: let go of the company, keep the name.
  if p_kind = 'subdomain' and p_release and v_purpose is null then
    v_purpose := 'reserved';
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

  if v_purpose = 'reserved' and (v_module is not null or v_path is not null) then
    raise exception 'A reserved name answers to nobody, so it cannot open '
                    'a module. Hold it, or put it to use'
      using errcode = '22023';
  end if;

  if p_name is not null then
    v_name := app.normalize_host_label(p_name);
    v_error := app.check_host_label(v_name, p_kind);
    if v_error is not null then
      raise exception '%', v_error using errcode = '22023';
    end if;
  end if;

  if p_kind = 'subdomain' then
    -- Read before writing, so that "is this about to be a company's?"
    -- can be answered from the row plus the arguments rather than from
    -- the arguments alone.
    select s.purpose, s.org_id into v_was, v_org
      from public.org_subdomains s where s.id = p_id;

    if v_was is null then
      raise exception 'No such reservation' using errcode = 'P0002';
    end if;

    if coalesce(v_purpose, v_was) = 'company'
       and coalesce(p_org_id, case when p_release then null else v_org end)
           is null then
      raise exception 'Choose the company this address belongs to'
        using errcode = '22023';
    end if;

    update public.org_subdomains s
       set purpose   = coalesce(v_purpose, s.purpose),
           -- Released, or moved off being a company's at all. Either
           -- way there is nobody on it afterwards.
           org_id    = case when p_release
                              or coalesce(v_purpose, s.purpose) <> 'company'
                            then null
                            else coalesce(p_org_id, s.org_id) end,
           subdomain = coalesce(v_name, s.subdomain),
           module_code = case
                           when coalesce(v_purpose, s.purpose) = 'reserved'
                             then null
                           when p_module_code is null then s.module_code
                           else v_module end,
           -- Follows the module: a screen left pointing into a module
           -- the name no longer serves is a restriction nobody can
           -- reason about. Three ways that happens now — the name
           -- parked, the module cleared, and the module moved without a
           -- new screen named — and all of them leave the path behind.
           landing_path = case
                            when coalesce(v_purpose, s.purpose) = 'reserved'
                              then null
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
  text, uuid, uuid, text, text, text, boolean, text) from public;
grant execute on function public.platform_update_reservation(
  text, uuid, uuid, text, text, text, boolean, text) to authenticated;

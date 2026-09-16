-- =====================================================================
-- iAkauntan :: 0606 which register to ask
--
-- "Check the SSM register" becomes "Entity Search", and asks WHICH
-- register first. SSM registers companies and businesses; MIA
-- registers accountants and audit firms; the Malaysian Bar registers
-- advocates and solicitors. A contact can be any of those and the
-- button only ever knew about one of them.
--
-- The list is a table for the same reason `0605` made the kinds of
-- business one: a platform administrator adding a fourth register
-- should not need a migration and a deploy.
--
-- ---------------------------------------------------------------------
-- Two kinds of register, and the difference is not cosmetic
--
-- `can_search` says whether this application can ASK. It is true for
-- exactly one of the three today, and that is a fact about the
-- registers rather than about how much work has been done:
--
--   * SSM answers. `0589` reaches ssmsearch.com and `0604` added SSM's
--     own CIDP API behind the same seam, so a search returns rows.
--
--   * MIA does not. Its register is a WordPress form behind
--     Cloudflare's managed bot challenge with no API and no CORS
--     allowance, so neither the browser nor an edge function can read
--     it. `0603` says this at length and the conclusion has not
--     changed: working around a bot challenge is not something this
--     product does.
--
--   * The Bar publishes no API either, and its position is different
--     from MIA's in a way worth writing down. The Bar Council's own
--     directory at `legaldirectory.malaysianbar.org.my` is NOT behind
--     a bot challenge — third parties sell scrapers over it at the
--     scale of tens of thousands of rows, which they could not do if
--     it were. So the Bar is technically reachable and MIA is not.
--
--     It is still `false`, and the reason is the one `provider.ts`
--     already argues at length about ssmsearch.com: the only route in
--     is scraping somebody's website, and this repository runs exactly
--     one provider of that kind, deliberately, with its terms-of-
--     service problem written down, while the official route is
--     arranged. Adding a second by default is not a decision a
--     migration should make quietly.
--
--     The clean way in is the Bar Council granting one. Until then the
--     register opens and somebody reads it.
--
-- A register that cannot be searched still belongs on the list. It
-- opens its own site in a tab, which is what somebody would do anyway,
-- and it is how MIA has been verified since `0603`.
-- =====================================================================

create table public.search_registers (
  code text primary key
    check (code ~ '^[a-z][a-z0-9_]{1,40}$'),

  -- What it is called in front of somebody: 'SSM', 'MIA', 'Malaysian
  -- Bar'. Short, because it is a row in a list of choices.
  name text not null,

  -- What it registers, which is the half that tells somebody whether
  -- to pick it. 'Companies and businesses' beats a second line about
  -- the Companies Commission.
  registers text,

  -- Whether this application can ask it. See the header: false is a
  -- fact about the register, not a to-do.
  can_search boolean not null default false,

  -- Where a person goes when it cannot be searched from here. Required
  -- in that case and checked below, because a register that can
  -- neither be searched nor opened is a choice that does nothing.
  url text,

  sort_order integer not null default 100,
  is_active boolean not null default true,

  -- The three this shipped with. They may be renamed, reordered and
  -- switched off but not deleted: the code is what a recorded lookup
  -- will name, and `0607` is about to start recording them.
  is_builtin boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,

  constraint search_registers_reachable check (
    can_search or nullif(btrim(coalesce(url, '')), '') is not null)
);

comment on table public.search_registers is
  'The registers Entity Search offers. `can_search` says whether this '
  'application can ask the register directly; where it cannot, `url` '
  'is where a person goes instead. Read by anybody signed in (it is a '
  'list of choices); written only by a platform administrator.';

create index search_registers_order_idx
  on public.search_registers (sort_order, code) where is_active;

create trigger set_updated_at before update on public.search_registers
  for each row execute function app.set_updated_at();

insert into public.search_registers
  (code, name, registers, can_search, url, sort_order, is_builtin)
values
  ('ssm', 'SSM', 'Companies and businesses', true,
   'https://www.ssm-einfo.my/', 10, true),
  ('mia', 'MIA', 'Accountants and audit firms', false,
   'https://mia.org.my/members-firm-search/', 20, true),
  -- The DIRECTORY, not the Bar's homepage. Somebody who picks this is
  -- looking for an advocate, and the homepage would leave them to
  -- navigate there themselves.
  ('bar', 'Malaysian Bar', 'Advocates and solicitors', false,
   'https://legaldirectory.malaysianbar.org.my/', 30, true)
on conflict (code) do nothing;

alter table public.search_registers enable row level security;

create policy search_registers_read on public.search_registers
  for select to authenticated using (true);

grant select on public.search_registers to authenticated;

-- On the platform's own live channel, for the reason `0605` put
-- `entity_types` there: an administrator adding a register is doing it
-- for somebody who is looking at the button now.
do $do$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'search_registers'
  ) then
    alter publication supabase_realtime add table public.search_registers;
  end if;
end $do$;

-- ---------------------------------------------------------------------
-- Writing one
--
-- Same shape as `platform_save_entity_type`: an absent argument means
-- "leave it alone", so correcting a name cannot switch a register off
-- or quietly claim it can be searched.
-- ---------------------------------------------------------------------
create or replace function public.platform_save_search_register(
  p_code text,
  p_name text,
  p_registers text default null,
  p_can_search boolean default null,
  p_url text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_code text;
  v_exists boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'The registers are the whole platform''s list and may '
                    'only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  v_code := lower(btrim(coalesce(p_code, '')));
  if v_code = '' then
    raise exception 'A register needs a code' using errcode = '23514';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A register needs a name' using errcode = '23514';
  end if;

  select true into v_exists
    from public.search_registers where code = v_code;

  if v_exists is null then
    if v_code !~ '^[a-z][a-z0-9_]{1,40}$' then
      raise exception 'A code is lower-case letters, digits and '
                      'underscores, starting with a letter — for example '
                      'bursa'
        using errcode = '23514';
    end if;
    -- The check constraint refuses this too. Said here in words
    -- because a register that can neither be asked nor opened is a
    -- choice that does nothing, and a constraint name does not explain
    -- that.
    if not coalesce(p_can_search, false)
       and nullif(btrim(coalesce(p_url, '')), '') is null then
      raise exception 'A register this application cannot search needs an '
                      'address, so somebody can go and look'
        using errcode = '23514';
    end if;
    insert into public.search_registers
      (code, name, registers, can_search, url, sort_order, is_active,
       is_builtin, updated_by)
    values
      (v_code, btrim(p_name), nullif(btrim(p_registers), ''),
       coalesce(p_can_search, false),
       nullif(btrim(p_url), ''),
       coalesce(p_sort_order, 100),
       coalesce(p_is_active, true),
       false, auth.uid());
    return v_code;
  end if;

  update public.search_registers set
    name       = coalesce(nullif(btrim(p_name), ''), name),
    registers  = coalesce(nullif(btrim(p_registers), ''), registers),
    can_search = coalesce(p_can_search, can_search),
    url        = coalesce(nullif(btrim(p_url), ''), url),
    sort_order = coalesce(p_sort_order, sort_order),
    is_active  = coalesce(p_is_active, is_active),
    updated_by = auth.uid()
   where code = v_code;

  return v_code;
end;
$function$;

comment on function public.platform_save_search_register(
  text, text, text, boolean, text, integer, boolean) is
  'Adds or amends a register Entity Search offers. Platform '
  'administrators only. An absent argument means leave it alone. A '
  'register this application cannot search must carry an address, or '
  'choosing it would do nothing.';

grant execute on function public.platform_save_search_register(
  text, text, text, boolean, text, integer, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Removing one
--
-- The three this shipped with stay. Their codes are what a recorded
-- lookup names, and switching one off is what was meant anyway.
-- ---------------------------------------------------------------------
create or replace function public.platform_delete_search_register(p_code text)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_builtin boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'The registers are the whole platform''s list and may '
                    'only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  select is_builtin into v_builtin
    from public.search_registers where code = p_code;
  if v_builtin is null then
    raise exception 'No such register' using errcode = 'P0002';
  end if;
  if v_builtin then
    raise exception 'The registers this shipped with cannot be removed, '
                    'only switched off'
      using errcode = '23503';
  end if;

  delete from public.search_registers where code = p_code;
  return true;
end;
$function$;

comment on function public.platform_delete_search_register(text) is
  'Removes a register that was added here. Refuses the three this '
  'shipped with, which are switched off instead.';

grant execute on function public.platform_delete_search_register(text)
  to authenticated;

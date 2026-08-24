-- The rest of a front page: proof, reasons, and somewhere to press.
--
-- The page has a hero, feature blocks, pricing, store links and a
-- footer. What a Malaysian accounting-software site conventionally also
-- carries, and this one had nowhere to put:
--
--   * a band of numbers — customers, outlets, years;
--   * what customers say, with a name against it;
--   * the logos of businesses that use it;
--   * reasons to choose this one, as a short list rather than a feature
--     grid;
--   * a call to action partway down, for somebody who has read enough.
--
-- ## Three tables ship empty, and that is the whole point
--
-- `landing_stats`, `landing_testimonials` and `landing_logos` have no
-- seed rows and no defaults in the client. A section with nothing in it
-- does not render, exactly as the pricing block already behaves.
--
-- That is deliberate and it is not laziness. A number like "8,000
-- businesses" and a quote from a named person at a named company are
-- claims about the world, and nobody here is in a position to make them
-- on an operator's behalf. Shipping invented ones would put fabricated
-- evidence on a page that asks people for money, which is a different
-- kind of wrong from an empty section. So the operator fills them in
-- with figures they can stand behind, and until they do the page simply
-- does not have that band.
--
-- The feature blocks are different and do ship with copy: those describe
-- what the software does, which is checkable from the source, and
-- `0316`'s defaults were written from it.
--
-- ## Reasons reuse the table they belong in
--
-- `landing_sections` gains `kind`, defaulting to `feature`. A reason is
-- the same shape as a feature — icon, title, body, order — and a second
-- near-identical table would mean two savers, two policies and two
-- console tabs to keep in step. Every existing row is a feature, which
-- is what the default says.

alter table public.landing_sections
  add column if not exists kind text not null default 'feature';

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'landing_sections_kind_ck') then
    alter table public.landing_sections
      add constraint landing_sections_kind_ck
      check (kind in ('feature', 'reason'));
  end if;
end $$;

comment on column public.landing_sections.kind is
  'feature = the grid of what the product does; reason = the short list '
  'of why to choose it. Same shape, two places on the page.';

-- ---------------------------------------------------------------------
-- The numbers
-- ---------------------------------------------------------------------
create table if not exists public.landing_stats (
  id         uuid primary key default gen_random_uuid(),
  sort_order integer not null default 0,
  -- Text, not a number. "240,000", "30", "1,200+" and "RM4b" are all
  -- things a band like this carries, and the moment it is numeric
  -- somebody has to decide how to format it for a page that only ever
  -- displays it.
  value      text not null,
  label      text not null,
  icon       text,
  is_active  boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create index if not exists landing_stats_order_idx
  on public.landing_stats (sort_order, label);

comment on table public.landing_stats is
  'The band of figures on the front page. Ships empty: a claim about how '
  'many customers a platform has is the operator''s to make.';

-- ---------------------------------------------------------------------
-- What customers say
-- ---------------------------------------------------------------------
create table if not exists public.landing_testimonials (
  id         uuid primary key default gen_random_uuid(),
  sort_order integer not null default 0,
  quote      text not null,
  author     text,
  company    text,
  avatar_url text,
  is_active  boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create index if not exists landing_testimonials_order_idx
  on public.landing_testimonials (sort_order, id);

comment on table public.landing_testimonials is
  'Customer quotes. Ships empty, and must: a testimonial nobody said is '
  'a fabricated endorsement, whatever else it is.';

-- ---------------------------------------------------------------------
-- The logo wall
-- ---------------------------------------------------------------------
create table if not exists public.landing_logos (
  id         uuid primary key default gen_random_uuid(),
  sort_order integer not null default 0,
  name       text not null,
  logo_url   text not null,
  is_active  boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create index if not exists landing_logos_order_idx
  on public.landing_logos (sort_order, name);

comment on table public.landing_logos is
  'Customer logos. Ships empty. Putting a company''s mark on a page '
  'says they are a customer, which is theirs to agree to.';

-- ---------------------------------------------------------------------
-- Somewhere to press, partway down
-- ---------------------------------------------------------------------
alter table public.landing_page
  add column if not exists cta_headline text,
  add column if not exists cta_body     text,
  add column if not exists cta_label    text,
  add column if not exists cta_url      text;

comment on column public.landing_page.cta_headline is
  'The band partway down the page. Nothing renders unless a headline is '
  'set, so a platform that does not want one simply leaves it empty.';

-- ---------------------------------------------------------------------
-- Read by anybody, written by nobody
--
-- Same shape as `landing_sections`: the page is public, so `select` is
-- unconditional, and every write goes through a SECURITY DEFINER saver
-- that checks `app.is_platform_admin()`. No insert, update or delete
-- policy exists at all, which is what makes the savers the only door.
--
-- `0299` exists because Supabase grants every new table to anon and
-- authenticated regardless of what the migration says, so the revoke is
-- not optional and not a belt-and-braces gesture.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array
    array['landing_stats', 'landing_testimonials', 'landing_logos']
  loop
    execute format('alter table public.%I enable row level security', v_table);

    execute format(
      'drop policy if exists %I on public.%I', v_table || '_read', v_table);
    execute format(
      'create policy %I on public.%I for select using (true)',
      v_table || '_read', v_table);

    execute format('revoke all on public.%I from anon, authenticated', v_table);
    execute format('grant select on public.%I to anon, authenticated', v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The savers
--
-- Modelled on `0290`'s `platform_save_landing_section`, down to the
-- error message, because they are the same function about a different
-- table and any drift between them is a bug waiting to be found on the
-- one nobody exercised. Each: refuse anybody who is not a platform
-- administrator, insert when `p_id` is null and put the row at the end,
-- otherwise patch only the arguments that were passed.
--
-- `sort_order` defaults to ten past the last, which leaves room to slot
-- a row between two without renumbering the rest.
-- ---------------------------------------------------------------------
create or replace function public.platform_save_landing_stat(
  p_id uuid default null,
  p_value text default null,
  p_label text default null,
  p_icon text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if p_id is null then
    if coalesce(btrim(p_value), '') = ''
       or coalesce(btrim(p_label), '') = '' then
      raise exception 'A figure needs both the number and what it counts'
        using errcode = '23514';
    end if;
    insert into public.landing_stats
      (value, label, icon, sort_order, is_active, updated_by)
    values (btrim(p_value), btrim(p_label), p_icon,
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_stats)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_stats s set
    value      = coalesce(nullif(btrim(p_value), ''), s.value),
    label      = coalesce(nullif(btrim(p_label), ''), s.label),
    icon       = coalesce(p_icon, s.icon),
    sort_order = coalesce(p_sort_order, s.sort_order),
    is_active  = coalesce(p_is_active, s.is_active),
    updated_by = auth.uid(),
    updated_at = now()
   where s.id = p_id
  returning s.id into v_id;

  if v_id is null then
    raise exception 'No such figure' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function public.platform_delete_landing_stat(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  delete from public.landing_stats where id = p_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

create or replace function public.platform_save_landing_testimonial(
  p_id uuid default null,
  p_quote text default null,
  p_author text default null,
  p_company text default null,
  p_avatar_url text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if p_id is null then
    if coalesce(btrim(p_quote), '') = '' then
      raise exception 'A testimonial needs something somebody said'
        using errcode = '23514';
    end if;
    -- An unattributed quote is the shape a fabricated one takes, so the
    -- database asks who said it. It does not — cannot — check that they
    -- did; that is the operator's to stand behind. What it can do is
    -- refuse to store a page element that has nobody's name on it.
    if coalesce(btrim(p_author), '') = '' then
      raise exception 'A quote needs somebody''s name against it'
        using errcode = '23514';
    end if;
    insert into public.landing_testimonials
      (quote, author, company, avatar_url, sort_order, is_active, updated_by)
    values (btrim(p_quote), btrim(p_author), nullif(btrim(p_company), ''),
            nullif(btrim(p_avatar_url), ''),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_testimonials)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_testimonials t set
    quote      = coalesce(nullif(btrim(p_quote), ''), t.quote),
    author     = coalesce(nullif(btrim(p_author), ''), t.author),
    company    = coalesce(p_company, t.company),
    avatar_url = coalesce(p_avatar_url, t.avatar_url),
    sort_order = coalesce(p_sort_order, t.sort_order),
    is_active  = coalesce(p_is_active, t.is_active),
    updated_by = auth.uid(),
    updated_at = now()
   where t.id = p_id
  returning t.id into v_id;

  if v_id is null then
    raise exception 'No such testimonial' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function public.platform_delete_landing_testimonial(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  delete from public.landing_testimonials where id = p_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

create or replace function public.platform_save_landing_logo(
  p_id uuid default null,
  p_name text default null,
  p_logo_url text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if p_id is null then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A logo needs the name of whose it is'
        using errcode = '23514';
    end if;
    -- Same rule as the store links in `0290`: an image the browser
    -- cannot fetch is a broken box on the front page, and a relative
    -- path in a database read by three clients is not an address.
    if coalesce(btrim(p_logo_url), '') = ''
       or btrim(p_logo_url) !~ '^https?://' then
      raise exception 'A logo needs a full https address. Got %', p_logo_url
        using errcode = '22023';
    end if;
    insert into public.landing_logos
      (name, logo_url, sort_order, is_active, updated_by)
    values (btrim(p_name), btrim(p_logo_url),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_logos)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  if nullif(btrim(p_logo_url), '') is not null
     and btrim(p_logo_url) !~ '^https?://' then
    raise exception 'A logo needs a full https address. Got %', p_logo_url
      using errcode = '22023';
  end if;

  update public.landing_logos l set
    name       = coalesce(nullif(btrim(p_name), ''), l.name),
    logo_url   = coalesce(nullif(btrim(p_logo_url), ''), l.logo_url),
    sort_order = coalesce(p_sort_order, l.sort_order),
    is_active  = coalesce(p_is_active, l.is_active),
    updated_by = auth.uid(),
    updated_at = now()
   where l.id = p_id
  returning l.id into v_id;

  if v_id is null then
    raise exception 'No such logo' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function public.platform_delete_landing_logo(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  delete from public.landing_logos where id = p_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

-- ---------------------------------------------------------------------
-- Saving a section now has to say which kind it is
--
-- Dropped and recreated rather than replaced: adding a defaulted
-- parameter would leave the six-argument version in place beside the
-- seven-argument one, and a call naming the original six would then
-- match both and fail with "function is not unique". One signature, and
-- the existing callers keep working because `p_kind` defaults to the
-- same `feature` the column does.
-- ---------------------------------------------------------------------
drop function if exists public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean);

create or replace function public.platform_save_landing_section(
  p_id uuid default null,
  p_title text default null,
  p_body text default null,
  p_icon text default null,
  p_sort_order integer default null,
  p_is_active boolean default null,
  p_kind text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_kind), '') is not null
     and btrim(p_kind) not in ('feature', 'reason') then
    raise exception 'A block is a feature or a reason. Got %', p_kind
      using errcode = '22023';
  end if;

  if p_id is null then
    if coalesce(btrim(p_title), '') = '' then
      raise exception 'A section needs a title' using errcode = '23514';
    end if;
    insert into public.landing_sections
      (title, body, icon, sort_order, is_active, kind, updated_by)
    values (btrim(p_title), p_body, p_icon,
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_sections)),
            coalesce(p_is_active, true),
            coalesce(nullif(btrim(p_kind), ''), 'feature'), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_sections s set
    title      = coalesce(nullif(btrim(p_title), ''), s.title),
    body       = coalesce(p_body, s.body),
    icon       = coalesce(p_icon, s.icon),
    sort_order = coalesce(p_sort_order, s.sort_order),
    is_active  = coalesce(p_is_active, s.is_active),
    kind       = coalesce(nullif(btrim(p_kind), ''), s.kind),
    updated_by = auth.uid()
   where s.id = p_id
  returning s.id into v_id;

  if v_id is null then
    raise exception 'No such section' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- What a stranger gets, now that there is more of it
--
-- `0316`'s function, with `sections` split by kind and three collections
-- added. Every one of them keeps the same gate the sections already had:
-- `exists (select 1 from public.landing_page p where p.is_published)`.
-- A figure typed into the console before the site goes live is a draft,
-- and a draft is not published.
--
-- `brand` stays ungated, which is the whole point of `0316`, and the CTA
-- fields ride in on `page` because that is `to_jsonb(p)` and they are
-- columns on it now.
-- ---------------------------------------------------------------------
create or replace function public.landing_page()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'page', (select to_jsonb(p) - 'updated_by' - 'id'
               from public.landing_page p where p.is_published),
    -- Not gated. See `0316`.
    'brand', coalesce((
      select jsonb_build_object(
               'logo_url',          p.logo_url,
               'logo_dark_url',     p.logo_dark_url,
               'wordmark',          p.wordmark,
               'brand_colour',      p.brand_colour,
               'brand_colour_dark', p.brand_colour_dark,
               'theme_mode',        p.theme_mode,
               'app_icon_url',      p.app_icon_url)
        from public.landing_page p
    ), '{}'::jsonb),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'feature'
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'reasons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'reason'
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'stats', coalesce((
      select jsonb_agg(jsonb_build_object(
               'value', st.value, 'label', st.label, 'icon', st.icon)
               order by st.sort_order, st.label)
        from public.landing_stats st
       where st.is_active
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'testimonials', coalesce((
      select jsonb_agg(jsonb_build_object(
               'quote', t.quote, 'author', t.author,
               'company', t.company, 'avatar_url', t.avatar_url)
               order by t.sort_order, t.id)
        from public.landing_testimonials t
       where t.is_active
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'logos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', l.name, 'logo_url', l.logo_url)
               order by l.sort_order, l.name)
        from public.landing_logos l
       where l.is_active
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'app_links', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store_code', a.store_code, 'label', a.label,
               'url', a.url, 'badge_url', a.badge_url)
               order by a.sort_order, a.store_code)
        from public.landing_app_links a
       where a.is_active
         and exists (select 1 from public.landing_page p where p.is_published)
    ), '[]'::jsonb),
    'modules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', m.code, 'name', m.name,
               'description', m.description,
               'monthly_price', m.monthly_price,
               'is_core', m.is_core)
               order by m.is_core desc, m.sort_order, m.code)
        from public.platform_modules m
       where m.is_active
         and exists (select 1 from public.landing_page p
                      where p.is_published and p.show_pricing)
    ), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------
-- The grants `create or replace` just took away
--
-- `0165` installs an event trigger that strips PUBLIC and anon from
-- every function created in `public` or `app`. `landing_page()` is one
-- of the eight functions an unauthenticated caller may execute, and
-- `statutory.sql` counts them; leaving this out takes the front page
-- away from every visitor who has not signed in.
-- ---------------------------------------------------------------------
revoke all on function public.landing_page() from public;
grant execute on function public.landing_page() to anon, authenticated;

revoke all on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) from public;
grant execute on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) to authenticated;

revoke all on function public.platform_save_landing_stat(
  uuid, text, text, text, integer, boolean) from public;
grant execute on function public.platform_save_landing_stat(
  uuid, text, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_delete_landing_stat(uuid)
  to authenticated;

revoke all on function public.platform_save_landing_testimonial(
  uuid, text, text, text, text, integer, boolean) from public;
grant execute on function public.platform_save_landing_testimonial(
  uuid, text, text, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_delete_landing_testimonial(uuid)
  to authenticated;

revoke all on function public.platform_save_landing_logo(
  uuid, text, text, integer, boolean) from public;
grant execute on function public.platform_save_landing_logo(
  uuid, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_delete_landing_logo(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- The saver learns about the four new columns
--
-- `0315`'s function, unchanged except for the call to action. A patch
-- key it does not name is a key it silently drops, so adding columns
-- without coming back here gives an operator a Save button that reports
-- success and stores nothing — which is the same class of bug `0315`
-- itself was about.
--
-- Blankable, not coalesced. The rest of this function is split between
-- the two: a wordmark cannot be emptied, an optional URL can. These are
-- optional, and clearing the headline is how the band comes off the
-- page, so an empty string has to mean null rather than "no change".
-- ---------------------------------------------------------------------
create or replace function public.platform_save_landing_page(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_row public.landing_page; v_colour text;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if jsonb_typeof(p_patch) <> 'object' then
    raise exception 'A patch has to be an object of the fields that changed'
      using errcode = '22023';
  end if;

  if nullif(btrim(p_patch ->> 'theme_mode'), '') is not null
     and btrim(p_patch ->> 'theme_mode') not in ('system', 'light', 'dark') then
    raise exception 'The default scheme is system, light or dark. Got %',
                    p_patch ->> 'theme_mode'
      using errcode = '22023';
  end if;

  foreach v_colour in array array['brand_colour', 'brand_colour_dark'] loop
    if nullif(btrim(p_patch ->> v_colour), '') is not null
       and btrim(p_patch ->> v_colour) !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'A colour has to be six hex digits after a hash, like '
                      '#0B7A6B. Got % for %', p_patch ->> v_colour, v_colour
        using errcode = '22023';
    end if;
  end loop;

  -- Same rule the store links and the customer logos have: a button
  -- the browser cannot follow is worse than an absent one, because the
  -- visitor presses it and decides the product is broken.
  if nullif(btrim(p_patch ->> 'cta_url'), '') is not null
     and btrim(p_patch ->> 'cta_url') !~ '^https?://' then
    raise exception 'The button needs a full https address. Got %',
                    p_patch ->> 'cta_url'
      using errcode = '22023';
  end if;

  insert into public.landing_page (id) values (true) on conflict (id) do nothing;

  update public.landing_page p set
    logo_url          = case when p_patch ? 'logo_url'
                          then nullif(p_patch ->> 'logo_url', '')
                          else p.logo_url end,
    logo_dark_url     = case when p_patch ? 'logo_dark_url'
                          then nullif(p_patch ->> 'logo_dark_url', '')
                          else p.logo_dark_url end,
    wordmark          = coalesce(nullif(btrim(p_patch ->> 'wordmark'), ''), p.wordmark),
    tagline           = coalesce(p_patch ->> 'tagline', p.tagline),
    brand_colour      = coalesce(nullif(btrim(p_patch ->> 'brand_colour'), ''),
                                 p.brand_colour),
    brand_colour_dark = coalesce(nullif(btrim(p_patch ->> 'brand_colour_dark'), ''),
                                 p.brand_colour_dark),
    app_icon_url      = case when p_patch ? 'app_icon_url'
                             then nullif(p_patch ->> 'app_icon_url', '')
                             else p.app_icon_url end,
    theme_mode        = coalesce(nullif(btrim(p_patch ->> 'theme_mode'), ''),
                                 p.theme_mode),
    hero_headline     = coalesce(nullif(btrim(p_patch ->> 'hero_headline'), ''),
                                 p.hero_headline),
    hero_subhead      = coalesce(p_patch ->> 'hero_subhead', p.hero_subhead),
    hero_image_url    = case when p_patch ? 'hero_image_url'
                          then nullif(p_patch ->> 'hero_image_url', '')
                          else p.hero_image_url end,
    sign_in_label     = coalesce(nullif(btrim(p_patch ->> 'sign_in_label'), ''),
                                 p.sign_in_label),
    register_label    = coalesce(nullif(btrim(p_patch ->> 'register_label'), ''),
                                 p.register_label),
    register_enabled  = coalesce((p_patch ->> 'register_enabled')::boolean,
                                 p.register_enabled),
    show_pricing      = coalesce((p_patch ->> 'show_pricing')::boolean,
                                 p.show_pricing),
    pricing_heading   = coalesce(p_patch ->> 'pricing_heading', p.pricing_heading),
    pricing_note      = coalesce(p_patch ->> 'pricing_note', p.pricing_note),
    company_name      = coalesce(p_patch ->> 'company_name', p.company_name),
    company_reg_no    = coalesce(p_patch ->> 'company_reg_no', p.company_reg_no),
    address           = coalesce(p_patch ->> 'address', p.address),
    support_email     = coalesce(p_patch ->> 'support_email', p.support_email),
    support_phone     = coalesce(p_patch ->> 'support_phone', p.support_phone),
    privacy_url       = coalesce(p_patch ->> 'privacy_url', p.privacy_url),
    terms_url         = coalesce(p_patch ->> 'terms_url', p.terms_url),
    meta_title        = coalesce(p_patch ->> 'meta_title', p.meta_title),
    meta_description  = coalesce(p_patch ->> 'meta_description', p.meta_description),
    -- 0317. Blankable rather than coalesced, because taking the band
    -- off the page is done by clearing the headline, and a coalesce
    -- would quietly put back what was cleared.
    cta_headline      = case when p_patch ? 'cta_headline'
                          then nullif(btrim(p_patch ->> 'cta_headline'), '')
                          else p.cta_headline end,
    cta_body          = case when p_patch ? 'cta_body'
                          then nullif(p_patch ->> 'cta_body', '')
                          else p.cta_body end,
    cta_label         = case when p_patch ? 'cta_label'
                          then nullif(btrim(p_patch ->> 'cta_label'), '')
                          else p.cta_label end,
    cta_url           = case when p_patch ? 'cta_url'
                          then nullif(btrim(p_patch ->> 'cta_url'), '')
                          else p.cta_url end,
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the three new tables go on the wire
--
-- `0302` publishes the platform's own tables so a change made in the
-- console reaches everybody else's browser without a reload. A table
-- listed in `platform_live.dart` and not published here subscribes to
-- nothing and says so nowhere, which is the failure
-- `app/test/platform_live_test.dart` exists to name.
--
-- `replica identity full` for the same reason `0302` gives: a delete
-- carries only the primary key otherwise, Realtime cannot run the
-- policy against it, and the event is dropped rather than delivered —
-- so a testimonial withdrawn would be the one change that never
-- arrived.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array
    array['landing_stats', 'landing_testimonials', 'landing_logos']
  loop
    execute format('alter table public.%I replica identity full', v_table);

    if not exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = v_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end $$;

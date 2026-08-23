-- ---------------------------------------------------------------------
-- A corporate landing page, and somewhere to write it
--
-- Until now the only thing an unauthenticated visitor could be shown was
-- the sign-in form. Somebody arriving at the address on a business card
-- got a password box and no way to tell what they had arrived at, no
-- reason to make an account, and no link to the app on their phone.
--
-- This is the content behind that page. Three tables rather than one,
-- because the parts have different shapes:
--
--   `landing_page`      one row. The brand, the hero, the footer — the
--                       things there is exactly one of.
--   `landing_sections`  ordered blocks of copy. There is no right
--                       number of them, so they are rows.
--   `landing_app_links` the store buttons. "All app stores" is a list
--                       that grows — App Store, Play, AppGallery, and
--                       whatever Malaysia's operators ship next — so it
--                       is a list, not a column per shop.
--
-- ## Who may read it, and who may write it
--
-- It is a public web page, so an unauthenticated caller must be able to
-- read it. That is one new name on the anon allowlist in
-- `supabase/tests/statutory.sql`, which is a deliberate act and is meant
-- to feel like one. What `landing_page()` returns is the marketing copy
-- of a page anybody can already see by visiting the site — no
-- organization, no person, no identifier of either — and it takes no
-- argument, so there is nothing to probe it with.
--
-- The tables themselves stay shut. RLS is on with a select policy for
-- `authenticated` only; the anon path goes through the SECURITY DEFINER
-- function and nothing else. Writing is platform-admin only, through
-- RPCs, for the reason `platform_publish_statutory_schedule` gives about
-- rate tables: this is one shared thing with no org_id, so a write by
-- anybody is a write everybody sees.
--
-- ## Unpublished means unpublished
--
-- `is_published` on the page and `is_active` on every child. A section
-- being drafted must not appear on the live site the moment it is saved,
-- and `landing_page()` filters on both — asserted, because a CMS whose
-- draft is visible to the public is worse than no CMS.
--
-- ## The logo
--
-- A URL, not bytes. The `logos` bucket already exists and is already
-- public, so the console uploads there and stores the address. Keeping
-- the image out of the row also keeps `landing_page()` small enough to
-- be worth calling on every page load.
-- ---------------------------------------------------------------------

create table if not exists public.landing_page (
  id                boolean primary key default true,
  -- One row, and the type is what says so: `boolean primary key` with a
  -- check that it is true admits exactly one value.
  constraint landing_page_singleton check (id),

  -- Brand
  logo_url          text,
  logo_dark_url     text,
  wordmark          text not null default 'iAkauntan',
  tagline           text,
  brand_colour      text,

  -- The hero, which is the only part most visitors read
  hero_headline     text not null default
    'Accounting, CRM, payroll and e-Invoice for Malaysian business',
  hero_subhead      text,
  hero_image_url    text,
  sign_in_label     text not null default 'Sign in',
  register_label    text not null default 'Create an account',
  register_enabled  boolean not null default true,

  -- The foot of the page
  company_name      text,
  company_reg_no    text,
  address           text,
  support_email     text,
  support_phone     text,
  privacy_url       text,
  terms_url         text,

  -- Search engines, and the card that appears when the link is pasted
  meta_title        text,
  meta_description  text,

  is_published      boolean not null default false,
  updated_by        uuid references auth.users (id),
  updated_at        timestamptz not null default now()
);

create table if not exists public.landing_sections (
  id          uuid primary key default gen_random_uuid(),
  sort_order  integer not null default 0,
  icon        text,
  title       text not null,
  body        text,
  is_active   boolean not null default true,
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now()
);
create index if not exists landing_sections_order_idx
  on public.landing_sections (sort_order, title);

create table if not exists public.landing_app_links (
  id          uuid primary key default gen_random_uuid(),
  store_code  text not null,
  label       text not null,
  url         text not null,
  badge_url   text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now(),
  constraint landing_app_links_store_unique unique (store_code),
  -- A store button that goes nowhere is worse than an absent one: the
  -- visitor taps it and decides the product is broken.
  constraint landing_app_links_url_absolute
    check (url ~* '^https?://')
);
create index if not exists landing_app_links_order_idx
  on public.landing_app_links (sort_order, store_code);

alter table public.landing_page       enable row level security;
alter table public.landing_sections   enable row level security;
alter table public.landing_app_links  enable row level security;

-- Signed-in staff may read the tables directly, which is what the
-- console screen does. Anonymous visitors never touch them: they go
-- through `landing_page()`, which reads as the definer. Writing is not
-- granted to anybody — the RPCs below are the only way in.
drop policy if exists landing_page_read on public.landing_page;
create policy landing_page_read on public.landing_page
  for select to authenticated using (true);
drop policy if exists landing_sections_read on public.landing_sections;
create policy landing_sections_read on public.landing_sections
  for select to authenticated using (true);
drop policy if exists landing_app_links_read on public.landing_app_links;
create policy landing_app_links_read on public.landing_app_links
  for select to authenticated using (true);

grant select on public.landing_page, public.landing_sections,
                public.landing_app_links to authenticated;

drop trigger if exists set_updated_at on public.landing_page;
create trigger set_updated_at before update on public.landing_page
  for each row execute function app.set_updated_at();
drop trigger if exists set_updated_at on public.landing_sections;
create trigger set_updated_at before update on public.landing_sections
  for each row execute function app.set_updated_at();
drop trigger if exists set_updated_at on public.landing_app_links;
create trigger set_updated_at before update on public.landing_app_links
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- What a stranger sees
--
-- One call, one object, no arguments. Everything in it is copy somebody
-- chose to publish; there is no identifier of a company or a person
-- anywhere in the return, and nothing to vary to make it return
-- something else.
--
-- An unpublished page comes back as a null `page` rather than as an
-- error, so the site can fall back to the sign-in form without the
-- browser console filling with failures. The sections and links come
-- back empty in that case too, rather than leaking the copy somebody is
-- still drafting.
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
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active
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
    ), '[]'::jsonb));
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function in
-- `public` and `app`, so the grant has to come after the create — and
-- has to be re-issued after any `create or replace` of this function, or
-- the front door quietly stops opening for the people it is for.
revoke all on function public.landing_page() from public;
grant execute on function public.landing_page() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Writing it, from the platform console
--
-- One function per shape rather than a row editor, for the reason 0091
-- gives about rate tables: a page is a document. `p_patch` carries only
-- the fields the form changed, so two people editing different halves do
-- not overwrite each other with stale values from a full-row save.
--
-- Every one of them refuses anybody who is not a platform administrator,
-- with 42501, and says why: `landing_page` has no org_id, so a write by
-- one company would be a write to everybody's front door.
-- ---------------------------------------------------------------------
create or replace function public.platform_save_landing_page(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_row public.landing_page;
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

  insert into public.landing_page (id) values (true) on conflict (id) do nothing;

  update public.landing_page p set
    logo_url         = coalesce(p_patch ->> 'logo_url', p.logo_url),
    logo_dark_url    = coalesce(p_patch ->> 'logo_dark_url', p.logo_dark_url),
    wordmark         = coalesce(nullif(btrim(p_patch ->> 'wordmark'), ''), p.wordmark),
    tagline          = coalesce(p_patch ->> 'tagline', p.tagline),
    brand_colour     = coalesce(p_patch ->> 'brand_colour', p.brand_colour),
    hero_headline    = coalesce(nullif(btrim(p_patch ->> 'hero_headline'), ''),
                                p.hero_headline),
    hero_subhead     = coalesce(p_patch ->> 'hero_subhead', p.hero_subhead),
    hero_image_url   = coalesce(p_patch ->> 'hero_image_url', p.hero_image_url),
    sign_in_label    = coalesce(nullif(btrim(p_patch ->> 'sign_in_label'), ''),
                                p.sign_in_label),
    register_label   = coalesce(nullif(btrim(p_patch ->> 'register_label'), ''),
                                p.register_label),
    register_enabled = coalesce((p_patch ->> 'register_enabled')::boolean,
                                p.register_enabled),
    company_name     = coalesce(p_patch ->> 'company_name', p.company_name),
    company_reg_no   = coalesce(p_patch ->> 'company_reg_no', p.company_reg_no),
    address          = coalesce(p_patch ->> 'address', p.address),
    support_email    = coalesce(p_patch ->> 'support_email', p.support_email),
    support_phone    = coalesce(p_patch ->> 'support_phone', p.support_phone),
    privacy_url      = coalesce(p_patch ->> 'privacy_url', p.privacy_url),
    terms_url        = coalesce(p_patch ->> 'terms_url', p.terms_url),
    meta_title       = coalesce(p_patch ->> 'meta_title', p.meta_title),
    meta_description = coalesce(p_patch ->> 'meta_description', p.meta_description),
    is_published     = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by       = auth.uid()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.platform_save_landing_section(
  p_id uuid default null,
  p_title text default null,
  p_body text default null,
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
    if coalesce(btrim(p_title), '') = '' then
      raise exception 'A section needs a title' using errcode = '23514';
    end if;
    insert into public.landing_sections
      (title, body, icon, sort_order, is_active, updated_by)
    values (btrim(p_title), p_body, p_icon,
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_sections)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_sections s set
    title      = coalesce(nullif(btrim(p_title), ''), s.title),
    body       = coalesce(p_body, s.body),
    icon       = coalesce(p_icon, s.icon),
    sort_order = coalesce(p_sort_order, s.sort_order),
    is_active  = coalesce(p_is_active, s.is_active),
    updated_by = auth.uid()
   where s.id = p_id
  returning s.id into v_id;

  if v_id is null then
    raise exception 'No such section' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function public.platform_delete_landing_section(p_id uuid)
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
  delete from public.landing_sections where id = p_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

create or replace function public.platform_save_landing_app_link(
  p_store_code text,
  p_label text default null,
  p_url text default null,
  p_badge_url text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid; v_code text := lower(btrim(coalesce(p_store_code, '')));
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'A store link needs to say which store' using errcode = '23514';
  end if;

  -- The url check on the table refuses a relative address, but the
  -- message it produces names a constraint. Caught here so somebody
  -- pasting a link into a form is told what is wrong with what they
  -- pasted.
  if p_url is not null and p_url !~* '^https?://' then
    raise exception 'A store link has to be a full https:// address, got %',
      p_url using errcode = '22023';
  end if;

  -- Deliberately not an upsert. `on conflict do update` still has to
  -- offer a row to insert first, and the only url available for that row
  -- when the caller is switching an existing button off is the empty
  -- string — which the table's own check refuses, before the conflict
  -- clause is ever reached. So: update what is there, insert what is
  -- not, and tell a caller creating a new button that it needs somewhere
  -- to point.
  select id into v_id from public.landing_app_links where store_code = v_code;

  if v_id is null then
    if coalesce(btrim(p_url), '') = '' then
      raise exception 'A new % button needs the address it opens', v_code
        using errcode = '23514';
    end if;
    insert into public.landing_app_links
      (store_code, label, url, badge_url, sort_order, is_active, updated_by)
    values (v_code,
            coalesce(nullif(btrim(p_label), ''), initcap(replace(v_code, '_', ' '))),
            p_url, p_badge_url,
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_app_links)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_app_links a set
    label      = coalesce(nullif(btrim(p_label), ''), a.label),
    url        = coalesce(p_url, a.url),
    badge_url  = coalesce(p_badge_url, a.badge_url),
    sort_order = coalesce(p_sort_order, a.sort_order),
    is_active  = coalesce(p_is_active, a.is_active),
    updated_by = auth.uid()
   where a.id = v_id;

  return v_id;
end;
$$;

create or replace function public.platform_delete_landing_app_link(p_store_code text)
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
  delete from public.landing_app_links
   where store_code = lower(btrim(coalesce(p_store_code, '')));
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb) to authenticated;
grant execute on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_delete_landing_section(uuid) to authenticated;
grant execute on function public.platform_save_landing_app_link(
  text, text, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_delete_landing_app_link(text) to authenticated;

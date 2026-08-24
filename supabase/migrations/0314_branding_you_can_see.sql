-- Branding is a thing you can see and change, not a row you edit blind.
--
-- The platform's brand already lives on `landing_page` — `logo_url`,
-- `logo_dark_url`, `wordmark`, `brand_colour`, `brand_colour_dark` — and
-- `app.dart` already feeds the colours into `AppTheme.light` and
-- `AppTheme.dark`, so the whole product is already in whatever colours
-- the console last set. What is missing is not the plumbing. It is two
-- fields and a screen worth looking at.
--
-- Deliberately *not* a new `platform_branding` table. A second home for
-- the brand colour is a second answer to "what colour is this product",
-- and this repository has spent enough migrations removing places where
-- two copies of one fact could disagree.
--
-- ## `theme_mode`
--
-- Which scheme a visitor gets before they have chosen one. `MaterialApp`
-- defaults to `ThemeMode.system`, which is a sensible default and not a
-- decision anybody made — a platform that wants to look the same to
-- everybody has had no way to say so.
--
-- ## `app_icon_url`
--
-- The square source image the favicon and the PWA icons are generated
-- from at build time. It is a URL and not the icons themselves because
-- an icon set is nine files at seven sizes, and generating them from one
-- upload is the only version of this anybody would keep using.
--
-- Being honest about the boundary, because the console cannot hide it:
-- setting this changes nothing until the next deploy. The favicon and
-- the web icons are files inside the bundle, so they are rebuilt by CI;
-- the Android launcher icon and the iOS app icon are baked into a store
-- build, which this CI does not make. The tab says so rather than
-- implying an upload reaches a phone.
--
-- ## Clearing, which was not possible before
--
-- `platform_save_landing_page` reads a patch, and every field was
-- `coalesce(p_patch ->> 'x', p.x)`. Absent and null are indistinguishable
-- through `->>`, so a null meant "leave alone" and a logo, once set,
-- could never be removed — only replaced.
--
-- The three fields an uploader can genuinely take back — both logos and
-- the hero image — now test `p_patch ? 'x'` instead: absent still leaves
-- them alone, present sets them, and an empty string or a null clears
-- them. Nothing else changes, and no existing caller changes behaviour:
-- `landing_cms.dart` sends only the keys it changed and has never sent a
-- null.
--
-- The `nullif(btrim(...), '')` fields are left exactly as they were.
-- Those refuse to be blanked on purpose — a product with no wordmark is
-- not a product with an empty wordmark, it is a bug.
--
-- `landing_page()` needs no change at all: it returns `to_jsonb(p)`, so
-- both new columns reach the client the moment they exist.

alter table public.landing_page
  add column if not exists app_icon_url text,
  add column if not exists theme_mode   text not null default 'system';

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'landing_page_theme_mode_ck') then
    alter table public.landing_page
      add constraint landing_page_theme_mode_ck
      check (theme_mode in ('system', 'light', 'dark'));
  end if;
end $$;

comment on column public.landing_page.app_icon_url is
  'Square source image the favicon and PWA icons are generated from by '
  'CI at build time. Changing it changes nothing until the next deploy, '
  'and never reaches an installed Android or iOS launcher icon.';

comment on column public.landing_page.theme_mode is
  'Which scheme a visitor gets before choosing one: system, light or '
  'dark. system is what MaterialApp does by default.';

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
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

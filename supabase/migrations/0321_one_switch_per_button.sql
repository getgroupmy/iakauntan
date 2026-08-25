-- One switch per button, and a hero picture out of the box.
--
-- `0320` gave the console two switches: the button on the top bar and
-- the buttons under the headline. Right shape, wrong grain. A button is
-- three decisions, not one — where it sits, how wide the screen is when
-- it is drawn, and which way in it offers — and an operator who wants
-- "Create an account on the desktop bar but only Sign in on a phone"
-- had no way to say it.
--
-- So the two become eight, one for each button a visitor can actually
-- see:
--
--            desktop (> 760)      phone (<= 760)
--   bar      bar_sign_in_desktop  bar_sign_in_mobile
--            bar_register_desktop bar_register_mobile
--   hero     hero_sign_in_desktop hero_sign_in_mobile
--            hero_register_desktop hero_register_mobile
--
-- 760 is the width the masthead and the hero already changed shape at,
-- named rather than invented: the point at which the bar folds its
-- links into a menu.
--
-- ## The two they replace are seeded, then dropped
--
-- Whatever `0320`'s pair was set to is copied into the four switches it
-- stood for before the columns go, so a platform that turned the bar
-- off yesterday still has it off today. Dropping rather than leaving
-- them: they shipped one migration ago, nothing else reads them, and a
-- column the payload still carries and the page ignores is a column
-- somebody will one day set and wonder about.
--
-- `register_enabled` is untouched and still decides whether the
-- platform takes registrations at all. These eight say where its button
-- is drawn; it says whether there is one to draw. Off, and the four
-- register switches have nothing to act on — which is why they are
-- separate: turning registration back on should not also have to
-- rediscover which places used to show it.
--
-- ## And the hero has a picture out of the box
--
-- `hero_image_url` shipped null, and null draws the placeholder panel —
-- an empty window frame, which is the right answer for a platform that
-- has not chosen an image and the wrong one for this platform, which
-- has: `app/web/hero-dashboard.png` is a screenshot of the real
-- dashboard, rendered from the real widgets and served from the same
-- origin as the page. It becomes the default, and the row that is
-- already there gets it if nobody has set one.
--
-- The placeholder stays in the app for the case it was written for: an
-- address that will not load. A default is not a lock — clear the field
-- in the console and the built-in picture comes back, which is the
-- behaviour every other defaulted field on this page has.

alter table public.landing_page
  add column if not exists bar_sign_in_desktop   boolean not null default true,
  add column if not exists bar_sign_in_mobile    boolean not null default true,
  add column if not exists bar_register_desktop  boolean not null default true,
  add column if not exists bar_register_mobile   boolean not null default true,
  add column if not exists hero_sign_in_desktop  boolean not null default true,
  add column if not exists hero_sign_in_mobile   boolean not null default true,
  add column if not exists hero_register_desktop boolean not null default true,
  add column if not exists hero_register_mobile  boolean not null default true;

-- Carry 0320's answer forward before the columns that hold it go.
update public.landing_page p set
  bar_sign_in_desktop   = p.show_masthead_button,
  bar_sign_in_mobile    = p.show_masthead_button,
  bar_register_desktop  = p.show_masthead_button,
  bar_register_mobile   = p.show_masthead_button,
  hero_sign_in_desktop  = p.show_hero_buttons,
  hero_sign_in_mobile   = p.show_hero_buttons,
  hero_register_desktop = p.show_hero_buttons,
  hero_register_mobile  = p.show_hero_buttons
where p.id;

alter table public.landing_page
  drop column if exists show_masthead_button,
  drop column if exists show_hero_buttons;

comment on column public.landing_page.bar_sign_in_desktop is
  'Draw Sign in on the top bar on a screen wider than 760.';
comment on column public.landing_page.bar_sign_in_mobile is
  'Draw Sign in on the top bar, and in the menu sheet, on a phone.';
comment on column public.landing_page.bar_register_desktop is
  'Draw the register button on the top bar on a wide screen.';
comment on column public.landing_page.bar_register_mobile is
  'Draw the register button on the bar, and in the menu, on a phone.';
comment on column public.landing_page.hero_sign_in_desktop is
  'Draw Sign in under the headline on a wide screen.';
comment on column public.landing_page.hero_sign_in_mobile is
  'Draw Sign in under the headline on a phone.';
comment on column public.landing_page.hero_register_desktop is
  'Draw the register button under the headline on a wide screen.';
comment on column public.landing_page.hero_register_mobile is
  'Draw the register button under the headline on a phone.';

-- The hero's picture, for a platform that has not chosen one.
alter table public.landing_page
  alter column hero_image_url set default 'https://iakauntan.com/hero-dashboard.png';

update public.landing_page p
   set hero_image_url = 'https://iakauntan.com/hero-dashboard.png'
 where p.id and p.hero_image_url is null;

-- ---------------------------------------------------------------------
-- The saver learns the eight and forgets the two
--
-- `app.landing_payload` builds the page from `to_jsonb(p)`, so the
-- columns reach the browser and leave it without a change there. The
-- saver names every column it writes, so it needs one — and it would
-- fail on the next call if it did not, since the two it was written
-- against no longer exist.
--
-- Re-granted below because `0165`'s event trigger strips privileges
-- from anything created or replaced in `public`.
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
    -- 0321. One switch per button a visitor can actually see:
    -- the place it sits, the width it is drawn at, and which
    -- way in it offers.
    bar_sign_in_desktop = coalesce((p_patch ->> 'bar_sign_in_desktop')::boolean,
                                  p.bar_sign_in_desktop),
    bar_sign_in_mobile = coalesce((p_patch ->> 'bar_sign_in_mobile')::boolean,
                                  p.bar_sign_in_mobile),
    bar_register_desktop = coalesce((p_patch ->> 'bar_register_desktop')::boolean,
                                  p.bar_register_desktop),
    bar_register_mobile = coalesce((p_patch ->> 'bar_register_mobile')::boolean,
                                  p.bar_register_mobile),
    hero_sign_in_desktop = coalesce((p_patch ->> 'hero_sign_in_desktop')::boolean,
                                  p.hero_sign_in_desktop),
    hero_sign_in_mobile = coalesce((p_patch ->> 'hero_sign_in_mobile')::boolean,
                                  p.hero_sign_in_mobile),
    hero_register_desktop = coalesce((p_patch ->> 'hero_register_desktop')::boolean,
                                  p.hero_register_desktop),
    hero_register_mobile = coalesce((p_patch ->> 'hero_register_mobile')::boolean,
                                  p.hero_register_mobile),
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb)
  to authenticated;

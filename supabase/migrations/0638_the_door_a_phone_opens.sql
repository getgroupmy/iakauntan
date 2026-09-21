-- =====================================================================
-- iAkauntan :: 0638 the door a phone opens
--
-- Three switches, all of them about the app rather than the website,
-- and all of them for the same reason: the sign-in form is the FIRST
-- screen in the app and the only screen on the website that a visitor
-- is sent to rather than arriving at.
--
-- ---------------------------------------------------------------------
-- Why a phone needs its own answers at all
--
-- The website has a shopfront. Somebody who typed `iakauntan.com` has
-- not come to sign in -- they have come to find out what this is -- so
-- `/` is the landing page and the form is one button away.
--
-- An app has no shopfront. Nobody installs an accounting system from
-- an app store to read about accounting systems: they installed it
-- because they already have books here, or because somebody at work
-- told them to. So the app opens at the form, and every question the
-- landing page answers for a stranger has already been answered before
-- the download finished.
--
-- That difference is why these three cannot be the same switch as the
-- website's.
--
-- ---------------------------------------------------------------------
-- `signin_show_passkey_ios` and `signin_show_passkey_android`
--
-- Ship FALSE, like `signin_show_passkey` (`0579`) and for a longer
-- list of the same reason. A passkey button that is drawn before the
-- setup behind it is finished fails for everybody who presses it, and
-- the setup is in three different places:
--
--   * all three surfaces need passkeys switched on for the project in
--     the Supabase dashboard, or GoTrue answers `passkey_disabled`;
--   * Android additionally needs `assetlinks.json` served from the
--     domain, naming this package and BOTH signing certificates;
--   * iOS additionally needs an Associated Domains entitlement on the
--     Runner target and an `apple-app-site-association` served from
--     the domain.
--
-- Those are finished on different days, by different people, and two
-- of them can be wrong in a way nothing in the app can detect until
-- somebody presses the button. `docs/passkeys.md` is the list.
--
-- So: one switch per surface, turned on as each surface's half is
-- done. A single switch would mean the first surface to be ready
-- turning the button on for the two that are not.
--
-- ---------------------------------------------------------------------
-- `signin_show_register_mobile`
--
-- Ships TRUE, unlike the two above, because it takes something away
-- rather than offering something new -- and a switch that ships in the
-- state that changes behaviour is a migration that changes behaviour.
--
-- It is a VETO over `signin_show_register`, not a replacement: the app
-- offers the way on to the registration form when both are on. An
-- operator who wants strangers to sign up on the website and not in
-- the app turns this one off and leaves the other alone, which is not
-- something one switch can say.
--
-- Not a security control, and none of these three are. `signup_enabled`
-- is, and `0563` put that where it has to be -- a trigger on
-- `auth.users` that refuses. These decide what is DRAWN. Somebody who
-- reaches the registration form another way is still refused by the
-- trigger, and somebody whose passkey button is hidden can still sign
-- in with a password.
-- =====================================================================

alter table public.landing_page
  add column if not exists signin_show_passkey_ios boolean not null
    default false,
  add column if not exists signin_show_passkey_android boolean not null
    default false,
  add column if not exists signin_show_register_mobile boolean not null
    default true;

comment on column public.landing_page.signin_show_passkey_ios is
  'Draw "Sign in with a passkey" in the iOS app. Ships FALSE, like '
  '`signin_show_passkey` and separately from it: iOS needs an '
  'Associated Domains entitlement and an apple-app-site-association '
  'served from the domain on top of the project-level dashboard '
  'setting, and until both are in place the button fails for '
  'everybody who presses it. See docs/passkeys.md. Not a security '
  'control: it decides whether the button is drawn.';

comment on column public.landing_page.signin_show_passkey_android is
  'Draw "Sign in with a passkey" in the Android app. Ships FALSE, '
  'like `signin_show_passkey` and separately from it: Android needs '
  'an assetlinks.json served from the domain naming this package and '
  'BOTH signing certificates -- the upload key and Play App Signing '
  '-- on top of the project-level dashboard setting. Listing only the '
  'first is the commonest way this ships broken: it works on the '
  'developer''s handset and nowhere else. See docs/passkeys.md.';

comment on column public.landing_page.signin_show_register_mobile is
  'Offer the way on to the registration form in the iOS and Android '
  'apps. Ships TRUE, unlike the two passkey switches, because it '
  'takes something away rather than offering something new. A VETO '
  'over `signin_show_register` rather than a replacement: the app '
  'draws the link when both are on, so switching this off closes the '
  'door in the app and leaves the website''s alone. Not a security '
  'control -- `signup_enabled` is, enforced by 0563''s trigger on '
  'auth.users -- this only decides whether the link is drawn.';

-- ---------------------------------------------------------------------
-- The payload carries all three to the sign-in screen
--
-- Restated whole from `0613`, which is what is live, with three lines
-- added beside the passkey's. In `brand` rather than `page` for the
-- reason every other sign-in switch is: the form draws whether or not
-- a marketing site has been published, and in the app there is no
-- marketing site to publish.
-- ---------------------------------------------------------------------
create or replace function app.landing_payload(p_draft boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'page', (select to_jsonb(p) - 'updated_by' - 'id'
               from public.landing_page p
              where p_draft or p.is_published),
    'brand', coalesce((
      select jsonb_build_object(
               'logo_url',          p.logo_url,
               'logo_dark_url',     p.logo_dark_url,
               'wordmark',          p.wordmark,
               'brand_colour',      p.brand_colour,
               'brand_colour_dark', p.brand_colour_dark,
               'theme_mode',        p.theme_mode,
               'app_icon_url',      p.app_icon_url,
               -- 0331. In `brand` and not in `page` because `page` is
               -- gated on publication above, and the visitor who needs
               -- this page is standing at a door that does not open.
               -- Telling them nothing because the marketing site is
               -- still a draft is the one outcome worth ruling out.
               'unknown_title',     p.unknown_title,
               'unknown_body',      p.unknown_body,
               'unknown_cta_label', p.unknown_cta_label,
               'unknown_cta_url',   p.unknown_cta_url,
               -- 0335, and in `brand` for the same reason: the sign-in
               -- screen draws before anything is published, and it is
               -- the screen this switch governs.
               'demo_accounts_enabled', p.demo_accounts_enabled,
               -- 0336, and in `brand` for the reason the two above are:
               -- the sign-in screen draws whether or not anybody has
               -- published a marketing site.
               'signin_show_logo',     p.signin_show_logo,
               'signin_show_name',     p.signin_show_name,
               'signin_headline',      p.signin_headline,
               'signin_show_headline', p.signin_show_headline,
               'signin_show_heading',  p.signin_show_heading,
               'signin_show_register', p.signin_show_register,
               -- 0579. Ships false: GoTrue answers
               -- `passkey_disabled` until the dashboard switch is
               -- on, so a button drawn before that fails for
               -- everybody who presses it.
               'signin_show_passkey',  p.signin_show_passkey,
               -- 0613. Ships false for the same reason and in the
               -- same order: the Supabase dashboard has to have an
               -- SMTP sender before this is worth drawing.
               'signin_show_magic_link', p.signin_show_magic_link,
               -- 0556. Cloudflare Turnstile's SITE key, which is
               -- public by design: it identifies the widget to the
               -- browser and proves nothing on its own. The secret
               -- that verifies a token lives in the Supabase
               -- dashboard and never here.
               --
               -- Empty means no captcha, and the forms draw none.
               'turnstile_site_key',   p.turnstile_site_key,
               -- 0337. The colour of the panel and the words on the
               -- form. `brand` again, and for the third time the same
               -- reason: this screen draws before anything is
               -- published.
               'signin_email_label',     p.signin_email_label,
               'signin_password_label',  p.signin_password_label,
               'signin_name_label',      p.signin_name_label,
               'signin_forgot_label',    p.signin_forgot_label,
               'signin_register_prompt', p.signin_register_prompt,
               'signin_signin_prompt',   p.signin_signin_prompt,
               -- Not new, and that is the point: these two have been on
               -- the table since 0290 and the sign-in screen has been
               -- ignoring them, so an operator who renamed the button
               -- saw it change on the landing page and not on the form
               -- the button leads to.
               'sign_in_label',          p.sign_in_label,
               'register_label',         p.register_label,
               -- 0339. Stored since 0290, edited in the console since
               -- 0316, and read by nothing at all until now. `brand`
               -- rather than `page` because the tab has a title on
               -- every screen, including the ones a platform with no
               -- published marketing site still shows.
               'meta_title',             p.meta_title,
               'meta_description',       p.meta_description,
               -- 0343. Twelve overrides, and every one of them
               -- usually null. `brand` because the theme is built
               -- before anything is published: the sign-in screen
               -- is drawn in it.
               'scheme_light_primary', p.scheme_light_primary,
               'scheme_light_container', p.scheme_light_container,
               'scheme_light_secondary', p.scheme_light_secondary,
               'scheme_light_surface', p.scheme_light_surface,
               'scheme_light_surface_tint', p.scheme_light_surface_tint,
               'scheme_light_error', p.scheme_light_error,
               'scheme_dark_primary', p.scheme_dark_primary,
               'scheme_dark_container', p.scheme_dark_container,
               'scheme_dark_secondary', p.scheme_dark_secondary,
               'scheme_dark_surface', p.scheme_dark_surface,
               'scheme_dark_surface_tint', p.scheme_dark_surface_tint,
               'scheme_dark_error', p.scheme_dark_error,
               -- 0350. The login page's own seven, beside the sign-in
               -- page's. `brand` for the third time and the same
               -- reason: the screen these govern draws whether or not
               -- anybody has published a marketing site, and gating
               -- them would leave a company's door bare on a platform
               -- that never got round to pressing Publish.
               'login_show_headline',  p.login_show_headline,
               'login_show_heading',   p.login_show_heading,
               'login_headline',       p.login_headline,
               'login_email_label',    p.login_email_label,
               'login_password_label', p.login_password_label,
               'login_forgot_label',   p.login_forgot_label,
               'login_sign_in_label',  p.login_sign_in_label)
             -- 0638. A second object, merged. Not a style: the call
             -- above is at 96 of the 100 arguments Postgres allows a
             -- function, and three more switches is six more. Adding
             -- them to the list refuses the migration outright.
             --
             -- The two halves share no key, so `||` builds exactly the
             -- object one call would have. Put the next switch here.
             || jsonb_build_object(
               -- The same button on the two platforms that are not a
               -- browser, and one switch each rather than one between
               -- them. `signin_show_passkey` above is the web's: the
               -- three surfaces need different things done to them
               -- before the button works -- a dashboard setting for
               -- all three, an `assetlinks.json` for Android, an
               -- entitlement and an `apple-app-site-association` for
               -- iOS -- and those are finished on different days by
               -- different people. A single switch would mean turning
               -- the button on for a surface whose half of the setup
               -- is not done.
               'signin_show_passkey_ios',     p.signin_show_passkey_ios,
               'signin_show_passkey_android', p.signin_show_passkey_android,
               -- And the register link, which on a phone is a
               -- narrower question than on the web: an app store can
               -- have rules about what an account costs and who may
               -- open one, and the answer to "may a stranger sign up
               -- here" can differ between the shopfront and the build
               -- in the store. Ships TRUE, so nothing changes until
               -- somebody decides it should.
               'signin_show_register_mobile', p.signin_show_register_mobile)
        from public.landing_page p
    ), '{}'::jsonb),
    -- 0336. The bullets beside the sign-in form. Same table and same
    -- editor as the landing page's three bands, and a fourth `kind` so
    -- they are not mixed in with them.
    --
    -- Not gated on publication, unlike `sections` below and for the
    -- same reason `brand` is not: this list is beside a form that draws
    -- for everybody, all the time. `is_active` is the switch, and it is
    -- off on all three out of the box.
    -- 0350. The bullets beside a company's door, seeded from the
    -- sign-in page's. Ungated for the reason `signin_points` is:
    -- `is_active` is the switch, and it is off on every row out of the
    -- box.
    'login_points', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'login'
    ), '[]'::jsonb),
    'signin_points', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'signin'
    ), '[]'::jsonb),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'feature'
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'reasons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'reason'
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'badges', coalesce((
      select jsonb_agg(jsonb_build_object(
               'icon', s.icon, 'title', s.title, 'body', s.body)
               order by s.sort_order, s.title)
        from public.landing_sections s
       where s.is_active and s.kind = 'badge'
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'stats', coalesce((
      select jsonb_agg(jsonb_build_object(
               'value', st.value, 'label', st.label, 'icon', st.icon)
               order by st.sort_order, st.label)
        from public.landing_stats st
       where st.is_active
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'testimonials', coalesce((
      select jsonb_agg(jsonb_build_object(
               'quote', t.quote, 'author', t.author,
               'company', t.company, 'avatar_url', t.avatar_url)
               order by t.sort_order, t.id)
        from public.landing_testimonials t
       where t.is_active
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'logos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', l.name, 'logo_url', l.logo_url)
               order by l.sort_order, l.name)
        from public.landing_logos l
       where l.is_active
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
    ), '[]'::jsonb),
    'app_links', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store_code', a.store_code, 'label', a.label,
               'url', a.url, 'badge_url', a.badge_url)
               order by a.sort_order, a.store_code)
        from public.landing_app_links a
       where a.is_active
         and (p_draft or exists (select 1 from public.landing_page p
                                  where p.is_published))
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
                      where p.show_pricing
                        and (p_draft or p.is_published))
    ), '[]'::jsonb));
$function$;

-- ---------------------------------------------------------------------
-- And the console saves all three
--
-- Restated whole from `0613` with three coalesces added. Plain
-- booleans rather than blankable text: a switch has two states, and an
-- absent key still means "leave it alone", so a console that patches
-- one field does not reset the others.
-- ---------------------------------------------------------------------
create or replace function public.platform_save_landing_page(p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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

  foreach v_colour in array array['brand_colour', 'brand_colour_dark',
                                  'scheme_light_primary',
                                  'scheme_light_container',
                                  'scheme_light_secondary',
                                  'scheme_light_surface',
                                  'scheme_light_surface_tint',
                                  'scheme_light_error',
                                  'scheme_dark_primary',
                                  'scheme_dark_container',
                                  'scheme_dark_secondary',
                                  'scheme_dark_surface',
                                  'scheme_dark_surface_tint',
                                  'scheme_dark_error'] loop
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

  -- The rule the marketing button already has, for this page's button:
  -- a link the browser cannot follow is worse than an absent one.
  if nullif(btrim(p_patch ->> 'unknown_cta_url'), '') is not null
     and btrim(p_patch ->> 'unknown_cta_url') !~ '^https?://' then
    raise exception 'That button needs a full https address. Got %',
                    p_patch ->> 'unknown_cta_url'
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
    -- 0556. Cleared by an empty string rather than only set, because
    -- taking the captcha off has to be as easy as putting it on: a key
    -- that cannot be removed is a form that cannot be un-broken if the
    -- Cloudflare account goes away.
    turnstile_site_key = case when p_patch ? 'turnstile_site_key'
                          then nullif(btrim(p_patch ->> 'turnstile_site_key'), '')
                          else p.turnstile_site_key end,
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
    -- 0578. The footer four, on the same grain: `0321` left the footer
    -- out deliberately, and kept that argument as the default rather
    -- than as a rule -- all four ship true.
    footer_sign_in_desktop = coalesce(
                                  (p_patch ->> 'footer_sign_in_desktop')::boolean,
                                  p.footer_sign_in_desktop),
    footer_sign_in_mobile = coalesce(
                                  (p_patch ->> 'footer_sign_in_mobile')::boolean,
                                  p.footer_sign_in_mobile),
    footer_register_desktop = coalesce(
                                  (p_patch ->> 'footer_register_desktop')::boolean,
                                  p.footer_register_desktop),
    footer_register_mobile = coalesce(
                                  (p_patch ->> 'footer_register_mobile')::boolean,
                                  p.footer_register_mobile),
    -- 0331. The page a visitor gets at a name nobody holds. Cleared
    -- to null by an empty string like every other optional line here,
    -- and the screen falls back to its shipped copy when they are null
    -- — so an operator who empties the boxes gets the default back
    -- rather than a page with nothing on it.
    unknown_title     = case when p_patch ? 'unknown_title'
                          then nullif(btrim(p_patch ->> 'unknown_title'), '')
                          else p.unknown_title end,
    unknown_body      = case when p_patch ? 'unknown_body'
                          then nullif(btrim(p_patch ->> 'unknown_body'), '')
                          else p.unknown_body end,
    unknown_cta_label = case when p_patch ? 'unknown_cta_label'
                          then nullif(btrim(p_patch ->> 'unknown_cta_label'), '')
                          else p.unknown_cta_label end,
    unknown_cta_url   = case when p_patch ? 'unknown_cta_url'
                          then nullif(btrim(p_patch ->> 'unknown_cta_url'), '')
                          else p.unknown_cta_url end,
    -- 0335. A plain boolean rather than a blankable field: it is a
    -- switch, and an absent key still means "leave it alone".
    demo_accounts_enabled = coalesce(
      (p_patch ->> 'demo_accounts_enabled')::boolean, p.demo_accounts_enabled),
    -- 0336. Four switches and one line of copy, all for the sign-in
    -- screen. The headline is blankable rather than coalesced, like
    -- every other optional line of copy on this page: clearing the box
    -- is how somebody asks for the shipped wording back.
    signin_show_logo = coalesce(
      (p_patch ->> 'signin_show_logo')::boolean, p.signin_show_logo),
    signin_show_name = coalesce(
      (p_patch ->> 'signin_show_name')::boolean, p.signin_show_name),
    signin_headline = case when p_patch ? 'signin_headline'
                        then nullif(btrim(p_patch ->> 'signin_headline'), '')
                        else p.signin_headline end,
    signin_show_headline = coalesce(
      (p_patch ->> 'signin_show_headline')::boolean, p.signin_show_headline),
    signin_show_heading = coalesce(
      (p_patch ->> 'signin_show_heading')::boolean, p.signin_show_heading),
    signin_show_register = coalesce(
      (p_patch ->> 'signin_show_register')::boolean, p.signin_show_register),
    -- 0579. The passkey button. Ships false and has to be turned on in
    -- the Supabase dashboard before it is turned on here.
    signin_show_passkey = coalesce(
      (p_patch ->> 'signin_show_passkey')::boolean, p.signin_show_passkey),
    -- 0638. The same button on iOS and on Android, switched
    -- separately from each other and from the web's above. Each
    -- surface has its own half of the setup and they are not
    -- finished together.
    signin_show_passkey_ios = coalesce(
      (p_patch ->> 'signin_show_passkey_ios')::boolean,
      p.signin_show_passkey_ios),
    signin_show_passkey_android = coalesce(
      (p_patch ->> 'signin_show_passkey_android')::boolean,
      p.signin_show_passkey_android),
    -- 0638. Whether the app offers a way to open an account. A veto
    -- over `signin_show_register` rather than a replacement for it:
    -- switching this off closes the door in the app and leaves the
    -- website's alone.
    signin_show_register_mobile = coalesce(
      (p_patch ->> 'signin_show_register_mobile')::boolean,
      p.signin_show_register_mobile),
    -- 0613. The magic link button. Ships false and needs an SMTP
    -- sender in the Supabase dashboard before it is worth turning on.
    signin_show_magic_link = coalesce(
      (p_patch ->> 'signin_show_magic_link')::boolean,
      p.signin_show_magic_link),
    -- 0350. The login page's own seven. Booleans coalesced and text
    -- blankable, the same split the sign-in page's use and for the same
    -- reason: a switch has two states and a line of copy has three, the
    -- third being "give me back the words the product ships with".
    login_show_headline = coalesce(
      (p_patch ->> 'login_show_headline')::boolean, p.login_show_headline),
    login_show_heading = coalesce(
      (p_patch ->> 'login_show_heading')::boolean, p.login_show_heading),
    login_headline = case when p_patch ? 'login_headline'
                       then nullif(btrim(p_patch ->> 'login_headline'), '')
                       else p.login_headline end,
    login_email_label = case when p_patch ? 'login_email_label'
                          then nullif(btrim(p_patch ->> 'login_email_label'), '')
                          else p.login_email_label end,
    login_password_label = case when p_patch ? 'login_password_label'
                             then nullif(
                               btrim(p_patch ->> 'login_password_label'), '')
                             else p.login_password_label end,
    login_forgot_label = case when p_patch ? 'login_forgot_label'
                           then nullif(
                             btrim(p_patch ->> 'login_forgot_label'), '')
                           else p.login_forgot_label end,
    login_sign_in_label = case when p_patch ? 'login_sign_in_label'
                            then nullif(
                              btrim(p_patch ->> 'login_sign_in_label'), '')
                            else p.login_sign_in_label end,
    -- 0337. All blankable: clearing a box is how somebody asks for the
    -- word the product ships with, and a coalesce would put back what
    -- they just cleared.
    -- 0343. Blankable, like every other optional colour: clearing
    -- the box is how somebody asks Material to derive it again.
    scheme_light_primary = case when p_patch ? 'scheme_light_primary'
      then nullif(btrim(p_patch ->> 'scheme_light_primary'), '')
      else p.scheme_light_primary end,
    scheme_light_container = case when p_patch ? 'scheme_light_container'
      then nullif(btrim(p_patch ->> 'scheme_light_container'), '')
      else p.scheme_light_container end,
    scheme_light_secondary = case when p_patch ? 'scheme_light_secondary'
      then nullif(btrim(p_patch ->> 'scheme_light_secondary'), '')
      else p.scheme_light_secondary end,
    scheme_light_surface = case when p_patch ? 'scheme_light_surface'
      then nullif(btrim(p_patch ->> 'scheme_light_surface'), '')
      else p.scheme_light_surface end,
    scheme_light_surface_tint = case when p_patch ? 'scheme_light_surface_tint'
      then nullif(btrim(p_patch ->> 'scheme_light_surface_tint'), '')
      else p.scheme_light_surface_tint end,
    scheme_light_error = case when p_patch ? 'scheme_light_error'
      then nullif(btrim(p_patch ->> 'scheme_light_error'), '')
      else p.scheme_light_error end,
    scheme_dark_primary = case when p_patch ? 'scheme_dark_primary'
      then nullif(btrim(p_patch ->> 'scheme_dark_primary'), '')
      else p.scheme_dark_primary end,
    scheme_dark_container = case when p_patch ? 'scheme_dark_container'
      then nullif(btrim(p_patch ->> 'scheme_dark_container'), '')
      else p.scheme_dark_container end,
    scheme_dark_secondary = case when p_patch ? 'scheme_dark_secondary'
      then nullif(btrim(p_patch ->> 'scheme_dark_secondary'), '')
      else p.scheme_dark_secondary end,
    scheme_dark_surface = case when p_patch ? 'scheme_dark_surface'
      then nullif(btrim(p_patch ->> 'scheme_dark_surface'), '')
      else p.scheme_dark_surface end,
    scheme_dark_surface_tint = case when p_patch ? 'scheme_dark_surface_tint'
      then nullif(btrim(p_patch ->> 'scheme_dark_surface_tint'), '')
      else p.scheme_dark_surface_tint end,
    scheme_dark_error = case when p_patch ? 'scheme_dark_error'
      then nullif(btrim(p_patch ->> 'scheme_dark_error'), '')
      else p.scheme_dark_error end,
    signin_email_label = case when p_patch ? 'signin_email_label'
                           then nullif(btrim(p_patch ->> 'signin_email_label'), '')
                           else p.signin_email_label end,
    signin_password_label = case when p_patch ? 'signin_password_label'
                              then nullif(btrim(p_patch ->> 'signin_password_label'), '')
                              else p.signin_password_label end,
    signin_name_label = case when p_patch ? 'signin_name_label'
                          then nullif(btrim(p_patch ->> 'signin_name_label'), '')
                          else p.signin_name_label end,
    signin_forgot_label = case when p_patch ? 'signin_forgot_label'
                            then nullif(btrim(p_patch ->> 'signin_forgot_label'), '')
                            else p.signin_forgot_label end,
    signin_register_prompt = case when p_patch ? 'signin_register_prompt'
                               then nullif(btrim(p_patch ->> 'signin_register_prompt'), '')
                               else p.signin_register_prompt end,
    signin_signin_prompt = case when p_patch ? 'signin_signin_prompt'
                             then nullif(btrim(p_patch ->> 'signin_signin_prompt'), '')
                             else p.signin_signin_prompt end,
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$function$;

-- =====================================================================
-- iAkauntan :: 0653 the small print at the bottom of an app's door
--
-- Asked for as: at the bottom of the sign-in screen in the iOS and
-- Android apps, link to Terms of Use, Terms of Service and Privacy
-- Policy; a link to a page of demo logins beside them; and a switch for
-- each, per platform, in the console.
--
-- ---------------------------------------------------------------------
-- Why the apps and not the web
--
-- The website already has all three in the landing page's footer, on
-- every page including the one with the sign-in form on it. The apps
-- have no footer and no landing page -- `0639` opens a native build at
-- the form rather than at the shopfront -- so in an app these three
-- documents are linked from the consent line under the REGISTER button
-- and from nowhere else at all. Somebody signing in rather than
-- registering could not reach them.
--
-- That is a review problem as well as a courtesy one. Both stores ask
-- where a build's privacy policy is; a build whose only link to it is
-- under a button on a form the reviewer did not open is a build that
-- appears not to have one.
--
-- ---------------------------------------------------------------------
-- Eight switches, and why not two
--
-- Six for the legal links, one per document per platform, because the
-- two stores' rules are different rules changed on different days, in
-- the same way that `0638` split the passkey switch: one switch between
-- two surfaces means the surface that is not ready gets whatever the
-- one that is ready needed.
--
-- The six ship TRUE. Every switch added since `0579` ships false
-- because a way in nobody chose to draw is a way in the operator did
-- not know they were offering -- and these are not a way in. They are
-- links to documents, and a link is drawn only where the page behind it
-- is PUBLISHED, which is `0334`'s switch and is off out of the box. So
-- these turn on nothing at all on a fresh deployment, and an operator
-- who has just published their privacy policy does not have to find a
-- second switch before a reviewer can see it.
--
-- The remaining two are the demo page and they ship FALSE, which is the
-- whole reason they are a separate pair rather than a seventh and
-- eighth member of the list above. `demo_accounts.dart` opens by saying
-- that the demo password is compiled into the bundle and readable by
-- anyone who opens the app. The gates in front of it are cumulative and
-- these are added to the end of the chain, never in place of one:
--
--   1. DEMO_MODE, a compile-time flag. A build without it does not
--      carry the password, and no row here can put it back.
--   2. `demo_accounts_enabled`, off by default (`0335`).
--   3. these two, off by default, per platform.
--
-- ---------------------------------------------------------------------
-- And the splash picture
--
-- Asked for in the same breath as a console page called "Mobile
-- Application" to keep it and the eight switches above in one place.
-- `splash_image_url` is the ninth column and the only one that is not a
-- boolean.
--
-- NULLABLE, and null is not "no splash". It means "use the logo": the
-- apps draw `logo_url` on white in light mode and `logo_dark_url` on
-- black in dark, which is what every deployment already has and what
-- the request asked for by name. A not-null default would have been a
-- URL invented here for a picture nobody uploaded, and the first
-- deployment to see it would see a broken image where its own mark
-- should be.
--
-- There is no column for how long the splash is held. Five seconds was
-- asked for as a number rather than as a setting, and the app carries
-- it as one named constant; a column would be a second answer to a
-- question that has one.
--
-- ---------------------------------------------------------------------
-- Both functions restated whole
--
-- `app.landing_payload` and `public.platform_save_landing_page` are
-- reproduced from what is applied with the eight keys added and nothing
-- else changed, which is what `0638` and `0645` did. The payload keeps
-- the two `jsonb_build_object` calls joined by `||` that `0638` had to
-- introduce -- one call caps at 100 arguments and the first was at 96.
-- The second was at 8 and is now at 24.
-- =====================================================================

alter table public.landing_page
  add column if not exists signin_show_terms_ios boolean not null default true,
  add column if not exists signin_show_terms_android boolean not null
    default true,
  add column if not exists signin_show_terms_of_service_ios boolean not null
    default true,
  add column if not exists signin_show_terms_of_service_android boolean not null
    default true,
  add column if not exists signin_show_privacy_ios boolean not null
    default true,
  add column if not exists signin_show_privacy_android boolean not null
    default true,
  add column if not exists signin_show_demo_page_ios boolean not null
    default false,
  add column if not exists signin_show_demo_page_android boolean not null
    default false,
  -- The picture on the splash screen the apps now hold for a moment
  -- before the first real screen. Nullable, and null is not "no splash"
  -- -- it is "use the logo", which every deployment already has. See
  -- the header.
  add column if not exists splash_image_url text;

comment on column public.landing_page.splash_image_url is
  'The image the iOS and Android splash screen draws. Null means use '
  'the logo -- logo_url on white in light mode, logo_dark_url on black '
  'in dark -- so a deployment that uploads nothing still gets its own '
  'mark rather than a blank screen. See 0653.';
comment on column public.landing_page.signin_show_terms_ios is
  'Link Terms of Use at the foot of the sign-in screen in the iOS app. '
  'Ships true; the link is drawn only where that page is published. '
  'See 0653.';
comment on column public.landing_page.signin_show_terms_android is
  'Link Terms of Use at the foot of the sign-in screen in the Android '
  'app. Ships true; the link is drawn only where that page is '
  'published. See 0653.';
comment on column public.landing_page.signin_show_terms_of_service_ios is
  'Link Terms of Service at the foot of the sign-in screen in the iOS '
  'app. Ships true; the link is drawn only where that page is '
  'published. See 0653.';
comment on column public.landing_page.signin_show_terms_of_service_android is
  'Link Terms of Service at the foot of the sign-in screen in the '
  'Android app. Ships true; the link is drawn only where that page is '
  'published. See 0653.';
comment on column public.landing_page.signin_show_privacy_ios is
  'Link the Privacy Policy at the foot of the sign-in screen in the iOS '
  'app. Ships true; the link is drawn only where that page is '
  'published. See 0653.';
comment on column public.landing_page.signin_show_privacy_android is
  'Link the Privacy Policy at the foot of the sign-in screen in the '
  'Android app. Ships true; the link is drawn only where that page is '
  'published. See 0653.';
comment on column public.landing_page.signin_show_demo_page_ios is
  'Offer the demo logins page from the sign-in screen in the iOS app. '
  'Ships FALSE, and is the third gate after the DEMO_MODE build flag '
  'and demo_accounts_enabled, never a replacement for either. See 0653.';
comment on column public.landing_page.signin_show_demo_page_android is
  'Offer the demo logins page from the sign-in screen in the Android '
  'app. Ships FALSE, and is the third gate after the DEMO_MODE build '
  'flag and demo_accounts_enabled, never a replacement for either. See '
  '0653.';


CREATE OR REPLACE FUNCTION app.landing_payload(p_draft boolean)
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
               'signin_show_register_mobile', p.signin_show_register_mobile,
               -- 0645. "Continue with Google", and it ships false for
               -- two reasons rather than the usual one. The provider
               -- has to be enabled in the Supabase dashboard with a
               -- client id and secret -- without those the button
               -- takes somebody to an error page -- and on a PHONE
               -- there is a second wall: `signInWithOAuth` returns
               -- through a `redirectTo`, and neither platform
               -- registers a URL scheme, so a provider has nowhere to
               -- send the visitor back to. The button is drawn on the
               -- web only; see the migration header.
               'signin_show_google',          p.signin_show_google,
               -- 0653. The three legal links under the sign-in form in
               -- the two apps, and one switch per link per platform
               -- rather than one between them.
               --
               -- Six switches for three links looks like too many until
               -- you ask who sets them. An app store's review has rules
               -- about which of these a build must link to, the two
               -- stores' rules are not the same rules, and they change
               -- on different days. A single switch would mean turning a
               -- link off for the store that does not require it and
               -- failing review on the store that does.
               --
               -- All six ship TRUE, unlike every other switch added
               -- since 0579. They take nothing away that was not already
               -- withheld: an unpublished page is not linked whatever
               -- these say, so out of the box they turn on nothing at
               -- all. The operator who publishes their privacy policy
               -- should not then have to find a second switch before an
               -- app store can see it.
               'signin_show_terms_ios',     p.signin_show_terms_ios,
               'signin_show_terms_android', p.signin_show_terms_android,
               'signin_show_terms_of_service_ios',
                 p.signin_show_terms_of_service_ios,
               'signin_show_terms_of_service_android',
                 p.signin_show_terms_of_service_android,
               'signin_show_privacy_ios',     p.signin_show_privacy_ios,
               'signin_show_privacy_android', p.signin_show_privacy_android,
               -- 0653. The way to the demo page from the sign-in form,
               -- and it ships FALSE on both, which is the whole of why
               -- it is not in the list above.
               --
               -- The demo logins carry a password compiled into the
               -- bundle (`demo_accounts.dart` says so at the top), so
               -- every gate in front of them is deliberate: the
               -- compile-time DEMO_MODE flag, then
               -- `demo_accounts_enabled`, then these. Two more AND
               -- gates, never a replacement for either of the first
               -- two -- a switch in a database that could reopen a door
               -- a build closed would not be a closed door.
               'signin_show_demo_page_ios',
                 p.signin_show_demo_page_ios,
               'signin_show_demo_page_android',
                 p.signin_show_demo_page_android,
               -- 0653. The splash picture, and in `brand` for a
               -- stronger version of the reason everything else here
               -- is: the splash is the FIRST screen an app draws, long
               -- before anybody has signed in and whether or not a
               -- marketing site was ever published. Gated on
               -- publication it would be null on most deployments,
               -- which is the one case it exists to cover.
               'splash_image_url', p.splash_image_url)
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


CREATE OR REPLACE FUNCTION public.platform_save_landing_page(p_patch jsonb)
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
    -- 0645. Continue with Google. Ships false and needs the provider
    -- enabled in the Supabase dashboard first; the button is web-only
    -- until a URL scheme exists on the phones.
    signin_show_google = coalesce(
      (p_patch ->> 'signin_show_google')::boolean,
      p.signin_show_google),
    -- 0653. The three legal links at the foot of the sign-in form in
    -- the apps, one switch per link per platform. All ship true: an
    -- unpublished page is not linked whatever these say, so they take
    -- nothing away out of the box.
    signin_show_terms_ios = coalesce(
      (p_patch ->> 'signin_show_terms_ios')::boolean,
      p.signin_show_terms_ios),
    signin_show_terms_android = coalesce(
      (p_patch ->> 'signin_show_terms_android')::boolean,
      p.signin_show_terms_android),
    signin_show_terms_of_service_ios = coalesce(
      (p_patch ->> 'signin_show_terms_of_service_ios')::boolean,
      p.signin_show_terms_of_service_ios),
    signin_show_terms_of_service_android = coalesce(
      (p_patch ->> 'signin_show_terms_of_service_android')::boolean,
      p.signin_show_terms_of_service_android),
    signin_show_privacy_ios = coalesce(
      (p_patch ->> 'signin_show_privacy_ios')::boolean,
      p.signin_show_privacy_ios),
    signin_show_privacy_android = coalesce(
      (p_patch ->> 'signin_show_privacy_android')::boolean,
      p.signin_show_privacy_android),
    -- 0653. The way to the demo page, and the pair that ships false.
    -- The third and fourth gates in front of a password that is
    -- compiled into the bundle; the first two are the DEMO_MODE build
    -- flag and `demo_accounts_enabled`, and neither of those can be
    -- reopened from here.
    signin_show_demo_page_ios = coalesce(
      (p_patch ->> 'signin_show_demo_page_ios')::boolean,
      p.signin_show_demo_page_ios),
    signin_show_demo_page_android = coalesce(
      (p_patch ->> 'signin_show_demo_page_android')::boolean,
      p.signin_show_demo_page_android),
    -- 0653. The splash picture. BLANKABLE rather than coalesced, like
    -- the logos and every other optional image: clearing the box is how
    -- somebody asks for the logo back, and a coalesce would put back
    -- the picture they just removed.
    splash_image_url = case when p_patch ? 'splash_image_url'
                         then nullif(btrim(p_patch ->> 'splash_image_url'), '')
                         else p.splash_image_url end,
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


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare
  v_col text;
  v_default text;
  v_ships_on boolean;
begin
  -- Read out of the FUNCTIONS rather than out of a payload, for the
  -- reason `0645` wrote down: `brand` falls back to `'{}'` on a
  -- database with no `landing_page` row, and a migration's self-check
  -- must not depend on a company having been set up.
  foreach v_col in array array['signin_show_terms_ios',
                               'signin_show_terms_android',
                               'signin_show_terms_of_service_ios',
                               'signin_show_terms_of_service_android',
                               'signin_show_privacy_ios',
                               'signin_show_privacy_android',
                               'signin_show_demo_page_ios',
                               'signin_show_demo_page_android']
  loop
    if (select prosrc from pg_proc
         where oid = 'app.landing_payload(boolean)'::regprocedure)
       not like '%' || v_col || '%' then
      raise exception '% does not reach the sign-in screen', v_col;
    end if;

    -- The saver is a separate function and has to name each switch of
    -- its own. Eight added at once is eight chances to forget one.
    if (select prosrc from pg_proc
         where oid = 'public.platform_save_landing_page'::regproc)
       not like '%' || v_col || '%' then
      raise exception 'the console cannot change %', v_col;
    end if;

    -- And which way each one ships, from the column's own default --
    -- the only honest place to ask it, since there may be no row.
    -- The six legal links ship on and the two demo switches ship off,
    -- and getting that backwards is the one mistake here with a
    -- consequence: a demo password offered on every deployment.
    v_ships_on := v_col not like '%demo%';
    select column_default into v_default
      from information_schema.columns
     where table_schema = 'public' and table_name = 'landing_page'
       and column_name = v_col;
    if v_default is null
       or v_default not like (case when v_ships_on then '%true%'
                                   else '%false%' end) then
      raise exception '% ships the wrong way round: %',
        v_col, coalesce(v_default, '(no default)');
    end if;
  end loop;

  -- The splash picture is not a boolean and is checked on its own:
  -- it has to reach the payload and the saver, and it has to be
  -- NULLABLE. A not-null default would be a URL invented here for a
  -- picture nobody uploaded.
  if (select prosrc from pg_proc
       where oid = 'app.landing_payload(boolean)'::regprocedure)
     not like '%splash_image_url%' then
    raise exception 'the splash picture does not reach the apps';
  end if;
  if (select prosrc from pg_proc
       where oid = 'public.platform_save_landing_page'::regproc)
     not like '%splash_image_url%' then
    raise exception 'the console cannot change the splash picture';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'landing_page'
                and column_name = 'splash_image_url'
                and is_nullable = 'NO') then
    raise exception 'the splash picture has to be optional';
  end if;

  -- The second `jsonb_build_object` in the payload is what `0638` had
  -- to add because the first hit Postgres's 100-argument limit at 96.
  -- Twenty-four arguments now. Asserted because the failure mode is a
  -- migration that will not apply at all, found by whoever adds the
  -- twenty-fifth pair rather than by whoever wrote this.
  if (select count(*) from pg_proc
       where oid = 'app.landing_payload(boolean)'::regprocedure
         and prosrc like '%|| jsonb_build_object%') <> 1 then
    raise exception 'the payload no longer builds its brand object in '
                    'two halves, and the first half is at the limit';
  end if;
end $do$;

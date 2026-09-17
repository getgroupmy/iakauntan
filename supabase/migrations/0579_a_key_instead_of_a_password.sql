-- =====================================================================
-- iAkauntan :: 0579 a key instead of a password
--
-- Asked for: sign in with a passkey.
--
-- I expected this to mean building WebAuthn against a service-role
-- session-minting edge function, which is a bad thing to own. It does
-- not. The `gotrue` the app already pins carries a first-party passkey
-- API -- `auth.passkey.startAuthentication` and `verifyAuthentication`
-- return a real `AuthResponse`, save the session and fire
-- `AuthChangeEvent.signedIn`, exactly as `signInWithPassword` does. No
-- secret leaves the dashboard and nothing here signs a token.
--
-- ---------------------------------------------------------------------
-- The switch, and why it ships OFF
--
-- Every other appearance switch on this page ships ON, because the
-- thing it governs already works. This one does not, and the captcha
-- beside it says why in its own header:
--
--     the order to switch it on is: paste the key, watch a form draw
--     the widget, then turn the protection on in the dashboard -- the
--     other way round refuses every sign-in on the project, including
--     yours.
--
-- Passkeys have the same shape and the opposite default. GoTrue
-- answers `passkey_disabled` until somebody turns them on in the
-- Supabase dashboard, so a button drawn before that is a button that
-- fails for everybody who presses it. OFF is the only honest shipped
-- value: turn it on in the dashboard, then turn it on here.
--
-- It is not a security control. It decides whether the button is drawn,
-- and nothing else -- somebody who has enrolled a passkey and knows the
-- flow is not stopped by this being off, because GoTrue is what decides
-- whether a passkey is accepted.
--
-- ---------------------------------------------------------------------
-- In `brand`, not in `page`
--
-- Same reason `signin_show_register` and the rest are: the sign-in
-- screen draws before anything is published, and a platform that has
-- not written a marketing site still has a door.
-- =====================================================================

alter table public.landing_page
  add column if not exists signin_show_passkey boolean not null default false;

comment on column public.landing_page.signin_show_passkey is
  'Draw "Sign in with a passkey" on the sign-in form. Ships FALSE, '
  'unlike every other switch on this page, because GoTrue answers '
  '`passkey_disabled` until passkeys are turned on in the Supabase '
  'dashboard -- so the order is dashboard first, then here. Not a '
  'security control: it decides whether the button is drawn, and GoTrue '
  'decides whether a passkey is accepted.';

-- The payload carries it to the sign-in screen, and the patch
-- function learns to write it.

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
$function$

;

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
$function$

;

grant execute on function public.platform_save_landing_page(jsonb) to authenticated;

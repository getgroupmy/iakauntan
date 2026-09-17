-- =====================================================================
-- iAkauntan :: 0578 the way out at the bottom of the page
--
-- `0321` gave the console eight switches — one for each way-in button
-- a visitor can actually see — on the argument that a button is three
-- decisions and not one: where it sits, how wide the screen is when it
-- is drawn, and which way in it offers.
--
--            desktop (> 760)       phone (<= 760)
--   bar      bar_sign_in_desktop   bar_sign_in_mobile
--            bar_register_desktop  bar_register_mobile
--   hero     hero_sign_in_desktop  hero_sign_in_mobile
--            hero_register_desktop hero_register_mobile
--
-- It left the footer out, deliberately, and said so in
-- `landing_content.dart`:
--
--     The footer's links stay whatever is set here — somebody who has
--     read to the bottom and wants in should not have to guess the
--     address.
--
-- ---------------------------------------------------------------------
-- That was a reasonable default and it is not somebody else's decision
--
-- The argument holds for most platforms and it is still the default
-- here: all four ship TRUE, so nothing changes for anybody who does not
-- go looking. What it should not be is unreachable. A platform running
-- a closed beta, or one whose footer is drawn under a marketing page
-- that already carries its own call to action, has a reason the
-- original comment could not anticipate — and "we decided for you" is
-- not an answer the rest of this console gives anywhere else.
--
-- So the eight become twelve, along the grain `0321` established:
--
--   footer   footer_sign_in_desktop   footer_sign_in_mobile
--            footer_register_desktop  footer_register_mobile
--
-- 760 again, the same width the bar folds its links into a menu at, so
-- an operator who has set the bar switches does not have to learn a
-- second meaning of "phone".
--
-- ## What happens when both are off
--
-- The "Get started" heading is not drawn either. A footer column with a
-- heading and nothing under it is the failure the legal column already
-- guards against in this same widget — "a heading with nothing behind
-- it is still not rendered" — and it would read as a broken page
-- rather than a deliberate one.
--
-- `register_enabled` is untouched and still decides whether the
-- platform takes registrations at all. These say where its link is
-- drawn; it says whether there is one to draw.
-- =====================================================================

alter table public.landing_page
  add column if not exists footer_sign_in_desktop  boolean not null default true,
  add column if not exists footer_sign_in_mobile   boolean not null default true,
  add column if not exists footer_register_desktop boolean not null default true,
  add column if not exists footer_register_mobile  boolean not null default true;

comment on column public.landing_page.footer_sign_in_desktop is
  'Draw the footer''s Sign in link on a screen wider than 760. Ships '
  'true. Off leaves somebody who has read to the bottom no way in from '
  'there, which is a choice a platform may make and not one this '
  'system makes for it.';

comment on column public.landing_page.footer_sign_in_mobile is
  'Draw the footer''s Sign in link on a screen 760 or narrower. Ships '
  'true. Same width the top bar folds its links into a menu at, so '
  '"phone" means one thing across the whole page.';

comment on column public.landing_page.footer_register_desktop is
  'Draw the footer''s Create an account link on a screen wider than '
  '760. Ships true. Has nothing to act on when `register_enabled` is '
  'false — that decides whether the platform takes registrations at '
  'all, and this only decides where the link is drawn.';

comment on column public.landing_page.footer_register_mobile is
  'Draw the footer''s Create an account link on a screen 760 or '
  'narrower. Ships true. With both footer register switches off and '
  '`register_enabled` still true, registration is open and simply not '
  'offered from the footer.';

-- ---------------------------------------------------------------------
-- The patch function names every column it writes, so it has to learn
-- these four.
--
-- Restated from the live definition rather than retyped, with only the
-- four lines added -- `0565` rewrote two policies from their original
-- text and silently undid two later migrations, and this is the same
-- hazard in a different place.
--
-- The grant is explicit because `0165`'s event trigger strips EXECUTE
-- from PUBLIC on every CREATE FUNCTION in `public`, and a REPLACE fires
-- it. This function is granted to `authenticated` alone and to nothing
-- else; re-granting exactly that is what keeps the console working and
-- keeps the door no wider than it was.
-- ---------------------------------------------------------------------

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

grant execute on function public.platform_save_landing_page(jsonb) to authenticated;

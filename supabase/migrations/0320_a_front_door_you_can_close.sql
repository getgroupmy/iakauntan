-- A front door you can close.
--
-- The landing page offers a way in from four places: the button on the
-- top bar, the same button folded into the menu sheet on a phone, the
-- buttons under the headline, and a column of links in the footer.
-- Until now every one of them was unconditional — the only control was
-- `register_enabled`, which chooses *which* way in is offered, never
-- whether one is offered at all.
--
-- Asked for by somebody looking at their own phone: with registration
-- closed the bar and the hero both read "Sign in", one above the
-- other, and there was no way to take either off. Wanting a quieter
-- top of the page is an ordinary thing to want, and so is a site that
-- is a brochure rather than a door — a platform that onboards its
-- customers by hand does not need a sign-in button shouting at
-- visitors who will never have an account.
--
-- ## Two switches, not one
--
-- The bar and the hero are different places with different jobs, and a
-- platform may reasonably want one without the other: the bar button
-- alone reads as a product site, the hero buttons alone read as a
-- landing page. One switch would force them to move together, and the
-- complaint that prompted this was precisely that they did.
--
-- `show_masthead_button` also governs the phone's menu sheet, because
-- the sheet is the bar — it is where the bar's controls go when the
-- screen is too narrow to draw them. Hiding the button in the bar and
-- leaving it in the sheet would be hiding nothing.
--
-- ## What stays
--
-- The footer's "Get started" column keeps its links either way. A
-- footer link is not a button competing for the visitor's attention at
-- the top of the page, and somebody who has read to the bottom and
-- wants in should not have to guess the URL. Turning the page into a
-- brochure with no way in anywhere is a thing this deliberately does
-- not offer; `/signin` is always reachable by address, and the app
-- itself is unaffected — these two columns change one web page.
--
-- Both default true, so nothing changes for anybody who does not go
-- looking for the switch.

alter table public.landing_page
  add column if not exists show_masthead_button boolean not null default true,
  add column if not exists show_hero_buttons    boolean not null default true;

comment on column public.landing_page.show_masthead_button is
  'Draw the way-in button on the top bar, and in the menu sheet on a '
  'phone. Off leaves the bar with the logo and the menu.';
comment on column public.landing_page.show_hero_buttons is
  'Draw the way-in buttons under the hero headline.';

-- ---------------------------------------------------------------------
-- The saver learns the two new fields
--
-- `app.landing_payload` builds the page from `to_jsonb(p)`, so a new
-- column reaches the browser the moment it exists and needs no change
-- there. The saver names every column it writes, so it does need one.
--
-- Booleans, so `coalesce` on the cast is right: absent from the patch
-- means "not part of this edit", and the only two present values are
-- true and false. No blankable case is wanted here — unlike the CTA
-- band, which is taken off the page by clearing its headline.
--
-- Recreated in full because that is the only way to change a function,
-- and re-granted below because `0165`'s event trigger strips privileges
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
    -- 0320. Two switches, not one: the bar's button and the hero's
    -- are separate places and a platform may want one without the
    -- other.
    show_masthead_button = coalesce((p_patch ->> 'show_masthead_button')::boolean,
                                 p.show_masthead_button),
    show_hero_buttons = coalesce((p_patch ->> 'show_hero_buttons')::boolean,
                                 p.show_hero_buttons),
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb)
  to authenticated;

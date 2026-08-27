-- ---------------------------------------------------------------------
-- 0336 - the sign-in page stops being a poster we wrote
--
-- The left half of the sign-in screen is a teal panel with our mark on
-- it, the line "Accounting and CRM for Malaysian business.", and three
-- bullets about LHDN e-Invoice, double-entry and CRM. All of it is a
-- Dart literal. So is "New to iAkauntan? Create an account" under the
-- button.
--
-- That is somebody else's poster on every deployment of this product.
-- An operator who has uploaded their own logo, chosen their own colour
-- and written their own front page still signs in underneath our
-- marketing, and the only way to change a word of it is a release.
--
-- ## Everything gets a switch, and every switch starts off
--
-- Four booleans and a list, and all of them default to hidden:
--
--   signin_show_mark      the logo and wordmark
--   signin_show_headline  the big line, whose text is signin_headline
--   signin_show_heading   "Welcome back" and the sentence under it
--                         (the wording itself is `0334`'s site_pages)
--   signin_show_register  "New to X? Create an account"
--   landing_sections      the bullets, kind = 'signin', is_active each
--
-- Off by default is the point of the change rather than an accident of
-- it. A fresh deployment should show a sign-in form and nothing else -
-- no claims about Malaysian e-Invoice that its operator never made -
-- and anything on that page should be there because somebody put it
-- there.
--
-- **The copy is seeded anyway.** The switches start off, but the boxes
-- behind them start full: the headline is stored, and the three bullets
-- go into `landing_sections` as inactive rows. Turning a switch on is
-- one click and gives back exactly the page this repository has been
-- showing, rather than an empty field and a question about what used to
-- be there.
--
-- ## Why the bullets are landing_sections and not a new table
--
-- They are the same shape as the three bands the landing page already
-- has - an icon, a title, a line of body, an order and a switch - and
-- that table already has the saver, the ordering, the console card and
-- the realtime trigger. A fourth `kind` costs one check constraint. A
-- fifth table would cost all of it again.
--
-- They travel in the payload ungated, beside `brand`, because the
-- sign-in form draws whether or not a marketing site has been
-- published, and a bullet that only appears once the front page is live
-- is a bullet in the wrong place.
-- ---------------------------------------------------------------------

alter table public.landing_page
  add column if not exists signin_show_mark     boolean not null default false,
  add column if not exists signin_headline      text,
  add column if not exists signin_show_headline boolean not null default false,
  add column if not exists signin_show_heading  boolean not null default false,
  add column if not exists signin_show_register boolean not null default false;

comment on column public.landing_page.signin_show_mark is
  'Draw the logo and wordmark on the sign-in screen. A company at its '
  'own subdomain always gets its own mark regardless: that one is not '
  'the platform''s marketing.';
comment on column public.landing_page.signin_headline is
  'The large line beside the sign-in form. Null falls back to the copy '
  'the product ships with.';
comment on column public.landing_page.signin_show_headline is
  'Draw that line at all.';
comment on column public.landing_page.signin_show_heading is
  'Draw "Welcome back" and the sentence under it. The wording comes '
  'from site_pages(''signin'') and site_pages(''signup'').';
comment on column public.landing_page.signin_show_register is
  'Offer "New to X? Create an account" under the button.';

-- The line this repository has been showing, kept rather than lost.
-- Only where nobody has written one, so re-running cannot overwrite an
-- operator's own words.
update public.landing_page p
   set signin_headline = 'Accounting and CRM' || chr(10)
                      || 'for Malaysian business.'
 where p.id and p.signin_headline is null;

alter table public.landing_page
  alter column signin_headline
    set default 'Accounting and CRM' || chr(10) || 'for Malaysian business.';

-- ---------------------------------------------------------------------
-- The bullets become rows
--
-- Inactive, so nothing appears until somebody turns them on, and
-- guarded so a re-run does not make a second set.
-- ---------------------------------------------------------------------
alter table public.landing_sections
  drop constraint if exists landing_sections_kind_ck;

alter table public.landing_sections
  add constraint landing_sections_kind_ck
    check (kind in ('feature', 'reason', 'badge', 'signin'));

insert into public.landing_sections (sort_order, icon, title, body,
                                     is_active, kind)
select v.sort_order, 'check', v.title, v.body, false, 'signin'
  from (values
    (10, 'LHDN e-Invoice built in',
         'Submit to MyInvois and track validation without leaving your books.'),
    (20, 'Double-entry you can trust',
         'Every invoice, bill and payment posts to a balanced ledger.'),
    (30, 'Sales and CRM together',
         'Move a deal from lead to paid invoice in one system.')
  ) as v(sort_order, title, body)
 where not exists (select 1 from public.landing_sections s
                    where s.kind = 'signin');

-- ---------------------------------------------------------------------
-- The section saver learns the fourth kind
--
-- `0319`'s body with one word added to the check and one to the message.
-- Recreated rather than left alone because it would otherwise refuse
-- 'signin' with "A block is a feature, a reason or a badge", which is a
-- confusing way for a console to fail.
-- ---------------------------------------------------------------------
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
set search_path = public, app, pg_temp as $fn$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_kind), '') is not null
     and btrim(p_kind) not in ('feature', 'reason', 'badge', 'signin') then
    raise exception 'A block is a feature, a reason, a badge or a sign-in '
                    'point. Got %', p_kind
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
$fn$;

revoke all on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) from public;
grant execute on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) to authenticated;

create or replace function app.landing_payload(p_draft boolean)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp as $$
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
               'signin_show_mark',     p.signin_show_mark,
               'signin_headline',      p.signin_headline,
               'signin_show_headline', p.signin_show_headline,
               'signin_show_heading',  p.signin_show_heading,
               'signin_show_register', p.signin_show_register)
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
$$;

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
    signin_show_mark = coalesce(
      (p_patch ->> 'signin_show_mark')::boolean, p.signin_show_mark),
    signin_headline = case when p_patch ? 'signin_headline'
                        then nullif(btrim(p_patch ->> 'signin_headline'), '')
                        else p.signin_headline end,
    signin_show_headline = coalesce(
      (p_patch ->> 'signin_show_headline')::boolean, p.signin_show_headline),
    signin_show_heading = coalesce(
      (p_patch ->> 'signin_show_heading')::boolean, p.signin_show_heading),
    signin_show_register = coalesce(
      (p_patch ->> 'signin_show_register')::boolean, p.signin_show_register),
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb)
  to authenticated;

-- `landing_payload` stays granted to nobody: both its callers are
-- SECURITY DEFINER and run as the definer.
revoke all on function app.landing_payload(boolean) from public;

-- ---------------------------------------------------------------------
-- What the product costs, worked out by the person deciding
--
-- The landing page could say what iAkauntan does and could offer a way
-- in. What it could not do is answer the question somebody actually
-- arrives with, which is what it will cost them — and the answer is not
-- one number, because the product is a core with add-ons and two
-- businesses want different ones.
--
-- So: the catalogue reaches the landing page, and the page lets somebody
-- tick what they need and watch the monthly figure add up. The prices
-- are the real ones from `platform_modules`, which is the same table the
-- billing reads, so a quote on the front page and an invoice a month
-- later cannot disagree.
--
-- ## Opt in, not out
--
-- `show_pricing` defaults to false. Publishing a price list is a
-- commercial decision and not one a migration gets to make on somebody's
-- behalf — a platform that sells by conversation would find its whole
-- rate card on its front page the day it deployed this. Off, the modules
-- come back as an empty list exactly as an unpublished page does, and
-- the section does not appear.
--
-- ## What reaches a stranger
--
-- Code, name, description, price and whether it is core. Nothing about
-- who holds it, nothing about what anybody pays — `org_modules` is not
-- touched here and the figures are the list prices any salesperson would
-- read out. Still no new function and so no new name on the anon
-- allowlist: this rides on `landing_page()`, which already takes no
-- argument and already returns only what somebody chose to publish.
-- ---------------------------------------------------------------------

alter table public.landing_page
  add column if not exists show_pricing boolean not null default false;

alter table public.landing_page
  add column if not exists pricing_heading text;

alter table public.landing_page
  add column if not exists pricing_note text;

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
    ), '[]'::jsonb),
    -- The catalogue, and only when somebody has said to publish it.
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

revoke all on function public.landing_page() from public;
grant execute on function public.landing_page() to anon, authenticated;

-- The saver, so the three new fields are reachable from the console.
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
    logo_url          = coalesce(p_patch ->> 'logo_url', p.logo_url),
    logo_dark_url     = coalesce(p_patch ->> 'logo_dark_url', p.logo_dark_url),
    wordmark          = coalesce(nullif(btrim(p_patch ->> 'wordmark'), ''), p.wordmark),
    tagline           = coalesce(p_patch ->> 'tagline', p.tagline),
    brand_colour      = coalesce(nullif(btrim(p_patch ->> 'brand_colour'), ''),
                                 p.brand_colour),
    brand_colour_dark = coalesce(nullif(btrim(p_patch ->> 'brand_colour_dark'), ''),
                                 p.brand_colour_dark),
    hero_headline     = coalesce(nullif(btrim(p_patch ->> 'hero_headline'), ''),
                                 p.hero_headline),
    hero_subhead      = coalesce(p_patch ->> 'hero_subhead', p.hero_subhead),
    hero_image_url    = coalesce(p_patch ->> 'hero_image_url', p.hero_image_url),
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

grant execute on function public.platform_save_landing_page(jsonb) to authenticated;

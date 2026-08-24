-- A draft nobody could look at.
--
-- `0290` made the landing page a CMS and gated everything it returns on
-- `is_published`, which is right: a site whose half-written sentence is
-- visible the moment it is typed is worse than no site. `0317` added
-- three more collections behind the same gate.
--
-- What neither did was give the person writing the draft any way to see
-- it. The console shows a list of rows in a form; the page shows the
-- published copy or the built-in fallback. Between typing a testimonial
-- and publishing the site there is no state in which anybody can look
-- at the thing they are making.
--
-- Found the way these things are found: asked to see a stats band and a
-- testimonial band, the only two ways to do it were to publish invented
-- copy to the open internet or to unpublish and see nothing at all.
--
-- ## One body, two doors
--
-- The temptation is a second function that returns "roughly what the
-- page returns, ignoring publishing". That function drifts within a
-- release: somebody adds a key to `landing_page()`, forgets the
-- preview, and the preview quietly stops showing what the page will
-- show — which makes it worse than no preview, because it is trusted.
--
-- So the payload moves into `app.landing_payload(boolean)` and both
-- doors call it. `landing_page()` passes false and is what it always
-- was, byte for byte. `platform_landing_preview()` passes true and is
-- refused to anybody who is not a platform administrator. A key added
-- in future is added once and both doors carry it, which is the only
-- arrangement in which a preview can be believed.
--
-- ## The gate is not weakened
--
-- `p_draft` is not a parameter a caller chooses. `landing_page()` hard
-- codes false and takes no arguments, so there is no value an anonymous
-- visitor can pass to see a draft. The only route to true is through
-- the admin check below.

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
    -- Never gated, published or not. See `0316`: branding a product is
    -- not publishing a website.
    'brand', coalesce((
      select jsonb_build_object(
               'logo_url',          p.logo_url,
               'logo_dark_url',     p.logo_dark_url,
               'wordmark',          p.wordmark,
               'brand_colour',      p.brand_colour,
               'brand_colour_dark', p.brand_colour_dark,
               'theme_mode',        p.theme_mode,
               'app_icon_url',      p.app_icon_url)
        from public.landing_page p
    ), '{}'::jsonb),
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
    -- The catalogue, and only when somebody has said to publish it.
    -- `show_pricing` is still the operator's decision in a preview; what
    -- the draft flag lifts is publishing, not every switch on the page.
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

comment on function app.landing_payload(boolean) is
  'The landing page payload. False is what a stranger gets; true ignores publishing and is reachable only through platform_landing_preview, which checks for a platform administrator. Two doors, one body, so a preview cannot drift from the page it claims to preview.';

-- ---------------------------------------------------------------------
-- The public door, unchanged in what it returns
-- ---------------------------------------------------------------------
create or replace function public.landing_page()
returns jsonb
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
  select app.landing_payload(false);
$$;

-- ---------------------------------------------------------------------
-- The private one
-- ---------------------------------------------------------------------
create or replace function public.platform_landing_preview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'A draft of the front page is only a platform '
                    'administrator''s to look at'
      using errcode = '42501';
  end if;
  return app.landing_payload(true);
end;
$$;

-- ---------------------------------------------------------------------
-- Grants, because `create or replace` is not a no-op for privileges
--
-- `0165` installs an event trigger that strips PUBLIC and anon from
-- every function created in `public` or `app`. `landing_page()` is one
-- of the eight an unauthenticated caller may execute and `statutory.sql`
-- counts them; left out, this migration takes the front page away from
-- every visitor who has not signed in.
--
-- `app.landing_payload` is granted to nobody at all. It is called from
-- inside two SECURITY DEFINER functions, which run as the definer, so
-- no client role needs to reach it — and the one that takes `true`
-- should not be reachable except through the door that checks who is
-- knocking.
-- ---------------------------------------------------------------------
revoke all on function app.landing_payload(boolean) from public;

revoke all on function public.landing_page() from public;
grant execute on function public.landing_page() to anon, authenticated;

revoke all on function public.platform_landing_preview() from public;
grant execute on function public.platform_landing_preview() to authenticated;

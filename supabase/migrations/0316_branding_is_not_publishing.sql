-- Branding a product is not publishing a website.
--
-- `0314` put the brand on `landing_page` and `330a770` gave it a console
-- tab. Both missed that `landing_page()` returns the row only
-- `where p.is_published` — so an operator who uploads a logo, picks a
-- colour and presses Save gets nothing. The app reads that function,
-- finds `page` null, and falls back to the copy the product shipped
-- with. So does `scripts/ci/branding_icon.sh`, which then keeps the
-- shipped favicon and reports, accurately and uselessly, that no icon
-- is set.
--
-- Found the way these things are found: the branding was saved, checked
-- against the live database, and was not on the screen.
--
-- ## The two decisions are not the same decision
--
-- Publishing decides whether strangers see this company's hero copy,
-- pricing and footer instead of the built-in text. Branding decides what
-- the product looks like to the people already inside it. Tying the
-- second to the first means the only way to put your own logo on your
-- own accounting system is to also put a marketing site on the internet.
--
-- So the brand comes back always, in its own key, and everything that is
-- actually marketing stays gated exactly as it was.
--
-- ## Why a new key rather than ungating `page`
--
-- Because `page` being present is what the client reads as "an operator
-- has written this site". Returning the row unconditionally would make
-- every unpublished platform look published to the parser, and the
-- distinction would have to be reconstructed from which fields happened
-- to be null. A separate `brand` object keeps both answers exact and
-- leaves `page` byte-for-byte what it was.
--
-- `brand` is `{}` rather than null when the row does not exist yet, so
-- the client reads it the same way whether or not anybody has ever
-- opened the console.
--
-- Nothing else in the function changes: sections, store links and the
-- module catalogue keep their own `is_published` conditions.

create or replace function public.landing_page()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'page', (select to_jsonb(p) - 'updated_by' - 'id'
               from public.landing_page p where p.is_published),
    -- Not gated. See the note above this function.
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

-- Re-granted, because `create or replace` is not a no-op for privileges
-- here: `0165` installs an event trigger that strips PUBLIC and anon
-- from every function created in `public` or `app`. A grant to
-- `authenticated` survives; anon does not.
--
-- Left out, this migration takes the front page away from everybody who
-- is not signed in — which is the entire audience for a landing page.
-- `statutory.sql` counts the functions anon is meant to reach and caught
-- it at seven of eight.
revoke all on function public.landing_page() from public;
grant execute on function public.landing_page() to anon, authenticated;

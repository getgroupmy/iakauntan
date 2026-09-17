-- The saver could not save.
--
-- `platform_save_landing_page` has updated `landing_page` with no `where`
-- clause since `0294`, and `0314` re-created it verbatim and kept it.
-- Against production that raises
--
--   PostgrestException(message: UPDATE requires a WHERE clause, code: 21000)
--
-- and the Branding tab and the Landing page tab both fail on Save. This
-- adds the clause. Nothing else about the function changes.
--
-- ## Why an unqualified UPDATE was ever written
--
-- Because `landing_page` cannot hold more than one row. Its primary key
-- is `id boolean` and `landing_page_singleton` is `check (id)`, so `true`
-- is the only value it will accept. `where p.id` and no clause at all
-- therefore select exactly the same row, and the omission was invisible
-- in every environment that does not object to it on principle.
--
-- Supabase objects on principle. It loads `pg_safeupdate` for the client
-- roles, which refuses any UPDATE or DELETE without a WHERE — a blanket
-- rule, and a good one for a multi-tenant database, applied whether or
-- not the particular statement could have done any harm. `security
-- definer` does not exempt a function from it: the guard is a session
-- setting belonging to the role that called in, not to the role the
-- function runs as.
--
-- ## Why the tests did not catch it
--
-- Worth writing down, because it is the second time this shape of gap
-- has bitten and it will not be the last.
--
-- `branding.sql` calls this function twenty-three times and every call
-- passes locally. The no-Docker harness in `scripts/localdb/` is plain
-- Postgres with a shim; `pg_safeupdate` is not available to install, so
-- the guard that rejects this statement simply is not there. The
-- assertions were all true. They were true about a database that is not
-- the one the product runs on.
--
-- Nor can the fix be asserted behaviourally, and the singleton constraint
-- is the reason: with one row possible, a scoped UPDATE and an unscoped
-- one do the same thing, so no observation distinguishes them. What
-- `branding.sql` gains instead is a structural check — that the statement
-- carries a WHERE at all — which is the only form of this that can be
-- checked without the extension. It is narrow on purpose and says so.

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
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  where p.id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;


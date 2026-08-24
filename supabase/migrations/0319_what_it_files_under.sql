-- What it files under, said under the hero.
--
-- A landing page for accounting software is asked one question before
-- any other: does this handle what I actually have to submit. The page
-- answered it eight blocks down, inside feature copy.
--
-- So a third kind of block, drawn as a strip directly under the hero:
-- LHDN e-Invoice, SST, EPF, SOCSO, EIS, PCB, SSM. Short, no body copy,
-- a row of them.
--
-- ## Why these are defaults and stats are not
--
-- The same test `0317` applied, and it lands the other way here.
--
-- "MyInvois e-Invoice" on this page is a claim that the software
-- submits to MyInvois, which is checkable from `supabase/functions` and
-- asserted in `supabase/tests/einvoice_statutory.sql`. "EPF, SOCSO, EIS
-- and PCB" is a claim about arithmetic that `statutory.sql` fails CI
-- over if it moves. Those are claims about this repository, and this
-- repository is the evidence.
--
-- A customer count or a testimonial is a claim about the world, which
-- nobody here can check and nobody here should make on an operator's
-- behalf. That is why `landing_stats` ships empty and this ships full.
--
-- ## Not a certification badge
--
-- Worth being explicit, because a "trust strip" on a SaaS page usually
-- means ISO 27001, SOC 2, PCI DSS — and those are audits somebody
-- either passed or did not. Nothing here asserts one. Every entry names
-- a Malaysian statutory regime the software files under, which is a
-- statement about features. If a platform later holds a real
-- certification the operator can add it, and it will be true because
-- they added it.
--
-- ## A third kind rather than a fourth table
--
-- `landing_sections.kind` already carries `feature` and `reason`.
-- `badge` is the same shape again — icon, short title, order — so it
-- reuses the saver `0317` recreated, the policies, the realtime
-- publication and the console card. `landing_page()` splits it out the
-- way it already splits reasons.

alter table public.landing_sections
  drop constraint if exists landing_sections_kind_ck;

alter table public.landing_sections
  add constraint landing_sections_kind_ck
  check (kind in ('feature', 'reason', 'badge'));

comment on column public.landing_sections.kind is
  'feature = the grid of what the product does; reason = the short list '
  'of why to choose it; badge = the strip under the hero naming what it '
  'files under. Same shape, three places on the page.';

-- ---------------------------------------------------------------------
-- The saver learns the third kind
--
-- Recreated rather than replaced only for the check: leaving `0317`'s
-- version in place would refuse `badge` with "A block is a feature or a
-- reason", which is a confusing way for a console to fail.
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
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_kind), '') is not null
     and btrim(p_kind) not in ('feature', 'reason', 'badge') then
    raise exception 'A block is a feature, a reason or a badge. Got %', p_kind
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
$$;

-- ---------------------------------------------------------------------
-- And the payload carries the strip
--
-- `0318`'s body with one collection added, so both doors — the public
-- page and the administrator's preview — get it without either being
-- edited again. That is what the shared body is for.
-- ---------------------------------------------------------------------
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

-- `0165` strips PUBLIC and anon from every function created in `public`
-- or `app`, so the grants go back on. `app.landing_payload` stays
-- granted to nobody: both callers are SECURITY DEFINER and run as the
-- definer.
revoke all on function app.landing_payload(boolean) from public;

revoke all on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) from public;
grant execute on function public.platform_save_landing_section(
  uuid, text, text, text, integer, boolean, text) to authenticated;

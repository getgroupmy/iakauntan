-- =====================================================================
-- iAkauntan :: the platform's own branding
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/branding.sql
--
-- 0314 adds `app_icon_url` and `theme_mode` to `landing_page`, and
-- changes how the saver treats the three fields an uploader can take
-- back.
--
-- Its own file rather than more blocks in `landing_page.sql` for a dull
-- reason worth saying out loud: that file has a block that fails on the
-- no-Docker local harness, and everything after a failed block in a
-- single-transaction test file never runs. Assertions that cannot be run
-- locally are assertions written blind.
--
-- What is asserted:
--
--   * absent, present, empty and null are four different things to the
--     saver, and only two of them mean "leave it alone";
--   * a logo can be removed, which before 0314 it could not be;
--   * the fields that refuse to be blanked still refuse;
--   * `theme_mode` takes the three schemes and nothing else;
--   * both new columns reach the client through `landing_page()`
--     without anybody having listed them there;
--   * and none of it is reachable without being a platform admin.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A signed-in platform admin, and a page in a known state.
create or replace function pg_temp.brand_admin()
returns uuid language plpgsql as $$
declare v_admin uuid := pg_temp.test_user();
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  delete from public.landing_page;
  insert into public.landing_page (id, logo_url, wordmark, is_published)
  values (true, 'https://example.test/old.png', 'iAkauntan', true);

  return v_admin;
end $$;

-- Whatever the saver says the page holds now, for one field.
--
-- `->>` and not `->`, so the value comes back as text: `check_eq` has
-- overloads for text, numeric and uuid and none for jsonb, and a
-- cleared field then reads as a plain NULL rather than as the string
-- "null", which is a different thing and the one this file is about.
create or replace function pg_temp.saved(p_patch jsonb, p_field text)
returns text language sql as $$
  select public.platform_save_landing_page(p_patch) ->> p_field;
$$;

-- ---------------------------------------------------------------------
-- Absent, present, empty, null
--
-- The whole point of 0314's change. Before it, every field was
-- `coalesce(p_patch ->> 'x', p.x)`, and because `->>` cannot tell an
-- absent key from a JSON null, a logo could only ever be replaced —
-- never removed. Four cases because there are four, and two of them
-- used to collapse into one.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.brand_admin();

  perform pg_temp.check_eq('a patch that does not mention the logo leaves it',
    pg_temp.saved('{"tagline":"Books that balance"}', 'logo_url'),
    'https://example.test/old.png');

  perform pg_temp.check_eq('and the field it did mention was saved',
    pg_temp.saved('{}', 'tagline'), 'Books that balance');

  perform pg_temp.check_eq('a logo that is named is replaced',
    pg_temp.saved('{"logo_url":"https://example.test/new.png"}', 'logo_url'),
    'https://example.test/new.png');

  -- What an uploader's "remove" button sends.
  perform pg_temp.check_eq('an empty string takes the logo away',
    pg_temp.saved('{"logo_url":""}', 'logo_url'), null);

  perform pg_temp.check_eq('and so does an explicit null',
    pg_temp.saved('{"logo_url":"https://example.test/a.png"}', 'logo_url'),
    'https://example.test/a.png');
  perform pg_temp.check_eq('  — the case that was impossible before 0314',
    pg_temp.saved('{"logo_url":null}', 'logo_url'), null);

  -- The dark logo and the hero image took the same change.
  perform pg_temp.check_eq('the dark logo can be removed too',
    pg_temp.saved('{"logo_dark_url":null}', 'logo_dark_url'), null);
  perform pg_temp.check_eq('and the hero image',
    pg_temp.saved('{"hero_image_url":null}', 'hero_image_url'), null);
end $$;

-- ---------------------------------------------------------------------
-- What still refuses to be blanked
--
-- A product with no wordmark is not a product with an empty wordmark,
-- it is a bug. Those fields were deliberately left on the old
-- semantics, and this is what says the change did not leak into them.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.brand_admin();

  perform pg_temp.check_eq('an empty wordmark is refused, not stored',
    pg_temp.saved('{"wordmark":""}', 'wordmark'), 'iAkauntan');
  perform pg_temp.check_eq('and a null one is too',
    pg_temp.saved('{"wordmark":null}', 'wordmark'), 'iAkauntan');

  perform pg_temp.check_eq('a real one still goes in',
    pg_temp.saved('{"wordmark":"Akaun Saya"}', 'wordmark'), 'Akaun Saya');
end $$;

-- ---------------------------------------------------------------------
-- The scheme a visitor gets before choosing one
-- ---------------------------------------------------------------------
do $$
declare v_refused boolean := false;
begin
  perform pg_temp.brand_admin();

  perform pg_temp.check_eq('a fresh page defaults to the system scheme',
    pg_temp.saved('{}', 'theme_mode'), 'system');

  perform pg_temp.check_eq('and can be pinned to dark',
    pg_temp.saved('{"theme_mode":"dark"}', 'theme_mode'), 'dark');
  perform pg_temp.check_eq('and to light',
    pg_temp.saved('{"theme_mode":"light"}', 'theme_mode'), 'light');

  -- Refused by the saver with a message somebody can act on, rather
  -- than reaching the check constraint and surfacing as "23514".
  begin
    perform public.platform_save_landing_page('{"theme_mode":"midnight"}');
  exception when sqlstate '22023' then
    v_refused := true;
  end;
  perform pg_temp.check_true('a scheme nobody implemented is refused',
    v_refused);
  perform pg_temp.check_eq('and the old one is still standing',
    pg_temp.saved('{}', 'theme_mode'), 'light');

  -- The constraint is the backstop under the message, and it is what
  -- would stop a direct write if one ever got past the saver.
  perform pg_temp.check_true('with a check constraint behind it',
    exists (select 1 from pg_constraint
             where conname = 'landing_page_theme_mode_ck'));
end $$;

-- ---------------------------------------------------------------------
-- Both columns reach the client for free
--
-- `landing_page()` returns `to_jsonb(p)`, so it did not have to be
-- taught the new fields. This is the assertion that keeps that true: if
-- somebody ever replaces it with an explicit column list, this fails
-- rather than the console quietly losing the icon.
-- ---------------------------------------------------------------------
do $$
declare v_page jsonb;
begin
  perform pg_temp.brand_admin();
  perform public.platform_save_landing_page(jsonb_build_object(
    'app_icon_url', 'https://example.test/icon.png',
    'theme_mode', 'dark',
    'brand_colour', '#0B7A6B'));

  v_page := public.landing_page() -> 'page';

  perform pg_temp.check_eq('the icon reaches the client',
    v_page ->> 'app_icon_url', 'https://example.test/icon.png');
  perform pg_temp.check_eq('and the scheme',
    v_page ->> 'theme_mode', 'dark');
  perform pg_temp.check_eq('beside the colour that was already there',
    v_page ->> 'brand_colour', '#0B7A6B');

  -- The icon can be taken back as well.
  perform pg_temp.check_eq('and the icon can be removed',
    pg_temp.saved('{"app_icon_url":null}', 'app_icon_url'), null);
end $$;

-- ---------------------------------------------------------------------
-- A colour is six hex digits after a hash
--
-- 0294's validation, re-asserted here because 0314 re-creates the
-- function it lives in. A verbatim re-creation that quietly dropped it
-- would leave the console able to write `red` into a field the theme
-- parses as a colour.
-- ---------------------------------------------------------------------
do $$
declare v_refused boolean := false;
begin
  perform pg_temp.brand_admin();
  begin
    perform public.platform_save_landing_page('{"brand_colour":"teal"}');
  exception when sqlstate '22023' then
    v_refused := true;
  end;
  perform pg_temp.check_true('a colour that is not hex is refused',
    v_refused);
end $$;

-- ---------------------------------------------------------------------
-- And none of it belongs to anybody who is not running the platform
-- ---------------------------------------------------------------------
do $$
declare v_user uuid; v_refused boolean := false;
begin
  perform pg_temp.brand_admin();
  v_user := pg_temp.another_user('bukan-admin@branding.test');
  perform pg_temp.sign_in_as(v_user);

  begin
    perform public.platform_save_landing_page('{"wordmark":"Bukan Saya"}');
  exception when sqlstate '42501' then
    v_refused := true;
  end;
  perform pg_temp.check_true(
    'somebody who does not run the platform cannot rebrand it', v_refused);
end $$;

-- ---------------------------------------------------------------------
-- The statement is scoped
--
-- `0315`. Structural, not behavioural, and the distinction is the point:
-- `landing_page` can hold one row — `id boolean` with `check (id)` — so a
-- scoped UPDATE and an unscoped one touch the same row and no
-- observation tells them apart.
--
-- What does tell them apart is production, which loads `pg_safeupdate`
-- for the client roles and refuses an UPDATE with no WHERE outright. That
-- extension cannot be installed on this harness, so the twenty-three
-- assertions above all passed against a saver that raised
-- `21000 UPDATE requires a WHERE clause` the moment a real person pressed
-- Save.
--
-- So this reads the statement instead of running it. Narrow, and worth
-- having: it is the only form of the check available here, and the thing
-- it guards is a whole tab that does not work.
-- ---------------------------------------------------------------------
do $$
declare v_src text; v_update text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_save_landing_page';

  perform pg_temp.check_true('the saver is still there', v_src is not null);

  -- From the update to the returning that closes it, comments stripped
  -- so prose about WHERE clauses cannot satisfy the check.
  v_update := substring(
    regexp_replace(v_src, '--[^\n]*', '', 'g'),
    'update\s+public\.landing_page.*?returning');

  perform pg_temp.check_true(
    'and it updates landing_page exactly once', v_update is not null);
  perform pg_temp.check_true(
    'with a where clause, which pg_safeupdate requires in production',
    v_update ~* '\swhere\s');
end $$;

-- ---------------------------------------------------------------------
-- Branding a product is not publishing a website
--
-- `0316`. The bug this file exists to prevent, found in production after
-- the console had already saved everything correctly: `landing_page()`
-- returned the row only `where p.is_published`, so an operator who
-- uploaded a logo and picked a colour got nothing — the app fell back to
-- the shipped copy and CI kept the shipped favicon.
--
-- The two halves are asserted separately because they are two different
-- promises: the brand always comes back, and the marketing copy still
-- does not until somebody publishes it.
-- ---------------------------------------------------------------------
do $$
declare v_out jsonb;
begin
  perform pg_temp.brand_admin();
  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark',     'Akaun Saya',
    'logo_url',     'https://example.test/logo.png',
    'brand_colour', '#BE123C',
    'theme_mode',   'dark',
    'app_icon_url', 'https://example.test/icon.png',
    'hero_headline', 'A headline nobody has published',
    'is_published', false));

  v_out := public.landing_page();

  -- Unpublished, and the brand is there anyway.
  perform pg_temp.check_eq('an unpublished platform still has a wordmark',
    v_out -> 'brand' ->> 'wordmark', 'Akaun Saya');
  perform pg_temp.check_eq('and a logo',
    v_out -> 'brand' ->> 'logo_url', 'https://example.test/logo.png');
  perform pg_temp.check_eq('and its colour',
    v_out -> 'brand' ->> 'brand_colour', '#BE123C');
  perform pg_temp.check_eq('and the scheme it chose',
    v_out -> 'brand' ->> 'theme_mode', 'dark');
  perform pg_temp.check_eq('and the icon CI builds the favicon from',
    v_out -> 'brand' ->> 'app_icon_url', 'https://example.test/icon.png');

  -- And the site is still not published.
  perform pg_temp.check_true('while the page itself is still withheld',
    v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_true(
    'so the draft hero copy has not leaked into anything',
    v_out::text not like '%A headline nobody has published%');

  -- Published, and both halves arrive.
  perform public.platform_save_landing_page('{"is_published": true}');
  v_out := public.landing_page();
  perform pg_temp.check_true('publishing releases the page',
    v_out -> 'page' <> 'null'::jsonb);
  perform pg_temp.check_eq('and the brand is unchanged by it',
    v_out -> 'brand' ->> 'brand_colour', '#BE123C');
  perform pg_temp.check_eq('the hero copy arrives only now',
    v_out -> 'page' ->> 'hero_headline', 'A headline nobody has published');
end $$;

-- With no row at all, `brand` is an empty object rather than null, so a
-- client reads it the same way whether or not anybody has ever opened
-- the console.
do $$
declare v_out jsonb;
begin
  perform pg_temp.brand_admin();
  delete from public.landing_page;
  v_out := public.landing_page();
  perform pg_temp.check_eq('a platform nobody has branded yet returns {}',
    (v_out -> 'brand')::text, '{}');
end $$;

rollback;

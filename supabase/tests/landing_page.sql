-- =====================================================================
-- iAkauntan :: the front door, and who may change it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/landing_page.sql
--
-- 0290 adds the eighth function an unauthenticated caller may execute,
-- and the allowlist in `statutory.sql` exists so that adding one is a
-- decision rather than an accident. This file is the other half of that
-- decision: what `landing_page()` gives a stranger, what it withholds,
-- and that nobody but a platform administrator can change any of it.
--
-- The three things worth being careful about:
--
--   * an unpublished page is not a published one. A CMS whose draft is
--     visible the moment it is typed is worse than no CMS.
--   * the tables stay shut. The anon path is the function; a stranger
--     selecting from `landing_page` directly must get nothing.
--   * the page belongs to the platform, not to a company. It has no
--     org_id, so an ordinary owner editing it would be editing
--     everybody's front door.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Every block below starts from an empty page. They share one
-- transaction, so a section written by the block above is still there
-- for the block below to count — which is how the first draft of this
-- file came to assert two sections and find three.
create or replace function pg_temp.reset_landing()
returns void language sql as $$
  delete from public.landing_app_links;
  delete from public.landing_sections;
  delete from public.landing_page;
$$;

-- ---------------------------------------------------------------------
-- Nothing published, nothing shown
--
-- The page starts unpublished, and what comes back is a null page with
-- empty lists rather than an error — the site falls back to the sign-in
-- form, and the browser console does not fill with failures.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan',
    'hero_headline', 'Perakaunan untuk perniagaan Malaysia'));
  perform public.platform_save_landing_section(
    null, 'e-Invoice', 'Submitted to LHDN from the invoice screen.');
  perform public.platform_save_landing_app_link(
    'app_store', 'App Store', 'https://apps.apple.com/my/app/iakauntan/id1');

  v_out := public.landing_page();
  perform pg_temp.check_true('an unpublished page comes back as nothing at all',
    v_out -> 'page' = 'null'::jsonb);
  -- And the drafted copy does not leak through the lists, which is the
  -- part that would actually publish somebody's half-written sentence.
  perform pg_temp.check_eq('and its sections are withheld with it',
    jsonb_array_length(v_out -> 'sections'), 0);
  perform pg_temp.check_eq('and its store links too',
    jsonb_array_length(v_out -> 'app_links'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Published, and what a stranger gets
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_role text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan',
    'tagline', 'Kira, bukan agak',
    'hero_headline', 'Perakaunan untuk perniagaan Malaysia',
    'logo_url', 'https://cdn.iakauntan.test/logos/mark.png',
    'support_email', 'sokongan@iakauntan.test',
    'is_published', true));
  perform public.platform_save_landing_section(
    null, 'e-Invoice', 'Submitted to LHDN from the invoice screen.', 'receipt', 10);
  perform public.platform_save_landing_section(
    null, 'Payroll', 'EPF, SOCSO, EIS and PCB, worked out for you.', 'payments', 20);
  perform public.platform_save_landing_app_link(
    'app_store', 'App Store', 'https://apps.apple.com/my/app/iakauntan/id1',
    null, 20);
  perform public.platform_save_landing_app_link(
    'play_store', 'Google Play',
    'https://play.google.com/store/apps/details?id=my.iakauntan', null, 10);

  -- Read it as a stranger: no JWT at all, and the anon role.
  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_role := current_user;
    v_out := public.landing_page();
  end;
  reset role;

  perform pg_temp.check_true('the page was read as an anonymous visitor',
    v_role = 'anon');
  perform pg_temp.check_eq('the wordmark reaches them',
    v_out -> 'page' ->> 'wordmark', 'iAkauntan');
  perform pg_temp.check_eq('and the headline',
    v_out -> 'page' ->> 'hero_headline',
    'Perakaunan untuk perniagaan Malaysia');
  perform pg_temp.check_eq('and the logo to put at the top of it',
    v_out -> 'page' ->> 'logo_url', 'https://cdn.iakauntan.test/logos/mark.png');
  perform pg_temp.check_eq('both sections', jsonb_array_length(v_out -> 'sections'), 2);
  perform pg_temp.check_eq('both store links',
    jsonb_array_length(v_out -> 'app_links'), 2);

  -- Ordered by sort_order, not by insertion or by name: the shop the
  -- most customers use goes first, and the console decides which.
  perform pg_temp.check_eq('the store links come in the order somebody chose',
    v_out -> 'app_links' -> 0 ->> 'store_code', 'play_store');
  perform pg_temp.check_eq('the sections likewise',
    v_out -> 'sections' -> 0 ->> 'title', 'e-Invoice');

  -- Who edited it is not a stranger's business, and neither is the
  -- singleton key.
  perform pg_temp.check_true('who last edited it is not published',
    not (v_out -> 'page' ? 'updated_by'));
  perform pg_temp.check_true('nor the row''s own key',
    not (v_out -> 'page' ? 'id'));
end $$;

-- ---------------------------------------------------------------------
-- A section switched off is off, and so is a store link
--
-- Separate from the whole page being unpublished: this is the ordinary
-- case of retiring one block of copy or one shop without taking the
-- site down.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_section uuid; v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(jsonb_build_object('is_published', true));
  v_section := public.platform_save_landing_section(
    null, 'Coming soon', 'Not finished.', null, 30);
  perform public.platform_save_landing_app_link(
    'appgallery', 'AppGallery', 'https://appgallery.huawei.com/app/C1', null, 30);

  v_out := public.landing_page();
  perform pg_temp.check_eq('a live section is on the page',
    (select count(*) from jsonb_array_elements(v_out -> 'sections') e
      where e ->> 'title' = 'Coming soon'), 1);

  perform public.platform_save_landing_section(v_section, null, null, null, null, false);
  perform public.platform_save_landing_app_link(
    'appgallery', null, null, null, null, false);
  v_out := public.landing_page();
  perform pg_temp.check_eq('and once switched off it is not',
    (select count(*) from jsonb_array_elements(v_out -> 'sections') e
      where e ->> 'title' = 'Coming soon'), 0);
  perform pg_temp.check_eq('nor is a retired store',
    (select count(*) from jsonb_array_elements(v_out -> 'app_links') e
      where e ->> 'store_code' = 'appgallery'), 0);

  -- Deleting is the other way, and it says whether it found anything.
  perform pg_temp.check_true('deleting a section reports that it went',
    public.platform_delete_landing_section(v_section));
  perform pg_temp.check_true('and deleting it twice reports that it did not',
    not public.platform_delete_landing_section(v_section));
  perform pg_temp.check_true('a store link deletes the same way',
    public.platform_delete_landing_app_link('appgallery'));
  perform pg_temp.check_true('and says so when there was nothing to delete',
    not public.platform_delete_landing_app_link('appgallery'));
end $$;

-- ---------------------------------------------------------------------
-- The tables stay shut
--
-- The anonymous path is the function and only the function. A stranger
-- reading the tables directly is refused outright — there is no select
-- grant to anon at all, so this never reaches row level security. Worth
-- asserting as the refusal it is rather than as an empty result: the
-- first draft of this block expected zero rows, which would also have
-- passed had somebody later granted select and left an over-permissive
-- policy behind it.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_role text;
  v_page boolean := false; v_sections boolean := false; v_links boolean := false;
  v_n integer;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(jsonb_build_object('is_published', true));
  perform public.platform_save_landing_section(null, 'Visible', 'Published.');

  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  begin
    select count(*) into v_n from public.landing_page;
  exception when insufficient_privilege then v_page := true;
  end;
  begin
    select count(*) into v_n from public.landing_sections;
  exception when insufficient_privilege then v_sections := true;
  end;
  begin
    select count(*) into v_n from public.landing_app_links;
  exception when insufficient_privilege then v_links := true;
  end;
  reset role;

  perform pg_temp.check_true('the test ran as an anonymous visitor', v_role = 'anon');
  perform pg_temp.check_true('the page table is shut to a stranger', v_page);
  perform pg_temp.check_true('and the sections table', v_sections);
  perform pg_temp.check_true('and the links table', v_links);

  -- And the function is still the way through, so this is a closed door
  -- rather than a broken one.
  perform pg_temp.sign_out();
  set local role anon;
  v_n := jsonb_array_length(public.landing_page() -> 'sections');
  reset role;
  perform pg_temp.check_eq('while the function still answers', v_n, 1);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator writes it
--
-- The page has no org_id. A company owner editing it would be editing
-- every other company's front door, which is the same argument
-- `platform_publish_statutory_schedule` makes about rate tables.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org uuid := pg_temp.test_org('Syarikat Biasa');
  v_ok boolean;
begin
  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  perform pg_temp.sign_in_as(v_owner);

  v_ok := false;
  begin
    perform public.platform_save_landing_page(jsonb_build_object('wordmark', 'Mine'));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an ordinary owner cannot rewrite the page', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_section(null, 'Mine', 'Mine');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor add a section', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_app_link('play_store', 'X', 'https://x.test');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor point a store button somewhere else', v_ok);

  v_ok := false;
  begin
    perform public.platform_delete_landing_app_link('play_store');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor take one away', v_ok);

  v_ok := false;
  begin
    perform public.platform_delete_landing_section(gen_random_uuid());
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor delete a section', v_ok);

  -- And the refusal is a refusal, not a no-op that happened to change
  -- nothing: the wordmark is still what the administrator set.
  perform pg_temp.check_true('the page is as the administrator left it',
    (select wordmark <> 'Mine' from public.landing_page));
end $$;

-- ---------------------------------------------------------------------
-- A store button that goes nowhere
--
-- Worse than an absent one: the visitor taps it, nothing happens, and
-- they decide the product is broken. Refused by name rather than by
-- constraint, so somebody pasting a link into a form is told what is
-- wrong with what they pasted.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_ok boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  v_ok := false;
  begin
    perform public.platform_save_landing_app_link(
      'play_store', 'Google Play', 'play.google.com/store/apps');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a store link without a scheme is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_app_link('', 'Nowhere', 'https://x.test');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and a link that does not say which store', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_section(null, '   ', 'No title');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a section with no title is refused', v_ok);

  -- Saving the same store twice updates it rather than making a second
  -- button for the same shop.
  perform public.platform_save_landing_app_link(
    'play_store', 'Google Play', 'https://play.google.com/store/apps/details?id=a');
  perform public.platform_save_landing_app_link(
    'play_store', null, 'https://play.google.com/store/apps/details?id=b');
  perform pg_temp.check_eq('one shop is one button',
    (select count(*) from public.landing_app_links where store_code = 'play_store'), 1);
  perform pg_temp.check_eq('and the second save moved it',
    (select url from public.landing_app_links where store_code = 'play_store'),
    'https://play.google.com/store/apps/details?id=b');
  perform pg_temp.check_eq('while leaving the label it did not mention',
    (select label from public.landing_app_links where store_code = 'play_store'),
    'Google Play');
end $$;

-- ---------------------------------------------------------------------
-- There is one page
--
-- The singleton is enforced by the key rather than by everybody
-- remembering, because two rows would mean two front doors and
-- `landing_page()` picking whichever the heap offered.
-- ---------------------------------------------------------------------
do $$
declare v_ok boolean := false;
begin
  -- The block above left the page in whatever state its last refusal
  -- did, so put one row there deliberately rather than assuming.
  insert into public.landing_page (id) values (true) on conflict (id) do nothing;
  begin
    insert into public.landing_page (id) values (true);
  exception when unique_violation then v_ok := true;
  end;
  perform pg_temp.check_true('a second landing page cannot be created', v_ok);
  perform pg_temp.check_eq('and there is exactly one',
    (select count(*) from public.landing_page), 1);
end $$;

rollback;

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
  -- 0317's three. Left out of this list they would survive into the
  -- next block, which is how the first draft of this file came to
  -- assert two sections and find three.
  delete from public.landing_stats;
  delete from public.landing_testimonials;
  delete from public.landing_logos;
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

-- ---------------------------------------------------------------------
-- The price list, and the switch that keeps it off the front page
--
-- 0294 lets the landing page carry the catalogue so a visitor can tick
-- what they need and watch the monthly figure add up. Two things have
-- to hold, and neither is obvious from reading the function:
--
--   * publishing a rate card is a commercial decision. A platform that
--     sells by conversation would find its whole price list on its front
--     page the day this deployed, so `show_pricing` is off until
--     somebody turns it on, and off means an empty list rather than a
--     hidden section.
--   * the figures are list prices and nothing else. `org_modules` says
--     what a named company holds and what it was charged; none of that
--     is a stranger's business, and the way to be sure is to assert the
--     keys rather than to read the function and be satisfied.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_role text; v_entry jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan', 'is_published', true));

  -- Published, and the price list still not published.
  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_true('a published page is a published page',
    v_out -> 'page' <> 'null'::jsonb);
  perform pg_temp.check_eq('and it carries no prices until somebody says so',
    jsonb_array_length(v_out -> 'modules'), 0);

  -- Turn it on.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(jsonb_build_object(
    'show_pricing', true,
    'pricing_heading', 'Bayar untuk apa yang anda guna',
    'pricing_note', 'Harga sebulan, tidak termasuk SST.'));

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_role := current_user;
    v_out := public.landing_page();
  end;
  reset role;

  perform pg_temp.check_true('the price list was read as an anonymous visitor',
    v_role = 'anon');
  perform pg_temp.check_eq('the heading somebody wrote reaches them',
    v_out -> 'page' ->> 'pricing_heading', 'Bayar untuk apa yang anda guna');
  perform pg_temp.check_eq('and the small print under it',
    v_out -> 'page' ->> 'pricing_note', 'Harga sebulan, tidak termasuk SST.');
  perform pg_temp.check_eq('the catalogue is the one in platform_modules',
    jsonb_array_length(v_out -> 'modules'),
    (select count(*) from public.platform_modules where is_active));
  perform pg_temp.check_true('and there is something in it',
    jsonb_array_length(v_out -> 'modules') > 0);

  -- Core first, because those are what keeping books is rather than an
  -- add-on, and the picker counts them whether they were ticked or not.
  perform pg_temp.check_true('what the price includes comes first',
    (v_out -> 'modules' -> 0 ->> 'is_core')::boolean);

  -- The list price, not what anybody negotiated.
  select e into v_entry from jsonb_array_elements(v_out -> 'modules') e
   where e ->> 'code' = 'einvoice';
  perform pg_temp.check_eq('a module carries the price the billing reads',
    (v_entry ->> 'monthly_price')::numeric,
    (select monthly_price from public.platform_modules where code = 'einvoice'));

  -- Five keys, and the list of them is the assertion. Adding a sixth
  -- has to be a deliberate act, the same way adding a name to the anon
  -- allowlist is: `org_modules` knows which company holds what and what
  -- it actually paid, and none of that belongs on a front page.
  perform pg_temp.check_eq('and nothing else about it',
    (select string_agg(k, ',' order by k)
       from jsonb_object_keys(v_out -> 'modules' -> 0) k),
    'code,description,is_core,monthly_price,name');
end $$;

-- ---------------------------------------------------------------------
-- Two switches, and the page one governs both
--
-- `show_pricing` is not a way to publish a price list on an unpublished
-- page. A platform administrator drafting a rate card before launch
-- would otherwise have the rates readable by anybody who called the
-- function, while the page they belong to was still nobody's business.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_priced integer;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan', 'show_pricing', true, 'is_published', false));

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_true('the page is withheld',
    v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_eq('and the rates drafted for it with it',
    jsonb_array_length(v_out -> 'modules'), 0);

  -- A module switched off is off. The console keeps retired modules in
  -- the table so the companies still holding one keep working; the
  -- front page must not go on offering it.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(jsonb_build_object('is_published', true));
  perform public.platform_save_module('einvoice', p_is_active => false);

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  select count(*) into v_priced from jsonb_array_elements(v_out -> 'modules') e
   where e ->> 'code' = 'einvoice';
  perform pg_temp.check_eq('a retired module is not sold on the front page',
    v_priced, 0);

  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_module('einvoice', p_is_active => true);
end $$;


-- ---------------------------------------------------------------------
-- 0317: the three collections that ship empty, and stay empty
--
-- `landing_stats`, `landing_testimonials` and `landing_logos` carry
-- claims about the world — how many customers a platform has, what a
-- named person at a named company said about it, whose mark may appear
-- on the page. None of those is the software's to assert on an
-- operator's behalf, so the migration seeds nothing and the client
-- defaults nothing.
--
-- That is a property worth asserting rather than trusting, because the
-- failure is silent and expensive: a seed row added later "just as an
-- example" is a fabricated endorsement on a page that asks people for
-- money, and nobody reading the front page can tell the difference.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the product ships no customer figures',
    (select count(*) from public.landing_stats), 0);
  perform pg_temp.check_eq('and no testimonials',
    (select count(*) from public.landing_testimonials), 0);
  perform pg_temp.check_eq('and nobody else''s logo',
    (select count(*) from public.landing_logos), 0);
end $$;

-- ---------------------------------------------------------------------
-- What a stranger gets from the new collections
--
-- Same gate as the sections: written by an administrator, withheld
-- while the page is a draft, ordered by what somebody chose, and read
-- back as `anon` rather than as the superuser the rest of this file
-- would otherwise be.
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

  -- Drafted first, deliberately: everything below is written while the
  -- page is unpublished, so the withholding is tested against rows that
  -- exist rather than against an empty table that would pass anyway.
  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan', 'is_published', false));
  perform public.platform_save_landing_stat(
    null, '240,000', 'Businesses', 'store', 20);
  perform public.platform_save_landing_stat(
    null, '30', 'Years', 'schedule', 10);
  perform public.platform_save_landing_testimonial(
    null, 'The payroll run stopped being a week of my month.',
    'Siti Nurhaliza binti Rahman', 'Kedai Runcit Seri Muda', null, 10);
  perform public.platform_save_landing_logo(
    null, 'Sinar Teknologi', 'https://cdn.iakauntan.test/logos/sinar.png', 10);
  perform public.platform_save_landing_section(
    null, 'Support in your language', 'Bahasa Melayu and English.',
    'support', 10, null, 'reason');

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;

  perform pg_temp.check_true('a drafted page is still a draft',
    v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_eq('and the figures drafted for it are withheld',
    jsonb_array_length(v_out -> 'stats'), 0);
  perform pg_temp.check_eq('and the testimonials',
    jsonb_array_length(v_out -> 'testimonials'), 0);
  perform pg_temp.check_eq('and the customer logos',
    jsonb_array_length(v_out -> 'logos'), 0);
  perform pg_temp.check_eq('and the reasons to choose it',
    jsonb_array_length(v_out -> 'reasons'), 0);

  -- Publish, and read it as a stranger again.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_role := current_user;
    v_out := public.landing_page();
  end;
  reset role;

  perform pg_temp.check_true('the collections were read as a visitor',
    v_role = 'anon');
  perform pg_temp.check_eq('both figures reach them',
    jsonb_array_length(v_out -> 'stats'), 2);
  perform pg_temp.check_eq('in the order somebody chose, not the order typed',
    v_out -> 'stats' -> 0 ->> 'label', 'Years');
  perform pg_temp.check_eq('a figure keeps the formatting it was given',
    v_out -> 'stats' -> 1 ->> 'value', '240,000');
  perform pg_temp.check_eq('the testimonial reaches them',
    v_out -> 'testimonials' -> 0 ->> 'quote',
    'The payroll run stopped being a week of my month.');
  perform pg_temp.check_eq('with the name that stands behind it',
    v_out -> 'testimonials' -> 0 ->> 'author',
    'Siti Nurhaliza binti Rahman');
  perform pg_temp.check_eq('and the logo',
    v_out -> 'logos' -> 0 ->> 'logo_url',
    'https://cdn.iakauntan.test/logos/sinar.png');

  -- The two kinds are the same table and two places on the page. A
  -- reason landing in `sections` would put "Support in your language"
  -- in the feature grid, which is where this would go wrong quietly.
  perform pg_temp.check_eq('a reason is a reason',
    jsonb_array_length(v_out -> 'reasons'), 1);
  perform pg_temp.check_eq('and not a feature',
    jsonb_array_length(v_out -> 'sections'), 0);
  perform pg_temp.check_eq('and it is the one that was written',
    v_out -> 'reasons' -> 0 ->> 'title', 'Support in your language');

  -- A block saved without saying which kind is a feature, which is what
  -- every row written before 0317 is.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_section(
    null, 'Double-entry accounting', 'A ledger that balances.', 'payments', 20);
  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_eq('a block that did not say is a feature',
    jsonb_array_length(v_out -> 'sections'), 1);
  perform pg_temp.check_eq('and it did not join the reasons',
    jsonb_array_length(v_out -> 'reasons'), 1);
end $$;

-- ---------------------------------------------------------------------
-- Switching one off, and taking one away
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_stat uuid; v_quote uuid; v_logo uuid; v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  v_stat  := public.platform_save_landing_stat(null, '12', 'Outlets');
  v_quote := public.platform_save_landing_testimonial(
    null, 'Stock finally ties to the ledger.', 'Lim Wei Jian', 'Kedai Besi Maju');
  v_logo  := public.platform_save_landing_logo(
    null, 'Amanah Setiausaha', 'https://cdn.iakauntan.test/logos/amanah.png');

  v_out := public.landing_page();
  perform pg_temp.check_eq('all three are on the page',
    jsonb_array_length(v_out -> 'stats')
      + jsonb_array_length(v_out -> 'testimonials')
      + jsonb_array_length(v_out -> 'logos'), 3);

  perform public.platform_save_landing_stat(v_stat, p_is_active => false);
  perform public.platform_save_landing_testimonial(v_quote, p_is_active => false);
  perform public.platform_save_landing_logo(v_logo, p_is_active => false);

  v_out := public.landing_page();
  perform pg_temp.check_eq('a figure switched off is off',
    jsonb_array_length(v_out -> 'stats'), 0);
  perform pg_temp.check_eq('and a testimonial withdrawn is gone',
    jsonb_array_length(v_out -> 'testimonials'), 0);
  perform pg_temp.check_eq('and a customer who asked to come down is down',
    jsonb_array_length(v_out -> 'logos'), 0);

  -- Patching one field leaves the rest of the row where it was. The
  -- calls above passed nothing but `is_active`, so a coalesce written
  -- the wrong way round would have blanked the label.
  perform pg_temp.check_eq('and switching it off changed nothing else',
    (select label from public.landing_stats where id = v_stat), 'Outlets');

  perform pg_temp.check_true('deleting a figure reports that it went',
    public.platform_delete_landing_stat(v_stat));
  perform pg_temp.check_true('and twice reports that it did not',
    not public.platform_delete_landing_stat(v_stat));
  perform pg_temp.check_true('a testimonial deletes the same way',
    public.platform_delete_landing_testimonial(v_quote));
  perform pg_temp.check_true('and says so when there was nothing to delete',
    not public.platform_delete_landing_testimonial(v_quote));
  perform pg_temp.check_true('and a logo',
    public.platform_delete_landing_logo(v_logo));
  perform pg_temp.check_true('and says so the second time',
    not public.platform_delete_landing_logo(v_logo));
end $$;

-- ---------------------------------------------------------------------
-- What the savers refuse
--
-- The rule worth writing down is the testimonial's: a quote with nobody
-- against it is the exact shape an invented one takes. The database
-- cannot check that a person said a thing — that is the operator's to
-- stand behind — but it can refuse to store a page element that has no
-- name on it at all, which is the difference between a claim somebody
-- made and a claim that appeared.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_ok boolean; v_id uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  v_ok := false;
  begin
    perform public.platform_save_landing_stat(null, '240,000', '   ');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a number that does not say what it counts', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_stat(null, '', 'Businesses');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and a label with no number under it', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_testimonial(
      null, 'Best software ever.', null);
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a quote with nobody against it is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_testimonial(null, '   ', 'Somebody');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and a name with nothing said under it', v_ok);

  -- Same rule the store links have had since 0290: a relative path in a
  -- database three clients read is not an address.
  v_ok := false;
  begin
    perform public.platform_save_landing_logo(
      null, 'Sinar', '/assets/logos/sinar.png');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a logo without a scheme is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_logo(null, '  ', 'https://x.test/a.png');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and one that does not say whose it is', v_ok);

  -- And the refusal holds on the way through too, not only on creation.
  v_id := public.platform_save_landing_logo(
    null, 'Sinar', 'https://cdn.iakauntan.test/logos/sinar.png');
  v_ok := false;
  begin
    perform public.platform_save_landing_logo(v_id, null, 'sinar.png');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('editing one to a relative path is refused too', v_ok);
  perform pg_temp.check_eq('and the address it had is still there',
    (select logo_url from public.landing_logos where id = v_id),
    'https://cdn.iakauntan.test/logos/sinar.png');

  -- A block is one of two things, and a third would render nowhere.
  v_ok := false;
  begin
    perform public.platform_save_landing_section(
      null, 'Something', 'Somewhere', null, null, null, 'banner');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a block that is neither feature nor reason', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator, here too
--
-- The three new tables have no insert, update or delete policy at all,
-- so the savers are the only door. This asserts the door is locked; the
-- block below asserts there is no window.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org uuid := pg_temp.test_org('Syarikat Lain');
  v_ok boolean;
begin
  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  perform pg_temp.sign_in_as(v_owner);

  v_ok := false;
  begin
    perform public.platform_save_landing_stat(null, '1,000,000', 'Businesses');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an ordinary owner cannot post a figure', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_testimonial(
      null, 'We are the best.', 'Us');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor put words in a customer''s mouth', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_logo(
      null, 'Somebody Else', 'https://x.test/a.png');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor hang somebody else''s mark on the page', v_ok);

  v_ok := false;
  begin
    perform public.platform_delete_landing_stat(gen_random_uuid());
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor take a figure down', v_ok);

  v_ok := false;
  begin
    perform public.platform_delete_landing_testimonial(gen_random_uuid());
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor a testimonial', v_ok);

  v_ok := false;
  begin
    perform public.platform_delete_landing_logo(gen_random_uuid());
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor a logo', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- The new tables are readable and not writable
--
-- Different from `landing_page` and `landing_sections`, which are shut
-- to anon outright. These three are granted `select` so the same
-- `for select using (true)` shape as the rest of the site's public data
-- holds, and the point to assert is the other half: a stranger — or any
-- signed-in user — writing to them directly is refused, because there
-- is no policy that would let them and no grant either.
-- ---------------------------------------------------------------------
do $$
declare
  v_role text; v_table text;
  v_ins boolean; v_upd boolean; v_del boolean;
begin
  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  reset role;
  perform pg_temp.check_true('the grants were read against a real anon role',
    v_role = 'anon');

  foreach v_table in array
    array['landing_stats', 'landing_testimonials', 'landing_logos']
  loop
    perform pg_temp.check_true(
      format('%s is readable by a visitor', v_table),
      has_table_privilege('anon', 'public.' || v_table, 'select'));

    select has_table_privilege('anon', 'public.' || v_table, 'insert'),
           has_table_privilege('anon', 'public.' || v_table, 'update'),
           has_table_privilege('anon', 'public.' || v_table, 'delete')
      into v_ins, v_upd, v_del;
    perform pg_temp.check_true(
      format('and %s is not a visitor''s to write', v_table),
      not (v_ins or v_upd or v_del));

    select has_table_privilege('authenticated', 'public.' || v_table, 'insert'),
           has_table_privilege('authenticated', 'public.' || v_table, 'update'),
           has_table_privilege('authenticated', 'public.' || v_table, 'delete')
      into v_ins, v_upd, v_del;
    perform pg_temp.check_true(
      format('nor a signed-in user''s: %s', v_table),
      not (v_ins or v_upd or v_del));

    -- No write policy either, so the savers are the only door rather
    -- than the convenient one.
    perform pg_temp.check_eq(
      format('%s has exactly one policy, and it is a read', v_table),
      (select string_agg(cmd, ',' order by cmd) from pg_policies
        where schemaname = 'public' and tablename = v_table),
      'SELECT');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Somewhere to press, partway down
--
-- Four columns on `landing_page`, so they ride out on `page` and are
-- withheld with it. Nothing renders unless a headline is set, which is
-- how a platform that does not want the band simply does not get one.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  v_out := public.landing_page();
  perform pg_temp.check_true('a page with no call to action carries none',
    v_out -> 'page' ->> 'cta_headline' is null);

  perform public.platform_save_landing_page(jsonb_build_object(
    'cta_headline', 'Mula hari ini',
    'cta_body',     'Percubaan 30 hari, tiada kad kredit.',
    'cta_label',    'Cuba percuma',
    'cta_url',      'https://iakauntan.test/daftar'));

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_eq('and one that does reaches a visitor',
    v_out -> 'page' ->> 'cta_headline', 'Mula hari ini');
  perform pg_temp.check_eq('with the button''s words',
    v_out -> 'page' ->> 'cta_label', 'Cuba percuma');
  perform pg_temp.check_eq('and somewhere for it to go',
    v_out -> 'page' ->> 'cta_url', 'https://iakauntan.test/daftar');

  -- Clearing the headline is how the band comes off again. A coalesce
  -- here would put back what was cleared and the operator would have no
  -- way to remove it at all.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(
    jsonb_build_object('cta_headline', ''));
  v_out := public.landing_page();
  perform pg_temp.check_true('and clearing the headline takes it off again',
    v_out -> 'page' ->> 'cta_headline' is null);
  perform pg_temp.check_eq('while leaving what it did not mention',
    v_out -> 'page' ->> 'cta_label', 'Cuba percuma');
end $$;

-- A button the browser cannot follow, same rule as the store links.
do $$
declare v_admin uuid := pg_temp.test_user(); v_ok boolean := false;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('cta_url', '/daftar'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a call to action with no scheme is refused', v_ok);
end $$;


-- ---------------------------------------------------------------------
-- 0318: a draft somebody can look at
--
-- The gate `0290` put on this page is right and stays. What it never
-- had was a way for the person writing the draft to see it, so the only
-- ways to look at a stats band were to publish invented copy to the
-- open internet or to unpublish and see nothing.
--
-- The property that matters is not "the preview shows the draft" — that
-- is easy and would pass with a function that returns anything. It is
-- that the preview shows *what the page will show once published*. A
-- preview that drifts from the page is worse than none, because it is
-- believed. Both doors call `app.landing_payload`, and the assertion
-- below is the two payloads being equal once publishing is the only
-- difference left.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_draft jsonb; v_public jsonb; v_published jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();

  -- A whole site, written and not published.
  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'iAkauntan',
    'hero_headline', 'Perakaunan untuk perniagaan Malaysia',
    'cta_headline', 'Mula hari ini',
    'is_published', false));
  perform public.platform_save_landing_section(
    null, 'e-Invoice', 'To MyInvois.', 'receipt', 10);
  perform public.platform_save_landing_section(
    null, 'Support', 'In Bahasa Melayu.', 'support', 10, null, 'reason');
  perform public.platform_save_landing_stat(null, '30', 'Years', 'schedule', 10);
  perform public.platform_save_landing_testimonial(
    null, 'The payroll run stopped being a week of my month.',
    'Lim Wei Jian', 'Kedai Besi Maju');
  perform public.platform_save_landing_logo(
    null, 'Sinar Teknologi', 'https://cdn.iakauntan.test/logos/sinar.png');
  perform public.platform_save_landing_app_link(
    'play_store', 'Google Play', 'https://play.google.com/store/apps/details?id=a');

  v_draft := public.platform_landing_preview();

  -- The point of the whole migration.
  perform pg_temp.check_true('an administrator can see the unpublished page',
    v_draft -> 'page' <> 'null'::jsonb);
  perform pg_temp.check_eq('and the figures drafted for it',
    jsonb_array_length(v_draft -> 'stats'), 1);
  perform pg_temp.check_eq('and the testimonials',
    jsonb_array_length(v_draft -> 'testimonials'), 1);
  perform pg_temp.check_eq('and the customer logos',
    jsonb_array_length(v_draft -> 'logos'), 1);
  perform pg_temp.check_eq('and the reasons',
    jsonb_array_length(v_draft -> 'reasons'), 1);
  perform pg_temp.check_eq('and the feature blocks',
    jsonb_array_length(v_draft -> 'sections'), 1);
  perform pg_temp.check_eq('and the store buttons',
    jsonb_array_length(v_draft -> 'app_links'), 1);

  -- While the same site is still nobody else's business.
  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_public := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_true('and a visitor still gets nothing',
    v_public -> 'page' = 'null'::jsonb);
  perform pg_temp.check_eq('nor the figures',
    jsonb_array_length(v_public -> 'stats'), 0);
  perform pg_temp.check_eq('nor the testimonials',
    jsonb_array_length(v_public -> 'testimonials'), 0);
  perform pg_temp.check_eq('nor the logos',
    jsonb_array_length(v_public -> 'logos'), 0);

  -- Now publish, change nothing else, and read it as a stranger. What
  -- they get has to be exactly what the administrator was shown — the
  -- one assertion that makes the preview worth having.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_published := public.landing_page();
  end;
  reset role;

  -- `is_published` itself is the one field that moved, so it is taken
  -- out of both sides rather than the comparison being loosened to the
  -- handful of keys somebody remembered to list.
  perform pg_temp.check_eq(
    'what the preview showed is what publishing published',
    (v_published #- '{page,is_published}')::text,
    (v_draft     #- '{page,is_published}')::text);
end $$;

-- ---------------------------------------------------------------------
-- The draft is a platform administrator's alone
--
-- The preview is the only route to an ungated payload, so it is the
-- only thing standing between a half-written site and anybody who can
-- call an RPC. `app.landing_payload` takes the flag but is granted to
-- nobody: both callers are SECURITY DEFINER and run as the definer, so
-- no client role needs to reach it and none can.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org uuid := pg_temp.test_org('Syarikat Ketiga');
  v_admin uuid := pg_temp.test_user();
  v_ok boolean; v_role text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(jsonb_build_object(
    'wordmark', 'Draf', 'hero_headline', 'Belum siap',
    'is_published', false));

  -- An ordinary company owner.
  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  perform pg_temp.sign_in_as(v_owner);
  v_ok := false;
  begin
    perform public.platform_landing_preview();
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an ordinary owner cannot read the draft', v_ok);

  -- And a stranger, who cannot even execute it.
  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  v_ok := false;
  begin
    perform public.platform_landing_preview();
  exception when insufficient_privilege then v_ok := true;
  end;
  reset role;
  perform pg_temp.check_true('the refusal was measured against anon',
    v_role = 'anon');
  perform pg_temp.check_true('a stranger may not even call it', v_ok);

  perform pg_temp.check_true('and the payload itself is granted to nobody',
    not has_function_privilege('anon', 'app.landing_payload(boolean)', 'execute')
    and not has_function_privilege(
      'authenticated', 'app.landing_payload(boolean)', 'execute'));

  -- The public function takes no argument, so there is no value a
  -- caller can pass to reach the draft body. Asserted structurally
  -- because no observation of a well-behaved caller could show it.
  perform pg_temp.check_eq('landing_page() takes no argument to abuse',
    (select count(*)::int from pg_proc
      where oid = 'public.landing_page()'::regprocedure and pronargs = 0), 1);
end $$;


-- ---------------------------------------------------------------------
-- 0319: a third kind, and what it may say
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_ok boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  perform public.platform_save_landing_section(
    null, 'MyInvois', null, 'receipt', 10, null, 'badge');
  perform public.platform_save_landing_section(
    null, 'Double entry', 'A ledger that balances.', 'payments', 10);
  perform public.platform_save_landing_section(
    null, 'Local support', 'In Bahasa Melayu.', 'support', 10, null, 'reason');

  v_out := public.landing_page();
  -- Three kinds, three keys, one row in each. The failure this catches
  -- is a badge landing in the feature grid, where it would render as a
  -- card with no body and read as unfinished copy.
  perform pg_temp.check_eq('a badge is a badge',
    jsonb_array_length(v_out -> 'badges'), 1);
  perform pg_temp.check_eq('and does not join the features',
    jsonb_array_length(v_out -> 'sections'), 1);
  perform pg_temp.check_eq('nor the reasons',
    jsonb_array_length(v_out -> 'reasons'), 1);
  perform pg_temp.check_eq('and it is the one that was written',
    v_out -> 'badges' -> 0 ->> 'title', 'MyInvois');

  -- Withheld with everything else while the page is a draft.
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', false));
  perform pg_temp.sign_out();
  begin
    set local role anon;
    v_out := public.landing_page();
  end;
  reset role;
  perform pg_temp.check_eq('a drafted badge is withheld too',
    jsonb_array_length(v_out -> 'badges'), 0);

  -- And an administrator can see it, which is 0318's shared body doing
  -- its job: `badges` was added once and both doors carry it.
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('while the preview shows it',
    jsonb_array_length(public.platform_landing_preview() -> 'badges'), 1);

  -- A fourth kind renders nowhere, so it is refused rather than stored.
  v_ok := false;
  begin
    perform public.platform_save_landing_section(
      null, 'Something', null, null, null, null, 'banner');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a fourth kind is refused', v_ok);

  -- And the two 0317 knew about still work, which is what recreating
  -- the saver could have broken.
  perform pg_temp.check_true('a feature still saves',
    public.platform_save_landing_section(
      null, 'Payroll', null, null, null, null, 'feature') is not null);
  perform pg_temp.check_true('and a reason',
    public.platform_save_landing_section(
      null, 'Fast', null, null, null, null, 'reason') is not null);
end $$;


-- ---------------------------------------------------------------------
-- 0321: one switch per button, and a hero picture out of the box
--
-- `0320` had two switches, one per place. `0321` has eight — place,
-- width, and which way in — because a button is three decisions and an
-- operator wanting "Create an account on the desktop bar, only Sign in
-- on a phone" could not say so.
--
-- What is asserted is the shape the page has to have for the switches
-- to be believed: all eight default on, each saves on its own without
-- disturbing the other seven, an untouched one survives somebody else's
-- edit, and none of them can be set by anybody but a platform
-- administrator. The failure this catches is a switch the console
-- writes and the payload drops, which is worse than no switch because
-- it is trusted.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_ok boolean; v_key text; v_other text;
  v_keys text[] := array[
    'bar_sign_in_desktop', 'bar_sign_in_mobile',
    'bar_register_desktop', 'bar_register_mobile',
    'hero_sign_in_desktop', 'hero_sign_in_mobile',
    'hero_register_desktop', 'hero_register_mobile'];
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.reset_landing();
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));

  -- Shipped on, all eight. A platform that never opens the console has
  -- the page it had before the columns existed.
  v_out := public.landing_page();
  foreach v_key in array v_keys loop
    perform pg_temp.check_eq(format('%s ships on', v_key),
      v_out -> 'page' ->> v_key, 'true');
  end loop;

  -- One at a time, and only the one. This is the whole reason there are
  -- eight rather than two: a switch that also moved the phone's button
  -- would look right in the console and wrong on the page.
  foreach v_key in array v_keys loop
    perform public.platform_save_landing_page(
      jsonb_build_object(v_key, false));
    v_out := public.landing_page();
    perform pg_temp.check_eq(format('%s goes off', v_key),
      v_out -> 'page' ->> v_key, 'false');
    foreach v_other in array v_keys loop
      if v_other <> v_key then
        perform pg_temp.check_eq(
          format('%s is untouched by %s', v_other, v_key),
          v_out -> 'page' ->> v_other, 'true');
      end if;
    end loop;
    -- Back on, so the next one starts from the same page.
    perform public.platform_save_landing_page(
      jsonb_build_object(v_key, true));
  end loop;

  -- A patch that says nothing about them changes none of them. The
  -- console sends only what the operator touched, so an untouched
  -- switch must survive somebody else's edit.
  perform public.platform_save_landing_page(
    jsonb_build_object('hero_sign_in_mobile', false));
  perform public.platform_save_landing_page(
    jsonb_build_object('hero_headline', 'Books that balance'));
  v_out := public.landing_page();
  perform pg_temp.check_eq('an unrelated edit leaves a switch alone',
    v_out -> 'page' ->> 'hero_sign_in_mobile', 'false');
  perform pg_temp.check_eq('while saving what it did change',
    v_out -> 'page' ->> 'hero_headline', 'Books that balance');

  -- The draft door carries them too. 0318's shared body is the reason
  -- this is one assertion rather than a second implementation: a key
  -- added to the page is added once.
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', false));
  perform pg_temp.check_eq('the preview shows the draft switch',
    public.platform_landing_preview() -> 'page' ->> 'hero_sign_in_mobile',
    'false');
  perform pg_temp.check_true('while the page itself shows nothing at all',
    public.landing_page() -> 'page' = 'null'::jsonb);

  -- The hero has a picture without anybody choosing one, and it is
  -- served from the same origin as the page.
  perform pg_temp.check_eq('the hero ships with a picture',
    public.platform_landing_preview() -> 'page' ->> 'hero_image_url',
    'https://iakauntan.com/hero-dashboard.png');

  -- 0325. And a mark, which reaches the browser through `brand` rather
  -- than `page` — branding a product is not publishing a website, so it
  -- is never gated on `is_published` and an unpublished platform still
  -- has its logo on the signed-in app.
  perform pg_temp.check_true('and the product ships with a mark',
    public.landing_page() -> 'brand' ->> 'logo_url' like
      'https://%/storage/v1/object/public/logos/landing/logo%');

  -- Nobody else may touch any of it. The page is the whole platform's
  -- front door, and an ordinary account holder — the same person, with
  -- the badge taken off — is not an administrator.
  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true, 'bar_sign_in_mobile', true));
  delete from public.platform_admins where user_id = v_admin;
  perform pg_temp.sign_in_as(v_admin);
  v_ok := false;
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('bar_sign_in_mobile', false));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true(
    'somebody who is not a platform administrator is refused', v_ok);
  perform pg_temp.check_eq('and the switch is where the administrator left it',
    public.landing_page() -> 'page' ->> 'bar_sign_in_mobile', 'true');
end $$;


-- ---------------------------------------------------------------------
-- 0322: the front page is told when to look again
--
-- The trigger sends the name of the table that changed to a public
-- broadcast topic and nothing else, so a stranger's browser can know to
-- re-ask `landing_page()` without the socket ever carrying a draft.
--
-- Asserted here as structure rather than as delivery: whether Realtime
-- hands the message on is Realtime's business and needs a running
-- server, but which tables carry the trigger, and that the payload is
-- the table name alone, are this repository's.
-- ---------------------------------------------------------------------
do $$
declare v_src text; v_table text;
begin
  select prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'landing_touched';

  perform pg_temp.check_true('the nudge exists', v_src is not null);

  -- The one thing that would turn a nudge into a leak. Matched on a
  -- field reference — `new.` or `old.` — rather than on the bare words,
  -- because the function's own comment says why it does not use them
  -- and a test that reads prose tests nothing.
  perform pg_temp.check_true('and carries no row with it',
    v_src !~ '\m(new|old)\.');
  perform pg_temp.check_true('only the name of the table that changed',
    v_src ~ 'tg_table_name');

  -- Every table the payload is built from. One left off is a page that
  -- updates for some edits and not others, which is harder to notice
  -- than one that never updates at all.
  foreach v_table in array array[
    'landing_page', 'landing_sections', 'landing_app_links',
    'landing_stats', 'landing_testimonials', 'landing_logos',
    'platform_modules']
  loop
    perform pg_temp.check_eq(format('%s nudges the front page', v_table),
      (select count(*)::int from pg_trigger t
        where t.tgrelid = format('public.%I', v_table)::regclass
          and not t.tgisinternal
          and t.tgfoid = 'app.landing_touched()'::regprocedure), 1);
  end loop;
end $$;


rollback;

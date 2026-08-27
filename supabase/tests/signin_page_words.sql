-- =====================================================================
-- iAkauntan :: the last things on the sign-in page that were ours
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/signin_page_words.sql
--
-- `0337` takes the panel's colour and the words on the form out of the
-- Dart. Three things here fail quietly:
--
--   * a colour that is not a colour reaches the screen and paints
--     nothing, or paints black, depending on how the parser feels;
--   * a word carried in `page` rather than beside `brand` changes in
--     the console and not on the form, because this screen draws before
--     anything is published;
--   * `sign_in_label` and `register_label` have been on this table
--     since `0290` and were never in `brand` at all, so the screen that
--     the button leads to could not read the button's own name.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Out of the box every word is unwritten, and the colour is unchosen
--
-- Null rather than a copy of the shipped string: the screen falls back
-- on null, and storing the default would freeze it into every row on
-- the day somebody improves it.
-- ---------------------------------------------------------------------
do $$
declare v_row public.landing_page; v_col text;
begin
  delete from public.landing_page;
  insert into public.landing_page (id) values (true);
  select * into v_row from public.landing_page;

  foreach v_col in array array[
    'signin_email_label', 'signin_password_label', 'signin_name_label',
    'signin_forgot_label', 'signin_register_prompt', 'signin_signin_prompt'
  ] loop
    perform pg_temp.check_true(
      format('%s is unwritten, not a copy of the shipped word', v_col),
      (to_jsonb(v_row) ->> v_col) is null);
  end loop;

  -- And the two that predate this migration still answer, because they
  -- are NOT NULL with a default and the console leans on that.
  perform pg_temp.check_eq('the sign-in button already had a name',
                           v_row.sign_in_label, 'Sign in');
  perform pg_temp.check_eq('and so did the other one',
                           v_row.register_label, 'Create an account');
end $$;

-- ---------------------------------------------------------------------
-- All of it reaches a stranger, on an unpublished site
--
-- The silent half. `page` is gated on publication and this screen is
-- not, so every one of these has to travel beside `brand`.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_brand jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'signin_email_label',     'E-mel',
    'signin_password_label',  'Kata laluan',
    'signin_name_label',      'Nama penuh',
    'signin_forgot_label',    'Lupa kata laluan?',
    'signin_register_prompt', 'Baru di sini? Buka akaun',
    'signin_signin_prompt',   'Sudah ada akaun? Log masuk',
    'sign_in_label',          'Log masuk',
    'register_label',         'Buka akaun'));

  perform pg_temp.sign_out();
  set local role anon;
  v_out := public.landing_page();
  reset role;
  v_brand := v_out -> 'brand';

  perform pg_temp.check_true('the marketing site is still a draft',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);

  perform pg_temp.check_eq('and the email box''s name',
                           v_brand ->> 'signin_email_label', 'E-mel');
  perform pg_temp.check_eq('and the password box''s',
                           v_brand ->> 'signin_password_label', 'Kata laluan');
  perform pg_temp.check_eq('and the name box''s',
                           v_brand ->> 'signin_name_label', 'Nama penuh');
  perform pg_temp.check_eq('and the forgotten-password link',
                           v_brand ->> 'signin_forgot_label',
                           'Lupa kata laluan?');
  perform pg_temp.check_eq('and the sentence offering an account',
                           v_brand ->> 'signin_register_prompt',
                           'Baru di sini? Buka akaun');
  perform pg_temp.check_eq('and the sentence back to signing in',
                           v_brand ->> 'signin_signin_prompt',
                           'Sudah ada akaun? Log masuk');

  -- The two 0290 columns, which the sign-in screen could not see at
  -- all until this migration put them in `brand`.
  perform pg_temp.check_eq('the button knows its own name now',
                           v_brand ->> 'sign_in_label', 'Log masuk');
  perform pg_temp.check_eq('and so does the other one',
                           v_brand ->> 'register_label', 'Buka akaun');
end $$;

-- ---------------------------------------------------------------------
-- An emptied box asks for the shipped word back
--
-- Null, not an empty string: the screen renders `?? 'Email'` on null
-- and an unlabelled box on ''.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_row public.landing_page;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'signin_email_label', '   '));
  select * into v_row from public.landing_page;

  perform pg_temp.check_true('an emptied label is null, not ""',
                             v_row.signin_email_label is null);

  -- And a patch that does not mention them leaves them alone.
  perform public.platform_save_landing_page(
    jsonb_build_object('wordmark', 'iAkauntan'));
  select * into v_row from public.landing_page;
  perform pg_temp.check_eq('saving something else keeps the words',
                           v_row.signin_password_label, 'Kata laluan');
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator writes any of it
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-words@iakauntan.test');
  v_denied boolean := false; v_kept text;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('signin_email_label', 'Mine now'));
  exception when insufficient_privilege then v_denied := true;
  end;
  perform pg_temp.check_true('a company owner cannot rename the boxes',
                             v_denied);

  select p.signin_password_label into v_kept from public.landing_page p;
  perform pg_temp.check_eq('and the words are as the operator left them',
                           v_kept, 'Kata laluan');
end $$;

-- ---------------------------------------------------------------------
-- The colour is Branding's, and only Branding's
--
-- `0337` briefly gave the sign-in panel a colour of its own. `0340`
-- took it back out: a platform has one colour, chosen once, and a
-- second field for it is a second answer that is free to disagree with
-- the first.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the sign-in screen has no colour of its own',
    not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'landing_page'
         and column_name = 'signin_panel_colour'));

  -- And the one it uses is still there to be set.
  perform pg_temp.check_true('while the brand colour still is',
    exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'landing_page'
         and column_name = 'brand_colour'));
end $$;

-- ---------------------------------------------------------------------
-- The browser's own furniture travels too
--
-- `meta_title` and `meta_description` have been stored since `0290` and
-- editable since `0316`, and nothing read them until `0339` put them in
-- `brand`. They are the tab's title and the sentence a link preview
-- shows, so they are needed on every screen — including every screen a
-- platform with no published marketing site still draws.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'meta_title', 'Kira Kira — buku',
    'meta_description', 'Perakaunan untuk perniagaan Malaysia.'));

  perform pg_temp.sign_out();
  set local role anon;
  v_out := public.landing_page();
  reset role;

  perform pg_temp.check_true('the site is still a draft',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_eq('the tab title reaches the browser anyway',
    v_out -> 'brand' ->> 'meta_title', 'Kira Kira — buku');
  perform pg_temp.check_eq('and the sentence a link preview reads',
    v_out -> 'brand' ->> 'meta_description',
    'Perakaunan untuk perniagaan Malaysia.');
end $$;

-- ---------------------------------------------------------------------
-- And the five pages change while somebody is looking at them
--
-- `0341` put `site_pages` in the realtime publication. Without it an
-- operator rewrites the sign-in screen's wording, watches the sign-in
-- page in the next tab, and nothing happens until they reload — which
-- reads exactly like a console that did not save.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the five pages are published for realtime',
    exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public' and tablename = 'site_pages'));

  -- Full, so a subscriber can tell a published page from a draft
  -- without going back to the database for the row it was just sent.
  perform pg_temp.check_eq('with the whole row, not just its key',
    (select c.relreplident::text from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'site_pages'), 'f');
end $$;

rollback;

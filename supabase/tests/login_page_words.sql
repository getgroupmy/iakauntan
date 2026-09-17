-- =====================================================================
-- iAkauntan :: the login page's own switches, labels and bullets
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/login_page_words.sql
--
-- `0350`. The console's Sign in page carries four cards of settings and
-- the Login page carried none, and the reason the cards could not
-- simply be drawn on both tabs is the failure this file exists to
-- catch: every one of them writes `signin_*` on the single
-- `landing_page` row, so a switch flicked under "Login page" would have
-- changed the platform's own sign-in screen without saying so.
--
-- Three things fail quietly here:
--
--   * a login column that writes through to its `signin_` twin, which
--     is the bug above and looks exactly like the feature working until
--     somebody opens the other tab;
--   * a login column that does not reach `brand`. The screen it dresses
--     draws before anything is published, so a value stranded in `page`
--     is a setting whose effect nobody can ever see;
--   * and the seed. A platform that has already dressed its sign-in
--     screen should find its workspace doors dressed the same way
--     rather than bare, which is what makes this a replicate rather
--     than a second empty page.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The seed: a login page starts as a copy of the sign-in page
-- ---------------------------------------------------------------------
do $$
declare v_row public.landing_page;
begin
  delete from public.landing_page;
  insert into public.landing_page
    (id, signin_show_headline, signin_show_heading, signin_headline,
     signin_email_label, signin_password_label, signin_forgot_label,
     sign_in_label)
  values (true, true, true, 'Accounting, done', 'Your email', 'Your password',
          'Lost it?', 'Come in');

  -- The migration's own statement, re-run against a row that has words
  -- in it. The rows in front of `0350` were bare, so running it again is
  -- the only way to watch it carry anything.
  update public.landing_page set
    login_show_headline  = signin_show_headline,
    login_show_heading   = signin_show_heading,
    login_headline       = signin_headline,
    login_email_label    = signin_email_label,
    login_password_label = signin_password_label,
    login_forgot_label   = signin_forgot_label,
    login_sign_in_label  = sign_in_label;

  select * into v_row from public.landing_page;

  perform pg_temp.check_true('a new login page opens with the sign-in '
                             'page''s switches',
                             v_row.login_show_headline
                             and v_row.login_show_heading);
  perform pg_temp.check_eq('and its headline', v_row.login_headline,
                           'Accounting, done');
  perform pg_temp.check_eq('and its email label', v_row.login_email_label,
                           'Your email');
  perform pg_temp.check_eq('and the name on its button',
                           v_row.login_sign_in_label, 'Come in');
end $$;

-- ---------------------------------------------------------------------
-- Writing one page does not write the other
--
-- The whole reason these columns exist. Without them the console would
-- have had one set of switches under two tabs.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_row public.landing_page;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'login_email_label', 'Work email',
    'login_headline', 'Sinar, at work',
    'login_show_headline', false));

  select * into v_row from public.landing_page;

  perform pg_temp.check_eq('the login page took the new word',
                           v_row.login_email_label, 'Work email');
  perform pg_temp.check_eq('and the sign-in page did not',
                           v_row.signin_email_label, 'Your email');
  perform pg_temp.check_eq('the login headline moved',
                           v_row.login_headline, 'Sinar, at work');
  perform pg_temp.check_eq('and the sign-in headline stayed',
                           v_row.signin_headline, 'Accounting, done');
  perform pg_temp.check_true('the login switch went off',
                             not v_row.login_show_headline);
  perform pg_temp.check_true('and the sign-in switch stayed on',
                             v_row.signin_show_headline);
end $$;

-- And the other direction, because a rule that only holds one way round
-- is not the rule.
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_row public.landing_page;
begin
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(
    '{"signin_email_label": "Platform email"}'::jsonb);

  select * into v_row from public.landing_page;
  perform pg_temp.check_eq('writing the sign-in page moved it',
                           v_row.signin_email_label, 'Platform email');
  perform pg_temp.check_eq('and left the login page alone',
                           v_row.login_email_label, 'Work email');
end $$;

-- ---------------------------------------------------------------------
-- An emptied box is a null, not an empty string
--
-- Clearing a label asks for the word the product ships with. An empty
-- string is not null, and the screen's `??` renders it — a field with
-- no label at all.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_row public.landing_page;
begin
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_landing_page(
    '{"login_email_label": "   "}'::jsonb);

  select * into v_row from public.landing_page;
  perform pg_temp.check_true('an emptied login label is null, not ""',
                             v_row.login_email_label is null);
  -- A key that was not in the patch at all is a field left alone.
  perform pg_temp.check_eq('and a field left out is left alone',
                           v_row.login_headline, 'Sinar, at work');
end $$;

-- ---------------------------------------------------------------------
-- All of it reaches a stranger, on an unpublished site
--
-- The silent half. `page` is gated on publication and this screen is
-- not, so every one of these has to travel beside `brand`.
-- ---------------------------------------------------------------------
do $$
declare v_brand jsonb; v_col text;
begin
  update public.landing_page set is_published = false;
  perform pg_temp.sign_out();

  v_brand := app.landing_payload(false) -> 'brand';

  foreach v_col in array array[
    'login_show_headline', 'login_show_heading', 'login_headline',
    'login_email_label', 'login_password_label', 'login_forgot_label',
    'login_sign_in_label'
  ] loop
    perform pg_temp.check_true(
      format('%s travels beside brand, not inside page', v_col),
      v_brand ? v_col);
  end loop;

  perform pg_temp.check_true('and page really is gated, so that was not '
                             'a free pass',
                             (app.landing_payload(false) -> 'page') = 'null'
                             ::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- The bullets beside a company's door are its own list
--
-- A fourth `kind`, so they are not mixed in with the sign-in page's
-- three — and ungated for the reason those are: `is_active` is the
-- switch, and it is off on every row out of the box.
-- ---------------------------------------------------------------------
do $$
declare v_points jsonb;
begin
  delete from public.landing_sections where kind in ('signin', 'login');
  insert into public.landing_sections (kind, title, body, sort_order,
                                       is_active)
  values ('signin', 'Platform bullet', 'Ours', 1, true),
         ('login',  'Company bullet',  'Theirs', 1, true),
         ('login',  'Switched off',    'Not drawn', 2, false);

  perform pg_temp.sign_out();
  v_points := app.landing_payload(false) -> 'login_points';

  perform pg_temp.check_eq('a door draws its own bullets',
                           jsonb_array_length(v_points), 1);
  perform pg_temp.check_eq('and they are the company''s, not the '
                           'platform''s',
                           v_points -> 0 ->> 'title', 'Company bullet');
  perform pg_temp.check_eq('the sign-in page still has its own',
                           app.landing_payload(false) -> 'signin_points'
                             -> 0 ->> 'title', 'Platform bullet');
end $$;

-- ---------------------------------------------------------------------
-- The section saver takes the fifth kind
--
-- Left out of the guard, the console's Add button on the Login page
-- would refuse the row with a message about the four kinds there used
-- to be.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text; v_n integer;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_section(
    p_title => 'A company point', p_body => 'Written here',
    p_kind => 'login', p_is_active => true);

  select count(*) into v_n from public.landing_sections
   where kind = 'login' and title = 'A company point';
  perform pg_temp.check_eq('the console can add a bullet to a door', v_n, 1);

  begin
    perform public.platform_save_landing_section(
      p_title => 'Nowhere', p_kind => 'nonsense');
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.check_eq('and a kind nothing renders is still refused',
                           v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- And only a platform administrator writes any of it
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-login@test.local');
  v_state text; v_label text;
begin
  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_landing_page(
      '{"login_email_label": "Mine now"}'::jsonb);
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.check_eq('a stranger cannot dress every door on the '
                           'platform', v_state, '42501');

  select login_email_label into v_label from public.landing_page;
  perform pg_temp.check_true('and nothing moved', v_label is null);
end $$;

rollback;

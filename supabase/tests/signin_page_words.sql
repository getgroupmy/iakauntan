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

  perform pg_temp.check_true('the panel colour is unchosen',
                             v_row.signin_panel_colour is null);
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
    'signin_panel_colour',    '#123456',
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

  perform pg_temp.check_eq('the panel colour reaches the form',
                           v_brand ->> 'signin_panel_colour', '#123456');
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
-- A colour that is not a colour is refused, twice
--
-- Once by the saver, with a sentence somebody can act on, and once by
-- the table — because the saver is the door everybody uses and the
-- constraint is what makes that true rather than merely usual.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text; v_msg text; v_direct boolean := false; v_kept text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('signin_panel_colour', 'teal'));
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.check_eq('a colour has to be a colour', v_state, '22023');
  perform pg_temp.check_true('and the refusal shows the shape wanted',
                             v_msg like '%#0B7A6B%');

  begin
    update public.landing_page set signin_panel_colour = 'teal';
  exception when check_violation then v_direct := true;
  end;
  perform pg_temp.check_true('the table refuses it too', v_direct);

  select p.signin_panel_colour into v_kept from public.landing_page p;
  perform pg_temp.check_eq('and the colour that was there is still there',
                           v_kept, '#123456');
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
    'signin_email_label', '   ',
    'signin_panel_colour', ''));
  select * into v_row from public.landing_page;

  perform pg_temp.check_true('an emptied label is null, not ""',
                             v_row.signin_email_label is null);
  perform pg_temp.check_true('and an emptied colour is null',
                             v_row.signin_panel_colour is null);

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

rollback;

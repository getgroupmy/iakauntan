-- =====================================================================
-- iAkauntan :: the sign-in page stops being a poster we wrote
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/signin_page_copy.sql
--
-- `0336` takes the panel beside the sign-in form out of the Dart and
-- puts it behind four switches and a list, all off out of the box.
--
-- What is worth asserting is mostly the closed state, because every way
-- this can break looks like a working page:
--
--   * a switch that defaults on puts our marketing back on somebody
--     else's deployment, and nobody would notice because it looks like
--     the product;
--   * the bullets carried in `sections` rather than beside `brand`
--     would appear only once a marketing site is published, which is a
--     different page's decision;
--   * an inactive bullet that still travels is a switch that does
--     nothing;
--   * and the seeded copy has to survive, or turning a switch on gives
--     an empty panel and a question about what used to be there.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Every switch is off, and the words are still there
--
-- Both halves matter. Off is the decision; the seeded copy is what
-- makes it a decision somebody can reverse in one click rather than a
-- deletion they have to undo from memory.
-- ---------------------------------------------------------------------
do $$
declare v_row public.landing_page; v_n integer;
begin
  delete from public.landing_page;
  insert into public.landing_page (id) values (true);
  select * into v_row from public.landing_page;

  perform pg_temp.check_true('the logo is off out of the box',
                             v_row.signin_show_logo is false);
  perform pg_temp.check_true('and the name beside it',
                             v_row.signin_show_name is false);
  perform pg_temp.check_true('and the headline',
                             v_row.signin_show_headline is false);
  perform pg_temp.check_true('and the heading above the form',
                             v_row.signin_show_heading is false);
  perform pg_temp.check_true('and the offer of an account',
                             v_row.signin_show_register is false);

  perform pg_temp.check_true('but the headline is written, not lost',
    v_row.signin_headline like 'Accounting and CRM%');

  select count(*) into v_n from public.landing_sections
   where kind = 'signin';
  perform pg_temp.check_eq('the three points are there to switch on',
                           v_n, 3);

  select count(*) into v_n from public.landing_sections
   where kind = 'signin' and is_active;
  perform pg_temp.check_eq('and none of them is switched on', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- Nothing reaches the page until somebody turns it on
--
-- Read as a stranger, because that is who is looking at this screen.
-- ---------------------------------------------------------------------
do $$
declare v_out jsonb; v_role text;
begin
  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  v_out := public.landing_page();
  reset role;

  perform pg_temp.check_true('the test ran as an anonymous visitor',
                             v_role = 'anon');
  perform pg_temp.check_true('the logo stays off for a visitor',
    (v_out -> 'brand' ->> 'signin_show_logo')::boolean is false);
  perform pg_temp.check_true('and the name',
    (v_out -> 'brand' ->> 'signin_show_name')::boolean is false);
  perform pg_temp.check_eq('and no point travels at all',
    jsonb_array_length(v_out -> 'signin_points'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Switched on, it reaches an unpublished site
--
-- The half that is silent when it breaks. `page` is gated on
-- publication; the sign-in form is not, so all of this has to travel
-- beside `brand` rather than inside `page`.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_id uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'signin_show_logo', true,
    'signin_show_headline', true,
    'signin_show_heading', true,
    'signin_show_register', true,
    'signin_headline', 'Perakaunan untuk perniagaan Malaysia.'));

  select s.id into v_id from public.landing_sections s
   where s.kind = 'signin' order by s.sort_order limit 1;
  perform public.platform_save_landing_section(
    p_id => v_id, p_is_active => true, p_kind => 'signin');

  perform pg_temp.sign_out();
  set local role anon;
  v_out := public.landing_page();
  reset role;

  -- Never published, and that is the point.
  perform pg_temp.check_true('the marketing site is still a draft',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);

  perform pg_temp.check_true('the logo reaches the form anyway',
    (v_out -> 'brand' ->> 'signin_show_logo')::boolean);
  -- 0338, and the point of the split: the patch turned the logo on and
  -- said nothing about the name, so the name is still off. One switch
  -- could not express that.
  perform pg_temp.check_true('and the name it said nothing about stays off',
    (v_out -> 'brand' ->> 'signin_show_name')::boolean is false);
  perform pg_temp.check_true('and the headline switch',
    (v_out -> 'brand' ->> 'signin_show_headline')::boolean);
  perform pg_temp.check_true('and the heading switch',
    (v_out -> 'brand' ->> 'signin_show_heading')::boolean);
  perform pg_temp.check_true('and the offer of an account',
    (v_out -> 'brand' ->> 'signin_show_register')::boolean);
  perform pg_temp.check_eq('and the operator''s own words',
    v_out -> 'brand' ->> 'signin_headline',
    'Perakaunan untuk perniagaan Malaysia.');

  perform pg_temp.check_eq('one point switched on is one point drawn',
    jsonb_array_length(v_out -> 'signin_points'), 1);
end $$;

-- ---------------------------------------------------------------------
-- The points are their own list, not mixed into the landing page's
--
-- One table, four kinds. A point that turned up in `sections` would
-- appear in the middle of the marketing site, which is the sort of
-- thing somebody finds by looking at their own front page.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('is_published', true));
  v_out := public.landing_page();

  perform pg_temp.check_true('no sign-in point is in the page''s own bands',
    not exists (
      select 1
        from jsonb_array_elements(v_out -> 'sections') e
       where e ->> 'title' = 'LHDN e-Invoice built in'));

  perform pg_temp.check_eq('while it is still beside the form',
    jsonb_array_length(v_out -> 'signin_points'), 1);
end $$;

-- ---------------------------------------------------------------------
-- Emptying the headline restores the shipped one
--
-- Same rule as every other optional line of copy on this page: clearing
-- a box is how somebody asks for the default back, and an empty string
-- would render as a heading of nothing at all.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_headline text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('signin_headline', '   '));
  select p.signin_headline into v_headline from public.landing_page p;
  perform pg_temp.check_true('an emptied headline is null, not ""',
                             v_headline is null);

  -- And an unrelated save leaves the switches where they were.
  perform public.platform_save_landing_page(
    jsonb_build_object('wordmark', 'iAkauntan'));
  perform pg_temp.check_true('saving something else moves no switch',
    (select p.signin_show_logo and p.signin_show_register
       from public.landing_page p));
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator moves any of it
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-signin@iakauntan.test');
  v_page boolean := false; v_point boolean := false; v_id uuid;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  select s.id into v_id from public.landing_sections s
   where s.kind = 'signin' order by s.sort_order limit 1;

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('signin_show_logo', false));
  exception when insufficient_privilege then v_page := true;
  end;
  begin
    perform public.platform_save_landing_section(
      p_id => v_id, p_title => 'Mine now', p_kind => 'signin');
  exception when insufficient_privilege then v_point := true;
  end;

  perform pg_temp.check_true('a company owner cannot move the switches',
                             v_page);
  perform pg_temp.check_true('nor rewrite the points', v_point);
end $$;

-- ---------------------------------------------------------------------
-- A fifth kind is refused, and the message says which four there are
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user(); v_msg text; v_state text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_landing_section(
      p_title => 'Somewhere else', p_kind => 'footer');
  exception when others then v_msg := sqlerrm; v_state := sqlstate;
  end;

  perform pg_temp.check_eq('a kind nothing renders is refused',
                           v_state, '22023');
  perform pg_temp.check_true('and the refusal knows about sign-in points',
                             v_msg like '%sign-in point%');
end $$;

-- ---------------------------------------------------------------------
-- And the column the two replace is gone
--
-- `0338` dropped `signin_show_mark` rather than leaving it. A column
-- the payload still carried and the screen ignored is one somebody
-- would eventually set and then wonder about.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the one switch the two replace is gone',
    not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'landing_page'
         and column_name = 'signin_show_mark'));
end $$;

rollback;

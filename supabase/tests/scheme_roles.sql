-- =====================================================================
-- iAkauntan :: the scheme, one role at a time
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheme_roles.sql
--
-- `0343` lets an operator override one role of the Material scheme
-- instead of only seeding the whole thing.
--
-- Three things fail quietly here:
--
--   * an override carried in `page` rather than beside `brand` changes
--     the console's preview and not the product, because the theme is
--     built before anything is published;
--   * an override that cannot be cleared is a choice somebody is stuck
--     with — "let Material choose again" has to be expressible;
--   * and a colour that is not a colour reaching the client is a role
--     that silently does not apply, or applies as black.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Twelve columns, all unchosen out of the box
--
-- Null is the normal state and has to stay the default: a colour stored
-- for every role would freeze today's derivation into every row on the
-- day Material improves it.
-- ---------------------------------------------------------------------
do $$
declare v_row public.landing_page; v_col text; v_n integer := 0;
begin
  delete from public.landing_page;
  insert into public.landing_page (id) values (true);
  select * into v_row from public.landing_page;

  foreach v_col in array array[
    'scheme_light_primary', 'scheme_light_container',
    'scheme_light_secondary', 'scheme_light_surface',
    'scheme_light_surface_tint', 'scheme_light_error',
    'scheme_dark_primary', 'scheme_dark_container',
    'scheme_dark_secondary', 'scheme_dark_surface',
    'scheme_dark_surface_tint', 'scheme_dark_error'
  ] loop
    v_n := v_n + 1;
    perform pg_temp.check_true(
      format('%s is Material''s to decide', v_col),
      (to_jsonb(v_row) ->> v_col) is null);
  end loop;
  perform pg_temp.check_eq('six roles, two schemes', v_n, 12);
end $$;

-- ---------------------------------------------------------------------
-- One role set reaches an unpublished site
--
-- The theme is built on every screen, including the sign-in form, which
-- draws long before anybody publishes a marketing page.
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
    'scheme_light_error', '#B91C1C',
    'scheme_dark_primary', '#93C5FD'));

  perform pg_temp.sign_out();
  set local role anon;
  v_out := public.landing_page();
  reset role;
  v_brand := v_out -> 'brand';

  perform pg_temp.check_true('the site is still a draft',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_eq('the chosen error red reaches the theme',
                           v_brand ->> 'scheme_light_error', '#B91C1C');
  perform pg_temp.check_eq('and the dark primary',
                           v_brand ->> 'scheme_dark_primary', '#93C5FD');

  -- And the ten nobody touched are still Material's.
  perform pg_temp.check_true('while the rest stay derived',
    (v_brand ->> 'scheme_light_primary') is null
      and (v_brand ->> 'scheme_dark_error') is null);
end $$;

-- ---------------------------------------------------------------------
-- And one role can be given back
--
-- "Let Material choose again" is a thing an operator has to be able to
-- say, or the first colour they try is the one they are stuck with.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_kept text; v_cleared text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('scheme_light_error', '   '));

  select p.scheme_light_error, p.scheme_dark_primary
    into v_cleared, v_kept from public.landing_page p;

  perform pg_temp.check_true('an emptied role is Material''s again',
                             v_cleared is null);
  perform pg_temp.check_eq('and the one beside it is untouched',
                           v_kept, '#93C5FD');
end $$;

-- ---------------------------------------------------------------------
-- A colour that is not a colour is refused, twice
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text; v_direct boolean := false;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('scheme_light_primary', 'crimson'));
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.check_eq('the saver refuses it', v_state, '22023');

  begin
    update public.landing_page set scheme_dark_surface = 'crimson';
  exception when check_violation then v_direct := true;
  end;
  perform pg_temp.check_true('and so does the table', v_direct);
end $$;

-- ---------------------------------------------------------------------
-- A patch that says nothing about them leaves them alone
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_kept text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('wordmark', 'iAkauntan'));
  select p.scheme_dark_primary into v_kept from public.landing_page p;

  perform pg_temp.check_eq('saving something else keeps the scheme',
                           v_kept, '#93C5FD');
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator changes any of it
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-scheme@iakauntan.test');
  v_denied boolean := false; v_kept text;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('scheme_light_primary', '#000000'));
  exception when insufficient_privilege then v_denied := true;
  end;

  perform pg_temp.check_true('a company owner cannot recolour the platform',
                             v_denied);
  select p.scheme_dark_primary into v_kept from public.landing_page p;
  perform pg_temp.check_eq('and the scheme is as the operator left it',
                           v_kept, '#93C5FD');
end $$;

rollback;

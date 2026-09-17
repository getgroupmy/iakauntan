-- =====================================================================
-- iAkauntan :: the demo logins are a decision, not a default
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_accounts_switch.sql
--
-- The sign-in screen can offer a row of one-tap logins into a seeded
-- demo company. `0335` makes that a switch a platform administrator
-- holds, and the assertions that matter are all about the closed state:
--
--   * the default is off. A column that defaulted to true would put the
--     demo logins on the front of every deployment that forgot to think
--     about it, which is exactly the failure being fixed;
--   * it travels in `brand`, not `page`. The sign-in screen draws
--     whether or not a marketing site has been published, so a switch
--     carried only in `page` is a switch that does nothing until the
--     front page goes live;
--   * only a platform administrator moves it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Off, out of the box
--
-- Asserted on a row nobody has touched, because that is the row a fresh
-- deployment has.
-- ---------------------------------------------------------------------
do $$
declare v_on boolean; v_nullable text;
begin
  delete from public.landing_page;
  insert into public.landing_page (id) values (true);

  select p.demo_accounts_enabled into v_on from public.landing_page p;
  perform pg_temp.check_true('a page nobody has touched offers no demo logins',
                             v_on is false);

  select c.is_nullable into v_nullable
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'landing_page'
     and c.column_name = 'demo_accounts_enabled';
  perform pg_temp.check_eq('and the column cannot be left unanswered',
                           v_nullable, 'NO');
end $$;

-- ---------------------------------------------------------------------
-- It reaches a visitor who has not signed in, and before publication
--
-- This is the half that is silent when it breaks: put in `page` instead
-- of `brand` and the switch appears to work in the console, does
-- nothing on the sign-in screen, and starts working the day somebody
-- publishes the marketing site for unrelated reasons.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_out jsonb; v_role text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('demo_accounts_enabled', true));

  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  v_out := public.landing_page();
  reset role;

  perform pg_temp.check_true('the test ran as an anonymous visitor',
                             v_role = 'anon');
  -- Never published. The sign-in screen draws anyway.
  perform pg_temp.check_true('and the site is still a draft',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);
  perform pg_temp.check_true('the switch reaches the sign-in screen anyway',
    (v_out -> 'brand' ->> 'demo_accounts_enabled')::boolean);
end $$;

-- ---------------------------------------------------------------------
-- And turning it back off is one call, not a rebuild
--
-- The point of moving it out of the compile-time flag.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('demo_accounts_enabled', false));

  perform pg_temp.sign_out();
  set local role anon;
  v_out := public.landing_page();
  reset role;

  perform pg_temp.check_true('off again, without a deployment',
    (v_out -> 'brand' ->> 'demo_accounts_enabled')::boolean is false);
end $$;

-- ---------------------------------------------------------------------
-- A patch that does not mention it leaves it alone
--
-- The console sends one key at a time. Saving the wordmark must not
-- switch the demo logins on, and must not switch them off either.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_on boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('demo_accounts_enabled', true));
  perform public.platform_save_landing_page(
    jsonb_build_object('wordmark', 'iAkauntan'));

  select p.demo_accounts_enabled into v_on from public.landing_page p;
  perform pg_temp.check_true('saving something else does not move it', v_on);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator moves it
--
-- It governs what every visitor to the front door is offered, and one
-- company's owner does not get to decide that for everybody.
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-demo@iakauntan.test');
  v_denied boolean := false; v_on boolean;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('demo_accounts_enabled', false));
  exception when insufficient_privilege then v_denied := true;
  end;
  perform pg_temp.check_true('a company owner cannot switch it', v_denied);

  select p.demo_accounts_enabled into v_on from public.landing_page p;
  perform pg_temp.check_true('and it is where the operator left it', v_on);
end $$;

rollback;

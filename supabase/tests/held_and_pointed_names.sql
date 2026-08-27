-- =====================================================================
-- iAkauntan :: a name held, and a name pointed at one thing
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/held_and_pointed_names.sql
--
-- `0342` lets an operator hold a name with nobody behind it, and point
-- a name at one module or one screen inside it.
--
-- The failures worth catching are the ones that look like the feature
-- working:
--
--   * a held name that still answers is a door into nothing, and the
--     visitor sees a page with somebody else's mark on it;
--   * a held name missing from the operator's own list is a name they
--     cannot find to give away — an inner join loses exactly the rows
--     the screen exists for;
--   * a path with no module is a restriction with nothing to check an
--     entitlement against;
--   * and a name taken twice is the one thing the whole table is for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- An operator can hold a name that belongs to nobody
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_row public.org_subdomains;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('shop');
  select * into v_row from public.org_subdomains where id = v_id;

  perform pg_temp.check_true('the name is held by nobody',
                             v_row.org_id is null);
  perform pg_temp.check_eq('and it is settled, not waiting',
                           v_row.status, 'approved');
  -- `org_subdomains_decided` requires this of anything not `requested`,
  -- and an operator holding a name is the decision.
  perform pg_temp.check_true('with the moment it was decided on it',
                             v_row.decided_at is not null);
  perform pg_temp.check_eq('and the name normalised', v_row.subdomain, 'shop');
end $$;

-- ---------------------------------------------------------------------
-- And nobody can take it
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text; v_msg text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_reserve_subdomain('SHOP');
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;

  perform pg_temp.check_eq('a name already held is refused', v_state, '23505');
  perform pg_temp.check_true('and the refusal names it',
                             v_msg like '%shop%');
end $$;

-- ---------------------------------------------------------------------
-- A held name answers with nothing at all
--
-- The half that is silent when it breaks: a held name that resolves is
-- a door into a company that is not there.
-- ---------------------------------------------------------------------
do $$
declare v_n integer; v_role text;
begin
  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  select count(*) into v_n from public.workspace_by_host('shop.iakauntan.com');
  reset role;

  perform pg_temp.check_true('the test ran as an anonymous visitor',
                             v_role = 'anon');
  perform pg_temp.check_eq('a held name is not a door', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- But the operator can still see it
--
-- An inner join to `organizations` loses precisely the rows this screen
-- exists to show, and loses them silently.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_n integer; v_org uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  select count(*) into v_n
    from public.platform_reservations() r where r.name = 'shop';
  select r.org_id into v_org
    from public.platform_reservations() r where r.name = 'shop';

  perform pg_temp.check_eq('a held name is on the operator''s list', v_n, 1);
  perform pg_temp.check_true('with no company beside it', v_org is null);
end $$;

-- ---------------------------------------------------------------------
-- A name pointed at a module, and at one screen inside it
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Kedai Pointed');
  v_id uuid; v_row record;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain(
    'till', v_org, 'pos', '/pos/till');

  select s.module_code, s.landing_path into v_row
    from public.org_subdomains s where s.id = v_id;

  perform pg_temp.check_eq('the address is confined to a module',
                           v_row.module_code, 'pos');
  perform pg_temp.check_eq('and to one screen inside it',
                           v_row.landing_path, '/pos/till');

  -- And it reaches the browser, which is the only place it does
  -- anything: the restriction is the app's to enforce.
  perform pg_temp.sign_out();
  set local role anon;
  select w.module_code, w.landing_path into v_row
    from public.workspace_by_host('till.iakauntan.com') w;
  reset role;

  perform pg_temp.check_eq('the module reaches the browser',
                           v_row.module_code, 'pos');
  perform pg_temp.check_eq('and the screen', v_row.landing_path, '/pos/till');
end $$;

-- ---------------------------------------------------------------------
-- A screen with no module is refused
--
-- A restriction with nothing to check an entitlement against, so the
-- app would have no honest answer to "may this company use it".
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text; v_msg text; v_direct boolean := false;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_reserve_subdomain(
      'orphan', null, null, '/pos/till');
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.check_eq('a screen has to belong to a module',
                           v_state, '22023');
  perform pg_temp.check_true('and the message says what to do instead',
                             v_msg like '%leave the screen empty%');

  -- The table refuses it too, so the function is the polite door rather
  -- than the only one.
  begin
    update public.org_subdomains
       set module_code = null, landing_path = '/pos/till'
     where subdomain = 'shop';
  exception when check_violation then v_direct := true;
  end;
  perform pg_temp.check_true('the table refuses it as well', v_direct);
end $$;

-- ---------------------------------------------------------------------
-- A module nobody sells is refused
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_state text; v_msg text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_reserve_subdomain('nosuch', null, 'teleport');
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.check_eq('a module that does not exist is refused',
                           v_state, '23503');
  -- The foreign key would refuse it too, with a sentence about a
  -- constraint. The check exists so an operator is told which thing
  -- they got wrong, so the message is the assertion rather than the
  -- code — the code is the same either way.
  perform pg_temp.check_true('and told which module it could not find',
                             v_msg like '%no module called teleport%');
end $$;

-- ---------------------------------------------------------------------
-- Pointing, re-pointing and un-pointing an existing name
--
-- Clearing matters as much as setting: an operator who changes their
-- mind must not have to delete the name to undo the restriction.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_row record;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  select s.id into v_id from public.org_subdomains s
   where s.subdomain = 'till';

  -- A patch that says nothing about the module leaves it alone.
  perform public.platform_update_reservation(
    'subdomain', v_id, p_name => 'counter');
  select s.module_code, s.landing_path, s.subdomain into v_row
    from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_eq('renaming does not un-point it',
                           v_row.module_code, 'pos');
  perform pg_temp.check_eq('and the new name took', v_row.subdomain,
                           'counter');

  -- Moving it to another module takes the old screen with it.
  perform public.platform_update_reservation(
    'subdomain', v_id, p_module_code => 'sales');
  select s.module_code, s.landing_path into v_row
    from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_eq('re-pointing moves the module',
                           v_row.module_code, 'sales');
  perform pg_temp.check_true('and drops a screen from the old one',
                             v_row.landing_path is null);

  -- And an empty module clears the restriction entirely.
  perform public.platform_update_reservation(
    'subdomain', v_id, p_module_code => '');
  select s.module_code, s.landing_path into v_row
    from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_true('an emptied module is no restriction',
                             v_row.module_code is null);
end $$;

-- ---------------------------------------------------------------------
-- And a name can be let go of without being deleted
--
-- `coalesce` cannot say "take the company off this", and a uuid has no
-- empty form — so releasing is its own argument.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_id uuid; v_org uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  select s.id into v_id from public.org_subdomains s
   where s.subdomain = 'counter';

  perform public.platform_update_reservation(
    'subdomain', v_id, p_release => true);
  select s.org_id into v_org from public.org_subdomains s where s.id = v_id;

  perform pg_temp.check_true('the company let go of it', v_org is null);
  perform pg_temp.check_eq('and the name is still held',
    (select s.status from public.org_subdomains s where s.id = v_id),
    'approved');
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator does any of it
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-platform-names@iakauntan.test');
  v_hold boolean := false; v_point boolean := false; v_id uuid;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  select s.id into v_id from public.org_subdomains s where s.subdomain = 'shop';

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_reserve_subdomain('mine');
  exception when insufficient_privilege then v_hold := true;
  end;
  begin
    perform public.platform_update_reservation(
      'subdomain', v_id, p_module_code => 'pos');
  exception when insufficient_privilege then v_point := true;
  end;

  perform pg_temp.check_true('a company owner cannot hold a name', v_hold);
  perform pg_temp.check_true('nor point one anywhere', v_point);
end $$;

rollback;

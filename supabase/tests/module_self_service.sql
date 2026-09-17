-- =====================================================================
-- iAkauntan :: a company turns its own module on
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/module_self_service.sql
--
-- Every add-on carried a price and none could be had: org_modules was
-- writable only by a platform administrator, and the settings screen
-- said "Contact us to add one of these" with nothing behind it. 0488
-- reverses 0018's rule -- the company switches its own add-ons on --
-- while keeping the table itself shut, so the path is one function
-- that reaches one row.
--
-- The last block is the one that matters most: 0486 refuses a second
-- company and tells the person to turn Multi-Company on under
-- Settings. These assert that the door it names actually opens.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.switch(
  p_org uuid, p_code text, p_on boolean default true)
returns text language plpgsql as $$
begin
  perform public.set_own_module(p_org, p_code, p_on);
  return case when app.has_module(p_org, p_code) then 'on' else 'off' end;
exception when others then return SQLERRM;
end $$;

do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_core  text;
begin
  perform pg_temp.sign_in_as(v_owner);
  -- Not the whole catalogue: the helper's default hands out every
  -- module, and a company that already holds everything has nothing to
  -- switch on.
  v_org := pg_temp.test_org('Syarikat Modul Sdn Bhd', array['crm']);

  -- ------------------------------------------------------------------
  -- Switching one on
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('it is not held to begin with',
    not app.has_module(v_org, 'multi_company'));
  perform pg_temp.check_eq('the company holds it the moment it is switched on',
    pg_temp.switch(v_org, 'multi_company'), 'on');
  perform pg_temp.check_eq('and a company can switch it off again',
    pg_temp.switch(v_org, 'multi_company', false), 'off');

  -- A lapsed entitlement that is switched on again is on. Leaving the
  -- old expiry would grant something that reads as held and behaves as
  -- absent, which is the worst of both.
  update public.org_modules
     set is_enabled = true, expires_at = now() - interval '1 day'
   where org_id = v_org and module_code = 'multi_company';
  perform pg_temp.check_true('a lapsed module reads as absent',
    not app.has_module(v_org, 'multi_company'));
  perform pg_temp.check_eq('a module that had lapsed comes back',
    pg_temp.switch(v_org, 'multi_company'), 'on');

  -- ------------------------------------------------------------------
  -- What cannot be switched
  -- ------------------------------------------------------------------
  select code into v_core from public.platform_modules
   where is_core and is_active order by sort_order limit 1;
  perform pg_temp.check_true('a core module is not something to switch on',
    pg_temp.switch(v_org, v_core) like '%is part of the product and is '
      'always on');
  perform pg_temp.check_eq(
    'a module that is not for sale cannot be switched on',
    pg_temp.switch(v_org, 'teleportation'),
    'There is no such module for sale');

  -- ------------------------------------------------------------------
  -- Who may
  -- ------------------------------------------------------------------
  v_clerk := pg_temp.another_user('kerani-0488@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accounts_clerk', 'active', now());
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_eq('a clerk cannot commit the company to a bill',
    pg_temp.switch(v_org, 'loyalty'),
    'Only an owner or admin may change the modules');
  perform pg_temp.check_true('so it stays off',
    not app.has_module(v_org, 'loyalty'));

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-0488@iakauntan.test'));
  perform pg_temp.check_eq(
    'somebody outside the company cannot switch anything on',
    pg_temp.switch(v_org, 'loyalty'),
    'Only an owner or admin may change the modules');

  -- ------------------------------------------------------------------
  -- The door 0486 names
  -- ------------------------------------------------------------------
  -- 0486 refuses a second company and says to turn Multi-Company on
  -- under Settings. Until 0488 there was nothing there to turn on, so
  -- the refusal named a room with no key in it.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('with the module on, another company may be added',
    (select case when public.can_add_company() then 'yes' else 'no' end),
    'yes');
  perform pg_temp.check_eq('and switching it off closes that door again',
    pg_temp.switch(v_org, 'multi_company', false), 'off');
  perform pg_temp.check_eq('so the refusal comes back',
    (select case when public.can_add_company() then 'yes' else 'no' end),
    'no');

  raise notice 'module self-service: all assertions passed';
end $$;

rollback;

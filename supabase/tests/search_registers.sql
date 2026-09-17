-- =====================================================================
-- iAkauntan :: which register Entity Search offers
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/search_registers.sql
--
-- `0606` turns "Check the SSM register" into "Entity Search" and makes
-- the list of registers a table an administrator can add to.
--
-- The one rule that is not bookkeeping: a register this application
-- cannot SEARCH must carry an address. Two of the three cannot be
-- searched and that is a fact about them rather than unfinished work —
-- MIA's register is behind a bot challenge with no API, and nobody has
-- established what the Bar offers. A register that can neither be
-- asked nor opened is a choice that does nothing when somebody picks
-- it, which is the quiet failure this refuses.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

do $$
declare
  v_seen bigint;
  v_role text;
begin
  -- ==================================================================
  -- 1. The three, and which of them answers
  -- ==================================================================
  select count(*) into v_seen from public.search_registers where is_builtin;
  perform pg_temp.check_eq('the three it shipped with', v_seen, 3::bigint);

  -- SSM is the only one this application can ask, and that is the
  -- whole distinction the screen turns on.
  select count(*) into v_seen
    from public.search_registers where can_search;
  perform pg_temp.check_eq('exactly one can be searched', v_seen, 1::bigint);
  perform pg_temp.check_true(
    'and it is SSM',
    exists (select 1 from public.search_registers
             where code = 'ssm' and can_search));

  -- The control: MIA is on the list and cannot be searched. Without
  -- this, a table holding only SSM would pass the count above.
  perform pg_temp.check_true(
    'while MIA is offered and cannot',
    exists (select 1 from public.search_registers
             where code = 'mia' and not can_search));

  -- Every register that cannot be searched has somewhere to send
  -- somebody. Asserted over the table rather than for MIA alone, so a
  -- fourth added later is held to it too.
  select count(*) into v_seen
    from public.search_registers
   where not can_search
     and nullif(btrim(coalesce(url, '')), '') is null;
  perform pg_temp.check_eq(
    'nothing unsearchable is also unreachable', v_seen, 0::bigint);

  -- ==================================================================
  -- 2. Only a platform administrator writes
  -- ==================================================================
  set local role authenticated;
  select current_user into v_role;
  perform pg_temp.check_eq(
    'the role actually switched', v_role, 'authenticated');

  begin
    perform public.platform_save_search_register('bursa', 'Bursa Malaysia');
    perform pg_temp.check_true(
      'somebody signed in cannot add a register', false);
  exception when insufficient_privilege or sqlstate '42501' then
    perform pg_temp.check_true(
      'somebody signed in cannot add a register', true);
  end;

  select count(*) into v_seen from public.search_registers;
  perform pg_temp.check_true(
    'though they can read the list, which is a list of choices',
    v_seen >= 3);

  reset role;
end $$;

-- =====================================================================
-- 3. What the administrator may and may not do
-- =====================================================================
do $$
declare v_me uuid;
begin
  -- `sign_in_as` and not merely `test_user()`. The guards inside these
  -- functions read `auth.uid()`, which the suite stubs out of
  -- `request.jwt.claims` — so without this the caller is nobody and a
  -- platform administrator's row belongs to somebody who is not
  -- asking. `test_org()` happens to sign in as a side effect, which is
  -- why a file that builds one does not need this line and this file
  -- does.
  v_me := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  -- The rule worth having. A register nobody can search and nobody can
  -- open is a row that does nothing.
  begin
    perform public.platform_save_search_register('bursa', 'Bursa Malaysia');
    perform pg_temp.check_true(
      'a register that can neither be searched nor opened is refused',
      false);
  exception when sqlstate '23514' then
    perform pg_temp.check_true(
      'a register that can neither be searched nor opened is refused',
      true);
  end;

  -- With an address it is fine.
  perform public.platform_save_search_register(
    'bursa', 'Bursa Malaysia', 'Listed companies', false,
    'https://www.bursamalaysia.com/', 40, true);
  perform pg_temp.check_true(
    'with an address it is added',
    exists (select 1 from public.search_registers
             where code = 'bursa' and url like '%bursamalaysia%'
               and not is_builtin));

  -- And one this application CAN search needs no address, because the
  -- search is the way in.
  perform public.platform_save_search_register(
    'inland_revenue', 'LHDN', 'Tax agents', true, null, 50, true);
  perform pg_temp.check_true(
    'one that can be searched needs no address',
    exists (select 1 from public.search_registers
             where code = 'inland_revenue' and can_search));

  -- An absent argument leaves it alone: correcting a name must not
  -- silently claim a register can be searched.
  perform public.platform_save_search_register('bursa', 'Bursa');
  perform pg_temp.check_true(
    'correcting a name leaves everything else alone',
    exists (select 1 from public.search_registers
             where code = 'bursa' and name = 'Bursa'
               and not can_search and sort_order = 40
               and url like '%bursamalaysia%'));

  -- Removing one that was added here.
  perform public.platform_delete_search_register('bursa');
  perform pg_temp.check_true(
    'a register added here can be removed',
    not exists (select 1 from public.search_registers where code = 'bursa'));

  -- But not one it shipped with: the code is what a recorded lookup
  -- will name.
  begin
    perform public.platform_delete_search_register('ssm');
    perform pg_temp.check_true('a built-in register cannot be removed', false);
  exception when sqlstate '23503' then
    perform pg_temp.check_true('a built-in register cannot be removed', true);
  end;

  -- Switching it off is what was meant.
  perform public.platform_save_search_register(
    'bar', 'Malaysian Bar', null, null, null, null, false);
  perform pg_temp.check_true(
    'but it can be switched off',
    exists (select 1 from public.search_registers
             where code = 'bar' and not is_active));
end $$;

rollback;

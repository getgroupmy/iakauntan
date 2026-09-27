-- =====================================================================
-- iAkauntan :: assigning and removing a company's access, from the console
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/platform_org_access.sql
--
-- `0720`. Unlike `0719`'s support grant, this is PERMANENT and it is
-- the customer's own access: a person assigned here can write, and
-- depending on the role can post to the ledger.
--
-- The claim the file exists for is the invariant: a company always has
-- an owner. It is checked on BOTH paths -- demoting the last owner and
-- removing the last owner leave the company in exactly the same state,
-- and it would be easy to guard only the one that looks dangerous.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.console_admin()
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = 'console@iakauntan.test';
  if v_id is null then
    v_id := pg_temp.another_user('console@iakauntan.test');
  end if;
  insert into public.platform_admins (user_id) values (v_id)
  on conflict do nothing;
  return v_id;
end;
$$;

create or replace function pg_temp.somebody(p_who text)
returns uuid language sql as $$
  select pg_temp.another_user(p_who || '-' || gen_random_uuid() || '@iakauntan.test');
$$;

-- ---------------------------------------------------------------------
-- Who may, and what it refuses before it does anything
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_staff uuid := pg_temp.somebody('staff');
  v_email text;
  v_org   uuid;
begin
  v_org := pg_temp.test_org('Access Sdn Bhd');
  select email::text into v_email from public.profiles where id = v_staff;

  -- As the company's own owner, who is not platform staff.
  begin
    perform public.platform_assign_org_access(v_org, v_email, 'admin');
    raise exception 'FAIL: an ordinary user assigned access';
  exception when sqlstate '42501' then
    raise notice 'ok   only the platform assigns access from the console';
  end;

  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_assign_org_access(
      gen_random_uuid(), v_email, 'admin');
    raise exception 'FAIL: assigned into a company that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   not into a company that does not exist';
  end;

  begin
    perform public.platform_assign_org_access(
      v_org, 'nobody@example.invalid', 'admin');
    raise exception 'FAIL: assigned access to nobody';
  exception when sqlstate 'P0002' then
    raise notice 'ok   nor to somebody who is not here';
  end;

  -- A role that does not exist. The message has to say what the roles
  -- ARE: `'manger'::app.member_role` raises 22P02 quoting the typo and
  -- nothing else, at the end of a form somebody just filled in.
  begin
    perform public.platform_assign_org_access(v_org, v_email, 'manger');
    raise exception 'FAIL: assigned a role that does not exist';
  exception when sqlstate '23514' then
    raise notice 'ok   and not a role this platform has never heard of';
  end;

  raise notice 'ok   assigning access is asked for, and checked first';
end $$;

-- ---------------------------------------------------------------------
-- Assigning, changing and removing
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_staff uuid := pg_temp.somebody('clerk');
  v_email text;
  v_org   uuid;
begin
  v_org := pg_temp.test_org('Growing Team Sdn Bhd');
  select email::text into v_email from public.profiles where id = v_staff;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_assign_org_access(v_org, v_email, 'accounts_clerk');
  perform pg_temp.check_eq('somebody is given access',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_staff), 'accounts_clerk');
  perform pg_temp.check_eq('and it is active straight away',
    (select status::text from public.org_members
      where org_id = v_org and user_id = v_staff), 'active');

  -- It is really access, not a row: the guards answer for them.
  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_true('the person can now open the company',
    app.is_org_member(v_org));
  perform pg_temp.check_true('and write in it',
    app.can_write(v_org));
  perform pg_temp.check_true('but not administer it, on that role',
    not app.can_admin(v_org));

  -- Assigning again is a role change, not a refusal. A console that
  -- made somebody remove and re-add would lose `joined_at` and write
  -- two audit rows describing something that never happened.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_assign_org_access(v_org, v_email, 'admin');
  perform pg_temp.check_eq('assigning again changes the role',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_staff), 'admin');
  perform pg_temp.check_eq('and does not make a second row',
    (select count(*) from public.org_members
      where org_id = v_org and user_id = v_staff), 1);

  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_true('so now they can administer it',
    app.can_admin(v_org));

  -- And the console can see it from either end.
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('the console lists the company''s people',
    (select count(*) from public.platform_org_members(v_org)) >= 2);
  perform pg_temp.check_eq('and the companies one person can open',
    (select count(*) from public.platform_user_organizations(v_staff)), 1);

  -- Taking it away.
  perform public.platform_remove_org_access(v_org, v_staff);
  perform pg_temp.check_eq('removing it takes the row out',
    (select count(*) from public.org_members
      where org_id = v_org and user_id = v_staff), 0);

  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_true('and the company closes to them',
    not app.is_org_member(v_org));

  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.platform_remove_org_access(v_org, v_staff);
    raise exception 'FAIL: removed access that was not there';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and removing it twice says so';
  end;

  raise notice 'ok   access is given, changed and taken away';
end $$;

-- ---------------------------------------------------------------------
-- A company always has an owner. Both ways of losing the last one
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_owner uuid := pg_temp.test_user();
  v_other uuid := pg_temp.somebody('second');
  v_email text;
  v_own_email text;
  v_org   uuid;
begin
  v_org := pg_temp.test_org('One Owner Sdn Bhd');
  select email::text into v_own_email from public.profiles where id = v_owner;
  select email::text into v_email from public.profiles where id = v_other;
  perform pg_temp.sign_in_as(v_admin);

  perform pg_temp.check_eq('the company starts with one owner',
    (select count(*) from public.org_members
      where org_id = v_org and role = 'owner' and status = 'active'), 1);

  -- Removing them.
  begin
    perform public.platform_remove_org_access(v_org, v_owner);
    raise exception 'FAIL: removed the only owner';
  exception when sqlstate '23514' then
    raise notice 'ok   the only owner cannot be removed';
  end;

  -- DEMOTING them, which leaves the company in exactly the same state
  -- and is the half that does not look dangerous.
  begin
    perform public.platform_assign_org_access(v_org, v_own_email, 'viewer');
    raise exception 'FAIL: demoted the only owner';
  exception when sqlstate '23514' then
    raise notice 'ok   and the only owner cannot be demoted either';
  end;

  perform pg_temp.check_eq('so the company still has its owner',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_owner), 'owner');

  -- With a second owner, both become ordinary acts.
  perform public.platform_assign_org_access(v_org, v_email, 'owner');
  perform public.platform_assign_org_access(v_org, v_own_email, 'viewer');
  perform pg_temp.check_eq('a second owner makes a demotion ordinary',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_owner), 'viewer');
  perform pg_temp.check_eq('and the company is still openable',
    (select count(*) from public.org_members
      where org_id = v_org and role = 'owner' and status = 'active'), 1);

  raise notice 'ok   a company never loses its last owner';
end $$;

-- ---------------------------------------------------------------------
-- The company can see what was done to it
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_staff uuid := pg_temp.somebody('audited');
  v_email text;
  v_org   uuid;
begin
  v_org := pg_temp.test_org('Audited Sdn Bhd');
  select email::text into v_email from public.profiles where id = v_staff;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_assign_org_access(v_org, v_email, 'sales');
  perform pg_temp.check_eq('the assignment is in the company''s trail',
    (select count(*) from public.audit_logs
      where org_id = v_org and table_name = 'org_members'
        and new_data ->> 'event' = 'platform_assign_access'), 1);

  perform public.platform_remove_org_access(v_org, v_staff);
  perform pg_temp.check_eq('and so is the removal',
    (select count(*) from public.audit_logs
      where org_id = v_org and table_name = 'org_members'
        and new_data ->> 'event' = 'platform_remove_access'), 1);
  perform pg_temp.check_true('with what was there before it',
    (select old_data ->> 'role' from public.audit_logs
      where org_id = v_org and table_name = 'org_members'
        and new_data ->> 'event' = 'platform_remove_access' limit 1) = 'sales');

  raise notice 'ok   the company can see who was let in and out';
end $$;

rollback;

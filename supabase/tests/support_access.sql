-- =====================================================================
-- iAkauntan :: support access, and a company made for somebody
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/support_access.sql
--
-- `0719`. A platform administrator entering a customer's account to see
-- what they see.
--
-- The claims worth the file are the NEGATIVE ones. That a grant lets
-- somebody read is easy and would be noticed in a day; that it lets
-- them WRITE would not be noticed at all until a customer's ledger had
-- a row in it nobody could explain. So the writes are checked at every
-- level -- write, post, administer -- in the one state where they might
-- leak.
--
-- And the other direction: that it stops. Expiry, revocation by us,
-- revocation BY THE CUSTOMER, and a real member not being quietly
-- demoted by a grant somebody left open.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.make_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

-- The platform administrator has to be a DIFFERENT PERSON from the
-- customer. `pg_temp.test_user()` returns one fixed fixture user and
-- the `add_creator_as_owner` trigger makes them the owner of every
-- company created here -- so using it for both sides would have the
-- administrator already owning the books they are asking to read, and
-- every assertion below would pass for the wrong reason.
--
-- Looked up before it is created: `pg_temp.another_user` always
-- INSERTS, so calling it once per block collides on the e-mail.
create or replace function pg_temp.support_admin()
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = 'support@iakauntan.test';
  if v_id is null then
    v_id := pg_temp.another_user('support@iakauntan.test');
  end if;
  perform pg_temp.make_platform_admin(v_id);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Who may grant one, and what it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_admin uuid := pg_temp.support_admin();
  v_org   uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Customer Sdn Bhd');

  -- An ordinary user, even the owner of the company in question.
  begin
    perform public.grant_support_access(v_org, 'curiosity');
    raise exception 'FAIL: an ordinary user granted support access';
  exception when sqlstate '42501' then
    raise notice 'ok   only the platform grants support access';
  end;

  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.grant_support_access(v_org, '   ');
    raise exception 'FAIL: granted with no reason';
  exception when sqlstate '23514' then
    raise notice 'ok   a grant with no reason recorded is refused';
  end;

  begin
    perform public.grant_support_access(gen_random_uuid(), 'a reason');
    raise exception 'FAIL: granted over a company that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and one over no company at all';
  end;

  raise notice 'ok   support access is asked for, with a reason';
end $$;

-- ---------------------------------------------------------------------
-- What it opens, and -- the point of the file -- what it does not
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_admin uuid := pg_temp.support_admin();
  v_org   uuid;
  v_id    uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Books To Read Sdn Bhd');

  perform pg_temp.sign_in_as(v_admin);

  -- Before. A platform administrator is not a member of anything.
  perform pg_temp.check_true('before a grant, the company is not visible',
    not app.is_org_member(v_org));
  perform pg_temp.check_true('and not in the switcher',
    not exists (select 1 from public.my_organizations() o where o.id = v_org));
  perform pg_temp.check_true('and the ledger is closed',
    not app.can_read_ledger(v_org));

  v_id := public.grant_support_access(v_org, 'Customer reported a missing invoice');

  -- After.
  perform pg_temp.check_true('a grant opens the company',
    app.is_org_member(v_org));
  perform pg_temp.check_true('and puts it in the switcher',
    exists (select 1 from public.my_organizations() o where o.id = v_org));
  perform pg_temp.check_true('and opens the ledger',
    app.can_read_ledger(v_org));
  perform pg_temp.check_eq('as an auditor, which is the read-only role',
    app.org_role(v_org)::text, 'auditor');

  -- THE ASSERTIONS THIS FILE EXISTS FOR.
  perform pg_temp.check_true('but it cannot write',
    not app.can_write(v_org));
  perform pg_temp.check_true('cannot post to the ledger',
    not app.can_post(v_org));
  perform pg_temp.check_true('and cannot administer the company',
    not app.can_admin(v_org));

  raise notice 'ok   a support session reads everything and changes nothing';
end $$;

-- ---------------------------------------------------------------------
-- That it stops
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_admin uuid := pg_temp.support_admin();
  v_org   uuid;
  v_id    uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Time Limited Sdn Bhd');
  perform pg_temp.sign_in_as(v_admin);

  -- Expiry. Access that has to be remembered to be revoked is access
  -- that never is.
  v_id := public.grant_support_access(v_org, 'Looking at a bank import', 30);
  perform pg_temp.check_true('while it runs, the company is open',
    app.is_org_member(v_org));

  -- Both, because `support_access_window_ck` keeps `expires_at` after
  -- `granted_at` -- which is right, and means winding the clock back
  -- has to wind the whole window back.
  update public.support_access
     set granted_at = now() - interval '2 hours',
         expires_at = now() - interval '1 minute'
   where id = v_id;
  perform pg_temp.check_true('once it expires, the company closes again',
    not app.is_org_member(v_org));
  perform pg_temp.check_true('and leaves the switcher',
    not exists (select 1 from public.my_organizations() o where o.id = v_org));
  perform pg_temp.check_true('and the ledger with it',
    not app.can_read_ledger(v_org));

  -- Capped. Eight hours is longer than any support call.
  v_id := public.grant_support_access(v_org, 'A long one', 10000);
  perform pg_temp.check_true('a grant cannot be opened for a week',
    (select expires_at from public.support_access where id = v_id)
      <= now() + interval '8 hours' + interval '1 minute');

  -- Asking twice extends rather than stacks, so ending it ends it.
  perform public.grant_support_access(v_org, 'And again');
  perform pg_temp.check_eq('one open grant per administrator per company',
    (select count(*) from public.support_access
      where org_id = v_org and admin_id = v_admin and ended_at is null), 1);

  perform public.end_support_access(
    (select id from public.support_access
      where org_id = v_org and admin_id = v_admin and ended_at is null));
  perform pg_temp.check_true('ending it closes the company',
    not app.is_org_member(v_org));

  raise notice 'ok   it expires, it is capped, and it can be ended';
end $$;

-- ---------------------------------------------------------------------
-- The customer can see it, and can show them out
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_admin uuid := pg_temp.support_admin();
  v_org   uuid;
  v_id    uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Watching Back Sdn Bhd');

  perform pg_temp.sign_in_as(v_admin);
  v_id := public.grant_support_access(v_org, 'Chasing a duplicated payment');

  perform pg_temp.sign_in_as(v_owner);

  -- Their own audit trail, not only ours. A support feature visible
  -- only to the people using it is surveillance with a nicer name.
  perform pg_temp.check_eq('the grant is in the customer''s audit trail',
    (select count(*) from public.audit_logs
      where org_id = v_org and table_name = 'support_access'
        and new_data ->> 'event' = 'support_granted'), 1);
  perform pg_temp.check_true('with the reason in it',
    (select new_data ->> 'reason' from public.audit_logs
      where org_id = v_org and table_name = 'support_access'
        and new_data ->> 'event' = 'support_granted' limit 1)
      = 'Chasing a duplicated payment');

  perform pg_temp.check_eq('and the company can see who is reading it',
    (select count(*) from public.org_support_access(v_org)), 1);

  -- And can end it. Seeing somebody in your books without being able
  -- to show them out is a notification, not a control.
  perform public.end_support_access(v_id);
  perform pg_temp.check_eq('the customer can end it themselves',
    (select count(*) from public.org_support_access(v_org)), 0);

  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and the administrator is out',
    not app.is_org_member(v_org));

  raise notice 'ok   the customer sees it and can end it';
end $$;

-- ---------------------------------------------------------------------
-- A real membership is never demoted by a grant
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.support_admin();
  v_org   uuid;
begin
  -- A company the platform administrator genuinely owns. Created while
  -- signed in AS THEM, so `add_creator_as_owner` makes them the owner.
  perform pg_temp.sign_in_as(v_admin);
  insert into public.organizations (name, slug, entity_type, base_currency)
  values ('My Own Firm Sdn Bhd',
          'my-own-firm-' || gen_random_uuid(), 'sdn_bhd', 'MYR')
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, pm.code, true from public.platform_modules pm
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.check_eq('they own it', app.org_role(v_org)::text, 'owner');
  perform public.grant_support_access(v_org, 'Reproducing a bug on my own books');

  -- `coalesce` puts the real membership first. Without it, a grant left
  -- open would silently take away somebody's ability to run their own
  -- company.
  perform pg_temp.check_eq('and a grant does not demote them to auditor',
    app.org_role(v_org)::text, 'owner');
  perform pg_temp.check_true('so they can still post to their own ledger',
    app.can_post(v_org));

  raise notice 'ok   a grant never takes a real role away';
end $$;

-- ---------------------------------------------------------------------
-- A company made for somebody else
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.support_admin();
  v_cust  uuid := pg_temp.another_user('newowner-' || gen_random_uuid() || '@iakauntan.test');
  v_email text;
  v_org   uuid;
begin
  perform pg_temp.sign_in_as(v_cust);
  select email::text into v_email from public.profiles where id = v_cust;

  -- Tried as the CUSTOMER, who is nobody in particular. `v_admin` is a
  -- platform administrator from the moment it is declared, so trying it
  -- as them would have proved only that the fixture works.
  begin
    perform public.platform_create_organization(v_email, 'Too Soon Sdn Bhd');
    raise exception 'FAIL: an ordinary user made a company for somebody';
  exception when sqlstate '42501' then
    raise notice 'ok   only the platform makes a company for somebody else';
  end;

  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_create_organization(
      'nobody@example.invalid', 'Ownerless Sdn Bhd');
    raise exception 'FAIL: made a company nobody owns';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a company with no owner is one nobody can open';
  end;

  v_org := public.platform_create_organization(v_email, 'Made For You Sdn Bhd');

  perform pg_temp.check_eq('the named person owns it',
    (select user_id from public.org_members
      where org_id = v_org and role = 'owner' and status = 'active'), v_cust);
  perform pg_temp.check_true('and the administrator holds nothing',
    not exists (select 1 from public.org_members
                 where org_id = v_org and user_id = v_admin
                   and status = 'active'));

  -- Composed, not copied: the seeding is `create_organization`'s and
  -- there is only one of it.
  perform pg_temp.check_true('it has a chart of accounts',
    (select count(*) from public.accounts where org_id = v_org) > 20);
  perform pg_temp.check_true('and tax codes',
    exists (select 1 from public.tax_codes where org_id = v_org and code = 'NA'));

  -- Editing it.
  perform public.platform_update_organization(
    v_org, p_name => 'Renamed Sdn Bhd', p_phone => '03-1234 5678');
  perform pg_temp.check_eq('the console can rename it',
    (select name from public.organizations where id = v_org), 'Renamed Sdn Bhd');
  perform pg_temp.check_eq('and set what it left alone',
    (select phone from public.organizations where id = v_org), '03-1234 5678');

  -- A blank box is "I did not type here", not "delete this".
  perform public.platform_update_organization(v_org, p_name => '  ');
  perform pg_temp.check_eq('a field left blank is left alone',
    (select name from public.organizations where id = v_org), 'Renamed Sdn Bhd');

  perform pg_temp.check_true('and the edit is in the company''s trail',
    exists (select 1 from public.audit_logs
             where org_id = v_org and table_name = 'organizations'
               and new_data ->> 'event' = 'platform_update'));

  raise notice 'ok   a company is made for somebody, and can be edited';
end $$;

rollback;

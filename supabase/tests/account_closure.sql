-- =====================================================================
-- iAkauntan :: closing an account without destroying it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_closure.sql
--
-- 0619 was asked for in one sentence -- "don't permanently delete, keep
-- records, but only console admin can see; for users it is deleted" --
-- and that sentence is two assertions that pull against each other,
-- which is the only reason this file is worth having:
--
--   * GONE. The person, their colleagues and every screen the product
--     has stop seeing it. `is_org_member` says no, `my_organizations`
--     returns nothing, the name on the profile is not their name.
--   * KEPT. The identity, the membership rows and the ledger account
--     are all still in the database, and a platform operator can read
--     every one of them and put them back.
--
-- Either alone passes for the wrong reason. Scrubbing everything is
-- "gone" with nothing kept -- which is what 0158 did. Doing nothing is
-- "kept" with nothing gone.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

-- ---------------------------------------------------------------------
-- A login: gone from the product, kept in the drawer
-- ---------------------------------------------------------------------
do $$
declare
  v_leaving uuid := pg_temp.another_user('leaving@closure.test');
  v_mate    uuid := pg_temp.another_user('staying@closure.test');
  v_org     uuid;
  v_res     jsonb;
  v_closure uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Kept Sdn Bhd', 'kept-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          v_leaving)
  returning id into v_org;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_leaving, 'owner', 'active'),
         (v_org, v_mate, 'owner', 'active')
  on conflict do nothing;
  update public.profiles
     set full_name = 'Leaving Person', email = 'leaving@closure.test',
         phone = '+60123456789'
   where id = v_leaving;
  update public.profiles set full_name = 'Team Mate' where id = v_mate;

  perform pg_temp.sign_in_as(v_leaving);
  v_res := public.close_my_account('Moving to another firm', false);
  perform pg_temp.check_eq('it reports the closure',
    v_res ->> 'closed', 'true');
  v_closure := (v_res ->> 'closure_id')::uuid;

  -- ------------------------------------------------------------------
  -- Gone
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the product shows no name',
    (select full_name from public.profiles where id = v_leaving),
    'Closed account');
  perform pg_temp.check_true('nor an address',
    (select email is null from public.profiles where id = v_leaving));
  perform pg_temp.check_true('nor a number',
    (select phone is null from public.profiles where id = v_leaving));
  perform pg_temp.check_true('sign-in is shut',
    (select banned_until is not null from auth.users where id = v_leaving));

  -- Still signed in as them, which is the case that matters: a session
  -- issued before the closure must not still open the books.
  perform pg_temp.sign_in_as(v_leaving);
  perform pg_temp.check_true('the guard every policy calls says no',
    not app.is_org_member(v_org));
  perform pg_temp.check_true('and the role behind it is nothing',
    app.org_role(v_org) is null);
  perform pg_temp.check_eq('the switcher offers no company',
    (select count(*) from public.my_organizations()), 0);

  -- ------------------------------------------------------------------
  -- Kept
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the membership row is still there',
    (select count(*) from public.org_members
      where user_id = v_leaving), 1);
  perform pg_temp.check_eq('suspended rather than deleted',
    (select status::text from public.org_members
      where user_id = v_leaving and org_id = v_org), 'suspended');
  perform pg_temp.check_eq('the closure keeps the real name',
    (select c.detail ->> 'full_name' from public.account_closures c
      where c.id = v_closure), 'Leaving Person');
  perform pg_temp.check_eq('and the real address',
    (select c.detail ->> 'email' from public.account_closures c
      where c.id = v_closure), 'leaving@closure.test');
  perform pg_temp.check_eq('and why they went',
    (select c.reason from public.account_closures c where c.id = v_closure),
    'Moving to another firm');
  perform pg_temp.check_eq('and that they pressed the button themselves',
    (select c.closed_via from public.account_closures c where c.id = v_closure),
    'self_service');
  perform pg_temp.check_true('the user row is still there to point at',
    exists (select 1 from auth.users where id = v_leaving));
  perform pg_temp.check_true('and the company still records who created it',
    (select created_by = v_leaving from public.organizations where id = v_org));

  -- Nobody else was touched, which a scrub with a missing WHERE would
  -- fail and every assertion above would still pass.
  perform pg_temp.sign_in_as(v_mate);
  perform pg_temp.check_eq('the colleague is untouched',
    (select full_name from public.profiles where id = v_mate), 'Team Mate');
  perform pg_temp.check_true('and still holds the company',
    app.is_org_member(v_org));
end $$;

-- ---------------------------------------------------------------------
-- The sole owner: refused, unless the companies go too
--
-- 0158's refusal, kept. What is added is the other answer, which is the
-- "multi" half of what was asked for: one login holding several
-- companies alone can now leave in one action, and each company is
-- recorded as its own closure rather than as a side effect.
-- ---------------------------------------------------------------------
do $$
declare
  v_solo uuid := pg_temp.another_user('solo@closure.test');
  v_a    uuid;
  v_b    uuid;
  v_msg  text;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Alone One Sdn Bhd', 'alone1-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_solo)
  returning id into v_a;
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Alone Two Sdn Bhd', 'alone2-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_solo)
  returning id into v_b;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_a, v_solo, 'owner', 'active'), (v_b, v_solo, 'owner', 'active')
  on conflict do nothing;

  perform pg_temp.sign_in_as(v_solo);
  perform pg_temp.check_eq('both companies are blockers',
    (select count(*) from public.my_account_deletion_blockers()), 2);

  begin
    perform public.close_my_account(null, false);
    v_msg := null;
  exception when sqlstate '23514' then
    v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_solo);
  perform pg_temp.check_eq('and the sole owner is refused', v_msg,
    'refused');
  perform pg_temp.check_true('with nothing closed',
    (select deleted_at is null from public.organizations where id = v_a));
  perform pg_temp.check_true('nothing scrubbed',
    (select deleted_at is null from public.profiles where id = v_solo));

  -- And the other answer.
  perform pg_temp.check_eq('taking the companies with it closes both',
    (public.close_my_account('Retiring', true) ->> 'organizations_closed')
      ::numeric, 2);
  perform pg_temp.check_true('the first company is closed',
    (select deleted_at is not null from public.organizations where id = v_a));
  perform pg_temp.check_true('so is the second',
    (select deleted_at is not null from public.organizations where id = v_b));
  perform pg_temp.check_eq('each recorded as its own closure',
    (select count(*) from public.account_closures c
      where c.subject_kind = 'organization' and c.subject_id in (v_a, v_b)), 2);

  -- Nothing in either company was deleted. The books are exactly where
  -- they were; what changed is who can see them.
  perform pg_temp.check_eq('and neither company lost a row',
    (select count(*) from public.org_members where org_id in (v_a, v_b)), 2);
end $$;

-- ---------------------------------------------------------------------
-- A company: closed under a member who is not closed themselves
--
-- The other half of "normal and multi". Closing one company is not
-- closing the login, and the login keeps the others.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.another_user('twohats@closure.test');
  v_keep  uuid;
  v_shut  uuid;
  v_msg   text;
  v_hand  uuid := pg_temp.another_user('staff@closure.test');
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Kept Trading', 'keeptrade-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_owner)
  returning id into v_keep;
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Shut Trading', 'shuttrade-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_owner)
  returning id into v_shut;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_keep, v_owner, 'owner', 'active'),
         (v_shut, v_owner, 'owner', 'active'),
         (v_shut, v_hand, 'accountant', 'active')
  on conflict do nothing;

  -- An accountant is not an owner, and closing a company is not a
  -- posting right.
  perform pg_temp.sign_in_as(v_hand);
  begin
    perform public.close_organization(v_shut, null);
    v_msg := null;
  exception when sqlstate '42501' then
    v_msg := 'refused';
  end;
  perform pg_temp.check_eq('only an owner may close a company', v_msg,
    'refused');

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('the owner may',
    (public.close_organization(v_shut, 'Struck off') ->> 'closed')::boolean);

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and it goes dark for its own owner',
    not app.is_org_member(v_shut));
  perform pg_temp.check_true('while the other company is untouched',
    app.is_org_member(v_keep));
  perform pg_temp.check_eq('the switcher offers one company, not two',
    (select count(*) from public.my_organizations()), 1);

  perform pg_temp.sign_in_as(v_hand);
  perform pg_temp.check_true('and dark for everybody else on it',
    not app.is_org_member(v_shut));

  -- Kept: the rows are all still there.
  perform pg_temp.check_eq('nothing was deleted',
    (select count(*) from public.org_members where org_id = v_shut), 2);
  perform pg_temp.check_eq('and the closure says what it was called',
    (select c.label from public.account_closures c
      where c.subject_kind = 'organization' and c.subject_id = v_shut),
    'Shut Trading');
end $$;

-- ---------------------------------------------------------------------
-- A ledger account: never deleted, not even an unused one
--
-- 0459 deleted an account nothing had ever been posted to. That was the
-- right answer to the question it was asked and the wrong answer to
-- this one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Chart Closure');
  v_acct  uuid;
  v_out   text;
begin
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '6911', 'Never Used', 'expense', 'other_expense')
  returning id into v_acct;

  v_out := public.retire_account(v_acct);
  perform pg_temp.check_eq('an untouched account is closed, not deleted',
    v_out, 'closed');
  perform pg_temp.check_true('the row is still there',
    exists (select 1 from public.accounts where id = v_acct));
  perform pg_temp.check_true('switched off',
    (select not is_active from public.accounts where id = v_acct));
  perform pg_temp.check_true('and hidden',
    (select deleted_at is not null from public.accounts where id = v_acct));
  perform pg_temp.check_eq('with a closure naming it',
    (select c.label from public.account_closures c
      where c.subject_kind = 'ledger_account' and c.subject_id = v_acct),
    '6911 Never Used');

  -- A second attempt is refused rather than writing a second closure.
  begin
    perform public.retire_account(v_acct);
    v_out := null;
  exception when sqlstate '23505' then
    v_out := 'refused';
  end;
  perform pg_temp.check_eq('closing it twice is refused', v_out, 'refused');
end $$;

-- ---------------------------------------------------------------------
-- An account the ledger brings back is not still closed
--
-- 0532 and 0539 gave thirteen posting helpers the job of REVIVING a
-- retired account rather than raising on its unique code or posting to
-- it while retired. So a ledger account can come back without the
-- console -- and if the closure written when it was retired stayed
-- open, the console would offer to restore something already alive and
-- the next retirement would be refused by a unique index.
-- ---------------------------------------------------------------------
--
-- Driven through the console rather than through `retire_account`,
-- because the thirteen accounts the helpers revive are all accounts the
-- ledger posts to by number, and `retire_account` refuses those by name
-- -- 0459's rule, and the right one. An operator's close is the path
-- that can actually reach one.
do $$
declare
  v_admin uuid := pg_temp.another_user('operator3@closure.test');
  v_org   uuid := pg_temp.test_org('Revived Chart');
  v_acct  uuid;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', app.today())::date);

  -- The account withholding tax sits in, which is one of the thirteen.
  v_acct := app.withholding_account(v_org);

  perform pg_temp.a_platform_admin(v_admin);
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('the operator closes it once',
    (public.platform_close_account('ledger_account', v_acct, 'Tidying')
      ->> 'closed')::boolean);
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('and the drawer holds one open closure',
    (select count(*) from public.account_closures
      where subject_kind = 'ledger_account' and subject_id = v_acct
        and restored_at is null), 1);

  -- A posting asks for it, and gets it back alive.
  perform pg_temp.check_eq('the ledger revives the same account',
    app.withholding_account(v_org), v_acct);
  perform pg_temp.check_true('so it is not closed any more',
    (select deleted_at is null from public.accounts where id = v_acct));

  -- Closing it again works, and the stale closure was closed out
  -- rather than left for the console to offer.
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('and it can be closed again',
    (public.platform_close_account('ledger_account', v_acct, 'Again')
      ->> 'closed')::boolean);
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('with still one open closure, not two',
    (select count(*) from public.account_closures
      where subject_kind = 'ledger_account' and subject_id = v_acct
        and restored_at is null), 1);
  perform pg_temp.check_eq('and the superseded one marked so',
    (select count(*) from public.account_closures
      where subject_kind = 'ledger_account' and subject_id = v_acct
        and restored_at is not null), 1);
end $$;

-- ---------------------------------------------------------------------
-- The drawer is shut
--
-- Row level security with no policy at all is how this schema says
-- "nobody's". The grant has to agree: a table one dropped policy away
-- from listing every closed account's email address is not a margin
-- worth keeping.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('account_closures has row level security on',
    (select relrowsecurity from pg_class
      where oid = 'public.account_closures'::regclass));
  perform pg_temp.check_true('and not one policy',
    not exists (select 1 from pg_policies
                 where schemaname = 'public'
                   and tablename = 'account_closures'));
  perform pg_temp.check_true('it is not granted to authenticated',
    not has_table_privilege('authenticated', 'public.account_closures',
                            'select'));
  perform pg_temp.check_true('nor to anon',
    not has_table_privilege('anon', 'public.account_closures', 'select'));
end $$;

-- ---------------------------------------------------------------------
-- The console is the only way in, and the only way back
-- ---------------------------------------------------------------------
do $$
declare
  v_admin   uuid := pg_temp.another_user('operator@closure.test');
  v_person  uuid := pg_temp.another_user('closed@closure.test');
  v_nosy    uuid := pg_temp.another_user('nosy@closure.test');
  v_org     uuid;
  v_closure uuid;
  v_msg     text;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Console Sdn Bhd', 'console-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_person)
  returning id into v_org;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_person, 'admin', 'active'),
         (v_org, v_nosy, 'owner', 'active')
  on conflict do nothing;
  update public.profiles
     set full_name = 'Closed Person', email = 'closed@closure.test'
   where id = v_person;

  -- A tenant owner is not a platform operator, and each of the three
  -- refuses them by name rather than by returning nothing.
  perform pg_temp.sign_in_as(v_nosy);
  begin
    perform * from public.platform_closed_accounts(null, false);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_nosy);
  perform pg_temp.check_eq('reading closures needs the console', v_msg,
    'refused');

  begin
    perform public.platform_close_account('user', v_person, null);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_nosy);
  perform pg_temp.check_eq('closing from the console needs the console',
    v_msg, 'refused');

  -- The operator closes it on request, which is the second path 0619
  -- was asked for.
  perform pg_temp.a_platform_admin(v_admin);
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('the operator can close somebody',
    (public.platform_close_account('user', v_person, 'Asked by email')
      ->> 'closed')::boolean);

  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('and it is recorded as the console''s doing',
    (select c.closed_via from public.platform_closed_accounts('user', false) c
      where c.subject_id = v_person), 'console');
  perform pg_temp.check_eq('with the identity the product no longer shows',
    (select c.detail ->> 'email'
       from public.platform_closed_accounts('user', false) c
      where c.subject_id = v_person), 'closed@closure.test');

  select c.id into v_closure
    from public.platform_closed_accounts('user', false) c
   where c.subject_id = v_person;

  -- Restoring is the operator's, and nobody else's.
  perform pg_temp.sign_in_as(v_nosy);
  begin
    perform public.platform_restore_account(v_closure, null);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_nosy);
  perform pg_temp.check_eq('restoring needs the console too', v_msg,
    'refused');

  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('the operator restores it',
    (public.platform_restore_account(v_closure, 'Changed their mind')
      ->> 'restored')::boolean);

  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('the name comes back',
    (select full_name from public.profiles where id = v_person),
    'Closed Person');
  perform pg_temp.check_eq('and the address',
    (select email::text from public.profiles where id = v_person),
    'closed@closure.test');
  perform pg_temp.check_true('sign-in is open again',
    (select banned_until is null from auth.users where id = v_person));
  perform pg_temp.check_eq('and the membership is back at what it was',
    (select status::text from public.org_members
      where user_id = v_person and org_id = v_org), 'active');

  perform pg_temp.sign_in_as(v_person);
  perform pg_temp.check_true('so the guard says yes again',
    app.is_org_member(v_org));

  -- Restored once, and not twice.
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.platform_restore_account(v_closure, null);
    v_msg := null;
  exception when sqlstate '23505' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('restoring twice is refused', v_msg, 'refused');
  perform pg_temp.check_eq('and the open list no longer carries it',
    (select count(*) from public.platform_closed_accounts('user', false) c
      where c.subject_id = v_person), 0);
  perform pg_temp.check_eq('while the whole list still does',
    (select count(*) from public.platform_closed_accounts('user', true) c
      where c.subject_id = v_person), 1);
end $$;

-- ---------------------------------------------------------------------
-- A company closed from the console comes back whole
-- ---------------------------------------------------------------------
do $$
declare
  v_admin   uuid := pg_temp.another_user('operator2@closure.test');
  v_owner   uuid := pg_temp.another_user('owner2@closure.test');
  v_org     uuid;
  v_closure uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by, status)
  values ('Back Again Sdn Bhd', 'back-' || gen_random_uuid(), 'sdn_bhd',
          'MYR', v_owner, 'trial')
  returning id into v_org;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_owner, 'owner', 'active') on conflict do nothing;

  perform pg_temp.a_platform_admin(v_admin);
  perform pg_temp.sign_in_as(v_admin);
  v_closure := (public.platform_close_account('organization', v_org,
    'Non-payment') ->> 'closure_id')::uuid;

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('the owner cannot see it',
    not app.is_org_member(v_org));

  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_restore_account(v_closure, null);
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('and its status is the one it had, not "active"',
    (select status from public.organizations where id = v_org), 'trial');

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('the owner has it back',
    app.is_org_member(v_org));
end $$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- The two guard functions are the ones worth asserting. Both predate
-- 0165, whose event trigger fires on CREATE OR REPLACE as well as
-- CREATE -- so replacing them without restating the grant revokes the
-- schema's central guard from every signed-in user, and the failure
-- does not show until somebody reads a table.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the membership guard is still authenticated''s',
    has_function_privilege('authenticated', 'app.is_org_member(uuid)',
                           'execute'));
  -- And still not a stranger's. 0023 swept PUBLIC off every function in
  -- `app` and granted `authenticated, service_role`; re-granting anon
  -- while restating the rest would have quietly opened the membership
  -- guard to anybody with the anon key.
  perform pg_temp.check_true('and still not a stranger''s',
    not has_function_privilege('anon', 'app.is_org_member(uuid)', 'execute'));
  perform pg_temp.check_true('the role behind it likewise',
    has_function_privilege('authenticated', 'app.org_role(uuid)', 'execute'));
  perform pg_temp.check_true('and the org switcher',
    has_function_privilege('authenticated', 'public.my_organizations()',
                           'execute'));

  perform pg_temp.check_true('closing your own account is authenticated''s',
    has_function_privilege('authenticated',
      'public.close_my_account(text, boolean)', 'execute'));
  perform pg_temp.check_true('and not a stranger''s',
    not has_function_privilege('anon',
      'public.close_my_account(text, boolean)', 'execute'));
  perform pg_temp.check_true('closing a company likewise',
    has_function_privilege('authenticated',
      'public.close_organization(uuid, text)', 'execute'));
  perform pg_temp.check_true('and not a stranger''s',
    not has_function_privilege('anon',
      'public.close_organization(uuid, text)', 'execute'));

  -- The console RPCs are granted to `authenticated` and guard
  -- themselves, which is how every other platform RPC in this schema
  -- works: the operator is a signed-in user like any other.
  perform pg_temp.check_true('the console listing is reachable by a session',
    has_function_privilege('authenticated',
      'public.platform_closed_accounts(text, boolean)', 'execute'));
  perform pg_temp.check_true('and not by a stranger',
    not has_function_privilege('anon',
      'public.platform_closed_accounts(text, boolean)', 'execute'));
  perform pg_temp.check_true('restoring is reachable by a session',
    has_function_privilege('authenticated',
      'public.platform_restore_account(uuid, text)', 'execute'));
  perform pg_temp.check_true('and not by a stranger',
    not has_function_privilege('anon',
      'public.platform_restore_account(uuid, text)', 'execute'));
end $$;

rollback;

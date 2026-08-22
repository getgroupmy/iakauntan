-- =====================================================================
-- iAkauntan :: access types
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/access_types.sql
--
-- 0127 lets a company narrow what a member may reach, module by module,
-- read or write. Two properties matter more than the feature itself.
--
-- The first is that it changes nothing until somebody uses it. Every
-- member of every existing company has no access type, and if that did
-- not mean "as before" this migration would have taken the product away
-- from all of them at once.
--
-- The second is that it cannot lock an owner out of their own company,
-- which would turn a mis-click into a support call nobody can answer
-- from inside the app.
--
-- Everything here runs as `authenticated`. The connection is a
-- superuser and a superuser bypasses row level security entirely, so a
-- policy test on the default connection asserts nothing at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.counts(p_org uuid, p_table text)
returns int language plpgsql as $$
declare v_n int;
begin
  execute format('select count(*) from public.%I where org_id = $1', p_table)
    into v_n using p_org;
  return v_n;
exception when insufficient_privilege then
  return -1;
end; $$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Akses Sdn Bhd');
  v_plain uuid := pg_temp.another_user('plain@akses.test');
  v_limited uuid := pg_temp.another_user('limited@akses.test');
  v_type uuid;
  v_contacts int;
  v_items int;
  v_wrote boolean;
  v_role text;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_plain, 'sales'), (v_org, v_limited, 'sales');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer');
  insert into public.items (org_id, code, name) values (v_org, 'I-1', 'Barang');

  insert into public.access_types (org_id, name)
  values (v_org, 'Contacts, read only') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'contacts', 'read');

  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_limited;

  -- ------------------------------------------------------------------
  -- Nobody is narrowed until somebody narrows them
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_plain);
  begin
    set local role authenticated;
    v_role := current_user;
    v_contacts := pg_temp.counts(v_org, 'contacts');
    v_items := pg_temp.counts(v_org, 'items');
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a member with no access type sees contacts',
    v_contacts, 1);
  perform pg_temp.check_eq('and items', v_items, 1);

  -- ------------------------------------------------------------------
  -- A granted module is reachable, at the level granted
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_limited);
  begin
    set local role authenticated;
    v_contacts := pg_temp.counts(v_org, 'contacts');
  end;
  reset role;
  perform pg_temp.check_eq('contacts granted read is readable', v_contacts, 1);

  perform pg_temp.sign_in_as(v_limited);
  begin
    set local role authenticated;
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'C-2', 'Baru', 'customer');
    v_wrote := true;
  exception when insufficient_privilege then v_wrote := false;
  end;
  reset role;
  perform pg_temp.check_true('but read does not mean write', not v_wrote);

  -- ------------------------------------------------------------------
  -- A module the access type never mentions is out of reach
  --
  -- Absent means none, so forgetting to add a module denies it rather
  -- than opening it. A select returns nothing rather than raising —
  -- that is what a restrictive policy does, and it is worth pinning
  -- down, because "empty" and "refused" look the same on screen and
  -- only one of them is what happened.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_limited);
  begin
    set local role authenticated;
    v_items := pg_temp.counts(v_org, 'items');
  end;
  reset role;
  perform pg_temp.check_eq('an unlisted module returns nothing', v_items, 0);

  -- ------------------------------------------------------------------
  -- The owner cannot be shut out by one
  -- ------------------------------------------------------------------
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_owner;

  perform pg_temp.sign_in_as(v_owner);
  begin
    set local role authenticated;
    v_items := pg_temp.counts(v_org, 'items');
    insert into public.items (org_id, code, name) values (v_org, 'I-2', 'Lagi');
    v_wrote := true;
  exception when insufficient_privilege then v_wrote := false;
  end;
  reset role;
  perform pg_temp.check_eq('an owner still sees a module they were denied',
    v_items, 1);
  perform pg_temp.check_true('and can still write it', v_wrote);
end $$;

-- ---------------------------------------------------------------------
-- One company's access type is not another's
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Akses Sdn Bhd');
  v_other uuid := pg_temp.test_org('Lain Lagi Sdn Bhd');
  v_member uuid;
  v_refused boolean;
begin
  select id into v_member from public.org_members
   where org_id = v_other and role = 'owner' limit 1;

  begin
    perform public.set_member_access_type(
      v_member,
      (select id from public.access_types where org_id = v_org limit 1));
    v_refused := false;
  exception when others then v_refused := true;
  end;

  perform pg_temp.check_true(
    'an access type cannot be borrowed from another company', v_refused);
end $$;

-- ---------------------------------------------------------------------
-- And the gate is on the tables it is supposed to be on
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
  v_policies int;
begin
  foreach v_table in array array[
    'sales_documents', 'purchase_documents', 'items', 'contacts',
    'employees', 'expense_claims', 'payslips', 'leads'
  ]
  loop
    select count(*) into v_policies
      from pg_policies
     where schemaname = 'public' and tablename = v_table
       and policyname like 'module_gate_%'
       and permissive = 'RESTRICTIVE';
    perform pg_temp.check_eq(
      format('%s is gated for all four commands', v_table), v_policies, 4);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The team list itself
--
-- 0129 put the access type into `org_team` rather than making the app
-- ask twice, and `org_team` was called by no test. It is the whole Team
-- screen in one answer — who is here, what they are, and which access
-- type narrows them — so it is also the one place where a company's
-- staff list could be handed to somebody outside it.
--
-- The row for somebody who has not accepted yet is the awkward one: no
-- profile, so no name and no address of their own, and the invitation's
-- address is all there is to show.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Pasukan Sdn Bhd');
  v_other uuid;
  v_clerk uuid := pg_temp.another_user('clerk@pasukan.test');
  v_stranger uuid := pg_temp.another_user('stranger@pasukan.test');
  v_outsider uuid := pg_temp.another_user('outsider@lain.test');
  v_type uuid; r record;
begin
  insert into public.profiles (id, full_name, email)
  values (v_clerk, 'Nurul Huda', 'clerk@pasukan.test')
  on conflict (id) do update set full_name = excluded.full_name,
                                 email = excluded.email;

  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accountant', 'active', now());
  -- Asked and not yet arrived: no user, no profile, an address on the
  -- invitation and nothing else.
  insert into public.org_members (org_id, invited_email, role, status)
  values (v_org, 'baru@pasukan.test', 'sales', 'invited');

  insert into public.access_types (org_id, name)
  values (v_org, 'Books only') returning id into v_type;
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_clerk;

  perform pg_temp.check_eq('the list is everybody, invited included',
    (select count(*) from public.org_team(v_org)), 3);

  select * into r from public.org_team(v_org) where user_id = v_clerk;
  perform pg_temp.check_eq('a member is named', r.full_name, 'Nurul Huda');
  perform pg_temp.check_eq('with the address on their profile',
    r.email, 'clerk@pasukan.test');
  perform pg_temp.check_eq('what they are here as', r.role::text, 'accountant');
  perform pg_temp.check_eq('and whether they have arrived',
    r.status::text, 'active');
  perform pg_temp.check_eq('and which access type narrows them',
    r.access_type_name, 'Books only');
  perform pg_temp.check_eq('by id as well as by name',
    r.access_type_id, v_type);

  -- Found by status rather than by the address, so that nulling the
  -- address column fails the assertion about the address rather than
  -- quietly making the row unfindable and failing for that instead.
  select * into r from public.org_team(v_org) where status = 'invited';
  perform pg_temp.check_true('somebody who has not accepted has no user yet',
    r.user_id is null);
  perform pg_temp.check_eq('the invitation carries the address it was sent to',
    r.invited_email, 'baru@pasukan.test');
  perform pg_temp.check_eq('and the invitation address stands in for theirs',
    r.email, 'baru@pasukan.test');
  perform pg_temp.check_true('with no access type until somebody gives one',
    r.access_type_id is null and r.access_type_name is null);

  -- The owner is unrestricted, and that is a null rather than a name.
  -- A screen that showed "Books only" against everybody because the
  -- join had gone wrong would be read as a company locked down.
  perform pg_temp.check_true('an unrestricted member carries no type',
    (select at.access_type_name is null from public.org_team(v_org) at
      where at.user_id = v_owner));

  -- ------------------------------------------------------------------
  -- Not a staff list anybody may read
  -- ------------------------------------------------------------------
  -- Deliberately not pg_temp.test_org: that one is created by the
  -- fixture user, who would then be its owner, and "another company" has
  -- to be one this caller is not in at all.
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Lain Sdn Bhd', 'lain-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_outsider)
  returning id into v_other;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and no window into another company''s team',
    (select count(*) from public.org_team(v_other)), 0);

  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_stranger, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('a member of the company sees the team',
    (select count(*) from public.org_team(v_org)), 4);
  perform pg_temp.check_eq('and nothing of one they are not in',
    (select count(*) from public.org_team(v_other)), 0);
  perform pg_temp.sign_in_as(v_owner);
end $$;

rollback;

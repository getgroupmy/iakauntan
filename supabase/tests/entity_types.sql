-- =====================================================================
-- iAkauntan :: the kinds of business, and who may add one
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/entity_types.sql
--
-- `0605` turns `app.entity_type` from an enum into a table so a
-- platform administrator can add a kind without a migration. Four
-- things are decisions rather than columns, and they are what this is
-- for:
--
--   * **`is_public_company` is the MBRS answer, carried on the row.**
--     `0172` decides whether a company files as public with
--     `o.entity_type = 'bhd'` -- a string comparison against one member
--     of a list somebody can now add to. Exactly one of the ten is
--     true, and it is `bhd`; that is asserted, because the day the
--     organizations column moves onto this table, that single row is
--     what MBRS will read.
--
--   * **Only a platform administrator writes.** The list is the whole
--     platform's, not a company's.
--
--   * **A kind in use cannot be deleted.** A contact filed as one is
--     filed as it, and a delete would leave the row pointing at
--     nothing. Switching it off is what was meant.
--
--   * **The ten this shipped with cannot be deleted at all**, because
--     `organizations.entity_type` is still the enum and still holds
--     them.
--
-- And the negative that matters most: the SSM deadline rules read a
-- DIFFERENT enum on a different table. Asserted here, because "adding
-- a kind of business cannot move a filing deadline" is the claim that
-- made this migration safe to write.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The platform's own staff. Both setters below re-check for it, and
-- `test_user()` is who the suite is acting as.
create or replace function pg_temp.a_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

do $$
declare
  v_seen  bigint;
  v_org   uuid;
  v_owner uuid;
  v_code  text;
  v_role  text;
begin
  v_owner := pg_temp.test_user();
  v_org := pg_temp.test_org('Kinds Sdn Bhd');

  -- ==================================================================
  -- 1. The ten the enum had, and the one MBRS cares about
  -- ==================================================================
  select count(*) into v_seen from public.entity_types where is_builtin;
  perform pg_temp.check_eq(
    'the ten the enum had are all here', v_seen, 10::bigint);

  -- Every member of the old enum has a row. Read from the enum itself
  -- rather than typed out, so the day somebody adds a member without a
  -- row this says so.
  select count(*) into v_seen
    from unnest(enum_range(null::app.entity_type)) as e(v)
   where not exists (
     select 1 from public.entity_types t where t.code = e.v::text);
  perform pg_temp.check_eq(
    'no member of the old enum is missing a row', v_seen, 0::bigint);

  -- THE one that matters. `0172` asks `o.entity_type = 'bhd'`, so when
  -- that column moves onto this table this single row is what decides
  -- whether a company files its accounts as a public company.
  select count(*) into v_seen
    from public.entity_types where is_public_company;
  perform pg_temp.check_eq(
    'exactly one kind is a public company', v_seen, 1::bigint);

  perform pg_temp.check_true(
    'and it is Berhad',
    exists (select 1 from public.entity_types
             where code = 'bhd' and is_public_company));

  -- The control for the assertion above: Sdn Bhd is the private one,
  -- and a table that answered true for everything would pass the count
  -- only by accident.
  perform pg_temp.check_true(
    'while Sdn Bhd is not',
    exists (select 1 from public.entity_types
             where code = 'sdn_bhd' and not is_public_company));

  -- ==================================================================
  -- 2. A contact keeps the kind it was filed as
  -- ==================================================================
  insert into public.contacts (org_id, code, name, contact_type, entity_type)
  values (v_org, 'C-KIND', 'Some Buyer Sdn Bhd', 'customer', 'sdn_bhd');

  perform pg_temp.check_true(
    'a contact is filed as a kind from the table',
    exists (select 1 from public.contacts c
              join public.entity_types t on t.code = c.entity_type
             where c.org_id = v_org and c.code = 'C-KIND'));

  -- ==================================================================
  -- 3. Only a platform administrator writes
  -- ==================================================================
  set local role authenticated;
  select current_user into v_role;
  perform pg_temp.check_eq(
    'the role actually switched', v_role, 'authenticated');

  begin
    perform public.platform_save_entity_type('co_operative', 'Co-operative');
    perform pg_temp.check_true(
      'somebody signed in cannot add a kind of business', false);
  exception when insufficient_privilege or sqlstate '42501' then
    perform pg_temp.check_true(
      'somebody signed in cannot add a kind of business', true);
  end;

  -- But they can READ it, because it is a dropdown on the contact form.
  select count(*) into v_seen from public.entity_types;
  perform pg_temp.check_true(
    'though they can read the list, which is a dropdown', v_seen >= 10);

  reset role;
end $$;

-- =====================================================================
-- 4. What the administrator may and may not do
--
-- Run as the owner, which is what the suite is. The permission check
-- above is the one that needed a role switch; these are about the
-- rules inside the function.
-- =====================================================================
do $$
declare
  v_seen bigint;
  v_org  uuid;
begin
  v_org := pg_temp.test_org('Kinds Sdn Bhd');
  perform pg_temp.a_platform_admin(pg_temp.test_user());

  -- A new kind, and a code that is not a code.
  begin
    perform public.platform_save_entity_type('Co Operative', 'Co-operative');
    perform pg_temp.check_true('a code with a space is refused', false);
  exception when sqlstate '23514' then
    perform pg_temp.check_true('a code with a space is refused', true);
  end;

  begin
    perform public.platform_save_entity_type('co_operative', '  ');
    perform pg_temp.check_true('a kind with no name is refused', false);
  exception when sqlstate '23514' then
    perform pg_temp.check_true('a kind with no name is refused', true);
  end;

  perform public.platform_save_entity_type(
    'co_operative', 'Co-operative', null, 45, true, false, true, true);
  perform pg_temp.check_true(
    'a new kind is added',
    exists (select 1 from public.entity_types
             where code = 'co_operative' and label = 'Co-operative'
               and sort_order = 45 and not is_builtin));

  -- An absent argument leaves it. Correcting a label must not switch a
  -- kind off, which is the shape `platform_save_landing_section` uses
  -- and the mistake it was written to avoid.
  perform public.platform_save_entity_type('co_operative', 'Koperasi');
  perform pg_temp.check_true(
    'correcting the name leaves everything else alone',
    exists (select 1 from public.entity_types
             where code = 'co_operative' and label = 'Koperasi'
               and sort_order = 45 and is_active));

  -- Removing one nothing is filed as.
  perform public.platform_delete_entity_type('co_operative');
  perform pg_temp.check_true(
    'a kind nothing is filed as can be removed',
    not exists (select 1 from public.entity_types
                 where code = 'co_operative'));

  -- A built-in cannot go: `organizations.entity_type` is still the enum
  -- and still holds these values.
  begin
    perform public.platform_delete_entity_type('sdn_bhd');
    perform pg_temp.check_true('a built-in kind cannot be removed', false);
  exception when sqlstate '23503' then
    perform pg_temp.check_true('a built-in kind cannot be removed', true);
  end;

  -- Nor one a contact is filed as.
  perform public.platform_save_entity_type('trust', 'Trust');
  insert into public.contacts (org_id, code, name, contact_type, entity_type)
  values (v_org, 'C-TRUST', 'A Trust', 'customer', 'trust');
  begin
    perform public.platform_delete_entity_type('trust');
    perform pg_temp.check_true('a kind in use cannot be removed', false);
  exception when sqlstate '23503' then
    perform pg_temp.check_true('a kind in use cannot be removed', true);
  end;

  -- Switching it off is what was meant, and it works with the contact
  -- still filed as it.
  perform public.platform_save_entity_type('trust', 'Trust', null, null, false);
  perform pg_temp.check_true(
    'but it can be switched off with the contact still filed as it',
    exists (select 1 from public.entity_types
             where code = 'trust' and not is_active)
    and exists (select 1 from public.contacts
                 where org_id = v_org and entity_type = 'trust'));
end $$;

-- =====================================================================
-- 5. The claim that made this safe to write
--
-- Adding a kind of business cannot move an SSM filing deadline,
-- because the deadline rules read `corp_entities.entity_type`, which is
-- `app.corp_entity_type` -- a different enum with different members.
-- Asserted rather than remembered: if somebody ever points
-- `corp_filing_types.applies_to` at this table, this fails and says so.
-- =====================================================================
do $$
declare
  v_type text;
begin
  select atttypid::regtype::text into v_type
    from pg_attribute
   where attrelid = 'public.corp_entities'::regclass
     and attname = 'entity_type' and attnum > 0 and not attisdropped;
  perform pg_temp.check_eq(
    'the deadline rules read a different list entirely',
    v_type, 'app.corp_entity_type');

  -- And the control: this list really is what CONTACTS read, so the
  -- assertion above is a distinction rather than a coincidence.
  select atttypid::regtype::text into v_type
    from pg_attribute
   where attrelid = 'public.contacts'::regclass
     and attname = 'entity_type' and attnum > 0 and not attisdropped;
  perform pg_temp.check_eq(
    'while a contact reads the new table', v_type, 'text');

  perform pg_temp.check_true(
    'through a foreign key, so a contact cannot name a kind that is gone',
    exists (select 1 from pg_constraint
             where conname = 'contacts_entity_type_fkey'
               and confrelid = 'public.entity_types'::regclass));
end $$;

rollback;

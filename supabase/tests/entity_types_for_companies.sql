-- =====================================================================
-- iAkauntan :: a company is a kind of business too
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/entity_types_for_companies.sql
--
-- `0605` moved contacts onto `entity_types` and `entity_types.sql`
-- asserts that. `0607` moves companies, which is the half with the
-- statutory readers, and this is what those readers are worth.
--
-- Two string comparisons against one member of a list an administrator
-- can now add to became two columns on the row:
--
--   * `is_public_company` -- CA 2016 s.340 (laid at the AGM) rather
--     than s.258 (circulated to members). `fs_deadlines.sql` already
--     asserts both sentences for the ten kinds that shipped. What that
--     file cannot assert, because the enum had no eleventh member, is
--     the one thing 0607 is FOR: a kind an administrator adds, marked
--     public, getting the public rule. That is asserted here, and it is
--     the assertion that would have failed against the old
--     `o.entity_type = 'bhd'`.
--
--   * `is_individual` -- NRIC or PASSPORT rather than BRN, which
--     MyInvois rejects for a person. Same shape, same test: a new kind
--     marked as a person, and the identifier that comes out.
--
-- And the negatives, because both are what makes the change safe:
-- adding a kind still cannot move an SSM filing deadline (those read a
-- different enum on a different table), and a kind a company is filed
-- as still cannot be deleted out from under it.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict (user_id) do nothing;
$$;

-- =====================================================================
-- The column moved, and it moved onto a key
-- =====================================================================
do $$
declare
  v_type text;
begin
  select atttypid::regtype::text into v_type
    from pg_attribute
   where attrelid = 'public.organizations'::regclass
     and attname = 'entity_type' and attnum > 0 and not attisdropped;
  perform pg_temp.check_eq(
    'a company reads the table now, not the enum', v_type, 'text');

  perform pg_temp.check_true(
    'through a foreign key, so a company cannot name a kind that is gone',
    exists (select 1 from pg_constraint
             where conname = 'organizations_entity_type_fkey'
               and confrelid = 'public.entity_types'::regclass));

  -- CONTROL. The claim that made 0605 safe to write, restated now that
  -- the other half has moved: the SSM filing deadlines read
  -- `corp_entities.entity_type`, which is a DIFFERENT enum with
  -- different members. If somebody ever points
  -- `corp_filing_types.applies_to` at this table, this fails and says
  -- so.
  select atttypid::regtype::text into v_type
    from pg_attribute
   where attrelid = 'public.corp_entities'::regclass
     and attname = 'entity_type' and attnum > 0 and not attisdropped;
  perform pg_temp.check_eq(
    'and the SSM deadline rules still read a different list entirely',
    v_type, 'app.corp_entity_type');
end $$;

-- =====================================================================
-- Only one `create_organization` survived
--
-- The enum overload had to go rather than sit beside the text one:
-- two signatures differing only in that parameter make every call
-- ambiguous, and the call that would start failing is the sign-up
-- path.
-- =====================================================================
do $$
declare
  v_n integer;
  v_third text;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_organization';
  perform pg_temp.check_eq(
    'exactly one create_organization, so no call is ambiguous', v_n, 1);

  select format_type(p.proargtypes[2], null) into v_third
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_organization';
  perform pg_temp.check_eq(
    'and the kind it takes is text, so a new kind can be chosen',
    v_third, 'text');
end $$;

-- =====================================================================
-- CA 2016 s.340, for a kind the enum never had
--
-- This is the assertion 0607 exists for. `berhad_terbuka` is not a
-- member of `app.entity_type` and never was; under the old
-- `o.entity_type = 'bhd'` a company filed as it would have been given
-- the PRIVATE company's rule, silently, and found out when a lodgement
-- was late.
-- =====================================================================
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_fil   uuid;
  v_basis text;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  perform public.platform_save_entity_type(
    'berhad_terbuka', 'Berhad (Terbuka)', null, 25, true,
    true,   -- is_public_company
    true, true);

  v_org := pg_temp.test_org('Terbuka Holdings');
  update public.organizations set entity_type = 'berhad_terbuka'
   where id = v_org;

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.fs_filings (org_id, fy_start, fy_end, framework, audit_status)
  values (v_org, date '2024-01-01', date '2024-12-31', 'mpers', 'audited')
  returning id into v_fil;

  select d.basis into v_basis from public.fs_deadlines(v_fil) d;
  perform pg_temp.check_true(
    'a kind the enum never had, marked public, is held to s.340',
    v_basis like '%s.340%');

  -- CONTROL. The same filing under a kind that is not public gets the
  -- other sentence, so the assertion above is reading the column
  -- rather than reporting the same string for everybody.
  update public.organizations set entity_type = 'sdn_bhd' where id = v_org;
  select d.basis into v_basis from public.fs_deadlines(v_fil) d;
  perform pg_temp.check_true(
    'and a private one is held to s.258',
    v_basis like '%s.258%' and v_basis not like '%s.340%');
end $$;

-- =====================================================================
-- MyInvois will not take a company number for a person
--
-- Same shape as the s.340 assertion above, and the same reason: an
-- administrator adding a kind that IS a person had nowhere to say so
-- while the trigger compared against the string `individual`.
-- =====================================================================
do $$
declare
  v_me   uuid := pg_temp.test_user();
  v_org  uuid;
  v_id   text;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  perform public.platform_save_entity_type(
    'orang_asing', 'Individual (non-resident)', null, 95, true,
    false,  -- is_public_company
    true, true,
    true);  -- is_individual

  v_org := pg_temp.test_org('Bukan Warganegara');
  update public.organizations
     set entity_type = 'orang_asing', country_code = 'SGP',
         einvoice_id_type = 'BRN'
   where id = v_org;

  select einvoice_id_type into v_id
    from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'a new kind marked as a person is identified by passport, not BRN',
    v_id, 'PASSPORT');

  -- Malaysian, same kind: NRIC rather than passport.
  update public.organizations
     set country_code = 'MYS', einvoice_id_type = 'BRN'
   where id = v_org;
  select einvoice_id_type into v_id
    from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'and a Malaysian one by NRIC', v_id, 'NRIC');

  -- CONTROL. A kind that is NOT a person keeps the business
  -- registration number, so the two assertions above are reading
  -- `is_individual` rather than rewriting everything they touch.
  update public.organizations
     set entity_type = 'sdn_bhd', einvoice_id_type = 'BRN'
   where id = v_org;
  select einvoice_id_type into v_id
    from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'while a company keeps its BRN', v_id, 'BRN');
end $$;

-- =====================================================================
-- A kind cannot be both a person and a public company
--
-- The two columns send the same company down two rules that contradict
-- each other: an AGM it does not hold, and an NRIC it does not have.
-- The setter refuses the combination on the way in, and refuses it on
-- an update that supplies only one half -- which is the case a check
-- written once, at insert, would miss.
-- =====================================================================
do $$
declare v_me uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  perform pg_temp.check_refused(
    'a kind cannot be added as both a person and a public company',
    $q$ select public.platform_save_entity_type(
          'mustahil', 'Impossible', null, 96, true, true, true, true, true) $q$,
    '%cannot be both a person and a public company%', '23514');

  -- And the half-and-half case: saved as a person, then amended to
  -- public without the update mentioning `is_individual` at all.
  perform public.platform_save_entity_type(
    'separuh', 'Half', null, 97, true, false, true, true, true);
  perform pg_temp.check_refused(
    'nor amended into both, one column at a time',
    $q$ select public.platform_save_entity_type(
          'separuh', 'Half', null, null, null, true) $q$,
    '%cannot be both a person and a public company%', '23514');

  -- CONTROL. The same update with the person flag turned off goes
  -- through, so the refusal above is about the pair rather than about
  -- the row being frozen.
  perform pg_temp.check_eq(
    'while turning one off and the other on is fine',
    public.platform_save_entity_type(
      'separuh', 'Half', null, null, null, true, null, null, false),
    'separuh');
end $$;

-- =====================================================================
-- Creating a company as a kind that was added after this shipped
-- =====================================================================
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_org uuid;
  v_got text;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);
  perform public.platform_save_entity_type(
    'koperasi', 'Koperasi', null, 65, true, false, true, true);

  -- The first company is free; every one after it is the Multi-Company
  -- module, and this file has already made several.
  perform pg_temp.test_org('Somewhere To Stand');
  perform pg_temp.allow_many_companies();

  v_org := public.create_organization('Koperasi Maju Jaya', null, 'koperasi');
  select entity_type into v_got from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'a company can be created as a kind added in the console',
    v_got, 'koperasi');
end $$;

-- =====================================================================
-- And refused, in words, as a kind that is not on the list
-- =====================================================================
do $$
declare v_me uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.allow_many_companies();
  perform pg_temp.check_refused(
    'a kind nobody has added is refused by name, not by constraint',
    $q$ select public.create_organization('Syarikat Hantu', null, 'hantu') $q$,
    '%not a kind of business this platform knows%', '23503');
end $$;

-- =====================================================================
-- A kind a company is filed as cannot be deleted out from under it
--
-- The foreign key would refuse it anyway. The RPC refuses first, and
-- says how many, because a constraint name at the end of a console
-- form is not an answer to give somebody.
-- =====================================================================
do $$
declare
  v_me uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);
  perform public.platform_save_entity_type(
    'amanah', 'Trust', null, 75, true, false, true, true);

  -- Nothing is filed as it yet, so it can go. Proves the refusal below
  -- is about the company rather than about the kind being new.
  perform pg_temp.check_true(
    'a kind nothing is filed as can be removed',
    public.platform_delete_entity_type('amanah'));

  perform public.platform_save_entity_type(
    'amanah', 'Trust', null, 75, true, false, true, true);
  perform pg_temp.allow_many_companies();
  perform public.create_organization('Amanah Warisan', null, 'amanah');

  perform pg_temp.check_refused(
    'and one a company is filed as is refused, naming how many',
    $q$ select public.platform_delete_entity_type('amanah') $q$,
    '%1 company/companies are filed as this kind%', '23503');
end $$;

-- =====================================================================
-- The console's own list of companies still reads
--
-- `platform_organizations` declared `entity_type app.entity_type` in
-- its RETURNS TABLE. A plpgsql result-type mismatch is a run-time
-- 42804 raised the first time somebody opens the page, so this calls
-- it.
-- =====================================================================
do $$
declare
  v_me uuid := pg_temp.test_user();
  v_n  integer;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);
  select count(*) into v_n from public.platform_organizations();
  perform pg_temp.check_true(
    'the console can still list the companies it just made', v_n > 0);
end $$;

-- =====================================================================
-- Registration can see the list without being signed in
--
-- `entity_types` is granted to `authenticated`, and the registration
-- form is the one screen in this product with nobody signed in. It
-- reads the list through `signup_reference()`, which answers as anon.
--
-- `individual` is deliberately absent: a company registering itself is
-- not a person. That is `for_organizations`, and this is its first
-- reader.
-- =====================================================================
do $$
declare
  v_codes text[];
begin
  perform pg_temp.sign_out();
  set local role anon;
  perform pg_temp.check_eq(
    'and this really is running as anon', current_user::text, 'anon');

  select array_agg(x->>'code' order by x->>'code') into v_codes
    from jsonb_array_elements(
           public.signup_reference() -> 'entity_types') x;

  perform pg_temp.check_true(
    'registration is offered the kinds of business with no session',
    'sdn_bhd' = any (v_codes) and 'bhd' = any (v_codes));
  perform pg_temp.check_true(
    'but not individual, which a company registering itself is not',
    not ('individual' = any (v_codes)));
  reset role;
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: what the register is allowed to overwrite
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ssm_register_lookup.sql
--
-- `set_contact_ssm_entity` exists because `contacts.registration_no` is
-- what MyInvois validates a party against, and a number somebody typed
-- off a letterhead is a different kind of fact from one a registry
-- returned. 0589 is the migration; this is the part of it that is a
-- decision rather than a column.
--
-- Three of those decisions can each be reversed by a one-line edit that
-- reads as a tidy-up, and all three would be found by a customer rather
-- than by a compiler:
--
--   * it OVERWRITES the name and the registration number. That is the
--     point. A lookup that left them alone would be a lookup that
--     changed nothing;
--   * it does NOT overwrite `id_value` when the contact already has
--     one. A sole proprietor is identified on an e-Invoice by NRIC,
--     and the business he trades as still has an SSM number; replacing
--     the one with the other submits under the wrong identifier for a
--     party somebody had already set up correctly;
--   * it KEEPS `old_registration_no` when the registry does not return
--     one. The register carries the new number for a company
--     incorporated before 2019 and not always the old one; a blanket
--     assignment would delete a true number because a search result
--     was silent about it.
--
-- And `ssm_verified_at` is the whole provenance story: if it can be
-- stamped by somebody who cannot write to the company, it says nothing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_stranger uuid;
  v_contact  uuid;
  v_row      public.contacts%rowtype;
begin
  v_org := pg_temp.test_org('Registry Test Sdn Bhd');

  -- A supplier as somebody typed it: the name off a letterhead, a
  -- transposed digit in the number, an older number already recorded,
  -- and an NRIC entered by hand because this one is a sole
  -- proprietorship and that is what LHDN identifies him by.
  insert into public.contacts
    (org_id, code, name, contact_type, registration_no,
     old_registration_no, id_type, id_value)
  values (v_org, 'S-REG-1', 'Kabeer Holdings Sdn Bhd', 'supplier',
          '201901030198', '1339519-K', 'NRIC', '880101015432')
  returning id into v_contact;

  -- ------------------------------------------------------------------
  -- What the registry said wins, where the registry is the authority
  -- ------------------------------------------------------------------
  perform public.set_contact_ssm_entity(
    v_contact,
    'KABEER HOLDINGS SDN. BHD.',
    '201901030189',
    null,
    'Company',
    'kabeer-holdings-sdn-bhd');

  select * into v_row from public.contacts where id = v_contact;

  perform pg_temp.check_eq('the registry''s spelling of the name',
    v_row.name, 'KABEER HOLDINGS SDN. BHD.');
  perform pg_temp.check_eq('the registry''s registration number',
    v_row.registration_no, '201901030189');
  perform pg_temp.check_eq('the entity type the letterhead did not state',
    v_row.ssm_entity_type, 'Company');
  perform pg_temp.check_eq('the registry''s own handle for the entity',
    v_row.ssm_slug, 'kabeer-holdings-sdn-bhd');
  perform pg_temp.check_true('the check is dated',
    v_row.ssm_verified_at is not null);

  -- ------------------------------------------------------------------
  -- And what it is not the authority on
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'an identifier entered deliberately for e-Invoice survives the lookup',
    v_row.id_value, '880101015432');
  perform pg_temp.check_eq('and keeps the type it was entered under',
    v_row.id_type, 'NRIC');
  perform pg_temp.check_eq(
    'an old number already on file survives a result that omits it',
    v_row.old_registration_no, '1339519-K');

  -- ------------------------------------------------------------------
  -- A contact with no identifier gets one, as a BRN
  -- ------------------------------------------------------------------
  insert into public.contacts
    (org_id, code, name, contact_type)
  values (v_org, 'S-REG-2', 'Something Or Other', 'supplier')
  returning id into v_contact;

  perform public.set_contact_ssm_entity(
    v_contact, 'ACME ENTERPRISE', '202301234567', 'JM0167410-V',
    'Business', 'acme-enterprise');

  select * into v_row from public.contacts where id = v_contact;

  -- Empty is not "entered deliberately". The SSM number identifies the
  -- party on the e-Invoice, so leaving the field blank for somebody to
  -- copy across by hand is how it ends up blank in production.
  perform pg_temp.check_eq('an empty identifier is filled from the register',
    v_row.id_value, '202301234567');
  perform pg_temp.check_eq('and is filled as a business registration number',
    v_row.id_type, 'BRN');
  perform pg_temp.check_eq('an old number the registry DID return is kept',
    v_row.old_registration_no, 'JM0167410-V');

  -- ------------------------------------------------------------------
  -- A match still has to be a match
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a registry match with no name',
    format('select public.set_contact_ssm_entity(%L, %L, %L)',
           v_contact, '   ', '202301234567'),
    '%has a name%');

  perform pg_temp.check_refused(
    'a lookup against a contact that does not exist',
    format('select public.set_contact_ssm_entity(%L, %L, %L)',
           gen_random_uuid(), 'ACME ENTERPRISE', '202301234567'),
    '%No such contact%');

  -- ------------------------------------------------------------------
  -- Provenance somebody else could stamp is not provenance
  -- ------------------------------------------------------------------
  -- `another_user`, not `test_user`: the second is idempotent and
  -- hands back the fixture user, so this assertion would have been
  -- about the owner refusing himself -- which is to say it would have
  -- passed by doing nothing. The helper says so, and this file got it
  -- wrong first time round anyway.
  v_stranger := pg_temp.another_user('stranger-ssm@example.test');
  perform pg_temp.sign_in_as(v_stranger);

  perform pg_temp.check_refused(
    'somebody outside the company stamping it as verified',
    format('select public.set_contact_ssm_entity(%L, %L, %L)',
           v_contact, 'ANYTHING AT ALL', '202301234567'),
    '%not permitted%');
end;
$$;

rollback;

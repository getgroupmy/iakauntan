-- =====================================================================
-- iAkauntan :: what the institute says, and who may record it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mia_credentials.sql
--
-- `0603` records what MIA's members and firms register said about a
-- corporate officer or a practice. The columns are the easy half. What
-- is a decision rather than a column, and what this file is for:
--
--   * the owning organization or firm is read FROM THE SUBJECT and
--     never taken from the caller. A caller who could name the org
--     would be choosing which company's permission check to face,
--     which is the whole check;
--   * `verified_via` is always `mia_website_manual`, whatever the
--     caller says. Nothing fetches mia.org.my, and a hand-typed row
--     that claimed to have come from an API would be a lie the schema
--     helped tell;
--   * `verified_by` is `auth.uid()` and not an argument, or the
--     provenance says nothing;
--   * a corporate officer's credential is guarded by `can_write` on the
--     COMPANY and a firm's by `can_manage_firm` on the FIRM, because a
--     practice keeping other people's books is outside the org tree.
--
-- The negatives are the point. A stranger being refused is what makes
-- the positives mean anything.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_owner    uuid;
  v_stranger uuid;
  v_entity   uuid;
  v_person   uuid;
  v_officer  uuid;
  v_firm     uuid;
  v_id       uuid;
  v_row      public.mia_credentials%rowtype;
  v_seen     bigint;
  v_role     text;
begin
  v_owner := pg_temp.test_user();
  v_org := pg_temp.test_org('Audit Client Sdn Bhd');

  insert into public.corp_entities (org_id, name, registration_no)
  values (v_org, 'Audit Client Sdn Bhd', '201901030189')
  returning id into v_entity;

  insert into public.corp_persons (org_id, full_name)
  values (v_org, 'TAN AH KOW') returning id into v_person;

  insert into public.corp_officers
    (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_entity, v_person, 'auditor', date '2026-01-01')
  returning id into v_officer;

  -- ------------------------------------------------------------------
  -- What the register said, against an officer
  -- ------------------------------------------------------------------
  v_id := public.upsert_mia_credential(
    'corp_officer', v_officer, 'member',
    jsonb_build_object(
      'member_no', '12345',
      'member_name', 'TAN AH KOW',
      'member_type', 'CA',
      'pc_holder', true,
      'state', 'Selangor',
      'raw_text', '12345	TAN AH KOW	CA	Selangor	Yes'));

  select * into v_row from public.mia_credentials where id = v_id;

  perform pg_temp.check_eq('the member number', v_row.member_no, '12345');
  perform pg_temp.check_eq('the member type', v_row.member_type, 'CA');
  perform pg_temp.check_true('the practising certificate', v_row.pc_holder);
  perform pg_temp.check_eq('the state as the register prints it',
    v_row.state, 'Selangor');
  perform pg_temp.check_true('what was pasted is kept',
    v_row.raw_text is not null);

  -- The owner came from the officer, not from the caller.
  perform pg_temp.check_eq('the company is read off the officer',
    v_row.org_id, v_org);
  perform pg_temp.check_true('and no firm is claimed',
    v_row.firm_id is null);

  -- Provenance.
  perform pg_temp.check_eq('who looked it up', v_row.verified_by, v_owner);
  perform pg_temp.check_eq('and how',
    v_row.verified_via::text, 'mia_website_manual');
  perform pg_temp.check_true('and when', v_row.verified_at is not null);

  -- ------------------------------------------------------------------
  -- A second look replaces the first rather than stacking
  -- ------------------------------------------------------------------
  perform public.upsert_mia_credential(
    'corp_officer', v_officer, 'member',
    jsonb_build_object('member_no', '12345', 'pc_holder', false));

  perform pg_temp.check_eq('one row for one subject and kind',
    (select count(*) from public.mia_credentials
      where subject_id = v_officer and kind = 'member'), 1::bigint);
  perform pg_temp.check_true('and it is the newer answer',
    not (select pc_holder from public.mia_credentials
          where subject_id = v_officer and kind = 'member'));

  -- ------------------------------------------------------------------
  -- The same officer may hold a firm credential as well
  --
  -- An engagement partner is a MEMBER and the firm they sign for is a
  -- FIRM. Two rows about one appointment.
  -- ------------------------------------------------------------------
  perform public.upsert_mia_credential(
    'corp_officer', v_officer, 'firm',
    jsonb_build_object('firm_no', 'af0759', 'firm_name', 'ABC & CO PLT',
                       'firm_type', 'A'));

  perform pg_temp.check_eq('a member credential and a firm credential',
    (select count(*) from public.mia_credentials
      where subject_id = v_officer), 2::bigint);

  -- 'af0759' and 'AF 0759' are the same firm.
  perform pg_temp.check_eq('the firm number is normalised on the way in',
    (select firm_no from public.mia_credentials
      where subject_id = v_officer and kind = 'firm'), 'AF 0759');

  -- ------------------------------------------------------------------
  -- A caller cannot dress a typed row up as an API answer
  -- ------------------------------------------------------------------
  perform public.upsert_mia_credential(
    'corp_officer', v_officer, 'member',
    jsonb_build_object('member_no', '12345',
                       'verified_via', 'mia_api',
                       'verified_by', gen_random_uuid()));

  select * into v_row from public.mia_credentials
   where subject_id = v_officer and kind = 'member';

  perform pg_temp.check_eq('a claimed provenance is ignored',
    v_row.verified_via::text, 'mia_website_manual');
  perform pg_temp.check_eq('and so is a claimed verifier',
    v_row.verified_by, v_owner);

  -- ------------------------------------------------------------------
  -- Somebody outside the company cannot record one
  -- ------------------------------------------------------------------
  v_stranger := pg_temp.another_user('stranger@iakauntan.test');
  perform pg_temp.sign_in_as(v_stranger);

  perform pg_temp.check_refused(
    'a stranger cannot record a credential on somebody else''s officer',
    format('select public.upsert_mia_credential(%L, %L, %L, %L::jsonb)',
           'corp_officer', v_officer, 'member', '{"member_no":"999"}'),
    '%not permitted%');

  -- UNDER row level security. The suite runs as the table's owner,
  -- which bypasses every policy — so a read assertion made without
  -- this passes whatever the policy says, and the first draft of this
  -- file did exactly that: it read two rows as postgres and reported
  -- the stranger could see them.
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_seen from public.mia_credentials
     where subject_id = v_officer;
  end;
  reset role;

  perform pg_temp.check_eq('the read ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('and a stranger cannot read one either',
    v_seen, 0::bigint);

  -- And the control: the same query, under the same role, for somebody
  -- who IS in the company. Without it "a stranger sees nothing" passes
  -- against a policy that shows nobody anything.
  perform pg_temp.sign_in_as(v_owner);
  begin
    set local role authenticated;
    select count(*) into v_seen from public.mia_credentials
     where subject_id = v_officer;
  end;
  reset role;

  perform pg_temp.check_eq('while the company still sees both',
    v_seen, 2::bigint);

  -- ------------------------------------------------------------------
  -- A subject that does not exist is refused rather than orphaned
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'an officer that does not exist',
    format('select public.upsert_mia_credential(%L, %L, %L, %L::jsonb)',
           'corp_officer', gen_random_uuid(), 'member', '{}'),
    '%No such officer%');

  perform pg_temp.check_refused(
    'and a subject kind this does not record',
    format('select public.upsert_mia_credential(%L, %L, %L, %L::jsonb)',
           'contact', v_officer, 'member', '{}'),
    '%officer or a firm%');

  -- ------------------------------------------------------------------
  -- Taking one off asks the same question
  -- ------------------------------------------------------------------
  select id into v_id from public.mia_credentials
   where subject_id = v_officer and kind = 'firm';

  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused(
    'a stranger cannot remove one',
    format('select public.delete_mia_credential(%L)', v_id),
    '%not permitted%');

  perform pg_temp.sign_in_as(v_owner);
  perform public.delete_mia_credential(v_id);
  perform pg_temp.check_eq('and the company can',
    (select count(*) from public.mia_credentials
      where subject_id = v_officer), 1::bigint);

  raise notice 'mia_credentials: every assertion passed';
end;
$$;

rollback;

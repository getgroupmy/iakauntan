-- =====================================================================
-- iAkauntan :: the alternate's principal, and who saw the document
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/alternates_and_verification.sql
--
-- Two columns from `0061` that nothing ever wrote, and both are the
-- half of a statutory record that says *who*.
--
-- `corp_officers.alternate_for`: the register could say somebody was an
-- alternate and never whose. Under s.208 an alternate acts in a
-- particular director's place, with that director's vote and not as
-- well as it — so whether a board had a quorum cannot be worked out
-- from a register that does not name the principal.
--
-- `corp_persons.id_verified_by`: the person editor recorded the date a
-- document was seen and never who saw it, which is not a CDD record. It
-- is asserted the same way `0378` asserts `lodged_by`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.av_entity(p_org uuid, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.corp_entities
    (org_id, name, registration_no, entity_type, incorporated_on)
  values (p_org, p_name, 'REG-' || substr(gen_random_uuid()::text, 1, 8),
          'sdn_bhd', date '2015-01-01')
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.av_person(p_org uuid, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.corp_persons (org_id, kind, full_name)
  values (p_org, 'individual', p_name) returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.av_officer(
  p_org uuid, p_entity uuid, p_person uuid, p_role text,
  p_alternate_for uuid default null, p_appointed date default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.corp_officers
    (org_id, entity_id, person_id, role, appointed_on, alternate_for)
  values (p_org, p_entity, p_person, p_role::app.corp_officer_role,
          coalesce(p_appointed, date '2020-01-01'), p_alternate_for)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- An alternate acts in somebody's place
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Pengarah Ganti Sdn Bhd');
  v_ent    uuid;
  v_other  uuid;
  v_lim    uuid;
  v_tan    uuid;
  v_wong   uuid;
  v_dir    uuid;
  v_alt    uuid;
  v_said   text;
begin
  v_ent   := pg_temp.av_entity(v_org, 'Kilang Contoh Sdn Bhd');
  v_other := pg_temp.av_entity(v_org, 'Syarikat Lain Sdn Bhd');
  v_lim   := pg_temp.av_person(v_org, 'Lim the director');
  v_tan   := pg_temp.av_person(v_org, 'Tan the alternate');
  v_wong  := pg_temp.av_person(v_org, 'Wong elsewhere');

  v_dir := pg_temp.av_officer(v_org, v_ent, v_lim, 'director');

  begin
    perform pg_temp.av_officer(v_org, v_ent, v_tan, 'alternate_director');
    raise exception 'FAIL: an alternate director was appointed for nobody';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an alternate director acts in somebody''s place',
    v_said like '%particular director''s place%');
  perform pg_temp.check_true('and the reason is the one that matters',
    v_said like '%quorum%');

  -- Not for somebody at another company, not for themselves, and not
  -- for an alternate.
  begin
    perform pg_temp.av_officer(v_org, v_other, v_wong, 'alternate_director',
      v_dir);
    raise exception 'FAIL: an alternate stood in at a different company';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the principal is an officer of the same company',
    v_said like '%same company%');

  begin
    perform pg_temp.av_officer(v_org, v_ent, v_lim, 'alternate_director',
      v_dir);
    raise exception 'FAIL: somebody stood in for themselves';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nobody stands in for themselves',
    v_said like '%for themselves%');

  v_alt := pg_temp.av_officer(v_org, v_ent, v_tan, 'alternate_director',
    v_dir);
  perform pg_temp.check_eq('an alternate names their principal',
    (select alternate_for from public.corp_officers where id = v_alt), v_dir);

  -- Derived rather than typed: the flag and the relationship are one
  -- fact now and cannot contradict each other.
  perform pg_temp.check_true('and the flag follows from it',
    (select is_alternate from public.corp_officers where id = v_alt));
  perform pg_temp.check_true('while the principal is not one',
    not (select is_alternate from public.corp_officers where id = v_dir));

  update public.corp_officers set is_alternate = false where id = v_alt;
  perform pg_temp.check_true('and it cannot be unticked out from under it',
    (select is_alternate from public.corp_officers where id = v_alt));

  begin
    perform pg_temp.av_officer(v_org, v_ent, v_wong, 'alternate_director',
      v_alt);
    raise exception 'FAIL: an alternate was given an alternate';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an alternate cannot have an alternate',
    v_said like '%already been made once%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- When the principal goes, so does the stand-in
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Berhenti Bersama Sdn Bhd');
  v_ent   uuid;
  v_lim   uuid;
  v_tan   uuid;
  v_nor   uuid;
  v_dir   uuid;
  v_dir2  uuid;
  v_alt   uuid;
  v_own   uuid;
  v_own2  uuid;
  v_said  text;
  v_audit bigint;
  v_row   public.corp_officers;
begin
  v_ent := pg_temp.av_entity(v_org, 'Kilang Contoh Sdn Bhd');
  v_lim := pg_temp.av_person(v_org, 'Lim');
  v_tan := pg_temp.av_person(v_org, 'Tan');
  v_nor := pg_temp.av_person(v_org, 'Noraini');

  v_dir  := pg_temp.av_officer(v_org, v_ent, v_lim, 'director');
  v_dir2 := pg_temp.av_officer(v_org, v_ent, v_nor, 'director');
  v_alt  := pg_temp.av_officer(v_org, v_ent, v_tan, 'alternate_director',
    v_dir);

  -- Two more stand-ins for the same director, who leave of their own
  -- accord before any of this. Their dates are chosen to collide with
  -- each step below — one with the principal's first cessation date,
  -- one with the date it is later corrected to — because a rule that
  -- says "moved by the principal's event, and not by their own" is only
  -- tested where the two dates are the same.
  v_own := pg_temp.av_officer(v_org, v_ent,
    pg_temp.av_person(v_org, 'Chandran'), 'alternate_director', v_dir);
  update public.corp_officers
     set resigned_on = date '2026-04-30', cessation_reason = 'Retired'
   where id = v_own;

  v_own2 := pg_temp.av_officer(v_org, v_ent,
    pg_temp.av_person(v_org, 'Devi'), 'alternate_director', v_dir);
  update public.corp_officers
     set resigned_on = date '2026-03-31', cessation_reason = 'Retired'
   where id = v_own2;

  update public.corp_officers
     set resigned_on = date '2026-03-31',
         cessation_reason = 'Resigned'
   where id = v_dir;

  select * into v_row from public.corp_officers where id = v_alt;
  perform pg_temp.check_eq('the alternate ceases with the principal',
    v_row.resigned_on::text, '2026-03-31');
  perform pg_temp.check_true('and the register says why',
    v_row.cessation_reason like 'Principal ceased%');

  -- The other director is untouched: the cascade follows the
  -- relationship and not the company.
  perform pg_temp.check_true('and nobody else is ceased',
    (select resigned_on is null from public.corp_officers where id = v_dir2));

  -- Appointing a stand-in for a place that no longer exists.
  begin
    perform pg_temp.av_officer(v_org, v_ent,
      pg_temp.av_person(v_org, 'Somebody late'), 'alternate_director', v_dir);
    raise exception 'FAIL: an alternate was appointed to a vacated place';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('there is no longer a place to act in',
    v_said like '%no longer a place%');

  -- One event, so a date corrected on the principal moves the
  -- stand-in's with it. A register that disagrees with itself about a
  -- single day is what the s.58 notification is filed from.
  update public.corp_officers set resigned_on = date '2026-04-30'
   where id = v_dir;
  perform pg_temp.check_eq('correcting the principal''s date moves theirs',
    (select resigned_on from public.corp_officers where id = v_alt)::text,
    '2026-04-30');
  perform pg_temp.check_eq('and leaves alone one who resigned on their own '
    'account, on the very day being corrected away from',
    (select resigned_on from public.corp_officers where id = v_own2)::text,
    '2026-03-31');

  -- An edit that is not about the cessation leaves the stand-in alone.
  -- The migration's early return also stops the write itself; that is
  -- unobservable here, because `write_audit_log` drops an update whose
  -- diff is empty, and it is kept for the reason written there.
  select count(*) into v_audit from public.audit_logs
   where table_name = 'corp_officers' and record_id = v_alt;
  update public.corp_officers set designation = 'Non-executive'
   where id = v_dir;
  perform pg_temp.check_eq('an unrelated edit leaves the stand-in alone',
    (select resigned_on from public.corp_officers where id = v_alt)::text,
    '2026-04-30');
  perform pg_temp.check_eq('and writes nothing to the register''s history',
    (select count(*) from public.audit_logs
      where table_name = 'corp_officers' and record_id = v_alt), v_audit);

  -- A cessation that happened only because of the principal's ends
  -- when the principal's does. One that did not, does not: the second
  -- stand-in left of their own accord, and happens to have left on the
  -- same day.
  update public.corp_officers set resigned_on = null, cessation_reason = null
   where id = v_dir;
  select * into v_row from public.corp_officers where id = v_alt;
  perform pg_temp.check_true('reinstating the principal restores the '
    'stand-in', v_row.resigned_on is null);
  perform pg_temp.check_true('and takes the borrowed reason with it',
    v_row.cessation_reason is null);
  select * into v_row from public.corp_officers where id = v_own;
  perform pg_temp.check_eq('while one who resigned on their own account '
    'stays resigned', v_row.resigned_on::text, '2026-04-30');
  perform pg_temp.check_eq('with their own reason',
    v_row.cessation_reason, 'Retired');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may be stood in for
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Senarai Pengarah Sdn Bhd');
  v_ent  uuid;
  v_lim  uuid;
  v_tan  uuid;
  v_nor  uuid;
  v_dir  uuid;
  v_gone uuid;
  v_alt  uuid;
begin
  v_ent := pg_temp.av_entity(v_org, 'Kilang Contoh Sdn Bhd');
  v_lim := pg_temp.av_person(v_org, 'Lim');
  v_tan := pg_temp.av_person(v_org, 'Tan');
  v_nor := pg_temp.av_person(v_org, 'Noraini');

  v_dir  := pg_temp.av_officer(v_org, v_ent, v_lim, 'director');
  v_alt  := pg_temp.av_officer(v_org, v_ent, v_tan, 'alternate_director',
    v_dir);
  v_gone := pg_temp.av_officer(v_org, v_ent, v_nor, 'director');
  update public.corp_officers set resigned_on = date '2025-12-31'
   where id = v_gone;

  perform pg_temp.check_eq('only sitting officers can be stood in for',
    (select count(*) from public.corp_principals_for_alternate(v_ent)), 1);
  perform pg_temp.check_eq('and it is the director, not the alternate',
    (select officer_id from public.corp_principals_for_alternate(v_ent)),
    v_dir);
  perform pg_temp.check_eq('and the one being edited is left out of '
    'their own list',
    (select count(*) from public.corp_principals_for_alternate(v_ent, v_dir)),
    0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who saw the document
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Semak Identiti Sdn Bhd');
  v_owner  uuid := pg_temp.test_user();
  v_person uuid;
  v_legacy uuid;
  v_said   text;
  v_row    public.corp_persons;
  v_today  date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_person := pg_temp.av_person(v_org, 'Lim Swee Hock');

  -- The shape the editor used to write: a date, and nobody.
  begin
    update public.corp_persons
       set id_verified_on = v_today, id_document_type = 'NRIC'
     where id = v_person;
    raise exception 'FAIL: a verification was recorded with no verifier';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a check is an act by a person',
    v_said like '%seen by this individual%');

  begin
    perform public.verify_person_identity(v_person, '  ');
    raise exception 'FAIL: nothing in particular was verified';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and it says what was seen',
    v_said like '%what was seen%');

  begin
    perform public.verify_person_identity(v_person, 'NRIC', v_today + 1);
    raise exception 'FAIL: a document was seen tomorrow';
  exception when sqlstate '23514' then null;
  end;

  perform public.verify_person_identity(
    v_person, 'NRIC', null, 'Original sighted at the office.');
  select * into v_row from public.corp_persons where id = v_person;
  perform pg_temp.check_eq('the verification records the document',
    v_row.id_document_type, 'NRIC');
  perform pg_temp.check_eq('the day it was seen',
    v_row.id_verified_on::text, v_today::text);
  perform pg_temp.check_eq('and who saw it', v_row.id_verified_by, v_owner);
  perform pg_temp.check_eq('with the note', v_row.kyc_notes,
    'Original sighted at the office.');

  -- An unrelated edit to a verified person is not a re-verification and
  -- must not be refused.
  update public.corp_persons set phone = '03-1234 5678' where id = v_person;
  perform pg_temp.check_eq('and an ordinary edit afterwards is untouched',
    (select id_verified_by from public.corp_persons where id = v_person),
    v_owner);

  -- A row exactly as every one of them stood before this migration: a
  -- date, and nobody. The trigger is what refuses to make one now, so
  -- the only honest way to produce the state it has to tolerate is to
  -- turn the trigger off for the insert. Refusing every later edit to
  -- these would mean a phone number could not be corrected until
  -- somebody re-did a check that may have been done properly in 2019.
  alter table public.corp_persons disable trigger corp_persons_verification_ck;
  insert into public.corp_persons
    (org_id, kind, full_name, id_document_type, id_verified_on)
  values (v_org, 'individual', 'Verified long ago', 'NRIC',
          date '2019-05-04')
  returning id into v_legacy;
  alter table public.corp_persons enable trigger corp_persons_verification_ck;

  update public.corp_persons set phone = '03-9999 0000' where id = v_legacy;
  perform pg_temp.check_eq('a record made before this rule stays editable',
    (select phone from public.corp_persons where id = v_legacy),
    '03-9999 0000');
  perform pg_temp.check_eq('with its date untouched',
    (select id_verified_on from public.corp_persons where id = v_legacy)::text,
    '2019-05-04');

  -- Re-dating it, though, is claiming a check happened — and a claim
  -- needs somebody making it.
  begin
    update public.corp_persons set id_verified_on = v_today
     where id = v_legacy;
    raise exception 'FAIL: an old record was re-dated with no verifier';
  exception when sqlstate '23514' then null;
  end;

  -- Withdrawing it clears both halves: a verifier with no date would be
  -- the same broken record the other way round.
  perform public.unverify_person_identity(v_person);
  select * into v_row from public.corp_persons where id = v_person;
  perform pg_temp.check_true('withdrawing it clears the date',
    v_row.id_verified_on is null);
  perform pg_temp.check_true('and the verifier with it',
    v_row.id_verified_by is null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may record one
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Bukan Setiausaha Sdn Bhd');
  v_ent    uuid;
  v_person uuid;
  v_out    uuid := pg_temp.another_user('outsider@av.test');
begin
  v_ent    := pg_temp.av_entity(v_org, 'Kilang Contoh Sdn Bhd');
  v_person := pg_temp.av_person(v_org, 'Somebody');
  perform public.verify_person_identity(v_person, 'NRIC');
  -- A sitting director, so "the outsider sees nobody" is an assertion
  -- about them and not about an empty company.
  perform pg_temp.av_officer(v_org, v_ent, v_person, 'director');

  -- Somebody with no part in this company at all. The registers are
  -- what a company is on paper, and a CDD record signed by a stranger
  -- is worse than none.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.verify_person_identity(v_person, 'Passport');
    raise exception 'FAIL: an outsider recorded a verification';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.unverify_person_identity(v_person);
    raise exception 'FAIL: an outsider withdrew a verification';
  exception when sqlstate '42501' then null;
  end;
  perform pg_temp.check_eq('and the list of principals is empty to them',
    (select count(*) from public.corp_principals_for_alternate(v_ent)), 0);
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('while the company''s own people see the '
    'director standing there',
    (select count(*) from public.corp_principals_for_alternate(v_ent)), 1);
  perform pg_temp.sign_in_as(v_out);

  begin
    perform public.verify_person_identity(gen_random_uuid(), 'NRIC');
    raise exception 'FAIL: a person who does not exist was verified';
  exception when sqlstate 'P0002' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('recording a verification is closed to anon',
    not has_function_privilege('anon',
      'public.verify_person_identity(uuid, text, date, text)', 'execute'));
  perform pg_temp.check_true('and withdrawing one',
    not has_function_privilege('anon',
      'public.unverify_person_identity(uuid)', 'execute'));
  perform pg_temp.check_true('and the list of who may be stood in for',
    not has_function_privilege('anon',
      'public.corp_principals_for_alternate(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may record one',
    has_function_privilege('authenticated',
      'public.verify_person_identity(uuid, text, date, text)', 'execute'));
end $$;

rollback;

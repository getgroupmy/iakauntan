-- =====================================================================
-- iAkauntan :: the people on this platform, from the console
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/platform_users.sql
--
-- `0721`. Reading people and editing the half of a person that lives in
-- `profiles`.
--
-- The other half -- creating an account, setting a password, suspending
-- one -- is NOT here and cannot be: those live in `auth.users` and are
-- written through the Admin API with the service role key, from
-- `supabase/functions/platform-users/`. What this file can still check
-- is that the console READS that state correctly, which is where the
-- subtle one is: `banned_until` in the PAST is somebody whose
-- suspension has run out, and showing them as locked out while they are
-- signing in perfectly happily is the kind of wrong that sends support
-- looking in the wrong place.
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
  select id into v_id from auth.users where email = 'people@iakauntan.test';
  if v_id is null then
    v_id := pg_temp.another_user('people@iakauntan.test');
  end if;
  insert into public.platform_admins (user_id) values (v_id)
  on conflict do nothing;
  return v_id;
end;
$$;

create or replace function pg_temp.somebody(p_who text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := pg_temp.another_user(
    p_who || '-' || gen_random_uuid() || '@iakauntan.test');
  update public.profiles set full_name = p_name where id = v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
do $$
declare
  v_plain uuid := pg_temp.somebody('plain', 'Nobody Special');
begin
  perform pg_temp.sign_in_as(v_plain);

  begin
    perform * from public.platform_users();
    raise exception 'FAIL: an ordinary user read the platform''s people';
  exception when sqlstate '42501' then
    raise notice 'ok   only the platform reads its list of people';
  end;

  begin
    perform public.platform_update_user(v_plain, 'Renamed By Themselves');
    raise exception 'FAIL: an ordinary user edited a profile here';
  exception when sqlstate '42501' then
    raise notice 'ok   and only the platform edits one from the console';
  end;
end $$;

-- ---------------------------------------------------------------------
-- What the list says
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_one   uuid := pg_temp.somebody('listed', 'Aminah Binti Hassan');
  v_org   uuid;
  r       record;
begin
  perform pg_temp.sign_in_as(v_admin);

  select * into r from public.platform_users('Aminah');
  perform pg_temp.check_eq('somebody is found by name',
    r.full_name, 'Aminah Binti Hassan');
  perform pg_temp.check_eq('with no company yet', r.company_count, 0);
  perform pg_temp.check_true('not suspended', not r.suspended);
  perform pg_temp.check_true('and not platform staff',
    not r.is_platform_admin);

  -- A company they can open.
  v_org := pg_temp.test_org('Counted Sdn Bhd');
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_assign_org_access(
    v_org,
    (select email::text from public.profiles where id = v_one),
    'accounts_clerk');

  select * into r from public.platform_users('Aminah');
  perform pg_temp.check_eq('and the company is counted', r.company_count, 1);

  -- The list without a query is the directory, which is what makes this
  -- a different question from `search_platform_users`.
  perform pg_temp.check_true('the list answers with no query at all',
    (select count(*) from public.platform_users()) >= 2);

  raise notice 'ok   the console can see who is here and what they hold';
end $$;

-- ---------------------------------------------------------------------
-- A suspension that has run out is not a suspension
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_now   uuid := pg_temp.somebody('locked', 'Currently Locked');
  v_past  uuid := pg_temp.somebody('served', 'Served Their Time');
begin
  update auth.users set banned_until = now() + interval '1 year' where id = v_now;
  update auth.users set banned_until = now() - interval '1 day'  where id = v_past;

  perform pg_temp.sign_in_as(v_admin);

  perform pg_temp.check_true('somebody banned until next year is suspended',
    (select suspended from public.platform_users('Currently Locked')));

  -- Reading the column for its PRESENCE rather than its value shows
  -- this person as locked out while they are signing in happily, and
  -- sends support looking in the wrong place.
  perform pg_temp.check_true('but one whose ban has run out is not',
    not (select suspended from public.platform_users('Served Their Time')));

  raise notice 'ok   a suspension is read by its date, not its presence';
end $$;

-- ---------------------------------------------------------------------
-- Editing the half that is ours
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.console_admin();
  v_one   uuid := pg_temp.somebody('edited', 'Before The Edit');
begin
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_update_user(v_one, 'After The Edit', '03-9999 0000');
  perform pg_temp.check_eq('the name can be corrected',
    (select full_name from public.profiles where id = v_one),
    'After The Edit');
  perform pg_temp.check_eq('and the phone number set',
    (select phone from public.profiles where id = v_one), '03-9999 0000');

  -- A blank box is "I did not type here", not "delete this".
  perform public.platform_update_user(v_one, '   ');
  perform pg_temp.check_eq('a field left blank is left alone',
    (select full_name from public.profiles where id = v_one),
    'After The Edit');

  -- `org_id` null: editing a person is not something one of their
  -- companies did, and it belongs in the platform trail.
  perform pg_temp.check_true('the edit is in the platform trail',
    exists (select 1 from public.audit_logs
             where org_id is null and table_name = 'profiles'
               and record_id = v_one
               and new_data ->> 'event' = 'platform_update_user'));
  perform pg_temp.check_eq('with what was there before it',
    (select old_data ->> 'full_name' from public.audit_logs
      where org_id is null and table_name = 'profiles' and record_id = v_one
      order by id limit 1), 'Before The Edit');

  begin
    perform public.platform_update_user(gen_random_uuid(), 'Ghost');
    raise exception 'FAIL: edited somebody who is not here';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and somebody who is not here cannot be edited';
  end;

  raise notice 'ok   a person can be corrected, and it is written down';
end $$;

rollback;

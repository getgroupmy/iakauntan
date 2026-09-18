-- =====================================================================
-- iAkauntan :: your own profile row
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/my_profile.sql
--
-- `0649` gives a person a way to change their own name, which the
-- product has never had. The interesting assertions are not that the
-- name lands -- they are the four things the function must REFUSE to
-- write, because `profiles_update` is a rule about ROWS and a policy
-- cannot be a rule about COLUMNS:
--
--   1. **`email`.** A copy of `auth.users.email`. Writing it here
--      changes what "Signed in as" says and changes nothing about the
--      address that signs somebody in or receives a reset link. The
--      screen would be confidently wrong about the one fact anybody
--      reads it for.
--   2. **`deleted_at`.** Four membership guards read it -- `0619`'s --
--      and nothing in the schema writes it. Setting your own locks you
--      out of every company you belong to, through a door nobody built.
--   3. **`last_org_id`.** The client writes this and should keep
--      writing it. A form that also wrote it would move somebody's
--      company under them when they saved their telephone number.
--   4. **Somebody else's row.** The whole of it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_other uuid := pg_temp.another_user('colleague@iakauntan.test');
  v_org   uuid;
  v_row   public.profiles;
begin
  -- `on conflict` because `app.handle_new_user` is a trigger on
  -- auth.users and may already have made the row. Either way the
  -- fixture ends with known values, which is what the assertions need.
  insert into public.profiles (id, email, full_name)
  values (v_me, 'fixture@iakauntan.test', 'Ahmad bin Ismail'),
         (v_other, 'colleague@iakauntan.test', 'Siti binti Rahman')
  on conflict (id) do update
    set email = excluded.email, full_name = excluded.full_name,
        salutation = null, phone = null, deleted_at = null;

  -- A company, so `last_org_id` is a real uuid rather than a null that
  -- would pass assertion 3 by having nothing to compare against.
  v_org := pg_temp.test_org('Kedai Kita');
  update public.profiles set last_org_id = v_org where id = v_me;

  perform pg_temp.sign_in_as(v_me);

  -- -------------------------------------------------------------------
  -- 1. It does what it is for
  -- -------------------------------------------------------------------
  v_row := public.update_my_profile(
    p_full_name => 'Ahmad Ismail',
    p_salutation => 'Mr',
    p_phone => '+60123456789');

  perform pg_temp.check_eq('name returned', v_row.full_name, 'Ahmad Ismail');
  perform pg_temp.check_eq('salutation returned', v_row.salutation, 'Mr');
  perform pg_temp.check_eq('phone returned', v_row.phone, '+60123456789');

  -- And on the TABLE, not merely in the returned record.
  perform pg_temp.check_eq(
    'name on the row',
    (select p.full_name from public.profiles p where p.id = v_me),
    'Ahmad Ismail');

  -- -------------------------------------------------------------------
  -- 2. A null argument leaves a column alone
  -- -------------------------------------------------------------------
  -- The screen sends every field it has; a caller that sends one field
  -- must not silently blank the rest.
  v_row := public.update_my_profile(p_full_name => 'Ahmad B. Ismail');

  perform pg_temp.check_eq('salutation kept', v_row.salutation, 'Mr');
  perform pg_temp.check_eq('phone kept', v_row.phone, '+60123456789');

  -- -------------------------------------------------------------------
  -- 3. An empty string clears one, which is what an emptied box means
  -- -------------------------------------------------------------------
  -- The other half of the COALESCE, and the reason the empty string is
  -- not normalised to null on the way in: without this, a form could
  -- show a telephone number nobody is able to remove.
  v_row := public.update_my_profile(p_phone => '');
  perform pg_temp.check_eq('phone cleared', v_row.phone, '');

  -- -------------------------------------------------------------------
  -- 4. The four things it must not write
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq(
    'email untouched',
    (select p.email::text from public.profiles p where p.id = v_me),
    'fixture@iakauntan.test');

  perform pg_temp.check_true(
    'deleted_at untouched',
    (select p.deleted_at is null from public.profiles p where p.id = v_me));

  perform pg_temp.check_eq(
    'last_org_id untouched',
    (select p.last_org_id from public.profiles p where p.id = v_me),
    v_org);

  perform pg_temp.check_eq(
    'the colleague''s name untouched',
    (select p.full_name from public.profiles p where p.id = v_other),
    'Siti binti Rahman');

  -- -------------------------------------------------------------------
  -- 5. Signed out, it refuses
  -- -------------------------------------------------------------------
  perform pg_temp.sign_out();
  perform pg_temp.check_refused(
    'a stranger changing a name',
    $q$select public.update_my_profile(p_full_name => 'Nobody At All')$q$,
    '%Not signed in%');

  -- And nothing moved on the way past.
  perform pg_temp.check_eq(
    'the refused call wrote nothing',
    (select p.full_name from public.profiles p where p.id = v_me),
    'Ahmad B. Ismail');

  -- -------------------------------------------------------------------
  -- 6. A closed login refuses
  -- -------------------------------------------------------------------
  -- Unreachable today: `0158` bans the auth row on the way out, so a
  -- closed login cannot get a token to call with. Asserted anyway,
  -- because that is a property of a DIFFERENT migration and it can stop
  -- being true without anybody editing `0649`.
  update public.profiles set deleted_at = now() where id = v_me;
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_refused(
    'a closed login tidying its own nameplate',
    $q$select public.update_my_profile(p_full_name => 'Back From The Dead')$q$,
    '%has been closed%');
  perform pg_temp.check_eq(
    'the closed login wrote nothing',
    (select p.full_name from public.profiles p where p.id = v_me),
    'Ahmad B. Ismail');
  update public.profiles set deleted_at = null where id = v_me;

  -- -------------------------------------------------------------------
  -- 7. A login with no profile row gets a sentence, not a silence
  -- -------------------------------------------------------------------
  -- `0619`'s guards are written as NOT EXISTS precisely so that a user
  -- with no profile keeps the access they have, so this is a state the
  -- schema allows rather than an impossible one.
  --
  -- The row has to be DELETED to reach it, and that is the finding:
  -- `on_auth_user_created` makes a profile for every auth user, so a
  -- login without one cannot arise through signup. The branch is
  -- defensive and this is the only way to exercise it -- which is
  -- worth knowing, because the first version of this assertion just
  -- made a user and passed for the wrong reason.
  declare
    v_rowless uuid := pg_temp.another_user('rowless@iakauntan.test');
  begin
    delete from public.profiles where id = v_rowless;
    perform pg_temp.sign_in_as(v_rowless);
  end;
  perform pg_temp.check_refused(
    'a login with no profile row',
    $q$select public.update_my_profile(p_full_name => 'Nobody')$q$,
    '%No profile on file%');

  -- -------------------------------------------------------------------
  -- 8. Only `authenticated` may call it
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'anon cannot call it',
    not has_function_privilege(
      'anon', 'public.update_my_profile(text, text, text, text)', 'execute'));
  perform pg_temp.check_true(
    'authenticated can call it',
    has_function_privilege(
      'authenticated',
      'public.update_my_profile(text, text, text, text)', 'execute'));

  perform pg_temp.sign_out();
end $$;

rollback;

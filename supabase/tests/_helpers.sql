-- =====================================================================
-- iAkauntan :: shared test helpers
--
-- Included by the other files in this directory with
--
--   \i supabase/tests/_helpers.sql
--
-- so paths are relative to the repository root, which is where CI runs
-- psql from. Everything lives in pg_temp and dies with the session.
-- =====================================================================

create or replace function pg_temp.check_eq(
  p_label text, p_actual numeric, p_expected numeric)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'ok   % = %', p_label, p_actual;
end;
$$;

create or replace function pg_temp.check_true(p_label text, p_value boolean)
returns void language plpgsql as $$
begin
  if p_value is not true then
    raise exception 'FAIL %: expected true', p_label;
  end if;
  raise notice 'ok   %', p_label;
end;
$$;

-- A user to hang the fixtures off. A freshly migrated stack has no one
-- signed up yet, and the trigger that enrols an organization's creator as
-- its owner needs a real row in auth.users, so make one if it is not
-- already there. Rolled back with everything else.
--
-- Pinned to its own address. This used to be "the first row in
-- auth.users", selected with `order by created_at limit 1` — and
-- `auth.users.created_at` has no default and is nullable, so every user
-- these helpers make carries NULL in it. The ordering was therefore over
-- a column in which every value was null, and the row that came back was
-- whichever the scan happened to reach first.
--
-- That is fine right up to the moment a file makes a second user, after
-- which `test_user()` can hand back somebody else's. It is not a
-- hypothetical: `manufacturing.sql` asserts that the owner of one
-- company can read its own bill of materials, and that assertion passed
-- on one CI run and failed on the next with nothing between them but an
-- unrelated commit — because `test_user()` returned the outsider created
-- forty lines earlier, who belongs to the other company and correctly
-- sees nothing. A fixture identity that is decided by physical row order
-- makes every test built on it a coin toss.
--
-- The empty strings are not decoration. GoTrue reads its token columns
-- into non-nullable Go strings, so a user inserted with those columns
-- left NULL cannot sign in at all: the row fails to scan and the API
-- answers 500 `{"code":"unexpected_failure","message":"Database error
-- querying schema"}` — before it ever looks at the password, which makes
-- it read like anything except what it is. Tests never call GoTrue, so
-- this changes nothing here; it is written down because this is the
-- pattern anyone will copy when they need to make a real user by hand.
create or replace function pg_temp.test_user()
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users
   where email = 'fixture@iakauntan.test';
  if v_id is null then
    insert into auth.users (
      id, email, created_at, updated_at,
      confirmation_token, recovery_token,
      email_change_token_new, email_change_token_current,
      phone_change_token, reauthentication_token,
      email_change, phone_change)
    values (gen_random_uuid(), 'fixture@iakauntan.test', now(), now(),
      '', '', '', '', '', '', '', '')
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- A *different* person each time, for tests about more than one.
--
-- `test_user()` above is idempotent by design — it returns the fixture
-- user and creates one only if it is not there — which is right for
-- hanging a fixture off and wrong whenever the point of the test is that
-- these are two people. Asked for three users it hands back the same one
-- three times, and every assertion about what a colleague cannot do
-- quietly becomes an assertion about yourself, which passes for the
-- wrong reason or fails for a reason that makes no sense.
--
-- `created_at` is set here for the same reason it is set above: the
-- column has no default, and a table of users that are all null in it
-- cannot be ordered by it.
--
-- The empty strings are load-bearing for the same reason they are above.
create or replace function pg_temp.another_user(p_email text)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, email, created_at, updated_at,
    confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (v_id, p_email, now(), now(), '', '', '', '', '', '', '', '');
  return v_id;
end;
$$;

-- Runs the rest of the transaction as that user, so the `can_*` guards
-- inside the SECURITY DEFINER functions see somebody rather than nobody.
create or replace function pg_temp.sign_in_as(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$;

create or replace function pg_temp.sign_out()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- A throwaway organization owned by the fixture user, already signed in
-- and with the standard chart of accounts, which anything that posts
-- needs. Deliberately not create_organization(): that reads auth.uid(),
-- and the caller has not signed in yet at this point.
create or replace function pg_temp.test_org(p_name text)
returns uuid language plpgsql as $$
declare v_owner uuid := pg_temp.test_user(); v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_owner)
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);
  perform pg_temp.sign_in_as(v_owner);
  return v_org;
end;
$$;

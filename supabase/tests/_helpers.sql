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
-- its owner needs a real row in auth.users, so make one if the database
-- is empty. Rolled back with everything else.
create or replace function pg_temp.test_user()
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users order by created_at limit 1;
  if v_id is null then
    insert into auth.users (id, email)
    values (gen_random_uuid(), 'fixture@iakauntan.test')
    returning id into v_id;
  end if;
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

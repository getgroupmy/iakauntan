-- =====================================================================
-- iAkauntan :: the title and the number somebody registers with
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/signup_details.sql
--
-- `0554`. Two things registration now asks for, and one of them is
-- arithmetic on a phone number that fails silently.
--
-- A Malaysian writes their mobile 012-345 6789. The zero is a trunk
-- prefix and is not part of the number: with the country code in front
-- the number is +60 12 345 6789. Keep the zero and the profile holds
-- +600123456789, which nothing can dial, and nothing anywhere says so
-- -- the field accepted it, the insert succeeded, and a message one day
-- is not delivered.
--
-- The rule is in the database rather than only in the form because a
-- form is one caller. `handle_new_user` is the second, and an import or
-- the console will be the third.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The zero that is not part of the number
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the trunk prefix is dropped',
    app.phone_e164('60', '0123456789'), '+60123456789');

  -- The assertion this file exists for. Without the ltrim the answer is
  -- +600123456789, which is not a number, and every other assertion
  -- here still passes.
  perform pg_temp.check_true('and the result cannot begin +600',
    app.phone_e164('60', '0123456789') not like '+600%');

  perform pg_temp.check_eq('a number written without one is unchanged',
    app.phone_e164('60', '123456789'), '+60123456789');

  perform pg_temp.check_eq('two zeros are two zeros',
    app.phone_e164('60', '00123456789'), '+60123456789');

  perform pg_temp.check_eq('spaces, dashes and brackets are decoration',
    app.phone_e164('+60', '(012) 345-6789'), '+60123456789');

  perform pg_temp.check_eq('another country, same rule',
    app.phone_e164('44', '07911 123456'), '+447911123456');
end $$;

-- ---------------------------------------------------------------------
-- What is not a phone number
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('an empty box stores nothing',
    app.phone_e164('60', '') is null);
  perform pg_temp.check_true('nor does a box holding only zeros',
    app.phone_e164('60', '000') is null);
  perform pg_temp.check_true('nor a number with no country',
    app.phone_e164('', '123456789') is null);
  perform pg_temp.check_true('nor null anything',
    app.phone_e164(null, null) is null);

  -- E.164 allows fifteen digits including the country code. Storing
  -- more would be storing something nothing can dial.
  perform pg_temp.check_true('and sixteen digits is a typo',
    app.phone_e164('60', '1234567890123456') is null);
  perform pg_temp.check_eq('fifteen is the most there can be',
    length(app.phone_e164('60', '1234567890123')), 16);
end $$;

-- ---------------------------------------------------------------------
-- Both reach the profile
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
  v_row  record;
begin
  -- Registration, as GoTrue performs it: a row in auth.users carrying
  -- what the form put in the metadata.
  v_user := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'newcomer@iakauntan.test', jsonb_build_object(
    'full_name', 'Nurul Aisyah binti Rahman',
    'salutation', 'Datin Seri',
    'phone_dial', '60',
    'phone_national', '012-345 6789',
    'country_code', 'MYS',
    'state_code', '14'));

  select * into v_row from public.profiles where id = v_user;

  perform pg_temp.check_eq('the name arrives',
    v_row.full_name, 'Nurul Aisyah binti Rahman');
  perform pg_temp.check_eq('the title arrives',
    v_row.salutation, 'Datin Seri');
  perform pg_temp.check_eq('and the number arrives dialable',
    v_row.phone, '+60123456789');

  -- `0555`. Where the PERSON is, which is not the same question as
  -- where the books are: somebody can keep a Singaporean company's
  -- books from Kuala Lumpur.
  perform pg_temp.check_eq('the country arrives',
    v_row.country_code, 'MYS');
  perform pg_temp.check_eq('and the state, as a ref_states code',
    v_row.state_code, '14');
  perform pg_temp.check_eq('which is the one the form starts on',
    (select name from public.ref_states where code = v_row.state_code),
    'Wilayah Persekutuan Kuala Lumpur');
end $$;

-- ---------------------------------------------------------------------
-- And somebody who gave neither still has a profile
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
  v_row  record;
begin
  -- Every account created before this migration, and every one created
  -- by an invitation rather than by the form.
  v_user := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'invited@iakauntan.test',
          jsonb_build_object('full_name', 'Wong Mei Ling'));

  select * into v_row from public.profiles where id = v_user;
  perform pg_temp.check_eq('the name still arrives',
    v_row.full_name, 'Wong Mei Ling');
  perform pg_temp.check_true('and the rest is empty rather than wrong',
    v_row.salutation is null and v_row.phone is null
      and v_row.country_code is null and v_row.state_code is null);
end $$;

-- ---------------------------------------------------------------------
-- The lists the form reads, with no session behind it
-- ---------------------------------------------------------------------
do $$
declare
  v_ref jsonb;
begin
  -- The registration form is the one screen with no session, so this
  -- has to answer as `anon`. A policy granted to `authenticated` would
  -- hand it two empty lists and the form would draw two empty
  -- dropdowns.
  set local role anon;
  v_ref := public.signup_reference();
  reset role;

  -- Against the tables rather than against a number, so the lists
  -- cannot quietly shrink: every active country that has a dialling
  -- code, and every active salutation.
  perform pg_temp.check_eq('a stranger reads every dialling code there is',
    jsonb_array_length(v_ref -> 'dial_codes'),
    (select count(*)::integer from public.ref_countries
      where is_active and coalesce(dial_code, '') <> ''));
  perform pg_temp.check_eq('and every salutation',
    jsonb_array_length(v_ref -> 'salutations'),
    (select count(*)::integer from public.salutations where is_active));
  perform pg_temp.check_eq('and every Malaysian state',
    jsonb_array_length(v_ref -> 'states'),
    (select count(*)::integer from public.ref_states));
  perform pg_temp.check_true('with the one the form starts on among them',
    exists (select 1 from jsonb_array_elements(v_ref -> 'states') st
             where st ->> 'code' = '14'
               and st ->> 'name' like '%Kuala Lumpur%'));

  -- And that those are lists rather than a handful.
  perform pg_temp.check_true('both are lists worth drawing',
    jsonb_array_length(v_ref -> 'dial_codes') > 40
      and jsonb_array_length(v_ref -> 'salutations') > 50);

  perform pg_temp.check_true('Malaysia is among them, with its code',
    exists (select 1 from jsonb_array_elements(v_ref -> 'dial_codes') c
             where c ->> 'code' = 'MYS' and c ->> 'dial_code' like '%60%'));

  -- The reason the list is long: a letter addressed to a Dato' Sri as
  -- "Mr" is an insult, and the English-speaking office's four titles
  -- do not cover the country this is written for.
  perform pg_temp.check_true('and the titles this country uses',
    exists (select 1 from jsonb_array_elements(v_ref -> 'salutations') s
             where s ->> 'name' = 'Dato'' Sri')
    and exists (select 1 from jsonb_array_elements(v_ref -> 'salutations') s
                 where s ->> 'name' = 'Ir')
    and exists (select 1 from jsonb_array_elements(v_ref -> 'salutations') s
                 where s ->> 'name' = 'Hajjah'));

  perform pg_temp.check_true('with the rest of the world too',
    exists (select 1 from jsonb_array_elements(v_ref -> 'salutations') s
             where s ->> 'name' = 'Señora'));
end $$;

-- ---------------------------------------------------------------------
-- The tables themselves stay shut
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the salutations table is not open to anon',
    not has_table_privilege('anon', 'public.salutations', 'select'));
  perform pg_temp.check_true('nor is the country reference',
    not has_table_privilege('anon', 'public.ref_countries', 'select'));
end $$;

rollback;

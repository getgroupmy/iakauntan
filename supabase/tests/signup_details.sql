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
    'state_code', '14',
    'use_kind', 'personal'));

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

  -- `0558`. What they said they were here for, so setup does not ask
  -- again one screen later.
  perform pg_temp.check_eq('and what they said they are here for',
    v_row.use_kind, 'personal');
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
      and v_row.country_code is null and v_row.state_code is null
      and v_row.use_kind is null);
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
-- A word nobody recognises is no answer, not a failed registration
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
begin
  v_user := gen_random_uuid();
  -- A sign-up that fails because a client sent an unknown word is a
  -- worse outcome than a question asked twice, so the trigger drops it
  -- rather than letting the constraint take the registration with it.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'oddly@iakauntan.test',
          jsonb_build_object('full_name', 'Odd Case',
                             'use_kind', 'somethingelse'));

  perform pg_temp.check_true('the account is still created',
    exists (select 1 from public.profiles where id = v_user));
  perform pg_temp.check_true('with no answer rather than a wrong one',
    (select use_kind from public.profiles where id = v_user) is null);
end $$;

-- ---------------------------------------------------------------------
-- Changing the number afterwards (0557)
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_user := auth.uid();

  perform pg_temp.check_eq('the same rule when it is changed later',
    public.update_my_phone('60', '012-345 6789'), '+60123456789');
  perform pg_temp.check_eq('and that is what the profile holds',
    (select phone from public.profiles where id = v_user), '+60123456789');

  -- The assertion that would fail if the RPC wrote what it was handed:
  -- a client deciding for itself what goes in the column is how the
  -- trunk-prefix zero comes back.
  perform pg_temp.check_true('with no zero in front of it',
    (select phone from public.profiles where id = v_user) not like '+600%');

  -- Taking it off is an answer, not a failure.
  perform pg_temp.check_true('an empty box removes the number',
    public.update_my_phone('60', '') is null);
  perform pg_temp.check_true('and the profile says so',
    (select phone from public.profiles where id = v_user) is null);

  -- But a typo is not. Storing nothing while the screen says "saved"
  -- is the silent half of the fault 0554 was written about.
  perform pg_temp.check_refused(
    'a number that cannot be dialled is refused rather than dropped',
    'select public.update_my_phone(''60'', ''1234567890123456'')',
    '%not a number we can dial%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- And only for yourself
-- ---------------------------------------------------------------------
do $$
declare
  v_other uuid;
  v_mine  uuid;
begin
  v_mine := auth.uid();
  v_other := pg_temp.another_user('someone.else@iakauntan.test');

  perform pg_temp.sign_in_as(v_other);
  perform public.update_my_phone('60', '199999999');

  -- The function takes no "whose", which is the whole guard: there is
  -- no argument to point at a colleague.
  perform pg_temp.check_eq('somebody else''s number is their own',
    (select phone from public.profiles where id = v_other), '+60199999999');
  perform pg_temp.check_true('and mine is untouched',
    (select phone from public.profiles where id = v_mine) is null);

  perform pg_temp.sign_in_as(v_mine);
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

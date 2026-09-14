-- =====================================================================
-- iAkauntan :: what registration already knows
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/registration_answers.sql
--
-- `0590`. Three things, each of which fails in a way nobody would
-- notice until somebody was already in the product.
--
-- An accounting practice is a third answer to "what is this for?", not
-- a kind of business. `profiles_use_kind_known` decides whether the
-- word survives the insert, and a constraint that still names two
-- answers turns every accountant's registration into a failed sign-up.
--
-- The company name and the entity type a business types at
-- registration are kept so setup can offer them back. An answer that
-- does not arrive is not an error anywhere: the form simply asks again,
-- which is the behaviour this file exists to distinguish from the
-- behaviour it is supposed to have.
--
-- And `create_organization` gained a parameter. Adding a defaulted one
-- to an existing signature would have made a SECOND overload and left
-- every existing call ambiguous -- an error at the last press of the
-- last screen of setup, on the one path nobody can work around. So the
-- old signature is dropped, and the assertion below is that exactly one
-- of these functions exists.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A practice is a third answer
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
  v_row  record;
begin
  v_user := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'practice@iakauntan.test', jsonb_build_object(
    'full_name', 'Lim & Partners',
    'use_kind', 'accountant'));

  select * into v_row from public.profiles where id = v_user;
  perform pg_temp.check_eq('an accountant registers as one',
    v_row.use_kind, 'accountant');

  -- The constraint itself, asked directly. The insert above goes
  -- through `handle_new_user`, which drops anything it does not
  -- recognise -- so it would pass with the constraint naming only two
  -- answers AND with it naming none at all. What is being checked here
  -- is the column, and the way to check a column is to write to it.
  --
  -- The two older answers still mean what they meant, said out loud
  -- because the constraint was DROPPED and re-created to add the third,
  -- and a re-created constraint is a chance to lose one.
  update public.profiles set use_kind = 'business' where id = v_user;
  perform pg_temp.check_eq('a business is still a business',
    (select p.use_kind from public.profiles p where p.id = v_user),
    'business');
  update public.profiles set use_kind = 'personal' where id = v_user;
  perform pg_temp.check_eq('and a person still a person',
    (select p.use_kind from public.profiles p where p.id = v_user),
    'personal');
  update public.profiles set use_kind = null where id = v_user;
  perform pg_temp.check_true('and an account nobody asked has no answer',
    (select p.use_kind from public.profiles p where p.id = v_user) is null);

  perform pg_temp.check_refused(
    'a word the schema has never heard of',
    format('update public.profiles set use_kind = %L where id = %L',
           'somethingelse', v_user),
    '%profiles_use_kind_known%');
end $$;

-- ---------------------------------------------------------------------
-- What a business says at registration, kept for setup
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
  v_row  record;
begin
  v_user := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'business@iakauntan.test', jsonb_build_object(
    'full_name', 'Tan Wei Ming',
    'use_kind', 'business',
    'business_name', '  Sinar Teknologi Sdn Bhd  ',
    'entity_type', 'sdn_bhd'));

  select * into v_row from public.profiles where id = v_user;
  perform pg_temp.check_eq('the company name arrives, trimmed',
    v_row.signup_business_name, 'Sinar Teknologi Sdn Bhd');
  perform pg_temp.check_eq('and the legal form with it',
    v_row.signup_entity_type, 'sdn_bhd');

  -- Nobody else is asked, so nobody else has one. A blank string would
  -- be a person with an empty company name on their profile, and setup
  -- would have to decide what that meant.
  v_user := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'person@iakauntan.test', jsonb_build_object(
    'full_name', 'Siti Nurhaliza',
    'use_kind', 'personal'));

  select * into v_row from public.profiles where id = v_user;
  perform pg_temp.check_true('a person carries neither',
    v_row.signup_business_name is null
      and v_row.signup_entity_type is null);
end $$;

-- ---------------------------------------------------------------------
-- And a word nobody recognises is dropped, not fatal
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := gen_random_uuid();
  v_row  record;
begin
  -- The whole point of checking the value in the trigger rather than
  -- letting the column's own constraint refuse it. A registration that
  -- fails because a client sent a word nobody recognises is a person
  -- who cannot sign up at all, and there is nothing on the screen to
  -- tell them why.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'odd-entity@iakauntan.test', jsonb_build_object(
    'full_name', 'Odd Case',
    'use_kind', 'business',
    'business_name', 'Something Or Other',
    'entity_type', 'a-kind-of-company-that-does-not-exist'));

  select * into v_row from public.profiles where id = v_user;
  perform pg_temp.check_true('the registration still happened',
    v_row.id is not null);
  perform pg_temp.check_eq('and the name it did send was kept',
    v_row.signup_business_name, 'Something Or Other');
  perform pg_temp.check_true('while the entity type is simply absent',
    v_row.signup_entity_type is null);
end $$;

-- ---------------------------------------------------------------------
-- The old registration number, and the overload that must not exist
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org   uuid;
  v_row   record;
  v_count integer;
begin
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_organization';
  -- Two would mean every call that omits the new parameter is
  -- ambiguous -- which is every call in the app, and the failure lands
  -- on the last press of the last screen of setup.
  perform pg_temp.check_eq('there is exactly one create_organization',
    v_count, 1);

  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);

  v_org := public.create_organization(
    p_name              => 'Kabeer Holdings Sdn Bhd',
    p_entity_type       => 'sdn_bhd',
    p_registration_no   => '200201003726',
    p_old_registration_no => '571389-H');

  select * into v_row from public.organizations where id = v_org;
  perform pg_temp.check_eq('the number the register issued first is kept',
    v_row.old_registration_no, '571389-H');
  perform pg_temp.check_eq('beside the one it issues now',
    v_row.registration_no, '200201003726');

  -- Never required, and that is the point. A company incorporated
  -- after 2019 has never had one, and a mandatory box in front of
  -- somebody with nothing to put in it is a box that gets a made-up
  -- number -- which then goes out on an invoice.
  perform pg_temp.allow_many_companies();
  v_org := public.create_organization(
    p_name            => 'Baru Teknologi Sdn Bhd',
    p_registration_no => '202301234567');

  select * into v_row from public.organizations where id = v_org;
  perform pg_temp.check_true('and a company that never had one is created',
    v_row.old_registration_no is null);

  -- An empty box is not a number. Stored as null rather than as '',
  -- which would print on a letterhead as a blank pair of brackets.
  perform pg_temp.allow_many_companies();
  v_org := public.create_organization(
    p_name                => 'Kosong Enterprise',
    p_registration_no     => '202401234567',
    p_old_registration_no => '   ');

  select * into v_row from public.organizations where id = v_org;
  perform pg_temp.check_true('and a box somebody cleared stores nothing',
    v_row.old_registration_no is null);
end $$;

rollback;

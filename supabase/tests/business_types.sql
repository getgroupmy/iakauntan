-- =====================================================================
-- iAkauntan :: what a business is, and what that turns on
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_types.sql
--
-- `0553` offers a restaurant a till and a law firm the client account.
-- Three things about that can go wrong quietly, and all three are here.
--
-- A code in `module_codes` that names no module switches nothing on and
-- says nothing: the loop skips it, the screen shows a tick, and the
-- company is set up without the thing it was shown. That is what a
-- foreign key would have caught, and the array does not have one -- so
-- the assertion is here instead, and it is the reason the array was
-- allowed.
--
-- A module already on for everybody, named in a list, makes a screen
-- claim the business type added it. `seed_org_modules` switches on
-- e-Invoice, purchases, inventory and CRM for every company, so none of
-- those may appear.
--
-- And a person filed as a business registration number is rejected by
-- MyInvois, which is not something this repository finds out about.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Every code in the catalogue names a module that exists
-- ---------------------------------------------------------------------
do $$
declare
  v_unknown text;
  v_core    text;
  v_default text;
begin
  select string_agg(distinct t.code || ' -> ' || c, ', ')
    into v_unknown
    from public.business_types t, unnest(t.module_codes) c
   where not exists (select 1 from public.platform_modules m
                      where m.code = c);
  perform pg_temp.check_true(
    coalesce('a business type offers a module that does not exist: '
             || v_unknown, 'every offered module exists'),
    v_unknown is null);

  select string_agg(distinct t.code || ' -> ' || c, ', ')
    into v_core
    from public.business_types t, unnest(t.module_codes) c
    join public.platform_modules m on m.code = c and m.is_core;
  perform pg_temp.check_true(
    coalesce('a business type offers a core module: ' || v_core,
             'nothing offers what is already part of the product'),
    v_core is null);

  -- The four `seed_org_modules` switches on for every company.
  select string_agg(distinct t.code || ' -> ' || c, ', ')
    into v_default
    from public.business_types t, unnest(t.module_codes) c
   where c in ('einvoice', 'purchases', 'inventory', 'crm');
  perform pg_temp.check_true(
    coalesce('a business type claims to add a module every company '
             'already has: ' || v_default,
             'nothing claims to add what every company already has'),
    v_default is null);

  perform pg_temp.check_true('the catalogue is not empty',
    (select count(*) from public.business_types where is_active) > 20);

  -- The answer that means "ask me instead" has to be there, and has to
  -- be empty: the screen shows the whole list with nothing ticked.
  perform pg_temp.check_eq('there is an "something else"',
    (select array_length(module_codes, 1)
       from public.business_types where code = 'other'), null::integer);
end $$;

-- ---------------------------------------------------------------------
-- Applying one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_n   integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Kopi Sdn Bhd', array['crm']);

  v_n := public.apply_business_type(v_org, 'restaurant');

  perform pg_temp.check_eq('the company is recorded as what it said',
    (select business_type from public.organizations where id = v_org),
    'restaurant');

  perform pg_temp.check_eq('and it was given what a restaurant needs',
    v_n, (select array_length(module_codes, 1)
            from public.business_types where code = 'restaurant'));
  perform pg_temp.check_true('the till among them',
    app.has_module(v_org, 'pos'));

  -- What it did NOT do: everything else in the catalogue.
  perform pg_temp.check_true('and not the client account',
    not app.has_module(v_org, 'legal'));
  perform pg_temp.check_true('nor payroll',
    not app.has_module(v_org, 'payroll'));
end $$;

-- ---------------------------------------------------------------------
-- The ticks somebody moved are the answer
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Sesuatu Yang Lain Sdn Bhd', array['crm']);

  -- "Something else", and a list chosen by hand. The type carries no
  -- modules, so what is switched on can only have come from the list.
  perform public.apply_business_type(v_org, 'other', array['legal', 'hr']);

  perform pg_temp.check_true('what was ticked is on',
    app.has_module(v_org, 'legal') and app.has_module(v_org, 'hr'));
  perform pg_temp.check_true('and nothing else was',
    not app.has_module(v_org, 'pos'));

  -- A core module in the list is skipped rather than refused: it is
  -- already on, and stopping over it would leave the rest unapplied.
  perform pg_temp.check_eq('a core module in the list is not counted',
    public.apply_business_type(v_org, 'other', array['sales', 'pos']), 1);
  perform pg_temp.check_true('and the rest of the list still applied',
    app.has_module(v_org, 'pos'));
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_other uuid;
begin
  v_org := pg_temp.test_org('Syarikat Ketiga Sdn Bhd', array['crm']);
  v_other := pg_temp.another_user('outsider@iakauntan.test');

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'somebody who is not in the company may not set it up',
    format('select public.apply_business_type(%L, %L)', v_org, 'restaurant'),
    '%owner or admin%', '42501');

  perform pg_temp.check_true('and nothing was recorded',
    (select business_type from public.organizations where id = v_org)
      is distinct from 'restaurant');
end $$;

-- ---------------------------------------------------------------------
-- A business type that does not exist
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Keempat Sdn Bhd', array['crm']);

  perform pg_temp.check_refused(
    'a business type nobody offers is refused',
    format('select public.apply_business_type(%L, %L)', v_org, 'unicorn_farm'),
    '%no business type%', 'P0002');
end $$;

-- ---------------------------------------------------------------------
-- A person is not a business registration number
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
begin
  v_org := pg_temp.test_org('Ahmad bin Ismail', array['crm']);
  update public.organizations
     set entity_type = 'individual'::app.entity_type,
         registration_no = '900101015555'
   where id = v_org;

  perform pg_temp.check_eq('a Malaysian person is filed under NRIC',
    (select einvoice_id_type from public.organizations where id = v_org),
    'NRIC');

  -- The one that matters: BRN on a person is rejected by MyInvois, and
  -- nothing in this repository finds that out.
  perform pg_temp.check_true('and not under a business registration',
    (select einvoice_id_type from public.organizations where id = v_org)
      <> 'BRN');

  update public.organizations
     set country_code = 'SGP', einvoice_id_type = 'BRN'
   where id = v_org;
  perform pg_temp.check_eq('somebody with no NRIC is filed under passport',
    (select einvoice_id_type from public.organizations where id = v_org),
    'PASSPORT');

  -- Said is said. A trigger that overrode this would file the wrong
  -- number for somebody who had already told it the right one.
  update public.organizations
     set einvoice_id_type = 'ARMY' where id = v_org;
  perform pg_temp.check_eq('an identification already stated is left alone',
    (select einvoice_id_type from public.organizations where id = v_org),
    'ARMY');
end $$;

-- ---------------------------------------------------------------------
-- And a company is still a company
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
begin
  v_org := pg_temp.test_org('Syarikat Biasa Sdn Bhd', array['crm']);
  perform pg_temp.check_eq('a Sdn Bhd keeps the business registration',
    (select einvoice_id_type from public.organizations where id = v_org),
    'BRN');
end $$;

rollback;

-- =====================================================================
-- iAkauntan :: which country the company is in
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_country.sql
--
-- `0351`. `organizations.country_code` has been on the table since
-- `0003` and `create_organization` never took it, so every company set
-- up through the product was recorded as Malaysian whether it was or
-- not.
--
-- Two of the three things asserted here fail silently:
--
--   * a country that is asked for and not stored looks exactly like the
--     feature working, right up until somebody in Singapore opens their
--     own company record;
--   * and the overload. A default does not replace a function, it
--     overloads it — leave the sixteen-argument version in place and a
--     caller that omits the country resolves to it, sets nothing, and
--     raises nothing.
--
-- The third is loud but worth pinning anyway: a caller that predates
-- this migration must still work, because the parameter is appended
-- with the default the column already had.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- There is one of it
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_proc where proname = 'create_organization';
  perform pg_temp.check_eq('create_organization is one function, not two',
                           v_n, 1);
end $$;

-- ---------------------------------------------------------------------
-- The country asked for is the country stored
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org uuid;
  v_country text;
begin
  perform pg_temp.sign_in_as(v_user);

  v_org := public.create_organization(
    p_name => 'Lion City Books Pte Ltd',
    p_entity_type => 'other',
    p_country_code => 'SGP');

  select o.country_code into v_country
    from public.organizations o where o.id = v_org;
  perform pg_temp.check_eq('a company in Singapore is recorded there',
                           v_country, 'SGP');
end $$;

-- ---------------------------------------------------------------------
-- And a caller that says nothing still gets what it got before
--
-- The parameter is appended with the column's own default, so every
-- call written before `0351` means the same thing after it.
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org uuid;
  v_country text;
begin
  perform pg_temp.sign_in_as(v_user);

  v_org := public.create_organization(
    p_name => 'Kedai Lama Sdn Bhd',
    p_entity_type => 'sdn_bhd');

  select o.country_code into v_country
    from public.organizations o where o.id = v_org;
  perform pg_temp.check_eq('a caller that says nothing is still Malaysian',
                           v_country, 'MYS');
end $$;

-- An empty string is not a country either: it falls back rather than
-- storing a blank, for the reason every other emptied box on this
-- platform does.
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org uuid;
  v_country text;
begin
  perform pg_temp.sign_in_as(v_user);

  v_org := public.create_organization(
    p_name => 'Kedai Kosong Sdn Bhd',
    p_entity_type => 'sdn_bhd',
    p_country_code => '   ');

  select o.country_code into v_country
    from public.organizations o where o.id = v_org;
  perform pg_temp.check_eq('and an empty answer is not a country',
                           v_country, 'MYS');
end $$;

-- ---------------------------------------------------------------------
-- The list the screen picks from is there to pick from
--
-- `ref_countries` since `0011`. The screen reads alpha-2 for Google
-- Places and alpha-3 for the column, so both have to be present on
-- every row or the picker offers a country the address box cannot use.
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.ref_countries where is_active;
  perform pg_temp.check_true('there are countries to choose from', v_n > 10);

  select count(*) into v_n from public.ref_countries
   where is_active and (alpha2 is null or btrim(alpha2) = ''
                        or code is null or btrim(code) = '');
  perform pg_temp.check_eq('and every one carries both codes', v_n, 0);

  select count(*) into v_n from public.ref_countries
   where code = 'MYS' and alpha2 = 'MY';
  perform pg_temp.check_eq('Malaysia among them, spelt both ways', v_n, 1);
end $$;

rollback;

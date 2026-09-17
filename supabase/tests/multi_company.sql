-- =====================================================================
-- iAkauntan :: multi-company is a module
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/multi_company.sql
--
-- Holding more than one company on one account was the largest thing
-- this product did that nobody paid for: `create_organization` asked
-- only that somebody be signed in, and `create_firm` no more than that
-- either. 0486 makes the rule explicit -- the first company is what
-- signing up is for, everything after it is Multi-Company -- and puts
-- it on both doors.
--
-- The fixtures build their first company with `pg_temp.test_org` and
-- an explicit module list, because the helper's default is *every*
-- module, which would hand out the very entitlement under test.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Standing up a company, or the refusal it met.
create or replace function pg_temp.add_company(p_name text)
returns text language plpgsql as $$
declare v_id uuid;
begin
  v_id := public.create_organization(p_name);
  return 'made ' || (select name from public.organizations where id = v_id);
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.start_practice(p_name text)
returns text language plpgsql as $$
declare v_id uuid;
begin
  v_id := public.create_firm(p_name);
  return 'made ' || (select name from public.firms where id = v_id);
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.grant_module(p_org uuid, p_code text)
returns void language sql as $$
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (p_org, p_code, true)
  on conflict (org_id, module_code) do update set is_enabled = true;
$$;

do $$
declare
  v_org      uuid;
  v_colleague uuid;
  v_other    uuid;
  v_mine     uuid;
begin
  -- ------------------------------------------------------------------
  -- The module itself
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('it is an add-on, not core',
    exists (select 1 from public.platform_modules
             where code = 'multi_company'
               and is_active and not is_core and monthly_price > 0));

  -- ------------------------------------------------------------------
  -- Somebody signing up
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('the first company is free',
    pg_temp.add_company('Syarikat Pertama Sdn Bhd'),
    'made Syarikat Pertama Sdn Bhd');

  perform pg_temp.check_eq('a second company needs the module',
    pg_temp.add_company('Syarikat Kedua Sdn Bhd'),
    'Adding another company needs the Multi-Company module. Turn it on '
    'for a company you already own, under Settings, and then add this '
    'one.');
  perform pg_temp.check_eq('and so does a practice',
    pg_temp.start_practice('Kira Dua & Rakan'),
    'Starting a practice needs the Multi-Company module. Turn it on '
    'for a company you already own, under Settings, and then start '
    'the practice.');
  perform pg_temp.check_true('and the app is told, so the button is not drawn',
    not public.can_add_company());

  -- ------------------------------------------------------------------
  -- Once it is bought
  -- ------------------------------------------------------------------
  select m.org_id into v_org from public.org_members m
   where m.user_id = pg_temp.test_user() and m.role = 'owner'
   order by m.joined_at limit 1;
  perform pg_temp.grant_module(v_org, 'multi_company');

  perform pg_temp.check_true('the app is told the other way too',
    public.can_add_company());
  perform pg_temp.check_eq('with the module, another company can be added',
    pg_temp.add_company('Syarikat Kedua Sdn Bhd'),
    'made Syarikat Kedua Sdn Bhd');
  perform pg_temp.check_eq('and a practice can be started',
    pg_temp.start_practice('Kira Dua & Rakan'), 'made Kira Dua & Rakan');

  -- ------------------------------------------------------------------
  -- Whose entitlement it is
  -- ------------------------------------------------------------------
  -- Somebody invited into the books above. They own nothing, so their
  -- own first company is still theirs to make -- being a colleague is
  -- not something they spent anything on, in either direction.
  v_colleague := pg_temp.another_user('rakan-0486@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_colleague, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_colleague);
  perform pg_temp.check_eq(
    'somebody invited into a colleague''s books still gets their own '
    'first company',
    pg_temp.add_company('Syarikat Rakan Sdn Bhd'),
    'made Syarikat Rakan Sdn Bhd');

  -- And having done so, they are where everybody else is: the module
  -- sits on somebody else's company, not on theirs.
  perform pg_temp.check_eq('a module on somebody else''s company is not yours',
    pg_temp.add_company('Syarikat Rakan Dua Sdn Bhd'),
    'Adding another company needs the Multi-Company module. Turn it on '
    'for a company you already own, under Settings, and then add this '
    'one.');

  -- ------------------------------------------------------------------
  -- And nobody's existing companies were taken away
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- The two they made above, both still theirs. The gate is on the
  -- next one, never on what somebody already has.
  perform pg_temp.check_eq('the companies already made are still there',
    (select count(*)::integer from public.org_members m
      where m.user_id = pg_temp.test_user() and m.role = 'owner'), 2);

  raise notice 'multi-company: all assertions passed';
end $$;

rollback;

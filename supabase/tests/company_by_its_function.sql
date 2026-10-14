-- =====================================================================
-- iAkauntan :: a company is made by its function (0879)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_by_its_function.sql
--
-- A signed-in user could insert a company row directly, past
-- `create_organization` and the Multi-Company question it asks, and own
-- a company with no chart of accounts. A company is made by its
-- function now, and only by it. Asked with the role `authenticated`, as
-- the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_co (owner uuid, first_org uuid, newcomer uuid);
grant select on t_co to authenticated;

-- What `create_organization` made, or the refusal it met.
create or replace function pg_temp.add_company(p_name text)
returns text language plpgsql as $$
declare v_id uuid;
begin
  v_id := public.create_organization(p_name);
  return 'made ' || (select name from public.organizations where id = v_id)
      || ', owned by me: '
      || exists (select 1 from public.org_members m
                  where m.org_id = v_id and m.user_id = auth.uid()
                    and m.role = 'owner')
      || ', with a chart of accounts: '
      || exists (select 1 from public.accounts a where a.org_id = v_id);
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.insert_company(p_name text)
returns text language sql as $$
  select format($q$insert into public.organizations (name, slug, created_by)
                   values (%L, %L, auth.uid())$q$,
                p_name, 'co-' || substr(md5(p_name || random()::text), 1, 10));
$$;

do $$
declare r t_co;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.owner := pg_temp.test_user();
  r.first_org := pg_temp.test_org('Satu Sahaja Sdn Bhd');
  -- The helper hands out every module; this owner has paid for one company.
  delete from public.org_modules
   where org_id = r.first_org and module_code = 'multi_company';
  r.newcomer := pg_temp.another_user('baru@satusahaja.test');
  insert into t_co select r.*;
end $$;

-- ---------------------------------------------------------------------
-- An owner without Multi-Company
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select owner from t_co));
set local role authenticated;

do $$
declare d t_co;
begin
  select * into d from t_co;
  perform pg_temp.check_true('the premise: this owner may not add a company',
    not public.can_add_company());
  perform pg_temp.check_refused('a second company is not inserted past its function',
    pg_temp.insert_company('Kedua Percuma Sdn Bhd'),
    'permission denied for table organizations', '42501');
  perform pg_temp.check_eq('and its function refuses it, as before',
    pg_temp.add_company('Kedua Percuma Sdn Bhd'),
    'Adding another company needs the Multi-Company module. Turn it on '
    'for a company you already own, under Settings, and then add this '
    'one.');
  perform pg_temp.check_eq('so they own the one company',
    (select count(*) from public.org_members
      where user_id = d.owner and role = 'owner')::int, 1);

  update public.organizations set name = 'Satu Sahaja Berhad'
   where id = d.first_org;
  perform pg_temp.check_eq('and still rename the one they have',
    (select name from public.organizations where id = d.first_org),
    'Satu Sahaja Berhad');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- With the module, the function makes it, and the bare insert still
-- does not
-- ---------------------------------------------------------------------
insert into public.org_modules (org_id, module_code, is_enabled)
select first_org, 'multi_company', true from t_co
on conflict (org_id, module_code) do update set is_enabled = true;

select pg_temp.sign_in_as((select owner from t_co));
set local role authenticated;

do $$
begin
  perform pg_temp.check_refused('an owner with Multi-Company inserts no company either',
    pg_temp.insert_company('Kedua Berbayar Sdn Bhd'),
    'permission denied for table organizations', '42501');
  perform pg_temp.check_eq('the function makes it, with its books',
    pg_temp.add_company('Kedua Berbayar Sdn Bhd'),
    'made Kedua Berbayar Sdn Bhd, owned by me: true, with a chart of accounts: true');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Somebody's first company
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select newcomer from t_co));
set local role authenticated;

do $$
begin
  perform pg_temp.check_refused('a first company is not inserted either',
    pg_temp.insert_company('Pertama Saya Sdn Bhd'),
    'permission denied for table organizations', '42501');
  perform pg_temp.check_eq('it is made by its function, free',
    pg_temp.add_company('Pertama Saya Sdn Bhd'),
    'made Pertama Saya Sdn Bhd, owned by me: true, with a chart of accounts: true');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- No client role inserts, and no policy says it may
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('neither client role holds insert on organizations, on the table or a column',
    (select string_agg(r || ':' || (has_table_privilege(r, 'public.organizations', 'insert')
                                    or has_any_column_privilege(r, 'public.organizations', 'insert')),
                       ', ' order by r)
       from unnest(array['anon', 'authenticated']) r),
    'anon:false, authenticated:false');
  perform pg_temp.check_eq('and no policy admits an insert',
    (select count(*) from pg_policy
      where polrelid = 'public.organizations'::regclass
        and polcmd in ('a', '*'))::int, 0);
end $$;

rollback;

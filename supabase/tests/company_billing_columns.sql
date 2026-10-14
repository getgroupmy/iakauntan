-- =====================================================================
-- iAkauntan :: a company is billed as the platform says (0826)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_billing_columns.sql
--
-- `bill_the_month` bills an active company that is not a demonstration.
-- Before `0826` a company's own admin could write both: two companies
-- holding a paid module the whole of January, one marked a demo and
-- one put on a trial by their owners, and February's run billed
-- neither. Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cb (a uuid, b uuid, firm uuid, u uuid);
grant select on t_cb to authenticated;

do $$
declare
  r t_cb;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  perform pg_temp.allow_many_companies();
  r.a := pg_temp.test_org('Bayar Penuh Sdn Bhd', array['crm']);
  r.b := pg_temp.test_org('Bayar Juga Sdn Bhd', array['crm']);
  -- Both held a paid module the whole of January.
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.a, 'multi_company', true, timestamptz '2025-11-04 09:00+08'),
         (r.b, 'multi_company', true, timestamptz '2025-11-04 09:00+08')
  on conflict (org_id, module_code) do update
     set is_enabled = true, enabled_at = excluded.enabled_at;
  -- An accounting firm neither has asked to take them on.
  insert into public.firms (name, slug) values ('Firma Orang Lain', 'firma-orang-lain') returning id into r.firm;
  insert into t_cb select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_cb;
  r record;
begin
  select * into d from t_cb;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_true('and is the company''s admin', app.can_admin(d.b));

  -- What was measured, and the rest of the platform's columns, each on
  -- its own.
  for r in select * from (values
      ('is_demo', 'true', d.b, 'Bayar Juga Sdn Bhd'),
      ('status', '''trial''', d.a, 'Bayar Penuh Sdn Bhd'),
      ('firm_id', format('%L::uuid', d.firm), d.a, 'Bayar Penuh Sdn Bhd'),
      -- 'owner' is refused already, by `firm_role_is_not_owner`; 'admin'
      -- is the role a firm's people would take over the company with.
      ('firm_member_role', '''admin''', d.a, 'Bayar Penuh Sdn Bhd'))
      as t(col, val, org, name)
  loop
    perform pg_temp.check_refused(format('a company does not set its own %s', r.col),
      format('update public.organizations set %s = %s where id = %L', r.col, r.val, r.org),
      format('%s of %s is the platform''s to set%%', r.col, r.name), '42501');
  end loop;

  -- Nor is one made with any of them. Since `0879` no client makes a
  -- company at all -- `create_organization` is the door -- so the
  -- refusal is the privilege's, before the guard's insert branch is
  -- reached. That branch stays, and answers if the grant ever returns;
  -- its four mutants survive until then, as equivalent ones.
  for r in select * from (values
      ('is_demo', 'true'),
      ('status', '''trial'''),
      ('firm_id', format('%L::uuid', d.firm)),
      ('firm_member_role', '''admin'''))
      as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor is a company made with its %s set', r.col),
      format($q$insert into public.organizations (name, created_by, %s)
                values ('Syarikat Sendiri', %L, %s)$q$, r.col, d.u, r.val),
      'permission denied for table organizations', '42501');
  end loop;

  -- What the settings screen writes is as before.
  update public.organizations
     set phone = '+60 3-1234 5678', website = 'https://bayarpenuh.example',
         rounding_method = rounding_method
   where id = d.a;
  perform pg_temp.check_eq('the settings screen still writes the company',
    (select phone from public.organizations where id = d.a), '+60 3-1234 5678');
  perform pg_temp.check_eq('and both are still active, and not demonstrations',
    (select string_agg(status || '/' || is_demo, ',' order by name)
       from public.organizations where id in (d.a, d.b)),
    'active/false,active/false');
end $$;

reset role;

-- So February bills them both.
do $$
declare d t_cb;
begin
  select * into d from t_cb;
  perform app.bill_the_month(date '2026-02-01');
  perform pg_temp.check_eq('February''s run bills both companies for January',
    (select count(*)::integer from public.platform_invoices
      where org_id in (d.a, d.b) and notes = 'modules:2026-01'), 2);

  -- The platform, as the owner, still sets them. (The guard's other
  -- door, `pg_trigger_depth() > 1`, has nothing to assert here and its
  -- mutant survives as an equivalent one: every function that writes
  -- these columns is a definer, which runs as the owner at any depth.)
  update public.organizations set is_demo = true where id = d.b;
  perform pg_temp.check_true('the owner, at the top, is not refused',
    (select is_demo from public.organizations where id = d.b));
end $$;

rollback;

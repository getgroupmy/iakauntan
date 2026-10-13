-- =====================================================================
-- iAkauntan :: an employee reads her own, and not the company's (0872)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/employee_reads_her_own.sql
--
-- `0871` shut every module gate to an employee with no access type. The
-- tables with no module gate asked `is_org_member` alone, so she still
-- read the chart of accounts, the projects, the company's access types
-- and the member list. She reads her company's frame and her own, and the
-- rest is the staff's. Asked with the role `authenticated`, as the app
-- asks.
--
-- The list of what she may still read lives here, and the last block
-- refuses a table any member can read that is on neither side of it --
-- so the next table somebody adds has to say which it is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ro (org uuid, other uuid, staff uuid, viewer uuid,
  storekeeper uuid);
grant select on t_ro to authenticated;

do $$
declare r t_ro; v_type uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org   := pg_temp.test_org('Kedai Sendiri Sdn Bhd', array['hr', 'payroll']);
  r.other := pg_temp.test_org('Kedai Kedua Sdn Bhd');
  r.staff       := pg_temp.another_user('staf@kedaisendiri.test');
  r.viewer      := pg_temp.another_user('lihat@kedaisendiri.test');
  r.storekeeper := pg_temp.another_user('stor@kedaisendiri.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.staff, 'employee', 'active'),
         (r.org, r.viewer, 'viewer', 'active'),
         (r.org, r.storekeeper, 'employee', 'active'),
         -- The same person, somewhere she is more than an employee.
         (r.other, r.staff, 'viewer', 'active');

  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E1', 'Staf Biasa', r.staff, pg_temp.today());
  insert into public.departments (org_id, code, name) values (r.org, 'GDG', 'Gudang');
  insert into public.leave_types (org_id, code, name) values (r.org, 'AL', 'Cuti Tahunan');
  insert into public.projects (org_id, code, name) values (r.org, 'P-1', 'Projek Rahsia');

  insert into public.access_types (org_id, name)
  values (r.org, 'Projects, read only') returning id into v_type;
  update public.org_members set access_type_id = v_type
   where org_id = r.org and user_id = r.storekeeper;

  insert into t_ro select r.*;
end $$;

create or replace function pg_temp.records(p_org uuid) returns text
language sql as $$
  select (select count(*) from public.accounts where org_id = p_org) || ' accounts / '
      || (select count(*) from public.projects where org_id = p_org) || ' project / '
      || (select count(*) from public.access_types where org_id = p_org) || ' access type / '
      || (select count(*) from public.org_members where org_id = p_org) || ' members';
$$;

-- What the company holds, counted as its owner sees it.
do $$
declare d t_ro;
begin
  select * into d from t_ro;
  perform pg_temp.check_true('the premise: the company has accounts, a project, an access type and four members',
    (select count(*) from public.accounts where org_id = d.org) > 0
    and (select count(*) from public.projects where org_id = d.org) = 1
    and (select count(*) from public.access_types where org_id = d.org) = 1
    and (select count(*) from public.org_members where org_id = d.org) = 4);
end $$;

create temporary table t_seen (who text, seen text);
grant all on t_seen to authenticated;
insert into t_seen select 'owner', pg_temp.records((select org from t_ro));

-- ---------------------------------------------------------------------
-- The employee: her own, and the frame
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select staff from t_ro));
set local role authenticated;

do $$
declare d t_ro;
begin
  select * into d from t_ro;
  perform pg_temp.check_eq('an employee reads none of the company''s records, and herself on the member list',
    pg_temp.records(d.org), '0 accounts / 0 project / 0 access type / 1 members');
  perform pg_temp.check_eq('and the member she reads is her',
    (select string_agg(role::text, ',') from public.org_members
      where org_id = d.org and user_id = d.staff), 'employee');
  perform pg_temp.check_eq('she still reads her company, its departments and its leave types',
    (select count(*) from public.organizations where id = d.org) || ' / '
      || (select count(*) from public.departments where org_id = d.org) || ' / '
      || (select count(*) from public.leave_types where org_id = d.org),
    '1 / 1 / 1');
  -- Where she is a View Only member, she is one.
  insert into t_seen select 'staff elsewhere', pg_temp.records(d.other);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('somewhere she is more than an employee, she reads what that role reads',
    (select seen from t_seen where who = 'staff elsewhere') not like '0 accounts%');
end $$;

-- ---------------------------------------------------------------------
-- Nobody else changes
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select viewer from t_ro));
set local role authenticated;
insert into t_seen select 'viewer', pg_temp.records((select org from t_ro));
reset role;

select pg_temp.sign_in_as((select storekeeper from t_ro));
set local role authenticated;
insert into t_seen select 'storekeeper', pg_temp.records((select org from t_ro));
reset role;

do $$
begin
  perform pg_temp.check_eq('a View Only member reads all of it, as the owner does',
    (select seen from t_seen where who = 'viewer'),
    (select seen from t_seen where who = 'owner'));
  perform pg_temp.check_eq('and so does an employee the company has given an access type',
    (select seen from t_seen where who = 'storekeeper'),
    (select seen from t_seen where who = 'owner'));
end $$;

-- ---------------------------------------------------------------------
-- Every table any member may read is on one side of the line
-- ---------------------------------------------------------------------
-- A table whose read policy admits any member and which no restrictive
-- read policy narrows -- a module gate, a ledger gate, `0872`'s own --
-- has to be one an employee may read, and named here. A new table that
-- is neither fails this until somebody decides.
do $$
declare
  v_self_service text[] := array[
    -- The company, and what the app needs to know about it.
    'organizations', 'org_modules', 'org_login_pages', 'module_promotions',
    'live_changes',
    -- What self-service is filed against.
    'branches', 'departments', 'positions', 'work_shifts',
    'public_holidays', 'leave_types', 'leave_entitlement_bands',
    'claim_types', 'claim_approval_settings', 'appraisal_cycles',
    'onboarding_templates', 'onboarding_template_items',
    'custom_fields_def', 'fiscal_years', 'fiscal_periods',
    'exchange_rates', 'tax_codes',
    -- Hers by their own policies.
    'notifications', 'todos', 'ai_conversations', 'ai_messages',
    'chat_links', 'firms',
    -- Read through a parent shut by `0872`.
    'payment_batches', 'access_type_modules'];
begin
  perform pg_temp.check_eq('every table any member may read is gated or on the self-service list',
    coalesce((
      select string_agg(c.relname, ', ' order by c.relname)
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
       where exists (select 1 from pg_policy p
                      where p.polrelid = c.oid and p.polpermissive
                        and p.polcmd in ('r', '*')
                        and pg_get_expr(p.polqual, p.polrelid) ~ 'is_org_member\(')
         and not exists (select 1 from pg_policy p
                          where p.polrelid = c.oid and not p.polpermissive
                            and p.polcmd in ('r', '*'))
         and c.relname <> all (v_self_service)), 'none'),
    'none');
  perform pg_temp.check_eq('and nothing on the list is gated as well, which would make the list a lie',
    coalesce((
      select string_agg(c.relname, ', ' order by c.relname)
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
       where c.relname = any (v_self_service)
         and exists (select 1 from pg_policy p
                      where p.polrelid = c.oid and p.polname = 'staff_records_select')), 'none'),
    'none');
end $$;

rollback;

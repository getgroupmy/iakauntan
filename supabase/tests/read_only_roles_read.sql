-- =====================================================================
-- iAkauntan :: read-only roles read (0882)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/read_only_roles_read.sql
--
-- `module_access` answered every member with no access type `write` on
-- every module, so a View Only member and an auditor wrote through the
-- definers that ask `can_write_module` and nothing else. Read-only roles
-- read now, and the HR Manager writes HR's two modules. Asked with the
-- role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ro (org uuid, viewer uuid, auditor uuid, hr uuid,
  clerk uuid, accountant uuid, typed_viewer uuid);
grant select on t_ro to authenticated;
create temporary table t_access (who text, answer text);
grant all on t_access to authenticated;

-- What module_access answers the signed-in member, module by module.
create or replace function pg_temp.answers(p_org uuid) returns text
language sql as $$
  select string_agg(m || ':' || app.module_access(p_org, m)::text, ' '
                    order by m)
    from unnest(array['hr', 'payroll', 'pos', 'sales', 'ticketing']) m;
$$;

do $$
declare r t_ro; v_type uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Baca Sahaja Sdn Bhd');
  r.viewer       := pg_temp.another_user('lihat@bacasahaja.test');
  r.auditor      := pg_temp.another_user('audit@bacasahaja.test');
  r.hr           := pg_temp.another_user('hr@bacasahaja.test');
  r.clerk        := pg_temp.another_user('kerani@bacasahaja.test');
  r.accountant   := pg_temp.another_user('akauntan@bacasahaja.test');
  r.typed_viewer := pg_temp.another_user('lihat2@bacasahaja.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.viewer, 'viewer', 'active'),
         (r.org, r.auditor, 'auditor', 'active'),
         (r.org, r.hr, 'hr_manager', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.accountant, 'accountant', 'active'),
         (r.org, r.typed_viewer, 'viewer', 'active');

  -- A View Only member the company has given the helpdesk.
  insert into public.access_types (org_id, name)
  values (r.org, 'Helpdesk') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'ticketing', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = r.org and user_id = r.typed_viewer;

  insert into t_ro select r.*;
end $$;

-- ---------------------------------------------------------------------
-- What each role is answered
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select viewer from t_ro));
set local role authenticated;
insert into t_access select 'viewer', pg_temp.answers((select org from t_ro));
reset role;

select pg_temp.sign_in_as((select auditor from t_ro));
set local role authenticated;
insert into t_access select 'auditor', pg_temp.answers((select org from t_ro));
reset role;

select pg_temp.sign_in_as((select hr from t_ro));
set local role authenticated;
insert into t_access select 'hr_manager', pg_temp.answers((select org from t_ro));
reset role;

select pg_temp.sign_in_as((select clerk from t_ro));
set local role authenticated;
insert into t_access select 'clerk', pg_temp.answers((select org from t_ro));
reset role;

select pg_temp.sign_in_as((select accountant from t_ro));
set local role authenticated;
insert into t_access select 'accountant', pg_temp.answers((select org from t_ro));
reset role;

do $$
begin
  perform pg_temp.check_eq('a View Only member is answered read on every module',
    (select answer from t_access where who = 'viewer'),
    'hr:read payroll:read pos:read sales:read ticketing:read');
  perform pg_temp.check_eq('and so is an auditor',
    (select answer from t_access where who = 'auditor'),
    'hr:read payroll:read pos:read sales:read ticketing:read');
  perform pg_temp.check_eq('the HR Manager writes HR''s two and reads the rest',
    (select answer from t_access where who = 'hr_manager'),
    'hr:write payroll:write pos:read sales:read ticketing:read');
  perform pg_temp.check_eq('a clerk writes, as before',
    (select answer from t_access where who = 'clerk'),
    'hr:write payroll:write pos:write sales:write ticketing:write');
  perform pg_temp.check_eq('and so does an accountant',
    (select answer from t_access where who = 'accountant'),
    'hr:write payroll:write pos:write sales:write ticketing:write');
end $$;

-- ---------------------------------------------------------------------
-- Through a definer that asks only can_write_module
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select viewer from t_ro));
set local role authenticated;
do $$
begin
  perform pg_temp.check_refused('a View Only member raises no ticket',
    format('select public.create_ticket(%L, %L)', (select org from t_ro), 'Dari penonton'),
    'Insufficient privileges to raise a ticket', '42501');
end $$;
reset role;

select pg_temp.sign_in_as((select auditor from t_ro));
set local role authenticated;
do $$
begin
  perform pg_temp.check_refused('nor does an auditor',
    format('select public.create_ticket(%L, %L)', (select org from t_ro), 'Dari juruaudit'),
    'Insufficient privileges to raise a ticket', '42501');
end $$;
reset role;

select pg_temp.sign_in_as((select hr from t_ro));
set local role authenticated;
do $$
declare d t_ro;
begin
  select * into d from t_ro;
  perform pg_temp.check_refused('nor the HR Manager, outside HR',
    format('select public.create_ticket(%L, %L)', d.org, 'Dari HR'),
    'Insufficient privileges to raise a ticket', '42501');
  -- Through `employees`' own module gate, which asks can_write_module.
  insert into public.employees (org_id, employee_no, full_name, hire_date)
  values (d.org, 'E-HR', 'Pekerja Baru', pg_temp.today());
  perform pg_temp.check_eq('who still adds an employee',
    (select count(*) from public.employees where org_id = d.org and employee_no = 'E-HR')::int, 1);
end $$;
reset role;

select pg_temp.sign_in_as((select accountant from t_ro));
set local role authenticated;
do $$
begin
  perform pg_temp.check_true('an accountant raises a ticket, as before',
    public.create_ticket((select org from t_ro), 'Dari akauntan') is not null);
end $$;
reset role;

select pg_temp.sign_in_as((select typed_viewer from t_ro));
set local role authenticated;
do $$
begin
  perform pg_temp.check_true('a View Only member given the helpdesk by an access type raises one',
    public.create_ticket((select org from t_ro), 'Dari meja bantuan') is not null);
end $$;
reset role;

-- And reading is as it was.
select pg_temp.sign_in_as((select viewer from t_ro));
set local role authenticated;
do $$
begin
  perform pg_temp.check_eq('the View Only member still reads both tickets',
    (select count(*) from public.tickets where org_id = (select org from t_ro))::int, 2);
end $$;
reset role;

rollback;

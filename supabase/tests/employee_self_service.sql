-- =====================================================================
-- iAkauntan :: an employee is self-service (0871)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/employee_self_service.sql
--
-- The `employee` role was "self-service only" in every place it was
-- described and nowhere it was enforced: `module_access` answered
-- `write` for every module to a member with no access type, and an
-- employee read every customer and every item's cost. She keeps HR --
-- her own record, leave and claims -- and payroll to read her payslips,
-- and nothing else unless an access type says so. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ss (org uuid, staff uuid, viewer uuid,
  storekeeper uuid, staff_emp uuid);
grant select on t_ss to authenticated;

do $$
declare r t_ss; v_type uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Swalayan Kakitangan Sdn Bhd',
                            array['hr', 'payroll', 'inventory']);
  r.staff       := pg_temp.another_user('staf@swalayan.test');
  r.viewer      := pg_temp.another_user('lihat@swalayan.test');
  r.storekeeper := pg_temp.another_user('stor@swalayan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.staff, 'employee', 'active'),
         (r.org, r.viewer, 'viewer', 'active'),
         (r.org, r.storekeeper, 'employee', 'active');

  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E1', 'Staf Biasa', r.staff, pg_temp.today())
  returning id into r.staff_emp;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E2', 'Penjaga Stor', r.storekeeper, pg_temp.today());

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan Besar', 'customer');
  insert into public.items (org_id, code, name, cost_price)
  values (r.org, 'I-1', 'Barang', 40);

  -- The storekeeper is an employee the company has given more: the
  -- stock list, to read.
  insert into public.access_types (org_id, name)
  values (r.org, 'Stock, read only') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'inventory', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = r.org and user_id = r.storekeeper;

  insert into t_ss select r.*;
end $$;

create or replace function pg_temp.access_to(p_org uuid, p_modules text[])
returns text language sql as $$
  select string_agg(m || ' ' || app.module_access(p_org, m)::text, ', ' order by o)
    from unnest(p_modules) with ordinality as x(m, o);
$$;

-- ---------------------------------------------------------------------
-- The employee: HR and her payslips, and nothing else
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select staff from t_ss));
set local role authenticated;

do $$
declare d t_ss;
begin
  select * into d from t_ss;
  perform pg_temp.check_eq('an employee writes in HR, reads payroll, and has no other module',
    pg_temp.access_to(d.org, array['hr', 'payroll', 'sales', 'contacts',
                                   'accounting', 'inventory', 'purchases']),
    'hr write, payroll read, sales none, contacts none, accounting none, '
    || 'inventory none, purchases none');
  perform pg_temp.check_eq('and the menus the app draws from it say the same',
    (select string_agg(module_code || ' ' || access, ', ' order by module_code)
       from public.my_module_access(d.org) where access <> 'none'),
    'hr write, payroll read');
  perform pg_temp.check_eq('she reads no customer and no item, nor its cost',
    (select count(*) from public.contacts where org_id = d.org) || ' / '
      || (select count(*) from public.items where org_id = d.org),
    '0 / 0');
  perform pg_temp.check_eq('she reads her own record',
    (select string_agg(employee_no, ',') from public.employees where org_id = d.org),
    'E1');

  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, total_amount)
  values (d.org, 'CLM-SS-1', d.staff_emp, pg_temp.today(), 'Parking', 12.00);
  perform pg_temp.check_eq('and files a claim of her own',
    (select count(*) from public.expense_claims
      where org_id = d.org and employee_id = d.staff_emp)::int, 1);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Nobody else changes
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select viewer from t_ss));
set local role authenticated;

do $$
declare d t_ss;
begin
  select * into d from t_ss;
  perform pg_temp.check_eq('a View Only member still reads the day-to-day records',
    (select count(*) from public.contacts where org_id = d.org) || ' / '
      || (select count(*) from public.items where org_id = d.org),
    '1 / 1');
end $$;

reset role;

select pg_temp.sign_in_as((select storekeeper from t_ss));
set local role authenticated;

do $$
declare d t_ss;
begin
  select * into d from t_ss;
  perform pg_temp.check_eq('an employee given an access type has what it gives, and only that',
    pg_temp.access_to(d.org, array['inventory', 'hr', 'sales']),
    'inventory read, hr none, sales none');
  perform pg_temp.check_eq('so the storekeeper reads the stock list',
    (select count(*) from public.items where org_id = d.org)::int, 1);
end $$;

reset role;

-- A module the company does not hold is nobody's, the employee's
-- included: that is still asked first.
update public.org_modules set is_enabled = false
 where org_id = (select org from t_ss) and module_code = 'payroll';

select pg_temp.sign_in_as((select staff from t_ss));
set local role authenticated;

do $$
declare d t_ss;
begin
  select * into d from t_ss;
  perform pg_temp.check_eq('with payroll switched off she has HR alone',
    pg_temp.access_to(d.org, array['hr', 'payroll']),
    'hr write, payroll none');
end $$;

reset role;

rollback;

-- =====================================================================
-- iAkauntan :: 0044 hrms harden
-- Applied as project migration 20260810060247.
-- =====================================================================

-- 1. The directory becomes a security definer *function* rather than a
-- view. Same effect, but the membership check is explicit and it stops
-- tripping the linter's definer-view rule, which exists because such a
-- view silently ignores the caller's RLS.
drop view if exists public.v_employee_directory;

create or replace function public.employee_directory(p_org_id uuid)
returns table (
  id uuid,
  employee_no text,
  full_name text,
  preferred_name text,
  email citext,
  phone text,
  photo_url text,
  employment_status app.employment_status,
  department_id uuid,
  department_name text,
  position_id uuid,
  position_title text,
  manager_id uuid,
  manager_name text,
  hire_date date
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select e.id, e.employee_no, e.full_name, e.preferred_name, e.email,
         e.phone, e.photo_url, e.employment_status,
         e.department_id, d.name, e.position_id, p.title,
         e.manager_id, m.full_name, e.hire_date
    from public.employees e
    left join public.departments d on d.id = e.department_id
    left join public.positions p on p.id = e.position_id
    left join public.employees m on m.id = e.manager_id
   where e.org_id = p_org_id
     and app.is_org_member(p_org_id)
   order by e.full_name;
$$;

comment on function public.employee_directory is
  'Who works here: name, department, role and contact. Deliberately excludes salary, identifiers and everything else on the employee row.';

-- 2. Restore the pinned search_path lost when the prefix helper was
-- recreated to add the HR document types.
create or replace function app.default_doc_prefix(p_doc_type text)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'matter'               then 'MAT-'
    when 'client_transaction'   then 'CLI-'
    when 'employee'             then 'EMP-'
    when 'payroll_run'          then 'PYR-'
    when 'leave_request'        then 'LV-'
    when 'expense_claim'        then 'CLM-'
    when 'job_requisition'      then 'JR-'
    else 'DOC-'
  end;
$$;

-- 3. Functions created since the last hardening pass inherit PUBLIC
-- execute, which hands them to the anon role. Same idempotent sweep as
-- migration 0023.
do $do$
declare
  fn record;
begin
  for fn in
    select n.nspname as schema_name,
           p.proname as func_name,
           pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon',
                   fn.schema_name, fn.func_name, fn.args);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role',
                   fn.schema_name, fn.func_name, fn.args);
  end loop;
end
$do$;

-- =====================================================================
-- iAkauntan :: 0032 hrms payroll accounts
-- Applied as project migration 20260810054955.
-- =====================================================================

-- Payroll needs a few accounts the original chart did not carry.
-- Backfilled for existing tenants so posting never has to invent an
-- account at run time.
do $do$
declare
  v_org record;
  v_parent uuid;
begin
  for v_org in select id from public.organizations loop
    select id into v_parent from public.accounts
     where org_id = v_org.id and code = '2100';
    if v_parent is not null then
      insert into public.accounts
        (org_id, code, name, account_type, account_subtype, is_group,
         parent_id, sort_order)
      select v_org.id, v.code, v.name, 'liability'::app.account_type,
             'current_liability'::app.account_subtype, false, v_parent, v.ord
        from (values
          ('2145', 'Salaries Payable', 2145),
          ('2185', 'Zakat Payable', 2185),
          ('2195', 'HRD Corp Levy Payable', 2195)
        ) as v(code, name, ord)
       where not exists (
         select 1 from public.accounts a
          where a.org_id = v_org.id and a.code = v.code);
    end if;

    select id into v_parent from public.accounts
     where org_id = v_org.id and code = '6000';
    if v_parent is not null then
      insert into public.accounts
        (org_id, code, name, account_type, account_subtype, is_group,
         parent_id, sort_order)
      select v_org.id, '6150', 'HRD Corp Levy', 'expense'::app.account_type,
             'payroll_expense'::app.account_subtype, false, v_parent, 6150
       where not exists (
         select 1 from public.accounts a
          where a.org_id = v_org.id and a.code = '6150');
    end if;
  end loop;
end
$do$;

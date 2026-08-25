-- The demo tenants can show an attachment.
--
-- `0323` made attachments a module and granted it to nobody, which was
-- the instruction and is right for customers: the point of a module is
-- that somebody chooses it. The demo tenants are not customers. They
-- exist so a visitor can see what the product does, and a demonstration
-- with the paperwork missing from every bill misrepresents what is for
-- sale.
--
-- `demo_rebuild.sql` already asserts this and caught it: "no active
-- module is left without a demo tenant to show it in", expected 0, got
-- 1. The assertion was right and `0323` was incomplete.
--
-- ## Why not by data, like every other module here
--
-- `app.demo_modules_in_use` switches a module on for a demo tenant that
-- has rows for it — a till because there are outlets, HR because there
-- are employees. Attachments have no domain of their own to detect:
-- they hang off bills and claims and employees that are already there,
-- and a seed that has not happened to upload a file yet would leave the
-- module off and the demo silent about it.
--
-- So this one is granted to every demo tenant outright. It is the only
-- module in the list that is about a capability rather than a subject,
-- and that is the difference the code should say out loud rather than
-- pretend away by inventing a table to count.

update public.org_modules om
   set is_enabled = true, expires_at = null
  from public.organizations o
 where o.id = om.org_id and o.is_demo
   and om.module_code = 'attachments'
   and not om.is_enabled;

insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
select o.id, 'attachments', true, now(),
       'Enabled by 0324: a demo tenant shows every module, and '
       'attachments hang off records rather than having rows of their own.'
  from public.organizations o
 where o.is_demo
   and not exists (
     select 1 from public.org_modules om
      where om.org_id = o.id and om.module_code = 'attachments')
on conflict (org_id, module_code) do update
  set is_enabled = true, expires_at = null;

-- ---------------------------------------------------------------------
-- And a rebuild keeps it
--
-- `app.demo_rebuild` drops the demo tenants and makes them again, so a
-- one-off update above would last until the next rebuild and then
-- silently stop being true. Recreated in full rather than patched:
-- reading forty lines beats finding one changed word in a text
-- substitution, which is the objection this repository has to
-- restatement everywhere it can be avoided and the reason to accept it
-- here.
-- ---------------------------------------------------------------------
create or replace function app.demo_modules_in_use()
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
        union all
        -- 0324. Not detected from rows, unlike every line above it.
        -- Attachments hang off records that already exist rather than
        -- having a subject of their own, so a tenant that happens not
        -- to have uploaded a file yet would show nothing about a
        -- feature it can perfectly well demonstrate.
        select id, 'attachments' from public.organizations where is_demo
      ) x
      join public.organizations g on g.id = x.org_id and g.is_demo
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled)
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by app.demo_modules_in_use: the tenant has data for it.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function app.demo_modules_in_use() from public, anon, authenticated;

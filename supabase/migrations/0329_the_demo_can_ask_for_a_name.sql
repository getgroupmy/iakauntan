-- The demo tenants hold the two name modules, so the demo shows them.
--
-- `demo_rebuild.sql` asserts that no active module is left without a
-- demo tenant to show it in, and `0327` and `0328` added two. That
-- assertion is not bookkeeping: a module nobody can see in the demo is
-- a module a prospect is told about and cannot look at, which is the
-- same as not having built it.
--
-- ## Granted outright, like attachments and unlike everything else
--
-- `app.demo_modules_in_use` switches a module on for a tenant that has
-- rows for it — a till because there are outlets, HR because there are
-- employees. Neither of these has rows to detect: a company has a
-- subdomain only once somebody has asked for one and an operator has
-- agreed, and mail only once somebody has written to it. A demo tenant
-- rebuilt this morning has neither and never will by itself.
--
-- So both are granted to every demo tenant outright, and the demo shows
-- the thing there actually is to show: the form where a company asks
-- for a name, and an inbox waiting for its first message.
--
-- ## No name is reserved here, deliberately
--
-- Seeding `sinar.iakauntan.com` as approved would make the demo tenant
-- a real occupant of a namespace with exactly one of everything in it —
-- and `app.demo_rebuild` drops these tenants and makes them again, so
-- the name would be released and re-taken on a schedule. A demo that
-- shows the request being made is a better demo than one that shows a
-- door already open, and it costs the platform nothing.

update public.org_modules om
   set is_enabled = true, expires_at = null
  from public.organizations o
 where o.id = om.org_id and o.is_demo
   and om.module_code in ('workspace_address', 'mailbox')
   and not om.is_enabled;

insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
select o.id, m.code, true, now(),
       'Enabled by 0329: a demo tenant shows every module, and a name '
       'on our domain has no rows to be detected from.'
  from public.organizations o
 cross join (values ('workspace_address'), ('mailbox')) as m(code)
 where o.is_demo
   and not exists (
     select 1 from public.org_modules om
      where om.org_id = o.id and om.module_code = m.code)
on conflict (org_id, module_code) do update
  set is_enabled = true, expires_at = null;

-- ---------------------------------------------------------------------
-- And a rebuild keeps them
-- ---------------------------------------------------------------------
-- `app.demo_rebuild` drops the demo tenants and makes them again, so a
-- grant written above is gone by tomorrow unless the function that
-- decides what a rebuilt tenant holds knows about it too.
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
        union all
        -- 0329, and for the same reason twice over. A name on our
        -- domain exists only once somebody has asked for one and an
        -- operator has agreed; mail arrives only once somebody has
        -- written to the address. A tenant rebuilt this morning has
        -- neither and never will by itself.
        select id, 'workspace_address'
          from public.organizations where is_demo
        union all
        select id, 'mailbox' from public.organizations where is_demo
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


-- `0165`'s event trigger strips grants from anything recreated in
-- `app`, so this is re-granted exactly as `0324` left it: to nobody but
-- the roles that run the rebuild.
revoke all on function app.demo_modules_in_use() from public, anon, authenticated;

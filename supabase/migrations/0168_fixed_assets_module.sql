-- Sell the fixed asset register that already exists.
--
-- The register is not new. `fixed_assets`, `depreciation_runs` and
-- `depreciation_entries` have been here since the assets work, with
-- straight-line and reducing-balance depreciation, disposal that charges
-- the catch-up and posts the gain or loss to its own account (`0156`),
-- and the schedule an auditor asks for (`report_depreciation_history`,
-- `report_asset_movements`).
--
-- What it never had was an entitlement. Its policies are `can_write` and
-- `is_org_member` with no `has_module` anywhere, so every tenant has had
-- it switched on since the day it shipped, whether they asked or not.
-- This gives it a catalog row and the same two gates every other paid
-- add-on carries.
--
-- **Every existing tenant keeps it.** The insert at the bottom grants
-- the entitlement to every organization already on the deployment, so
-- this migration takes nothing away from anybody; it only means the
-- *next* tenant has to ask.

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('fixed_assets', 'Fixed Assets',
   'Asset register, straight-line and reducing-balance depreciation, '
   'disposal with gain or loss, and the movement schedule an auditor asks '
   'for',
   false, 39, 15)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- The two gates
--
-- Reads stay open on the permissive policy — switching an add-on off
-- stops new records without hiding a tenant's own history, which is how
-- every other module here behaves and matters more for assets than for
-- most: the register is evidence for a set of accounts already filed.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array[
    'fixed_assets', 'depreciation_runs', 'depreciation_entries'
  ] loop
    execute format('drop policy if exists %I on public.%I',
                   v_table || '_insert', v_table);
    execute format('drop policy if exists %I on public.%I',
                   v_table || '_update', v_table);
    execute format('drop policy if exists %I on public.%I',
                   v_table || '_delete', v_table);
    execute format('drop policy if exists %I on public.%I',
                   v_table || '_write', v_table);

    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (app.can_write(org_id)
                     and app.has_module(org_id, ''fixed_assets''))',
      v_table || '_insert', v_table);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (app.can_write(org_id)
                and app.has_module(org_id, ''fixed_assets''))
         with check (app.can_write(org_id)
                     and app.has_module(org_id, ''fixed_assets''))',
      v_table || '_update', v_table);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (app.can_admin(org_id)
                and app.has_module(org_id, ''fixed_assets''))',
      v_table || '_delete', v_table);

    -- The access-type layer from 0127, so a company can keep a member
    -- out of the asset register without taking it off the company.
    execute format(
      'create policy module_gate_select on public.%I
         as restrictive for select to authenticated
         using (app.can_read_module(org_id, ''fixed_assets''))', v_table);
    execute format(
      'create policy module_gate_insert on public.%I
         as restrictive for insert to authenticated
         with check (app.can_write_module(org_id, ''fixed_assets''))', v_table);
    execute format(
      'create policy module_gate_update on public.%I
         as restrictive for update to authenticated
         using (app.can_write_module(org_id, ''fixed_assets''))
         with check (app.can_write_module(org_id, ''fixed_assets''))', v_table);
    execute format(
      'create policy module_gate_delete on public.%I
         as restrictive for delete to authenticated
         using (app.can_write_module(org_id, ''fixed_assets''))', v_table);
  end loop;
end $$;

-- Nobody loses a register they are already using.
insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
select o.id, 'fixed_assets', true, now()
  from public.organizations o
on conflict (org_id, module_code) do nothing;

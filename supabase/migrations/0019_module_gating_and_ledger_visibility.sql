-- =====================================================================
-- iAkauntan :: 0019 module gating and ledger visibility
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ledger and audit trail: readable by finance roles and auditors only.
-- Sales and purchasing staff have no business reading the journals.
-- ---------------------------------------------------------------------
do $do$
declare t text;
begin
  foreach t in array array['gl_entries', 'gl_lines'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.can_read_ledger(org_id))', t || '_select', t);
  end loop;
end
$do$;

drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select to authenticated using (app.can_read_ledger(org_id));

drop policy if exists einvoice_logs_select on public.einvoice_logs;
create policy einvoice_logs_select on public.einvoice_logs
  for select to authenticated using (app.can_read_ledger(org_id));

-- ---------------------------------------------------------------------
-- Module entitlement, enforced on writes.
--
-- Reads stay open so switching an add-on off never hides a tenant's own
-- history; it only stops them creating more.
-- ---------------------------------------------------------------------
do $do$
declare
  gated constant jsonb := jsonb_build_object(
    'purchases', jsonb_build_array(
      'purchase_documents', 'purchase_document_lines', 'purchase_payments'),
    'inventory', jsonb_build_array(
      'stock_movements', 'stock_levels', 'stock_adjustments',
      'stock_adjustment_lines'),
    'crm', jsonb_build_array(
      'leads', 'pipelines', 'pipeline_stages', 'opportunities',
      'opportunity_stage_history', 'activities'),
    'einvoice', jsonb_build_array(
      'einvoice_documents', 'einvoice_lines', 'einvoice_submissions',
      'einvoice_consolidations', 'einvoice_consolidation_items')
  );
  module_code text;
  tbl text;
  write_fn text;
  post_tables constant text[] := array[
    'einvoice_submissions', 'einvoice_consolidations',
    'einvoice_consolidation_items'];
begin
  for module_code in select jsonb_object_keys(gated) loop
    for tbl in
      select jsonb_array_elements_text(gated -> module_code)
    loop
      write_fn := case when tbl = any (post_tables)
                       then 'app.can_post' else 'app.can_write' end;

      execute format('drop policy if exists %I on public.%I', tbl || '_insert', tbl);
      execute format('drop policy if exists %I on public.%I', tbl || '_update', tbl);
      execute format('drop policy if exists %I on public.%I', tbl || '_delete', tbl);

      execute format(
        'create policy %I on public.%I for insert to authenticated
           with check (%s(org_id) and app.has_module(org_id, %L))',
        tbl || '_insert', tbl, write_fn, module_code);

      execute format(
        'create policy %I on public.%I for update to authenticated
           using (%s(org_id) and app.has_module(org_id, %L))
           with check (%s(org_id) and app.has_module(org_id, %L))',
        tbl || '_update', tbl, write_fn, module_code, write_fn, module_code);

      execute format(
        'create policy %I on public.%I for delete to authenticated
           using (%s(org_id) and app.has_module(org_id, %L))',
        tbl || '_delete', tbl, write_fn, module_code);
    end loop;
  end loop;
end
$do$;

-- New tenants start with the add-ons their plan includes.
create or replace function app.seed_org_modules(p_org_id uuid)
returns void language sql security definer
set search_path = public, pg_temp as $$
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  select p_org_id, m.code, m.code in ('einvoice', 'purchases', 'inventory', 'crm'), now()
    from public.platform_modules m
   where not m.is_core
  on conflict do nothing;
$$;

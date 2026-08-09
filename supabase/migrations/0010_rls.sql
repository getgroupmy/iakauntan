-- =====================================================================
-- iAkauntan :: 0010 row level security
--
-- Every tenant table follows the same shape:
--   read   -> any active member of the org
--   write  -> depends on the table's sensitivity tier
-- so the policies are generated rather than hand written.
--
-- The helper functions are SECURITY DEFINER, which is what stops the
-- org_members policies from recursing into themselves.
-- =====================================================================

grant usage on schema app to authenticated, anon, service_role;

-- ---------------------------------------------------------------------
-- Generated policies
-- ---------------------------------------------------------------------
do $do$
declare
  t         text;
  write_fn  text;

  -- Global code lists: readable by any signed-in user, written by the
  -- service role only (which bypasses RLS entirely).
  ref_tables text[] := array[
    'ref_countries', 'ref_states', 'ref_msic_codes', 'ref_classification_codes',
    'ref_uom_codes', 'ref_currencies', 'ref_tax_types', 'ref_einvoice_types',
    'ref_payment_modes', 'ref_exemption_reasons'
  ];

  -- Ledger and setup tables: only owner/admin/accountant may change them.
  post_tables text[] := array[
    'gl_entries', 'gl_lines', 'recurring_journals', 'fiscal_years', 'fiscal_periods',
    'accounts', 'tax_codes', 'bank_accounts', 'bank_transactions',
    'bank_reconciliations', 'einvoice_submissions', 'einvoice_consolidations',
    'einvoice_consolidation_items'
  ];

  -- Structural tables: owner/admin only.
  admin_tables text[] := array['number_sequences'];

  tenant_tables text[] := array[
    'fiscal_years', 'fiscal_periods', 'accounts', 'tax_codes', 'payment_terms',
    'contacts', 'contact_addresses', 'contact_persons', 'warehouses',
    'item_categories', 'items', 'price_levels', 'item_prices', 'bank_accounts',
    'gl_entries', 'gl_lines', 'recurring_journals',
    'sales_documents', 'sales_document_lines', 'receipts', 'payment_allocations',
    'purchase_documents', 'purchase_document_lines', 'purchase_payments',
    'stock_movements', 'stock_levels', 'stock_adjustments', 'stock_adjustment_lines',
    'bank_transactions', 'bank_reconciliations', 'expenses',
    'einvoice_documents', 'einvoice_lines', 'einvoice_submissions',
    'einvoice_consolidations', 'einvoice_consolidation_items',
    'leads', 'pipelines', 'pipeline_stages', 'opportunities',
    'opportunity_stage_history', 'activities', 'notes', 'attachments',
    'number_sequences'
  ];
begin
  foreach t in array ref_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_read', t);
  end loop;

  foreach t in array tenant_tables loop
    execute format('alter table public.%I enable row level security', t);

    write_fn := case
      when t = any (admin_tables) then 'app.can_admin'
      when t = any (post_tables)  then 'app.can_post'
      else 'app.can_write'
    end;

    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (%s(org_id))', t || '_insert', t, write_fn);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (%s(org_id)) with check (%s(org_id))', t || '_update', t, write_fn, write_fn);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (%s(org_id))', t || '_delete', t, write_fn);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------
-- Tables whose org_id is nullable (null = shared across all tenants)
-- ---------------------------------------------------------------------
do $do$
declare t text;
begin
  foreach t in array array['exchange_rates', 'tin_validations'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (org_id is null or app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (org_id is not null and app.can_write(org_id))', t || '_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (app.can_write(org_id)) with check (app.can_write(org_id))', t || '_update', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (app.can_write(org_id))', t || '_delete', t);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------
-- Append-only audit trails: readable by admins, written by the backend
-- ---------------------------------------------------------------------
alter table public.audit_logs enable row level security;
create policy audit_logs_select on public.audit_logs
  for select to authenticated using (app.can_admin(org_id));

alter table public.einvoice_logs enable row level security;
create policy einvoice_logs_select on public.einvoice_logs
  for select to authenticated using (app.is_org_member(org_id));

-- ---------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------
create or replace function app.shares_org_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.org_members mine
      join public.org_members theirs on theirs.org_id = mine.org_id
     where mine.user_id = auth.uid()
       and mine.status = 'active'
       and theirs.user_id = p_user_id
       and theirs.status = 'active'
  );
$$;

alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or app.shares_org_with(id));

create policy profiles_insert on public.profiles
  for insert to authenticated with check (id = auth.uid());

create policy profiles_update on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------
-- Organizations
--
-- Any signed-in user may create one; the trigger below immediately makes
-- them its owner, so the org is never left without a member.
-- ---------------------------------------------------------------------
alter table public.organizations enable row level security;

create policy organizations_select on public.organizations
  for select to authenticated using (app.is_org_member(id));

create policy organizations_insert on public.organizations
  for insert to authenticated with check (created_by = auth.uid());

create policy organizations_update on public.organizations
  for update to authenticated
  using (app.can_admin(id)) with check (app.can_admin(id));

create policy organizations_delete on public.organizations
  for delete to authenticated
  using (app.has_org_role(id, array['owner']::app.member_role[]));

create or replace function app.add_creator_as_owner()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (new.id, coalesce(new.created_by, auth.uid()), 'owner', 'active', now())
  on conflict (org_id, user_id) do nothing;
  return new;
end;
$$;

create trigger add_creator_as_owner
  after insert on public.organizations
  for each row execute function app.add_creator_as_owner();

-- ---------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------
alter table public.org_members enable row level security;

create policy org_members_select on public.org_members
  for select to authenticated
  using (user_id = auth.uid() or app.is_org_member(org_id));

create policy org_members_insert on public.org_members
  for insert to authenticated with check (app.can_admin(org_id));

create policy org_members_update on public.org_members
  for update to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

-- An owner cannot be removed; demote them first.
create policy org_members_delete on public.org_members
  for delete to authenticated
  using (app.can_admin(org_id) and role <> 'owner');

-- ---------------------------------------------------------------------
-- Storage bucket for attachments, logos and e-Invoice PDFs
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 26214400)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit)
values ('logos', 'logos', true, 5242880)
on conflict (id) do nothing;

-- Objects are keyed as <org_id>/<entity>/<file>, so the first path
-- segment is the tenant boundary.
create policy attachments_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'attachments'
    and app.is_org_member(nullif(split_part(name, '/', 1), '')::uuid)
  );

create policy attachments_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'attachments'
    and app.can_write(nullif(split_part(name, '/', 1), '')::uuid)
  );

create policy attachments_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'attachments'
    and app.can_write(nullif(split_part(name, '/', 1), '')::uuid)
  );

create policy logos_read on storage.objects
  for select using (bucket_id = 'logos');

create policy logos_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'logos'
    and app.can_admin(nullif(split_part(name, '/', 1), '')::uuid)
  );

-- =====================================================================
-- iAkauntan :: 0020 platform operator console
--
-- These RPCs are the only way platform staff reach across tenants. Each
-- re-checks is_platform_admin(), so SECURITY DEFINER is safe here.
-- =====================================================================

-- Seed add-on entitlements for every new tenant. Done as a trigger so
-- create_organization() stays untouched.
create or replace function app.seed_modules_on_org()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  perform app.seed_org_modules(new.id);
  return new;
end;
$$;

create trigger seed_modules after insert on public.organizations
  for each row execute function app.seed_modules_on_org();

create or replace function public.platform_stats()
returns jsonb language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v jsonb;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'organizations',      (select count(*) from public.organizations where deleted_at is null),
    'organizations_active',(select count(*) from public.organizations where status = 'active' and deleted_at is null),
    'users',              (select count(*) from public.profiles),
    'invoices',           (select count(*) from public.sales_documents
                            where doc_type = 'invoice' and deleted_at is null),
    'invoiced_value',     (select coalesce(sum(base_total_amount), 0)
                             from public.sales_documents
                            where doc_type = 'invoice'
                              and status not in ('draft','void') and deleted_at is null),
    'einvoices_valid',    (select count(*) from public.einvoice_documents where status = 'valid'),
    'einvoices_failed',   (select count(*) from public.einvoice_documents
                            where status in ('invalid','failed')),
    'einvoice_enabled_orgs', (select count(*) from public.organizations where einvoice_enabled),
    'signups_30d',        (select count(*) from public.profiles
                            where created_at > now() - interval '30 days')
  ) into v;
  return v;
end;
$$;

create or replace function public.platform_organizations()
returns table (
  id uuid, name text, slug text, status text, entity_type app.entity_type,
  registration_no text, tin text, einvoice_enabled boolean,
  einvoice_environment text, created_at timestamptz,
  member_count bigint, invoice_count bigint, invoiced_value numeric,
  modules text[])
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;

  return query
    select o.id, o.name, o.slug::text, o.status, o.entity_type,
           o.registration_no, o.tin, o.einvoice_enabled,
           o.einvoice_environment, o.created_at,
           (select count(*) from public.org_members m
             where m.org_id = o.id and m.status = 'active'),
           (select count(*) from public.sales_documents d
             where d.org_id = o.id and d.doc_type = 'invoice' and d.deleted_at is null),
           (select coalesce(sum(d.base_total_amount), 0) from public.sales_documents d
             where d.org_id = o.id and d.doc_type = 'invoice'
               and d.status not in ('draft','void') and d.deleted_at is null),
           (select coalesce(array_agg(om.module_code order by om.module_code), '{}')
              from public.org_modules om
             where om.org_id = o.id and om.is_enabled)
      from public.organizations o
     where o.deleted_at is null
     order by o.created_at desc;
end;
$$;

create or replace function public.platform_set_module(
  p_org_id uuid, p_module_code text, p_enabled boolean)
returns void language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;
  if exists (select 1 from public.platform_modules
              where code = p_module_code and is_core) then
    raise exception 'Core modules cannot be switched off';
  end if;

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, enabled_by)
  values (p_org_id, p_module_code, p_enabled,
          case when p_enabled then now() else null end, auth.uid())
  on conflict (org_id, module_code) do update
    set is_enabled = excluded.is_enabled,
        enabled_at = excluded.enabled_at,
        enabled_by = excluded.enabled_by;
end;
$$;

create or replace function public.platform_set_org_status(
  p_org_id uuid, p_status text)
returns void language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;
  if p_status not in ('active', 'trial', 'suspended', 'archived') then
    raise exception 'Unknown status %', p_status;
  end if;
  update public.organizations set status = p_status where id = p_org_id;
end;
$$;

create or replace function public.platform_update_setting(
  p_key text, p_value jsonb)
returns void language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;
  insert into public.platform_settings (key, value, updated_by, updated_at)
  values (p_key, p_value, auth.uid(), now())
  on conflict (key) do update
    set value = excluded.value, updated_by = excluded.updated_by,
        updated_at = now();
end;
$$;

-- Lets the app decide whether to show the console at all.
create or replace function public.am_i_platform_admin()
returns boolean language sql stable security definer
set search_path = public, app, pg_temp as $$
  select app.is_platform_admin();
$$;

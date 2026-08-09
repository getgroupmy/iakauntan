-- =====================================================================
-- iAkauntan :: 0018 platform tier, module entitlements, permissions
--
-- Introduces a level above tenancy (platform operators), a catalog of
-- sellable modules, and the reworked permission model that adds the
-- accounts clerk and auditor roles.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Super admins: platform staff, not members of any particular tenant.
-- RLS on with no write policy, so membership can only be granted out of
-- band by the service role. A tenant admin can never escalate into it.
-- ---------------------------------------------------------------------
create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  granted_by uuid references auth.users (id),
  note text,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;

comment on table public.platform_admins is
  'Platform operators. Membership is granted out of band (service role) so a tenant admin can never escalate into it.';

create or replace function app.is_platform_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.platform_admins p where p.user_id = auth.uid());
$$;

-- A super admin may read their own row so the app can show the console.
create policy platform_admins_self on public.platform_admins
  for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Platform settings: backend service configuration
-- ---------------------------------------------------------------------
create table public.platform_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  description text,
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;

create policy platform_settings_read on public.platform_settings
  for select to authenticated using (app.is_platform_admin());
create policy platform_settings_write on public.platform_settings
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

insert into public.platform_settings (key, value, description) values
  ('signup_enabled', '{"enabled": true}',
   'Allow new self-service registrations'),
  ('maintenance_mode', '{"enabled": false, "message": ""}',
   'Show a maintenance banner and block writes'),
  ('trial_days', '{"days": 30}', 'Length of the free trial for new tenants'),
  ('einvoice_defaults', '{"environment": "sandbox", "version": "1.0"}',
   'Defaults applied to newly created tenants'),
  ('support', '{"email": "support@iakauntan.my", "phone": ""}',
   'Support contact shown in the app')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- Module catalog and per-tenant entitlements
-- ---------------------------------------------------------------------
create table public.platform_modules (
  code text primary key,
  name text not null,
  description text,
  -- Core modules cannot be switched off; add-ons are sold separately.
  is_core boolean not null default false,
  monthly_price numeric(18, 2) not null default 0,
  sort_order integer not null default 0,
  is_active boolean not null default true
);
alter table public.platform_modules enable row level security;
create policy platform_modules_read on public.platform_modules
  for select to authenticated using (true);

insert into public.platform_modules (code, name, description, is_core, monthly_price, sort_order) values
  ('sales',      'Sales & Invoicing', 'Quotations through invoices and receipts', true, 0, 1),
  ('accounting', 'General Ledger',    'Double-entry books, reports and closing',  true, 0, 2),
  ('contacts',   'Contacts',          'Customers and suppliers',                  true, 0, 3),
  ('einvoice',   'LHDN e-Invoice',    'MyInvois submission and validation',      false, 49, 4),
  ('purchases',  'Purchasing',        'Purchase orders, bills and supplier payments', false, 39, 5),
  ('inventory',  'Inventory',         'Stock levels, costing and stock takes',   false, 39, 6),
  ('crm',        'CRM',               'Leads, pipeline and activities',          false, 29, 7),
  ('legal',      'Legal Firm Accounting',
   'Matters, client account segregation and time recording for law firms', false, 99, 8)
on conflict (code) do nothing;

create table public.org_modules (
  org_id uuid not null references public.organizations (id) on delete cascade,
  module_code text not null references public.platform_modules (code) on delete cascade,
  is_enabled boolean not null default false,
  enabled_at timestamptz,
  enabled_by uuid references auth.users (id),
  expires_at timestamptz,
  notes text,
  primary key (org_id, module_code)
);
alter table public.org_modules enable row level security;

-- Members can see what their org is entitled to; only platform admins
-- may change it, so a tenant cannot grant itself a paid add-on.
create policy org_modules_read on public.org_modules
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());
create policy org_modules_write on public.org_modules
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

create or replace function app.has_module(p_org_id uuid, p_code text)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(
    (select m.is_core from public.platform_modules m where m.code = p_code),
    false)
  or exists (
    select 1 from public.org_modules om
     where om.org_id = p_org_id
       and om.module_code = p_code
       and om.is_enabled
       and (om.expires_at is null or om.expires_at > now()));
$$;

comment on function app.has_module is
  'True when the tenant may use a module. Core modules are always on; add-ons need an entitlement row.';

-- Give every existing tenant the add-ons they are already using, so this
-- migration does not switch off working features.
insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
select o.id, m.code, true, now()
  from public.organizations o
  cross join public.platform_modules m
 where m.code in ('einvoice', 'purchases', 'inventory', 'crm')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Permission tiers, now including accounts clerk and auditor
-- ---------------------------------------------------------------------

-- Owner and company admin: structural changes and membership.
create or replace function app.can_admin(p_org_id uuid)
returns boolean language sql stable as $$
  select app.has_org_role(p_org_id, array['owner','admin']::app.member_role[]);
$$;

-- Anyone trusted to write to the ledger or close a period. An accounts
-- clerk deliberately sits outside this: they prepare, someone else posts.
create or replace function app.can_post(p_org_id uuid)
returns boolean language sql stable as $$
  select app.has_org_role(p_org_id,
    array['owner','admin','accountant']::app.member_role[]);
$$;

-- Anyone who may create or edit operational documents.
create or replace function app.can_write(p_org_id uuid)
returns boolean language sql stable as $$
  select app.has_org_role(p_org_id,
    array['owner','admin','accountant','accounts_clerk','sales','purchaser']::app.member_role[]);
$$;

-- Who may look at the general ledger and audit trail. Auditors get read
-- access to everything; sales and purchasing staff do not.
create or replace function app.can_read_ledger(p_org_id uuid)
returns boolean language sql stable as $$
  select app.has_org_role(p_org_id,
    array['owner','admin','accountant','accounts_clerk','auditor']::app.member_role[]);
$$;

grant execute on function app.is_platform_admin() to authenticated, service_role;
grant execute on function app.has_module(uuid, text) to authenticated, service_role;
grant execute on function app.can_read_ledger(uuid) to authenticated, service_role;

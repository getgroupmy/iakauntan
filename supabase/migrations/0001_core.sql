-- =====================================================================
-- iAkauntan :: 0001 core
-- Tenancy, identity, roles, audit and document numbering primitives.
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "citext";
create extension if not exists "pg_trgm";

create schema if not exists app;

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type app.member_role as enum (
  'owner',        -- full control incl. billing & org deletion
  'admin',        -- full control except billing
  'accountant',   -- full accounting, posting, closing
  'sales',        -- CRM + sales documents, no GL
  'purchaser',    -- purchasing documents
  'viewer'        -- read only
);

create type app.member_status as enum ('invited', 'active', 'suspended');

create type app.doc_status as enum (
  'draft',
  'pending',      -- awaiting approval
  'approved',
  'posted',
  'partial',      -- partially paid / partially delivered
  'completed',
  'void',
  'rejected'
);

-- Malaysian business entity classifications used by LHDN
create type app.entity_type as enum (
  'sdn_bhd', 'bhd', 'enterprise', 'partnership', 'llp',
  'sole_proprietor', 'association', 'government', 'individual', 'other'
);

-- ---------------------------------------------------------------------
-- Profiles (mirrors auth.users)
-- ---------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  full_name     text,
  email         citext,
  phone         text,
  avatar_url    text,
  locale        text not null default 'en-MY',
  timezone      text not null default 'Asia/Kuala_Lumpur',
  last_org_id   uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.profiles is 'Application profile for each auth user.';

-- ---------------------------------------------------------------------
-- Organizations (tenants). One row per company/business entity.
-- ---------------------------------------------------------------------
create table public.organizations (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  legal_name            text,
  slug                  citext not null unique,
  entity_type           app.entity_type not null default 'sdn_bhd',

  -- Malaysian statutory identifiers
  registration_no       text,             -- SSM new format e.g. 202301234567
  old_registration_no   text,             -- pre-2019 format e.g. 1234567-A
  tin                   text,             -- LHDN Tax Identification Number (C........)
  sst_registration_no   text,             -- Sales & Service Tax registration
  tourism_tax_reg_no    text,
  msic_code             text,             -- 5 digit MSIC 2008
  business_activity     text,

  -- Address (LHDN requires structured address on e-Invoice)
  address_line1         text,
  address_line2         text,
  address_line3         text,
  postcode              text,
  city                  text,
  state_code            text,             -- refs ref_states.code
  country_code          text not null default 'MYS',

  email                 citext,
  phone                 text,
  website               text,
  logo_url              text,

  -- Accounting configuration
  base_currency         char(3) not null default 'MYR',
  fiscal_year_end_month smallint not null default 12 check (fiscal_year_end_month between 1 and 12),
  fiscal_year_end_day   smallint not null default 31 check (fiscal_year_end_day between 1 and 31),
  books_start_date      date,
  is_sst_registered     boolean not null default false,
  default_sales_tax_code_id   uuid,
  default_purchase_tax_code_id uuid,
  rounding_method       text not null default 'nearest_5cent'
                        check (rounding_method in ('none', 'nearest_5cent', 'nearest_10cent')),
  decimal_places        smallint not null default 2 check (decimal_places between 0 and 6),

  -- e-Invoice configuration
  einvoice_enabled      boolean not null default false,
  einvoice_environment  text not null default 'sandbox'
                        check (einvoice_environment in ('sandbox', 'production')),
  einvoice_client_id    text,
  -- Client secret is never stored here; kept in vault / edge function secret store.
  einvoice_secret_ref   text,
  einvoice_tin          text,
  einvoice_id_type      text default 'BRN' check (einvoice_id_type in ('NRIC', 'BRN', 'PASSPORT', 'ARMY')),
  einvoice_id_value     text,

  status                text not null default 'active'
                        check (status in ('active', 'trial', 'suspended', 'archived')),
  trial_ends_at         timestamptz,
  settings              jsonb not null default '{}'::jsonb,

  created_by            uuid references auth.users (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);

create index on public.organizations (slug);
create index on public.organizations (created_by);
comment on table public.organizations is 'Tenant. One organization = one set of books.';

-- ---------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------
create table public.org_members (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  user_id       uuid references auth.users (id) on delete cascade,
  invited_email citext,
  role          app.member_role not null default 'viewer',
  status        app.member_status not null default 'active',
  -- Fine grained overrides on top of the role, e.g. {"gl.post": false}
  permissions   jsonb not null default '{}'::jsonb,
  invited_by    uuid references auth.users (id),
  invite_token  text unique,
  invite_expires_at timestamptz,
  joined_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, user_id),
  constraint org_members_identity_ck
    check (user_id is not null or invited_email is not null)
);

create index on public.org_members (user_id) where user_id is not null;
create index on public.org_members (org_id);
create index on public.org_members (invited_email) where invited_email is not null;

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create table public.audit_logs (
  id          bigserial primary key,
  org_id      uuid references public.organizations (id) on delete cascade,
  user_id     uuid references auth.users (id) on delete set null,
  table_name  text not null,
  record_id   uuid,
  action      text not null check (action in ('insert', 'update', 'delete', 'post', 'void', 'submit')),
  old_data    jsonb,
  new_data    jsonb,
  ip_address  inet,
  user_agent  text,
  created_at  timestamptz not null default now()
);

create index on public.audit_logs (org_id, created_at desc);
create index on public.audit_logs (table_name, record_id);

-- ---------------------------------------------------------------------
-- Document numbering
-- ---------------------------------------------------------------------
create table public.number_sequences (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  doc_type      text not null,   -- 'invoice', 'quotation', 'credit_note', ...
  prefix        text not null default '',
  suffix        text not null default '',
  padding       smallint not null default 5 check (padding between 1 and 12),
  next_value    bigint not null default 1,
  -- 'never' | 'yearly' | 'monthly' -> resets next_value and injects period into prefix
  reset_policy  text not null default 'yearly'
                check (reset_policy in ('never', 'yearly', 'monthly')),
  period_key    text,            -- last period the sequence ran in, e.g. '2026' or '2026-08'
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, doc_type)
);

-- ---------------------------------------------------------------------
-- Shared triggers
-- ---------------------------------------------------------------------
create or replace function app.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;

  -- Claim any pending invitations addressed to this e-mail.
  update public.org_members
     set user_id  = new.id,
         status   = 'active',
         joined_at = now()
   where invited_email = new.email
     and user_id is null
     and status = 'invited';

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

create trigger set_updated_at before update on public.profiles
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.organizations
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.org_members
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.number_sequences
  for each row execute function app.set_updated_at();

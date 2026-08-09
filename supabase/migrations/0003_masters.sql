-- =====================================================================
-- iAkauntan :: 0003 master data
-- Chart of accounts, tax codes, fiscal calendar, contacts, items,
-- warehouses, price lists, payment terms and bank accounts.
-- =====================================================================

create type app.account_type as enum (
  'asset', 'liability', 'equity', 'revenue', 'expense'
);

create type app.account_subtype as enum (
  'current_asset', 'bank', 'cash', 'accounts_receivable', 'inventory',
  'fixed_asset', 'accumulated_depreciation', 'other_asset',
  'current_liability', 'accounts_payable', 'tax_payable', 'long_term_liability',
  'other_liability',
  'share_capital', 'retained_earnings', 'reserves', 'drawings',
  'sales', 'other_income',
  'cost_of_sales', 'operating_expense', 'payroll_expense',
  'depreciation_expense', 'finance_cost', 'tax_expense', 'other_expense'
);

create type app.contact_type as enum ('customer', 'supplier', 'both', 'employee', 'other');

-- ---------------------------------------------------------------------
-- Fiscal calendar
-- ---------------------------------------------------------------------
create table public.fiscal_years (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  name        text not null,
  start_date  date not null,
  end_date    date not null,
  status      text not null default 'open' check (status in ('open', 'closed', 'locked')),
  closed_at   timestamptz,
  closed_by   uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, name),
  constraint fiscal_years_range_ck check (end_date > start_date)
);

create table public.fiscal_periods (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  fiscal_year_id  uuid not null references public.fiscal_years (id) on delete cascade,
  period_no       smallint not null check (period_no between 1 and 13),
  name            text not null,
  start_date      date not null,
  end_date        date not null,
  status          text not null default 'open' check (status in ('open', 'closed', 'locked')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (fiscal_year_id, period_no),
  constraint fiscal_periods_range_ck check (end_date >= start_date)
);

create index on public.fiscal_periods (org_id, start_date, end_date);

-- ---------------------------------------------------------------------
-- Chart of accounts
-- ---------------------------------------------------------------------
create table public.accounts (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  code              text not null,
  name              text not null,
  description       text,
  account_type      app.account_type not null,
  account_subtype   app.account_subtype not null,
  parent_id         uuid references public.accounts (id) on delete set null,
  -- true for headers/groups that cannot receive postings
  is_group          boolean not null default false,
  is_system         boolean not null default false,   -- created by setup, cannot be deleted
  is_active         boolean not null default true,
  currency          char(3),                          -- null = base currency
  tax_code_id       uuid,
  opening_balance   numeric(18, 2) not null default 0,
  opening_balance_date date,
  -- Cached running balance maintained by the GL posting trigger
  current_balance   numeric(18, 2) not null default 0,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (org_id, code)
);

create index on public.accounts (org_id, account_type);
create index on public.accounts (org_id, parent_id);
create index on public.accounts (org_id) where deleted_at is null;

comment on column public.accounts.is_group is
  'Group/header accounts aggregate children and cannot be posted to directly.';

-- ---------------------------------------------------------------------
-- Tax codes (SST: sales tax, service tax; plus zero rated / exempt)
-- ---------------------------------------------------------------------
create table public.tax_codes (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  code              text not null,
  name              text not null,
  -- MyInvois tax type code, refs ref_tax_types
  tax_type_code     text not null default '06' references public.ref_tax_types (code),
  rate              numeric(9, 4) not null default 0 check (rate >= 0),
  is_inclusive      boolean not null default false,
  applies_to        text not null default 'both' check (applies_to in ('sales', 'purchase', 'both')),
  -- GL accounts the tax posts to
  sales_tax_account_id    uuid references public.accounts (id),
  purchase_tax_account_id uuid references public.accounts (id),
  -- Exemption handling for e-Invoice
  is_exempt         boolean not null default false,
  exemption_reason  text,
  is_active         boolean not null default true,
  is_default        boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (org_id, code)
);

create index on public.tax_codes (org_id) where is_active;

alter table public.accounts
  add constraint accounts_tax_code_fk
  foreign key (tax_code_id) references public.tax_codes (id) on delete set null;

alter table public.organizations
  add constraint organizations_default_sales_tax_fk
  foreign key (default_sales_tax_code_id) references public.tax_codes (id) on delete set null,
  add constraint organizations_default_purchase_tax_fk
  foreign key (default_purchase_tax_code_id) references public.tax_codes (id) on delete set null;

-- ---------------------------------------------------------------------
-- Payment terms
-- ---------------------------------------------------------------------
create table public.payment_terms (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  code          text not null,
  name          text not null,
  days          integer not null default 30,
  -- 'net' = n days from invoice date, 'eom' = end of month + days, 'cod' = on delivery
  term_type     text not null default 'net' check (term_type in ('net', 'eom', 'cod', 'prepaid')),
  discount_percent numeric(9, 4) not null default 0,
  discount_days integer not null default 0,
  is_default    boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);

-- ---------------------------------------------------------------------
-- Contacts (customers, suppliers, or both)
-- ---------------------------------------------------------------------
create table public.contacts (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  code                text not null,
  contact_type        app.contact_type not null default 'customer',
  name                text not null,
  legal_name          text,
  entity_type         app.entity_type not null default 'sdn_bhd',

  -- Malaysian statutory identifiers (mandatory for e-Invoice buyers)
  tin                 text,
  registration_no     text,
  old_registration_no text,
  sst_registration_no text,
  id_type             text check (id_type in ('NRIC', 'BRN', 'PASSPORT', 'ARMY')),
  id_value            text,
  msic_code           text,
  is_tin_verified     boolean not null default false,
  tin_verified_at     timestamptz,

  -- Primary contact details
  email               citext,
  phone               text,
  mobile              text,
  fax                 text,
  website             text,

  -- Billing address
  address_line1       text,
  address_line2       text,
  address_line3       text,
  postcode            text,
  city                text,
  state_code          text references public.ref_states (code),
  country_code        char(3) not null default 'MYS' references public.ref_countries (code),

  -- Commercial terms
  currency            char(3) not null default 'MYR' references public.ref_currencies (code),
  payment_term_id     uuid references public.payment_terms (id),
  credit_limit        numeric(18, 2) not null default 0,
  credit_hold         boolean not null default false,
  price_level_id      uuid,
  discount_percent    numeric(9, 4) not null default 0,
  tax_code_id         uuid references public.tax_codes (id),

  -- Default control accounts (override org defaults)
  receivable_account_id uuid references public.accounts (id),
  payable_account_id    uuid references public.accounts (id),

  -- CRM linkage
  owner_id            uuid references auth.users (id),
  tags                text[] not null default '{}',
  notes               text,
  is_active           boolean not null default true,
  custom_fields       jsonb not null default '{}'::jsonb,

  created_by          uuid references auth.users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  unique (org_id, code)
);

create index on public.contacts (org_id, contact_type) where deleted_at is null;
create index on public.contacts (org_id, name);
create index on public.contacts using gin (name gin_trgm_ops);
create index on public.contacts (org_id, owner_id);
create index on public.contacts (tin) where tin is not null;

-- Additional addresses (shipping, branches)
create table public.contact_addresses (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  contact_id    uuid not null references public.contacts (id) on delete cascade,
  label         text not null default 'Shipping',
  address_type  text not null default 'shipping' check (address_type in ('billing', 'shipping', 'branch')),
  attention     text,
  address_line1 text,
  address_line2 text,
  address_line3 text,
  postcode      text,
  city          text,
  state_code    text references public.ref_states (code),
  country_code  char(3) not null default 'MYS' references public.ref_countries (code),
  phone         text,
  is_default    boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index on public.contact_addresses (contact_id);

-- Contact persons
create table public.contact_persons (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  contact_id  uuid not null references public.contacts (id) on delete cascade,
  name        text not null,
  designation text,
  department  text,
  email       citext,
  phone       text,
  mobile      text,
  is_primary  boolean not null default false,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index on public.contact_persons (contact_id);

-- ---------------------------------------------------------------------
-- Warehouses / locations
-- ---------------------------------------------------------------------
create table public.warehouses (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  code          text not null,
  name          text not null,
  address_line1 text,
  address_line2 text,
  postcode      text,
  city          text,
  state_code    text references public.ref_states (code),
  country_code  char(3) not null default 'MYS',
  is_default    boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);

-- ---------------------------------------------------------------------
-- Items (stock and non stock)
-- ---------------------------------------------------------------------
create table public.item_categories (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  code        text not null,
  name        text not null,
  parent_id   uuid references public.item_categories (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

create table public.items (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  code                text not null,
  name                text not null,
  description         text,
  item_type           text not null default 'stock'
                      check (item_type in ('stock', 'service', 'non_stock', 'bundle', 'fixed_asset')),
  category_id         uuid references public.item_categories (id) on delete set null,
  barcode             text,

  uom_code            text not null default 'UNT' references public.ref_uom_codes (code),
  -- MyInvois item classification (mandatory on e-Invoice lines)
  classification_code text not null default '022' references public.ref_classification_codes (code),

  -- Pricing
  unit_price          numeric(18, 4) not null default 0,
  cost_price          numeric(18, 4) not null default 0,
  min_price           numeric(18, 4),
  currency            char(3) not null default 'MYR',

  -- Tax
  sales_tax_code_id   uuid references public.tax_codes (id),
  purchase_tax_code_id uuid references public.tax_codes (id),

  -- GL mapping
  sales_account_id    uuid references public.accounts (id),
  purchase_account_id uuid references public.accounts (id),
  inventory_account_id uuid references public.accounts (id),
  cogs_account_id     uuid references public.accounts (id),

  -- Inventory control
  track_inventory     boolean not null default true,
  costing_method      text not null default 'weighted_average'
                      check (costing_method in ('weighted_average', 'fifo', 'standard')),
  reorder_level       numeric(18, 4) not null default 0,
  reorder_quantity    numeric(18, 4) not null default 0,
  -- Cached totals maintained by stock movement triggers
  quantity_on_hand    numeric(18, 4) not null default 0,
  average_cost        numeric(18, 6) not null default 0,

  preferred_supplier_id uuid references public.contacts (id) on delete set null,
  image_url           text,
  is_active           boolean not null default true,
  is_sold             boolean not null default true,
  is_purchased        boolean not null default true,
  custom_fields       jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  unique (org_id, code)
);

create index on public.items (org_id, item_type) where deleted_at is null;
create index on public.items using gin (name gin_trgm_ops);
create index on public.items (org_id, category_id);
create index on public.items (barcode) where barcode is not null;

-- Price levels / tiers
create table public.price_levels (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  code        text not null,
  name        text not null,
  -- Either a blanket percentage off list, or explicit per-item prices below
  adjustment_percent numeric(9, 4) not null default 0,
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

alter table public.contacts
  add constraint contacts_price_level_fk
  foreign key (price_level_id) references public.price_levels (id) on delete set null;

create table public.item_prices (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  item_id         uuid not null references public.items (id) on delete cascade,
  price_level_id  uuid not null references public.price_levels (id) on delete cascade,
  unit_price      numeric(18, 4) not null,
  min_quantity    numeric(18, 4) not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (item_id, price_level_id, min_quantity)
);

-- ---------------------------------------------------------------------
-- Bank accounts
-- ---------------------------------------------------------------------
create table public.bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  account_id        uuid not null references public.accounts (id) on delete restrict,
  name              text not null,
  bank_name         text,
  bank_code         text,           -- e.g. MBBEMYKL
  account_number    text,
  account_type      text not null default 'current'
                    check (account_type in ('current', 'savings', 'credit_card', 'cash', 'ewallet')),
  currency          char(3) not null default 'MYR' references public.ref_currencies (code),
  opening_balance   numeric(18, 2) not null default 0,
  current_balance   numeric(18, 2) not null default 0,
  is_default        boolean not null default false,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index on public.bank_accounts (org_id) where is_active;

-- updated_at triggers
create trigger set_updated_at before update on public.fiscal_years    for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.fiscal_periods  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.accounts        for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.tax_codes       for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.payment_terms   for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.contacts        for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.contact_addresses for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.contact_persons for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.warehouses      for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.item_categories for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.items           for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.price_levels    for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.item_prices     for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.bank_accounts   for each row execute function app.set_updated_at();

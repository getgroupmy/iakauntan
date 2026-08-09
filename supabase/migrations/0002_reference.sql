-- =====================================================================
-- iAkauntan :: 0002 reference data tables
-- Global (non tenant scoped) lookup tables driven by LHDN / MyInvois
-- code lists and Malaysian standards. Readable by every authenticated
-- user, writable only by service role.
-- =====================================================================

-- Countries (LHDN uses ISO 3166-1 alpha-3)
create table public.ref_countries (
  code        char(3) primary key,
  name        text not null,
  alpha2      char(2),
  dial_code   text,
  is_active   boolean not null default true
);

-- Malaysian states (LHDN state codes, 2 digits)
create table public.ref_states (
  code        text primary key,
  name        text not null,
  country_code char(3) not null default 'MYS' references public.ref_countries (code),
  is_active   boolean not null default true
);

-- MSIC 2008 business activity codes (5 digit)
create table public.ref_msic_codes (
  code        text primary key,
  description text not null,
  category    text,
  is_active   boolean not null default true
);

create index on public.ref_msic_codes using gin (description gin_trgm_ops);

-- MyInvois classification codes (item level, 3 digit, 001..045)
create table public.ref_classification_codes (
  code        text primary key,
  description text not null,
  is_active   boolean not null default true
);

-- Unit of measure codes (UN/ECE Recommendation 20, as adopted by MyInvois)
create table public.ref_uom_codes (
  code        text primary key,
  name        text not null,
  category    text,
  is_active   boolean not null default true
);

-- Currencies (ISO 4217)
create table public.ref_currencies (
  code            char(3) primary key,
  name            text not null,
  symbol          text,
  decimal_places  smallint not null default 2,
  is_active       boolean not null default true
);

-- MyInvois tax type codes
create table public.ref_tax_types (
  code        text primary key,
  description text not null,
  is_active   boolean not null default true
);

-- MyInvois e-Invoice document type codes
create table public.ref_einvoice_types (
  code          text primary key,
  description   text not null,
  is_self_billed boolean not null default false,
  -- sign applied to amounts when posting: 1 = increases AR, -1 = reduces AR
  direction     smallint not null default 1,
  is_active     boolean not null default true
);

-- MyInvois payment mode codes
create table public.ref_payment_modes (
  code        text primary key,
  description text not null,
  is_active   boolean not null default true
);

-- MyInvois tax exemption reason / e-Invoice state codes for exemptions
create table public.ref_exemption_reasons (
  code        text primary key,
  description text not null,
  is_active   boolean not null default true
);

-- Foreign exchange rates (shared, seeded from BNM or entered manually)
create table public.exchange_rates (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid references public.organizations (id) on delete cascade,
  from_currency char(3) not null references public.ref_currencies (code),
  to_currency   char(3) not null references public.ref_currencies (code),
  rate          numeric(18, 8) not null check (rate > 0),
  rate_date     date not null,
  source        text not null default 'manual' check (source in ('manual', 'bnm', 'api')),
  created_at    timestamptz not null default now(),
  unique (org_id, from_currency, to_currency, rate_date)
);

create index on public.exchange_rates (from_currency, to_currency, rate_date desc);

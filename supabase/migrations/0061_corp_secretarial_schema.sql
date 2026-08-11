-- =====================================================================
-- iAkauntan :: 0061 corporate secretarial (add-on module 'secretarial')
--
-- For a firm acting as company secretary. The tenant is the firm; the
-- companies it acts for are corp_entities, which are deliberately not
-- organizations — a client company is a subject of record here, not a
-- tenant with logins.
--
-- Modelled on the Companies Act 2016, which replaced the numbered forms
-- of the 1965 Act with sections. Practitioners still say "Form 49", so
-- the seeded filing types carry both.
-- =====================================================================

create type app.corp_entity_type as enum (
  'sdn_bhd',        -- private company limited by shares
  'berhad',         -- public company
  'llp',            -- limited liability partnership (PLT)
  'sole_prop',      -- registered business
  'partnership',
  'foreign',        -- foreign company registered under Part IV
  'clbg'            -- company limited by guarantee
);

create type app.corp_entity_status as enum (
  'incorporated', 'dormant', 'struck_off', 'winding_up', 'dissolved', 'resigned'
);

create type app.corp_person_kind as enum ('individual', 'corporate');

create type app.corp_officer_role as enum (
  'director', 'alternate_director', 'secretary', 'auditor',
  'manager', 'chairman', 'ceo', 'cfo', 'partner', 'compliance_officer'
);

create type app.corp_share_event as enum (
  'allotment',      -- s.78 return of allotment
  'transfer',       -- Form 32A
  'transmission',   -- on death or bankruptcy
  'cancellation',   -- buy-back or reduction
  'conversion'      -- between classes
);

create type app.corp_resolution_kind as enum (
  'board', 'members_ordinary', 'members_special', 'written'
);

create type app.corp_filing_status as enum (
  'not_due', 'due', 'in_preparation', 'awaiting_signature',
  'lodged', 'approved', 'rejected', 'not_applicable'
);

-- ---------------------------------------------------------------------
-- The companies the firm acts for
-- ---------------------------------------------------------------------
create table public.corp_entities (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  name text not null,
  former_names text[],
  registration_no text,              -- the 12-digit SSM number
  old_registration_no text,          -- the pre-2019 format, still quoted
  entity_type app.corp_entity_type not null default 'sdn_bhd',
  status app.corp_entity_status not null default 'incorporated',

  incorporated_on date,
  incorporated_in text default 'Malaysia',
  -- The Annual Return is due from this date, not from the year end.
  financial_year_end_day integer check (financial_year_end_day between 1 and 31),
  financial_year_end_month integer check (financial_year_end_month between 1 and 12),

  registered_office text,
  registered_office_changed_on date,
  business_address text,
  correspondence_email text,
  phone text,

  nature_of_business text,
  msic_code text,

  -- A private company may be exempt from audit under the Registrar's
  -- practice directive; it still lodges unaudited financial statements.
  is_audit_exempt boolean not null default false,
  has_constitution boolean not null default false,
  constitution_adopted_on date,

  -- The firm's own file reference and who runs the file.
  client_ref text,
  contact_id uuid references public.contacts (id) on delete set null,
  responsible_secretary uuid references auth.users (id),
  engaged_on date,
  disengaged_on date,

  notes text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, registration_no)
);

create index on public.corp_entities (org_id, status);
create index on public.corp_entities (org_id, name);

-- ---------------------------------------------------------------------
-- People and bodies corporate, with the KYC a secretary has to hold
--
-- One record, used as officer, member and beneficial owner alike: an
-- NRIC kept in three places is an NRIC that will disagree with itself.
-- ---------------------------------------------------------------------
create table public.corp_persons (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  kind app.corp_person_kind not null default 'individual',
  full_name text not null,
  former_name text,

  -- Individuals
  nric text,
  passport_no text,
  passport_country text,
  nationality text default 'Malaysian',
  date_of_birth date,
  gender text,
  is_resident_in_malaysia boolean not null default true,

  -- Bodies corporate
  registration_no text,
  incorporated_in text,

  email text,
  phone text,
  address_line1 text,
  address_line2 text,
  city text,
  postcode text,
  state_code text,
  country text default 'Malaysia',

  -- KYC. A secretary is a reporting institution under the AMLA for some
  -- engagements, and in every case has to know who they are filing for.
  id_document_type text,
  id_verified_on date,
  id_verified_by uuid references auth.users (id),
  is_pep boolean not null default false,
  kyc_notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_persons (org_id, full_name);
create unique index corp_persons_nric_key on public.corp_persons (org_id, nric)
  where nric is not null;

-- ---------------------------------------------------------------------
-- Register of directors, managers and secretaries (s.57)
-- ---------------------------------------------------------------------
create table public.corp_officers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  person_id uuid not null references public.corp_persons (id) on delete restrict,

  role app.corp_officer_role not null,
  appointed_on date not null,
  resigned_on date,
  cessation_reason text,

  is_alternate boolean not null default false,
  alternate_for uuid references public.corp_officers (id) on delete set null,

  -- s.201 consent to act, and the s.198 declaration that the person is
  -- not disqualified. A secretary who cannot produce these has a problem.
  consent_received_on date,
  declaration_received_on date,

  -- A secretary must be a member of a prescribed body or hold a licence
  -- from the Registrar under s.20G of the Companies Commission Act.
  licence_no text,
  licence_body text,
  licence_expires_on date,

  designation text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_officers (entity_id, role) where resigned_on is null;
create index on public.corp_officers (org_id, person_id);

-- ---------------------------------------------------------------------
-- Share capital
--
-- The Companies Act 2016 abolished par value and authorised capital, so
-- there is issued capital and nothing else.
-- ---------------------------------------------------------------------
create table public.corp_share_classes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  code text not null,
  name text not null default 'Ordinary',
  currency char(3) not null default 'MYR',
  votes_per_share numeric(10,4) not null default 1,
  is_redeemable boolean not null default false,
  rights text,
  created_at timestamptz not null default now(),
  unique (entity_id, code)
);

-- Every movement in the shares, kept as events. Positions are computed
-- from them, the way the ledger computes balances from journals: a
-- register that can be edited directly is a register that will drift
-- from the returns already lodged.
create table public.corp_share_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  share_class_id uuid not null references public.corp_share_classes (id) on delete restrict,

  event_type app.corp_share_event not null,
  event_date date not null,

  from_person_id uuid references public.corp_persons (id) on delete restrict,
  to_person_id uuid references public.corp_persons (id) on delete restrict,

  quantity numeric(20,4) not null check (quantity > 0),
  consideration_per_share numeric(18,4),
  total_consideration numeric(18,2),
  is_cash boolean not null default true,
  consideration_note text,          -- when not for cash, s.78(2) wants to know

  certificate_no text,
  instrument_ref text,              -- Form 32A for a transfer
  stamp_duty numeric(18,2),
  stamp_certificate_no text,

  resolution_id uuid,
  filing_id uuid,
  notes text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),

  -- An allotment has no transferor; a cancellation has no transferee.
  constraint corp_share_events_parties_ck check (
    case event_type
      when 'allotment'    then from_person_id is null and to_person_id is not null
      when 'cancellation' then from_person_id is not null and to_person_id is null
      else from_person_id is not null and to_person_id is not null
    end)
);

create index on public.corp_share_events (entity_id, event_date);
create index on public.corp_share_events (org_id, to_person_id);

-- ---------------------------------------------------------------------
-- Register of beneficial owners (s.60B, in force since 1 April 2024)
-- ---------------------------------------------------------------------
create table public.corp_beneficial_owners (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  person_id uuid not null references public.corp_persons (id) on delete restrict,

  -- The statutory criteria. More than one may apply to the same person.
  holds_20pc_shares boolean not null default false,
  holds_20pc_voting boolean not null default false,
  appoints_majority_directors boolean not null default false,
  has_significant_influence boolean not null default false,
  other_control text,

  shareholding_percent numeric(7,4),
  notified_on date,
  entered_on date not null default current_date,
  ceased_on date,
  cessation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_beneficial_owners (entity_id) where ceased_on is null;

-- ---------------------------------------------------------------------
-- Register of charges (s.357), registrable within 30 days (s.352)
-- ---------------------------------------------------------------------
create table public.corp_charges (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,

  charge_no text,
  charge_type text,                 -- debenture, fixed, floating, lien…
  created_on date not null,
  registered_on date,
  amount_secured numeric(18,2),
  currency char(3) not null default 'MYR',
  chargee_name text not null,
  property_charged text,
  ranking text,

  satisfied_on date,
  satisfaction_filed_on date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_charges (entity_id) where satisfied_on is null;

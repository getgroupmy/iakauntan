-- =====================================================================
-- iAkauntan :: 0025 HRMS core
--
-- Employee records plus the statutory rate tables the payroll engine
-- reads. Rates are data, not code: every schedule carries an effective
-- range and a provenance flag, so a gazetted change is an insert rather
-- than a deploy, and a payslip can say which schedule produced it.
-- =====================================================================

create type app.employment_status as enum (
  'probation', 'active', 'notice', 'resigned', 'terminated',
  'retired', 'suspended'
);

create type app.employment_type as enum (
  'full_time', 'part_time', 'contract', 'internship', 'temporary'
);

create type app.pay_frequency as enum ('monthly', 'semi_monthly', 'weekly', 'daily');

create type app.marital_status as enum ('single', 'married', 'divorced', 'widowed');

-- Drives EPF eligibility and the PCB rate: a non-resident is taxed at a
-- flat rate rather than the progressive scale.
create type app.residency_status as enum (
  'citizen', 'permanent_resident', 'expatriate', 'foreign_worker'
);

-- ---------------------------------------------------------------------
-- Org structure
-- ---------------------------------------------------------------------
create table public.departments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  parent_id uuid references public.departments (id) on delete set null,
  -- Where this department's payroll cost lands in the ledger.
  cost_centre text,
  head_employee_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

create table public.positions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  title text not null,
  department_id uuid references public.departments (id) on delete set null,
  grade text,
  min_salary numeric(18, 2),
  max_salary numeric(18, 2),
  job_description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

-- ---------------------------------------------------------------------
-- Employees
-- ---------------------------------------------------------------------
create table public.employees (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_no text not null,

  -- Links the record to a login so the person can use self-service.
  -- Null for staff who never sign in; payroll does not need a login.
  user_id uuid references auth.users (id) on delete set null,

  full_name text not null,
  preferred_name text,
  email citext,
  phone text,

  -- Identity. NRIC is stored without dashes so it matches what KWSP,
  -- PERKESO and LHDN expect in submission files.
  nric text,
  passport_no text,
  nationality text not null default 'MYS',
  residency_status app.residency_status not null default 'citizen',
  date_of_birth date,
  gender text,
  marital_status app.marital_status not null default 'single',
  -- Spouse working affects the PCB category and the spouse relief.
  spouse_is_working boolean not null default false,
  is_disabled boolean not null default false,
  spouse_is_disabled boolean not null default false,

  address_line1 text,
  address_line2 text,
  city text,
  postcode text,
  state_code text references public.ref_states (code),
  country_code char(3) not null default 'MYS',

  emergency_contact_name text,
  emergency_contact_phone text,
  emergency_contact_relation text,

  -- Employment
  department_id uuid references public.departments (id) on delete set null,
  position_id uuid references public.positions (id) on delete set null,
  manager_id uuid references public.employees (id) on delete set null,
  employment_type app.employment_type not null default 'full_time',
  employment_status app.employment_status not null default 'probation',
  hire_date date not null,
  confirmation_date date,
  resignation_date date,
  last_working_date date,
  termination_reason text,

  -- Pay
  pay_frequency app.pay_frequency not null default 'monthly',
  basic_salary numeric(18, 2) not null default 0,
  -- Used for daily-rate and overtime maths; Malaysian practice is the
  -- ordinary rate of pay = monthly wage / 26.
  working_days_per_month numeric(5, 2) not null default 26,
  working_hours_per_day numeric(5, 2) not null default 8,
  currency char(3) not null default 'MYR',

  bank_name text,
  bank_account_no text,
  bank_account_holder text,

  -- Statutory identifiers
  epf_no text,
  socso_no text,
  income_tax_no text,          -- LHDN file number, e.g. SG 12345678090
  tin text,                    -- the newer TIN, needed for e-Invoice
  eis_no text,

  -- Statutory participation. A foreign worker on a temporary pass may be
  -- outside EPF; a director's fee may be outside SOCSO. Defaults follow
  -- the common case and are overridable per employee.
  epf_eligible boolean not null default true,
  socso_eligible boolean not null default true,
  eis_eligible boolean not null default true,
  pcb_eligible boolean not null default true,
  hrdf_eligible boolean not null default true,
  -- Voluntary EPF above the statutory rate, as a percentage of wages.
  epf_voluntary_employee_rate numeric(6, 3) not null default 0,
  epf_voluntary_employer_rate numeric(6, 3) not null default 0,
  zakat_monthly numeric(18, 2) not null default 0,
  -- CP38: an LHDN instruction to deduct arrears on top of monthly PCB.
  cp38_monthly numeric(18, 2) not null default 0,

  photo_url text,
  notes text,
  custom_fields jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (org_id, employee_no),
  -- One login maps to at most one employee record per company.
  unique (org_id, user_id)
);

create index employees_org_status_idx
  on public.employees (org_id, employment_status);
create index employees_org_dept_idx on public.employees (org_id, department_id);
create index employees_user_idx on public.employees (user_id) where user_id is not null;

alter table public.departments
  add constraint departments_head_fkey
  foreign key (head_employee_id) references public.employees (id) on delete set null;

comment on table public.employees is
  'Central employee record. Statutory identifiers and eligibility flags feed the payroll engine directly.';

-- Children and other dependants, which drive the PCB child relief.
create table public.employee_dependants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  name text not null,
  relationship text not null,           -- child, spouse, parent
  nric text,
  date_of_birth date,
  is_disabled boolean not null default false,
  -- A child in full-time tertiary education attracts a larger relief.
  in_higher_education boolean not null default false,
  -- Both parents may claim; this records the share this employee takes.
  relief_claim_percent numeric(5, 2) not null default 100,
  is_tax_dependant boolean not null default true,
  created_at timestamptz not null default now()
);
create index employee_dependants_emp_idx
  on public.employee_dependants (employee_id);

create table public.employee_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  doc_type text not null,               -- contract, offer_letter, permit, certificate
  title text not null,
  file_path text,
  issued_date date,
  expires_date date,
  notes text,
  uploaded_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);
create index employee_documents_emp_idx
  on public.employee_documents (employee_id);
-- Work permits and professional certificates expire; this is what a
-- "expiring in the next 60 days" list reads.
create index employee_documents_expiry_idx
  on public.employee_documents (org_id, expires_date)
  where expires_date is not null;

-- ---------------------------------------------------------------------
-- Statutory schedules
--
-- A schedule is one authority's rules over one period. Payroll picks the
-- schedule in force on the pay date, so re-running an old period keeps
-- using the rules that applied then.
-- ---------------------------------------------------------------------
create type app.statutory_body as enum ('epf', 'socso', 'eis', 'pcb', 'hrdf');

-- percentage: contribution = rate x wage (optionally on a rounded wage)
-- table:      contribution = the amount stated for the wage band
create type app.statutory_method as enum ('percentage', 'table');

create table public.statutory_schedules (
  id uuid primary key default gen_random_uuid(),
  body app.statutory_body not null,
  name text not null,
  method app.statutory_method not null,
  effective_from date not null,
  effective_to date,

  -- KWSP's Third Schedule rounds wages up to the next RM20 before
  -- applying the rate, then rounds the contribution up to the ringgit.
  wage_round_up_to numeric(10, 2),
  result_rounding text not null default 'nearest_cent'
    check (result_rounding in ('nearest_cent', 'nearest_5sen', 'up_ringgit')),

  -- Provenance, stated plainly. The percentage schedules below are the
  -- published statutory rates; the gazetted contribution *tables* carry
  -- band-level amounts that differ by a few sen, so anyone filing real
  -- returns should load the official table and mark it verified.
  source text,
  is_verified boolean not null default false,
  notes text,
  created_at timestamptz not null default now()
);

comment on column public.statutory_schedules.is_verified is
  'False means the figures were derived from published percentages rather than transcribed from the authority''s gazetted table. Verify before filing.';

create table public.statutory_rates (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.statutory_schedules (id) on delete cascade,
  -- Which population this row applies to, e.g. socso 'act4' (under 60)
  -- versus 'act800' (60 and over, employment injury only).
  category text not null default 'default',
  wage_from numeric(18, 2) not null default 0,
  wage_to numeric(18, 2),                       -- null = no upper bound
  -- percentage method
  employee_rate numeric(8, 4) not null default 0,
  employer_rate numeric(8, 4) not null default 0,
  -- table method
  employee_amount numeric(18, 2),
  employer_amount numeric(18, 2),
  -- Contributions stop counting wages above this.
  wage_ceiling numeric(18, 2),
  sort_order integer not null default 0
);
create index statutory_rates_lookup_idx
  on public.statutory_rates (schedule_id, category, wage_from);

-- Annual income tax scale, used to compute PCB by projecting the year.
create table public.tax_brackets (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.statutory_schedules (id) on delete cascade,
  chargeable_from numeric(18, 2) not null,
  chargeable_to numeric(18, 2),
  rate_percent numeric(8, 4) not null,
  -- Tax on everything below chargeable_from, so the marginal maths is
  -- a lookup plus one multiplication.
  cumulative_tax numeric(18, 2) not null default 0,
  sort_order integer not null default 0
);
create index tax_brackets_lookup_idx
  on public.tax_brackets (schedule_id, chargeable_from);

create table public.tax_reliefs (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.statutory_schedules (id) on delete cascade,
  code text not null,
  name text not null,
  -- Granted without the employee claiming it (individual relief, EPF).
  is_automatic boolean not null default false,
  default_amount numeric(18, 2) not null default 0,
  max_amount numeric(18, 2),
  -- 'individual', 'spouse', 'child', 'child_disabled', 'child_tertiary',
  -- 'epf_life', 'disabled_self'
  applies_to text not null default 'individual',
  sort_order integer not null default 0,
  unique (schedule_id, code)
);

-- What the employee has told payroll they will claim this year. PCB is a
-- monthly estimate of an annual liability, so these change the deduction.
create table public.employee_tax_reliefs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  tax_year integer not null,
  relief_code text not null,
  amount numeric(18, 2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  unique (employee_id, tax_year, relief_code)
);

-- Pay received before joining, or under a previous employer this year.
-- PCB projects the whole year, so it has to know what came before.
create table public.employee_ytd_opening (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  tax_year integer not null,
  gross_pay numeric(18, 2) not null default 0,
  epf_employee numeric(18, 2) not null default 0,
  pcb_paid numeric(18, 2) not null default 0,
  zakat_paid numeric(18, 2) not null default 0,
  benefits_in_kind numeric(18, 2) not null default 0,
  notes text,
  unique (employee_id, tax_year)
);

-- ---------------------------------------------------------------------
-- Updated-at triggers, matching the rest of the schema
-- ---------------------------------------------------------------------
create trigger set_updated_at before update on public.employees
  for each row execute function app.set_updated_at();

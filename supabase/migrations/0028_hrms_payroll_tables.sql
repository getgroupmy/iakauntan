-- =====================================================================
-- iAkauntan :: 0028 hrms payroll tables
-- Applied as project migration 20260810054528.
-- =====================================================================

create type app.payroll_status as enum
  ('draft', 'calculated', 'approved', 'posted', 'paid', 'void');

create type app.payslip_line_kind as enum (
  'earning',              -- adds to gross and to what the employee is paid
  'deduction',            -- taken off the employee's pay
  'employer_contribution' -- a company cost that never touches net pay
);

-- Recurring allowances and deductions, defined once per company. The
-- liability flags are the whole point: overtime is SOCSO-liable but not
-- EPF-liable, a travelling allowance is usually neither.
create table public.salary_components (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  kind app.payslip_line_kind not null default 'earning',
  is_taxable boolean not null default true,
  is_epf_liable boolean not null default true,
  is_socso_liable boolean not null default true,
  is_eis_liable boolean not null default true,
  is_hrdf_liable boolean not null default true,
  -- A fixed sum, or a percentage of basic salary.
  default_amount numeric(18, 2) not null default 0,
  percent_of_basic numeric(8, 4),
  account_id uuid references public.accounts (id),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

create table public.employee_salary_components (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  component_id uuid not null references public.salary_components (id) on delete cascade,
  amount numeric(18, 2),
  effective_from date not null default current_date,
  effective_to date,
  notes text,
  created_at timestamptz not null default now()
);
create index employee_salary_components_emp_idx
  on public.employee_salary_components (employee_id);

create table public.pay_periods (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,                 -- 2026-08
  period_start date not null,
  period_end date not null,
  pay_date date not null,
  frequency app.pay_frequency not null default 'monthly',
  is_closed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (org_id, code),
  constraint pay_periods_date_order check (period_end >= period_start)
);

create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  run_no text not null,
  period_id uuid not null references public.pay_periods (id) on delete restrict,
  description text,
  status app.payroll_status not null default 'draft',

  employee_count integer not null default 0,
  total_gross numeric(18, 2) not null default 0,
  total_deductions numeric(18, 2) not null default 0,
  total_net numeric(18, 2) not null default 0,
  total_employer_cost numeric(18, 2) not null default 0,
  total_epf_employee numeric(18, 2) not null default 0,
  total_epf_employer numeric(18, 2) not null default 0,
  total_socso_employee numeric(18, 2) not null default 0,
  total_socso_employer numeric(18, 2) not null default 0,
  total_eis_employee numeric(18, 2) not null default 0,
  total_eis_employer numeric(18, 2) not null default 0,
  total_pcb numeric(18, 2) not null default 0,
  total_zakat numeric(18, 2) not null default 0,
  total_hrdf numeric(18, 2) not null default 0,

  calculated_at timestamptz,
  approved_by uuid references auth.users (id),
  approved_at timestamptz,
  gl_entry_id uuid references public.gl_entries (id),
  posted_at timestamptz,
  paid_at timestamptz,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, run_no)
);
create index payroll_runs_period_idx on public.payroll_runs (org_id, period_id);

create trigger set_updated_at before update on public.payroll_runs
  for each row execute function app.set_updated_at();

create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  run_id uuid not null references public.payroll_runs (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete restrict,

  -- Frozen copies of the details that appear on the payslip, because the
  -- employee may change department, salary or bank afterwards and the
  -- payslip has to keep saying what it said when it was issued.
  employee_no text,
  employee_name text,
  department_name text,
  position_title text,
  nric text,
  epf_no text,
  socso_no text,
  income_tax_no text,
  bank_name text,
  bank_account_no text,

  basic_salary numeric(18, 2) not null default 0,
  gross_pay numeric(18, 2) not null default 0,
  total_deductions numeric(18, 2) not null default 0,
  net_pay numeric(18, 2) not null default 0,

  -- The bases each authority charges on, kept so a payslip can be
  -- reconciled without re-deriving them.
  epf_wage numeric(18, 2) not null default 0,
  socso_wage numeric(18, 2) not null default 0,
  eis_wage numeric(18, 2) not null default 0,
  taxable_income numeric(18, 2) not null default 0,

  epf_employee numeric(18, 2) not null default 0,
  epf_employer numeric(18, 2) not null default 0,
  socso_employee numeric(18, 2) not null default 0,
  socso_employer numeric(18, 2) not null default 0,
  eis_employee numeric(18, 2) not null default 0,
  eis_employer numeric(18, 2) not null default 0,
  pcb numeric(18, 2) not null default 0,
  cp38 numeric(18, 2) not null default 0,
  zakat numeric(18, 2) not null default 0,
  hrdf numeric(18, 2) not null default 0,

  unpaid_leave_days numeric(6, 2) not null default 0,
  unpaid_leave_amount numeric(18, 2) not null default 0,
  ot_hours numeric(8, 2) not null default 0,
  ot_amount numeric(18, 2) not null default 0,
  claims_amount numeric(18, 2) not null default 0,

  -- Which schedules produced the figures above. An unverified schedule
  -- is recorded as such, so a payslip is never silently authoritative.
  epf_schedule_id uuid references public.statutory_schedules (id),
  socso_schedule_id uuid references public.statutory_schedules (id),
  eis_schedule_id uuid references public.statutory_schedules (id),
  pcb_schedule_id uuid references public.statutory_schedules (id),
  schedules_verified boolean not null default false,

  notes text,
  created_at timestamptz not null default now(),
  unique (run_id, employee_id)
);
create index payslips_employee_idx on public.payslips (employee_id);
create index payslips_org_idx on public.payslips (org_id);

create table public.payslip_lines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  payslip_id uuid not null references public.payslips (id) on delete cascade,
  line_no integer not null default 1,
  kind app.payslip_line_kind not null,
  code text not null,
  description text not null,
  quantity numeric(18, 4),
  rate numeric(18, 4),
  amount numeric(18, 2) not null default 0,
  is_taxable boolean not null default true,
  is_epf_liable boolean not null default false,
  is_socso_liable boolean not null default false,
  is_eis_liable boolean not null default false,
  account_id uuid references public.accounts (id),
  component_id uuid references public.salary_components (id)
);
create index payslip_lines_payslip_idx on public.payslip_lines (payslip_id);

-- Year-to-date figures, maintained as runs post. The EA form and the
-- PCB projection both read this rather than re-aggregating payslips.
create table public.payroll_ytd (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  tax_year integer not null,
  gross_pay numeric(18, 2) not null default 0,
  taxable_income numeric(18, 2) not null default 0,
  epf_employee numeric(18, 2) not null default 0,
  epf_employer numeric(18, 2) not null default 0,
  socso_employee numeric(18, 2) not null default 0,
  socso_employer numeric(18, 2) not null default 0,
  eis_employee numeric(18, 2) not null default 0,
  eis_employer numeric(18, 2) not null default 0,
  pcb numeric(18, 2) not null default 0,
  zakat numeric(18, 2) not null default 0,
  net_pay numeric(18, 2) not null default 0,
  months_paid integer not null default 0,
  updated_at timestamptz not null default now(),
  unique (employee_id, tax_year)
);

create trigger set_updated_at before update on public.payroll_ytd
  for each row execute function app.set_updated_at();

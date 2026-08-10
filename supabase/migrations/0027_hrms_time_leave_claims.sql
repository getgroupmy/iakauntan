-- =====================================================================
-- iAkauntan :: 0027 hrms time leave claims
-- Applied as project migration 20260810054427.
-- =====================================================================

create type app.attendance_status as enum (
  'present', 'late', 'absent', 'on_leave', 'rest_day', 'public_holiday', 'incomplete'
);
create type app.clock_method as enum ('web', 'mobile_gps', 'biometric', 'qr', 'manual');
create type app.request_status as enum
  ('draft', 'submitted', 'approved', 'rejected', 'cancelled');

create table public.work_shifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  start_time time not null,
  end_time time not null,
  break_minutes integer not null default 60,
  -- A night shift ends on the following calendar day.
  crosses_midnight boolean not null default false,
  grace_minutes integer not null default 10,
  -- Which weekdays this shift runs, 0 = Sunday.
  work_days integer[] not null default '{1,2,3,4,5}',
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

create table public.employee_shifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  shift_id uuid not null references public.work_shifts (id) on delete cascade,
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now()
);
create index employee_shifts_lookup_idx
  on public.employee_shifts (employee_id, effective_from);

create table public.public_holidays (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  holiday_date date not null,
  name text not null,
  -- Malaysian holidays are partly state-specific; null means nationwide.
  state_code text references public.ref_states (code),
  is_working boolean not null default false,
  unique (org_id, holiday_date, state_code)
);

create table public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  work_date date not null,
  shift_id uuid references public.work_shifts (id) on delete set null,

  clock_in timestamptz,
  clock_out timestamptz,
  clock_in_method app.clock_method,
  clock_out_method app.clock_method,

  -- Where the clock-in happened. Kept as plain columns rather than a
  -- geometry type so this needs no PostGIS.
  clock_in_lat numeric(10, 7),
  clock_in_lng numeric(10, 7),
  clock_out_lat numeric(10, 7),
  clock_out_lng numeric(10, 7),
  clock_in_address text,
  clock_out_address text,
  clock_in_device text,
  clock_out_device text,
  -- Biometric terminal identifier, when the punch came from a device.
  clock_in_terminal text,
  clock_out_terminal text,

  status app.attendance_status not null default 'present',
  worked_minutes integer not null default 0,
  late_minutes integer not null default 0,
  early_leave_minutes integer not null default 0,
  -- Overtime split by the Employment Act multiplier that applies.
  ot_normal_minutes integer not null default 0,
  ot_restday_minutes integer not null default 0,
  ot_holiday_minutes integer not null default 0,

  -- A correction made by HR after the fact, kept visible rather than
  -- silently overwriting what the terminal recorded.
  is_adjusted boolean not null default false,
  adjusted_by uuid references auth.users (id),
  adjustment_reason text,

  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, work_date)
);
create index attendance_org_date_idx on public.attendance_records (org_id, work_date);

create trigger set_updated_at before update on public.attendance_records
  for each row execute function app.set_updated_at();

create table public.leave_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  -- Paid leave keeps salary whole; unpaid leave drives a salary deduction.
  is_paid boolean not null default true,
  -- Annual entitlement in days, before any service-length scaling.
  default_days numeric(6, 2) not null default 0,
  -- Employment Act 1955 scales annual and sick leave by years of service.
  scales_with_service boolean not null default false,
  requires_attachment boolean not null default false,
  -- Days that may be carried into next year, and how long they survive.
  max_carry_forward numeric(6, 2) not null default 0,
  carry_forward_expiry_months integer,
  allow_half_day boolean not null default true,
  -- Minimum notice in days; zero for sick and emergency leave.
  notice_days integer not null default 0,
  colour text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

create table public.leave_entitlement_bands (
  id uuid primary key default gen_random_uuid(),
  leave_type_id uuid not null references public.leave_types (id) on delete cascade,
  service_years_from integer not null default 0,
  service_years_to integer,
  days numeric(6, 2) not null
);

create table public.leave_balances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  leave_type_id uuid not null references public.leave_types (id) on delete cascade,
  leave_year integer not null,
  entitled_days numeric(6, 2) not null default 0,
  carried_forward numeric(6, 2) not null default 0,
  adjustment_days numeric(6, 2) not null default 0,
  taken_days numeric(6, 2) not null default 0,
  pending_days numeric(6, 2) not null default 0,
  updated_at timestamptz not null default now(),
  unique (employee_id, leave_type_id, leave_year)
);

create trigger set_updated_at before update on public.leave_balances
  for each row execute function app.set_updated_at();

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  request_no text not null,
  employee_id uuid not null references public.employees (id) on delete cascade,
  leave_type_id uuid not null references public.leave_types (id) on delete restrict,
  start_date date not null,
  end_date date not null,
  -- Half days are common enough to model directly rather than as hours.
  is_half_day boolean not null default false,
  half_day_period text check (half_day_period in ('morning', 'afternoon')),
  total_days numeric(6, 2) not null,
  reason text,
  attachment_path text,
  contact_while_away text,

  status app.request_status not null default 'draft',
  submitted_at timestamptz,
  approver_id uuid references auth.users (id),
  decided_at timestamptz,
  decision_note text,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, request_no),
  constraint leave_requests_date_order check (end_date >= start_date)
);
create index leave_requests_emp_idx
  on public.leave_requests (employee_id, start_date);
create index leave_requests_pending_idx
  on public.leave_requests (org_id, status) where status = 'submitted';

create trigger set_updated_at before update on public.leave_requests
  for each row execute function app.set_updated_at();

create table public.claim_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  -- Where an approved claim lands in the ledger.
  expense_account_id uuid references public.accounts (id),
  requires_receipt boolean not null default true,
  monthly_cap numeric(18, 2),
  annual_cap numeric(18, 2),
  per_claim_cap numeric(18, 2),
  -- Mileage claims are quantity x rate rather than a stated amount.
  is_mileage boolean not null default false,
  rate_per_unit numeric(18, 4),
  unit_label text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);

create table public.expense_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  claim_no text not null,
  employee_id uuid not null references public.employees (id) on delete cascade,
  claim_date date not null default current_date,
  title text,
  status app.request_status not null default 'draft',
  total_amount numeric(18, 2) not null default 0,
  approved_amount numeric(18, 2) not null default 0,
  currency char(3) not null default 'MYR',

  submitted_at timestamptz,
  approver_id uuid references auth.users (id),
  decided_at timestamptz,
  decision_note text,

  -- Set when the approved claim has been posted to the ledger, and again
  -- when it has actually been paid out.
  gl_entry_id uuid references public.gl_entries (id),
  posted_at timestamptz,
  paid_at timestamptz,
  -- Reimbursed with salary rather than separately.
  pay_with_payroll boolean not null default true,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, claim_no)
);
create index expense_claims_emp_idx on public.expense_claims (employee_id, claim_date);
create index expense_claims_pending_idx
  on public.expense_claims (org_id, status) where status = 'submitted';

create trigger set_updated_at before update on public.expense_claims
  for each row execute function app.set_updated_at();

create table public.expense_claim_lines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  claim_id uuid not null references public.expense_claims (id) on delete cascade,
  line_no integer not null default 1,
  claim_type_id uuid references public.claim_types (id) on delete set null,
  expense_date date not null,
  description text not null,
  quantity numeric(18, 4),
  rate numeric(18, 4),
  amount numeric(18, 2) not null default 0,
  approved_amount numeric(18, 2),
  tax_code_id uuid references public.tax_codes (id),
  tax_amount numeric(18, 2) not null default 0,
  receipt_path text,
  -- Charged on to a customer or a legal matter where relevant.
  contact_id uuid references public.contacts (id),
  notes text
);
create index expense_claim_lines_claim_idx on public.expense_claim_lines (claim_id);

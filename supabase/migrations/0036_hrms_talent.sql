-- =====================================================================
-- iAkauntan :: 0036 hrms talent
-- Applied as project migration 20260810055202.
-- =====================================================================

create type app.requisition_status as enum
  ('draft', 'open', 'on_hold', 'filled', 'cancelled');

create type app.applicant_status as enum (
  'applied', 'screening', 'interview', 'assessment', 'offer',
  'hired', 'rejected', 'withdrawn'
);

create type app.appraisal_status as enum
  ('draft', 'self_review', 'manager_review', 'calibration', 'completed', 'cancelled');

create table public.job_requisitions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  requisition_no text not null,
  title text not null,
  department_id uuid references public.departments (id) on delete set null,
  position_id uuid references public.positions (id) on delete set null,
  hiring_manager_id uuid references public.employees (id) on delete set null,
  headcount integer not null default 1,
  employment_type app.employment_type not null default 'full_time',
  location text,
  salary_min numeric(18, 2),
  salary_max numeric(18, 2),
  description text,
  requirements text,
  status app.requisition_status not null default 'draft',
  opened_date date,
  target_start_date date,
  closed_date date,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, requisition_no)
);

create trigger set_updated_at before update on public.job_requisitions
  for each row execute function app.set_updated_at();

create table public.applicants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  requisition_id uuid references public.job_requisitions (id) on delete set null,
  full_name text not null,
  email citext,
  phone text,
  nric text,
  nationality text,
  current_employer text,
  current_position text,
  expected_salary numeric(18, 2),
  notice_period_days integer,
  source text,                      -- referral, jobstreet, linkedin, walk-in
  referred_by uuid references public.employees (id) on delete set null,
  resume_path text,
  status app.applicant_status not null default 'applied',
  rating integer check (rating between 1 and 5),
  notes text,
  applied_at timestamptz not null default now(),
  -- Set when the applicant becomes an employee, so the two records stay
  -- linked and the hire is traceable back to its requisition.
  hired_employee_id uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index applicants_req_idx on public.applicants (requisition_id, status);
create index applicants_org_status_idx on public.applicants (org_id, status);

create trigger set_updated_at before update on public.applicants
  for each row execute function app.set_updated_at();

-- Every move through the pipeline is kept rather than overwritten, so
-- time-to-hire and drop-off can be measured after the fact.
create table public.applicant_stage_history (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  from_status app.applicant_status,
  to_status app.applicant_status not null,
  note text,
  changed_by uuid references auth.users (id),
  changed_at timestamptz not null default now()
);
create index applicant_stage_history_idx
  on public.applicant_stage_history (applicant_id, changed_at);

create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  applicant_id uuid not null references public.applicants (id) on delete cascade,
  round_no integer not null default 1,
  scheduled_at timestamptz,
  duration_minutes integer not null default 60,
  mode text,                        -- onsite, video, phone
  location text,
  interviewer_id uuid references public.employees (id) on delete set null,
  outcome text check (outcome in ('pending', 'pass', 'fail', 'no_show')),
  score integer check (score between 1 and 5),
  feedback text,
  created_at timestamptz not null default now()
);
create index interviews_applicant_idx on public.interviews (applicant_id);

-- ---------------------------------------------------------------------
-- Onboarding
-- ---------------------------------------------------------------------
create table public.onboarding_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  department_id uuid references public.departments (id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.onboarding_template_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  template_id uuid not null references public.onboarding_templates (id) on delete cascade,
  title text not null,
  description text,
  category text,                    -- documents, equipment, access, training
  -- Days relative to the start date; negative means before day one.
  due_offset_days integer not null default 0,
  owner_role text,                  -- hr, manager, it, finance
  is_mandatory boolean not null default true,
  sort_order integer not null default 0
);

create table public.onboarding_checklists (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  template_id uuid references public.onboarding_templates (id) on delete set null,
  -- Also used for offboarding, which is the same shape run in reverse.
  kind text not null default 'onboarding'
    check (kind in ('onboarding', 'offboarding')),
  start_date date not null,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
create index onboarding_checklists_emp_idx
  on public.onboarding_checklists (employee_id);

create table public.onboarding_tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  checklist_id uuid not null references public.onboarding_checklists (id) on delete cascade,
  title text not null,
  description text,
  category text,
  due_date date,
  owner_employee_id uuid references public.employees (id) on delete set null,
  is_mandatory boolean not null default true,
  is_done boolean not null default false,
  done_at timestamptz,
  done_by uuid references auth.users (id),
  sort_order integer not null default 0
);
create index onboarding_tasks_checklist_idx
  on public.onboarding_tasks (checklist_id);

-- ---------------------------------------------------------------------
-- Performance
-- ---------------------------------------------------------------------
create table public.appraisal_cycles (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  period_start date not null,
  period_end date not null,
  self_review_due date,
  manager_review_due date,
  status app.appraisal_status not null default 'draft',
  -- The scale used, so a 1-5 cycle and a 1-10 cycle can coexist.
  rating_scale_max integer not null default 5,
  description text,
  created_at timestamptz not null default now()
);

create table public.appraisals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  cycle_id uuid not null references public.appraisal_cycles (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  reviewer_id uuid references public.employees (id) on delete set null,
  status app.appraisal_status not null default 'draft',

  self_rating numeric(4, 2),
  self_comments text,
  self_submitted_at timestamptz,
  manager_rating numeric(4, 2),
  manager_comments text,
  manager_submitted_at timestamptz,
  final_rating numeric(4, 2),
  calibration_note text,

  -- What the appraisal led to, which is usually the point of it.
  recommended_increment_percent numeric(6, 2),
  recommended_bonus numeric(18, 2),
  promotion_recommended boolean not null default false,
  development_plan text,

  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cycle_id, employee_id)
);
create index appraisals_employee_idx on public.appraisals (employee_id);

create trigger set_updated_at before update on public.appraisals
  for each row execute function app.set_updated_at();

create table public.appraisal_goals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  appraisal_id uuid not null references public.appraisals (id) on delete cascade,
  title text not null,
  description text,
  category text,                   -- kpi, competency, development
  weight_percent numeric(6, 2) not null default 0,
  target text,
  actual text,
  self_rating numeric(4, 2),
  manager_rating numeric(4, 2),
  comments text,
  sort_order integer not null default 0
);
create index appraisal_goals_appraisal_idx
  on public.appraisal_goals (appraisal_id);

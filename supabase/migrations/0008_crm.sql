-- =====================================================================
-- iAkauntan :: 0008 CRM
-- Leads, pipelines, opportunities, activities, notes and tasks.
-- A won opportunity converts into a contact + quotation, which is what
-- links CRM to the accounting side.
-- =====================================================================

create type app.lead_status as enum (
  'new', 'contacted', 'qualified', 'unqualified', 'converted', 'lost'
);

create type app.activity_type as enum (
  'call', 'email', 'meeting', 'task', 'note', 'whatsapp', 'site_visit', 'demo'
);

-- ---------------------------------------------------------------------
-- Leads
-- ---------------------------------------------------------------------
create table public.leads (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  lead_no         text not null,

  company_name    text,
  first_name      text,
  last_name       text,
  designation     text,
  email           citext,
  phone           text,
  mobile          text,
  website         text,

  address_line1   text,
  address_line2   text,
  postcode        text,
  city            text,
  state_code      text references public.ref_states (code),
  country_code    char(3) not null default 'MYS',

  source          text,   -- 'website', 'referral', 'walk_in', 'facebook', 'trade_show', ...
  industry        text,
  status          app.lead_status not null default 'new',
  rating          text check (rating in ('hot', 'warm', 'cold')),
  estimated_value numeric(18, 2) not null default 0,
  currency        char(3) not null default 'MYR',

  owner_id        uuid references auth.users (id),
  -- Populated when the lead is converted
  converted_contact_id     uuid references public.contacts (id) on delete set null,
  converted_opportunity_id uuid,
  converted_at    timestamptz,
  lost_reason     text,

  tags            text[] not null default '{}',
  notes           text,
  custom_fields   jsonb not null default '{}'::jsonb,
  last_activity_at timestamptz,

  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  unique (org_id, lead_no)
);

create index on public.leads (org_id, status) where deleted_at is null;
create index on public.leads (org_id, owner_id);
create index on public.leads using gin (company_name gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Pipelines and stages
-- ---------------------------------------------------------------------
create table public.pipelines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  name        text not null,
  description text,
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, name)
);

create table public.pipeline_stages (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  pipeline_id   uuid not null references public.pipelines (id) on delete cascade,
  name          text not null,
  -- Default probability applied to opportunities entering this stage
  probability   numeric(5, 2) not null default 0 check (probability between 0 and 100),
  stage_type    text not null default 'open'
                check (stage_type in ('open', 'won', 'lost')),
  color         text,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (pipeline_id, name)
);

create index on public.pipeline_stages (pipeline_id, sort_order);

-- ---------------------------------------------------------------------
-- Opportunities / deals
-- ---------------------------------------------------------------------
create table public.opportunities (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  opportunity_no  text not null,
  name            text not null,
  description     text,

  contact_id      uuid references public.contacts (id) on delete set null,
  contact_person_id uuid references public.contact_persons (id) on delete set null,
  lead_id         uuid references public.leads (id) on delete set null,

  pipeline_id     uuid not null references public.pipelines (id) on delete restrict,
  stage_id        uuid not null references public.pipeline_stages (id) on delete restrict,

  amount          numeric(18, 2) not null default 0,
  currency        char(3) not null default 'MYR',
  probability     numeric(5, 2) not null default 0 check (probability between 0 and 100),
  -- amount * probability / 100, maintained by trigger
  weighted_amount numeric(18, 2) not null default 0,

  expected_close_date date,
  actual_close_date   date,
  status          text not null default 'open'
                  check (status in ('open', 'won', 'lost', 'abandoned')),
  won_reason      text,
  lost_reason     text,
  competitor      text,
  source          text,

  owner_id        uuid references auth.users (id),
  -- Set when the deal is converted into a quotation/invoice
  quotation_id    uuid references public.sales_documents (id) on delete set null,

  tags            text[] not null default '{}',
  custom_fields   jsonb not null default '{}'::jsonb,
  last_activity_at timestamptz,
  stage_changed_at timestamptz not null default now(),

  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  unique (org_id, opportunity_no)
);

create index on public.opportunities (org_id, stage_id) where deleted_at is null;
create index on public.opportunities (org_id, status);
create index on public.opportunities (org_id, owner_id);
create index on public.opportunities (org_id, expected_close_date);
create index on public.opportunities (contact_id);

alter table public.leads
  add constraint leads_converted_opportunity_fk
  foreign key (converted_opportunity_id) references public.opportunities (id) on delete set null;

alter table public.sales_documents
  add constraint sales_documents_opportunity_fk
  foreign key (opportunity_id) references public.opportunities (id) on delete set null;

-- Stage transition history, drives funnel and velocity reporting
create table public.opportunity_stage_history (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  opportunity_id  uuid not null references public.opportunities (id) on delete cascade,
  from_stage_id   uuid references public.pipeline_stages (id) on delete set null,
  to_stage_id     uuid not null references public.pipeline_stages (id) on delete cascade,
  days_in_stage   integer,
  changed_by      uuid references auth.users (id),
  changed_at      timestamptz not null default now()
);

create index on public.opportunity_stage_history (opportunity_id, changed_at);

-- ---------------------------------------------------------------------
-- Activities (polymorphic: attach to lead, contact or opportunity)
-- ---------------------------------------------------------------------
create table public.activities (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  activity_type   app.activity_type not null default 'note',
  subject         text not null,
  description     text,

  lead_id         uuid references public.leads (id) on delete cascade,
  contact_id      uuid references public.contacts (id) on delete cascade,
  opportunity_id  uuid references public.opportunities (id) on delete cascade,
  contact_person_id uuid references public.contact_persons (id) on delete set null,

  due_date        timestamptz,
  completed_at    timestamptz,
  duration_minutes integer,
  location        text,
  outcome         text,

  status          text not null default 'pending'
                  check (status in ('pending', 'completed', 'cancelled', 'overdue')),
  priority        text not null default 'normal'
                  check (priority in ('low', 'normal', 'high', 'urgent')),

  assigned_to     uuid references auth.users (id),
  reminder_at     timestamptz,
  reminder_sent   boolean not null default false,
  attachments     jsonb not null default '[]'::jsonb,

  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint activities_target_ck check (
    num_nonnulls(lead_id, contact_id, opportunity_id) >= 1
  )
);

create index on public.activities (org_id, assigned_to, status);
create index on public.activities (org_id, due_date) where status = 'pending';
create index on public.activities (lead_id) where lead_id is not null;
create index on public.activities (contact_id) where contact_id is not null;
create index on public.activities (opportunity_id) where opportunity_id is not null;

-- ---------------------------------------------------------------------
-- Notes (free form, attachable to anything)
-- ---------------------------------------------------------------------
create table public.notes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  entity_table  text not null,
  entity_id     uuid not null,
  content       text not null,
  is_pinned     boolean not null default false,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index on public.notes (org_id, entity_table, entity_id);

-- ---------------------------------------------------------------------
-- Attachments / document storage metadata
-- ---------------------------------------------------------------------
create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  entity_table  text not null,
  entity_id     uuid not null,
  file_name     text not null,
  storage_path  text not null,
  mime_type     text,
  file_size     bigint,
  uploaded_by   uuid references auth.users (id),
  created_at    timestamptz not null default now()
);

create index on public.attachments (org_id, entity_table, entity_id);

create trigger set_updated_at before update on public.leads
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pipelines
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pipeline_stages
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.opportunities
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.activities
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.notes
  for each row execute function app.set_updated_at();

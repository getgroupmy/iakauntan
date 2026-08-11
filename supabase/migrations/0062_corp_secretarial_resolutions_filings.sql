-- =====================================================================
-- iAkauntan :: 0062 resolutions, filings and the document store
-- =====================================================================

create table public.corp_resolutions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,

  reference text,
  kind app.corp_resolution_kind not null default 'board',
  title text not null,
  body text,
  passed_on date,
  effective_on date,

  -- A written resolution circulated under s.297 rather than a meeting.
  meeting_held boolean not null default false,
  meeting_venue text,
  meeting_time time,
  chairman_person_id uuid references public.corp_persons (id) on delete set null,
  present_person_ids uuid[],
  in_favour integer,
  against integer,
  abstained integer,

  is_signed boolean not null default false,
  signed_on date,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_resolutions (entity_id, passed_on desc);

-- corp_filing_types is reference data: the section, what triggers it and
-- how many days there are. Deadlines are computed from it rather than
-- typed in, so a change in the law is one row.
create table public.corp_filing_types (
  code text primary key,
  name text not null,
  statute_ref text not null,          -- 'CA 2016 s.68'
  legacy_form text,                   -- what practitioners still call it
  trigger_kind text not null,         -- anniversary | fye | event | agm
  days_allowed integer,
  applies_to app.corp_entity_type[],
  description text,
  sort_order integer not null default 0
);

create table public.corp_filings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  filing_type text not null references public.corp_filing_types (code),

  -- What set the clock running: the anniversary, the year end, or the
  -- date of the change being notified.
  trigger_date date not null,
  due_date date not null,
  period_label text,

  status app.corp_filing_status not null default 'due',
  lodged_on date,
  ssm_reference text,
  lodged_by uuid references auth.users (id),
  fee_paid numeric(18,2),

  resolution_id uuid references public.corp_resolutions (id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_id, filing_type, trigger_date)
);

create index on public.corp_filings (org_id, due_date)
  where status not in ('lodged', 'approved', 'not_applicable');

alter table public.corp_share_events
  add constraint corp_share_events_resolution_fk
  foreign key (resolution_id) references public.corp_resolutions (id) on delete set null;
alter table public.corp_share_events
  add constraint corp_share_events_filing_fk
  foreign key (filing_id) references public.corp_filings (id) on delete set null;

-- ---------------------------------------------------------------------
-- Document templates and what they produced
-- ---------------------------------------------------------------------
create table public.corp_templates (
  id uuid primary key default gen_random_uuid(),
  -- Null org_id is a template the platform ships; a firm may copy it
  -- and edit its own.
  org_id uuid references public.organizations (id) on delete cascade,
  code text not null,
  name text not null,
  category text,
  applies_to app.corp_entity_type[],
  body text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index corp_templates_platform_code on public.corp_templates (code)
  where org_id is null;
create unique index corp_templates_org_code on public.corp_templates (org_id, code)
  where org_id is not null;

create table public.corp_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  entity_id uuid not null references public.corp_entities (id) on delete cascade,
  template_code text,
  title text not null,
  body text not null,
  -- The values used, kept beside the output. A document you cannot
  -- explain two years later is a document you cannot defend.
  merged_values jsonb,
  resolution_id uuid references public.corp_resolutions (id) on delete set null,
  filing_id uuid references public.corp_filings (id) on delete set null,
  generated_by uuid references auth.users (id),
  generated_at timestamptz not null default now()
);

create index on public.corp_documents (entity_id, generated_at desc);

do $do$
declare t text;
begin
  foreach t in array array[
    'corp_entities', 'corp_persons', 'corp_officers', 'corp_share_classes',
    'corp_share_events', 'corp_beneficial_owners', 'corp_charges',
    'corp_resolutions', 'corp_filings', 'corp_templates', 'corp_documents']
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = t
                  and column_name = 'updated_at') then
      execute format(
        'create trigger set_updated_at before update on public.%I
           for each row execute function app.set_updated_at()', t);
    end if;
  end loop;
end
$do$;

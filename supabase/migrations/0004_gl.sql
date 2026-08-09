-- =====================================================================
-- iAkauntan :: 0004 general ledger
-- Double entry journal with balanced-by-constraint enforcement.
-- Every subsidiary document (invoice, bill, payment, stock movement)
-- posts into gl_entries / gl_lines through a single posting function.
-- =====================================================================

create type app.journal_source as enum (
  'manual', 'sales_invoice', 'credit_note', 'debit_note', 'purchase_bill',
  'purchase_credit_note', 'receipt', 'payment', 'bank_transaction',
  'stock_movement', 'opening_balance', 'year_end_close', 'fx_revaluation',
  'payroll', 'depreciation'
);

-- ---------------------------------------------------------------------
-- Journal header
-- ---------------------------------------------------------------------
create table public.gl_entries (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  entry_no          text not null,
  entry_date        date not null,
  fiscal_period_id  uuid references public.fiscal_periods (id),
  source            app.journal_source not null default 'manual',

  -- Polymorphic link back to the document that produced this entry.
  source_table      text,
  source_id         uuid,

  description       text,
  reference         text,
  currency          char(3) not null default 'MYR',
  exchange_rate     numeric(18, 8) not null default 1 check (exchange_rate > 0),

  -- Control totals in base currency; kept in sync by the line trigger.
  total_debit       numeric(18, 2) not null default 0,
  total_credit      numeric(18, 2) not null default 0,

  status            text not null default 'posted'
                    check (status in ('draft', 'posted', 'void')),
  is_reversal       boolean not null default false,
  reversed_entry_id uuid references public.gl_entries (id) on delete set null,

  posted_at         timestamptz,
  posted_by         uuid references auth.users (id),
  created_by        uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (org_id, entry_no)
);

create index on public.gl_entries (org_id, entry_date desc);
create index on public.gl_entries (org_id, source, source_id);
create index on public.gl_entries (source_table, source_id);
create index on public.gl_entries (org_id, fiscal_period_id);

comment on column public.gl_entries.source_id is
  'Id of the originating document row in source_table. Null for manual journals.';

-- ---------------------------------------------------------------------
-- Journal lines
-- ---------------------------------------------------------------------
create table public.gl_lines (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  entry_id          uuid not null references public.gl_entries (id) on delete cascade,
  line_no           integer not null,
  account_id        uuid not null references public.accounts (id) on delete restrict,

  description       text,
  debit             numeric(18, 2) not null default 0 check (debit >= 0),
  credit            numeric(18, 2) not null default 0 check (credit >= 0),

  -- Foreign currency amounts (base currency amounts live in debit/credit)
  currency          char(3),
  fc_debit          numeric(18, 2) not null default 0,
  fc_credit         numeric(18, 2) not null default 0,
  exchange_rate     numeric(18, 8) not null default 1,

  -- Analytical dimensions
  contact_id        uuid references public.contacts (id) on delete set null,
  item_id           uuid references public.items (id) on delete set null,
  tax_code_id       uuid references public.tax_codes (id) on delete set null,
  tax_amount        numeric(18, 2) not null default 0,
  project_code      text,
  department_code   text,

  created_at        timestamptz not null default now(),

  unique (entry_id, line_no),
  -- Exactly one side of the entry must carry a value.
  constraint gl_lines_one_sided_ck check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0) or (debit = 0 and credit = 0)
  )
);

create index on public.gl_lines (entry_id);
create index on public.gl_lines (org_id, account_id);
create index on public.gl_lines (org_id, contact_id) where contact_id is not null;

-- ---------------------------------------------------------------------
-- Recurring journal templates
-- ---------------------------------------------------------------------
create table public.recurring_journals (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  name          text not null,
  description   text,
  frequency     text not null check (frequency in ('daily', 'weekly', 'monthly', 'quarterly', 'yearly')),
  interval_count integer not null default 1,
  start_date    date not null,
  end_date      date,
  next_run_date date not null,
  last_run_date date,
  -- [{account_id, debit, credit, description}, ...]
  template      jsonb not null,
  auto_post     boolean not null default false,
  is_active     boolean not null default true,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index on public.recurring_journals (org_id, next_run_date) where is_active;

create trigger set_updated_at before update on public.gl_entries
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.recurring_journals
  for each row execute function app.set_updated_at();

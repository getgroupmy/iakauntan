-- =====================================================================
-- iAkauntan :: 0007 LHDN MyInvois e-Invoice
--
-- Models the MyInvois lifecycle:
--   draft -> queued -> submitted -> valid | invalid
--   valid -> cancelled (by supplier, within 72h)
--   valid -> rejected  (requested by buyer within 72h, actioned by supplier)
--
-- Documents are pushed to LHDN in submissions (batches of up to 100
-- documents / 5 MB). Each batch gets a submissionUid; each document gets
-- a uuid + longId, and the longId is what the validation QR code encodes.
-- =====================================================================

create type app.einvoice_status as enum (
  'draft',       -- built locally, not yet queued
  'queued',      -- waiting for the submitter edge function
  'submitted',   -- accepted by MyInvois, awaiting validation
  'valid',       -- validated by LHDN
  'invalid',     -- rejected at validation with errors
  'cancelled',   -- cancelled by supplier within the 72h window
  'rejected',    -- buyer rejection request accepted by supplier
  'failed'       -- transport/auth failure before MyInvois accepted it
);

-- ---------------------------------------------------------------------
-- e-Invoice documents
-- ---------------------------------------------------------------------
create table public.einvoice_documents (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations (id) on delete cascade,

  -- Source document in our own books (sales or purchase side)
  source_table          text not null
                        check (source_table in ('sales_documents', 'purchase_documents')),
  source_id             uuid not null,

  -- MyInvois document type code, refs ref_einvoice_types (01..14)
  einvoice_type_code    text not null references public.ref_einvoice_types (code),
  einvoice_version      text not null default '1.1',
  is_self_billed        boolean not null default false,
  is_consolidated       boolean not null default false,

  -- Our internal document number, sent as the MyInvois eInvoiceCodeNumber
  internal_doc_no       text not null,
  issue_date            date not null,
  issue_time            time not null default (now() at time zone 'Asia/Kuala_Lumpur')::time,

  currency              char(3) not null default 'MYR',
  exchange_rate         numeric(18, 8) not null default 1,

  -- Supplier snapshot (frozen at submission time, LHDN validates against it)
  supplier_name         text not null,
  supplier_tin          text not null,
  supplier_id_type      text,
  supplier_id_value     text,
  supplier_sst_no       text,
  supplier_msic_code    text,
  supplier_business_activity text,
  supplier_email        text,
  supplier_phone        text,
  supplier_address      jsonb not null default '{}'::jsonb,

  -- Buyer snapshot
  buyer_name            text not null,
  buyer_tin             text not null,
  buyer_id_type         text,
  buyer_id_value        text,
  buyer_sst_no          text,
  buyer_email           text,
  buyer_phone           text,
  buyer_address         jsonb not null default '{}'::jsonb,

  -- Monetary totals as submitted
  total_excl_tax        numeric(18, 2) not null default 0,
  total_incl_tax        numeric(18, 2) not null default 0,
  total_discount        numeric(18, 2) not null default 0,
  total_tax             numeric(18, 2) not null default 0,
  total_charges         numeric(18, 2) not null default 0,
  rounding_amount       numeric(18, 2) not null default 0,
  payable_amount        numeric(18, 2) not null default 0,

  -- Full UBL 2.1 JSON payload actually sent, plus its SHA-256 digest
  ubl_payload           jsonb,
  payload_hash          text,
  signature             jsonb,

  -- MyInvois identifiers returned by the API
  submission_id         uuid,
  myinvois_uuid         text,
  myinvois_long_id      text,
  validation_link       text,
  qr_code_data          text,

  status                app.einvoice_status not null default 'draft',
  submitted_at          timestamptz,
  validated_at          timestamptz,
  -- Maintained by app.set_einvoice_cancel_deadline(). Not a generated
  -- column: timestamptz + interval is only STABLE, not IMMUTABLE.
  cancel_deadline       timestamptz,
  cancelled_at          timestamptz,
  cancellation_reason   text,
  rejection_reason      text,

  -- Validation feedback from LHDN
  validation_errors     jsonb not null default '[]'::jsonb,
  error_code            text,
  error_message         text,

  retry_count           smallint not null default 0,
  last_attempt_at       timestamptz,

  created_by            uuid references auth.users (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  unique (org_id, source_table, source_id, einvoice_type_code)
);

create index on public.einvoice_documents (org_id, status);
create index on public.einvoice_documents (org_id, issue_date desc);
create index on public.einvoice_documents (source_table, source_id);
create index on public.einvoice_documents (myinvois_uuid) where myinvois_uuid is not null;
create index on public.einvoice_documents (org_id, status, last_attempt_at)
  where status in ('queued', 'submitted');
create index on public.einvoice_documents (org_id, cancel_deadline) where status = 'valid';

comment on column public.einvoice_documents.cancel_deadline is
  'LHDN permits supplier cancellation only within 72 hours of validation.';

create or replace function app.set_einvoice_cancel_deadline()
returns trigger
language plpgsql
as $$
begin
  new.cancel_deadline := case
    when new.validated_at is null then null
    else new.validated_at + interval '72 hours'
  end;
  return new;
end;
$$;

create trigger set_cancel_deadline
  before insert or update of validated_at on public.einvoice_documents
  for each row execute function app.set_einvoice_cancel_deadline();

-- Wire the deferred FKs from the sales/purchase headers.
alter table public.sales_documents
  add constraint sales_documents_einvoice_fk
  foreign key (einvoice_id) references public.einvoice_documents (id) on delete set null;

alter table public.purchase_documents
  add constraint purchase_documents_einvoice_fk
  foreign key (einvoice_id) references public.einvoice_documents (id) on delete set null;

-- ---------------------------------------------------------------------
-- e-Invoice line snapshot (what was actually transmitted)
-- ---------------------------------------------------------------------
create table public.einvoice_lines (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  einvoice_id         uuid not null references public.einvoice_documents (id) on delete cascade,
  line_no             integer not null,

  classification_code text not null,
  description         text not null,
  quantity            numeric(18, 4) not null default 1,
  uom_code            text,
  unit_price          numeric(18, 4) not null default 0,

  subtotal            numeric(18, 2) not null default 0,
  discount_rate       numeric(9, 4) not null default 0,
  discount_amount     numeric(18, 2) not null default 0,
  charge_amount       numeric(18, 2) not null default 0,

  tax_type_code       text not null default '06',
  tax_rate            numeric(9, 4) not null default 0,
  tax_amount          numeric(18, 2) not null default 0,
  tax_exemption_reason text,
  tax_exempted_amount numeric(18, 2) not null default 0,

  total_excl_tax      numeric(18, 2) not null default 0,
  total_incl_tax      numeric(18, 2) not null default 0,

  -- Optional product traceability fields supported by MyInvois
  product_tariff_code text,
  country_of_origin   char(3),

  created_at          timestamptz not null default now(),
  unique (einvoice_id, line_no)
);

create index on public.einvoice_lines (einvoice_id);

-- ---------------------------------------------------------------------
-- Batch submissions to MyInvois
-- ---------------------------------------------------------------------
create table public.einvoice_submissions (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  submission_uid    text,             -- submissionUid returned by MyInvois
  environment       text not null default 'sandbox'
                    check (environment in ('sandbox', 'production')),
  document_count    integer not null default 0,
  accepted_count    integer not null default 0,
  rejected_count    integer not null default 0,

  status            text not null default 'pending'
                    check (status in ('pending', 'in_progress', 'valid', 'partial', 'invalid', 'failed')),
  request_payload   jsonb,
  response_payload  jsonb,
  http_status       integer,
  error_message     text,

  submitted_at      timestamptz,
  completed_at      timestamptz,
  submitted_by      uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index on public.einvoice_submissions (org_id, created_at desc);
create index on public.einvoice_submissions (submission_uid) where submission_uid is not null;

alter table public.einvoice_documents
  add constraint einvoice_documents_submission_fk
  foreign key (submission_id) references public.einvoice_submissions (id) on delete set null;

-- ---------------------------------------------------------------------
-- API call log (kept for the LHDN 7 year audit requirement)
-- ---------------------------------------------------------------------
create table public.einvoice_logs (
  id            bigserial primary key,
  org_id        uuid references public.organizations (id) on delete cascade,
  einvoice_id   uuid references public.einvoice_documents (id) on delete set null,
  submission_id uuid references public.einvoice_submissions (id) on delete set null,
  operation     text not null,     -- 'token', 'submit', 'status', 'cancel', 'validate_tin', 'search'
  endpoint      text,
  http_method   text,
  http_status   integer,
  request_body  jsonb,
  response_body jsonb,
  duration_ms   integer,
  error_message text,
  created_at    timestamptz not null default now()
);

create index on public.einvoice_logs (org_id, created_at desc);
create index on public.einvoice_logs (einvoice_id);

-- ---------------------------------------------------------------------
-- Consolidated B2C e-Invoice
-- LHDN allows aggregating B2C receipts into one monthly e-Invoice,
-- submitted within 7 calendar days after month end.
-- ---------------------------------------------------------------------
create table public.einvoice_consolidations (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  period_start    date not null,
  period_end      date not null,
  einvoice_id     uuid references public.einvoice_documents (id) on delete set null,
  document_count  integer not null default 0,
  total_amount    numeric(18, 2) not null default 0,
  status          text not null default 'draft'
                  check (status in ('draft', 'generated', 'submitted', 'valid', 'invalid')),
  -- Deadline is 7 days after period_end under the LHDN guideline.
  due_date        date generated always as (period_end + 7) stored,
  generated_at    timestamptz,
  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (org_id, period_start, period_end)
);

-- Which source documents rolled into a consolidation
create table public.einvoice_consolidation_items (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  consolidation_id  uuid not null references public.einvoice_consolidations (id) on delete cascade,
  sales_document_id uuid not null references public.sales_documents (id) on delete cascade,
  amount            numeric(18, 2) not null default 0,
  created_at        timestamptz not null default now(),
  unique (consolidation_id, sales_document_id)
);

-- ---------------------------------------------------------------------
-- TIN validation cache (LHDN rate limits the validation endpoint)
-- ---------------------------------------------------------------------
create table public.tin_validations (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid references public.organizations (id) on delete cascade,
  tin           text not null,
  id_type       text not null,
  id_value      text not null,
  is_valid      boolean not null,
  validated_at  timestamptz not null default now(),
  response      jsonb,
  unique (tin, id_type, id_value)
);

create index on public.tin_validations (tin);

create trigger set_updated_at before update on public.einvoice_documents
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.einvoice_submissions
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.einvoice_consolidations
  for each row execute function app.set_updated_at();

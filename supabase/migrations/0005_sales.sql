-- =====================================================================
-- iAkauntan :: 0005 sales cycle
-- Quotation -> Sales Order -> Delivery Order -> Invoice -> Receipt,
-- plus credit notes, debit notes and refund notes.
--
-- All sales documents share one shape so the Flutter client can reuse a
-- single editor: a header table + a lines table with identical columns.
-- =====================================================================

create type app.sales_doc_type as enum (
  'quotation', 'sales_order', 'delivery_order', 'invoice',
  'credit_note', 'debit_note', 'refund_note', 'proforma'
);

-- ---------------------------------------------------------------------
-- Sales document header
-- ---------------------------------------------------------------------
create table public.sales_documents (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  doc_type            app.sales_doc_type not null,
  doc_no              text not null,
  doc_date            date not null default current_date,

  contact_id          uuid not null references public.contacts (id) on delete restrict,
  contact_person_id   uuid references public.contact_persons (id) on delete set null,
  shipping_address_id uuid references public.contact_addresses (id) on delete set null,

  reference           text,           -- customer PO number
  subject             text,
  -- Document chaining: a DO created from an SO points back at it
  parent_id           uuid references public.sales_documents (id) on delete set null,
  -- For credit/debit/refund notes: the invoice being adjusted
  original_invoice_id uuid references public.sales_documents (id) on delete set null,

  -- Dates
  due_date            date,
  valid_until         date,           -- quotations
  delivery_date       date,
  payment_term_id     uuid references public.payment_terms (id),

  -- Currency
  currency            char(3) not null default 'MYR' references public.ref_currencies (code),
  exchange_rate       numeric(18, 8) not null default 1 check (exchange_rate > 0),

  -- Totals (document currency)
  subtotal            numeric(18, 2) not null default 0,
  discount_percent    numeric(9, 4) not null default 0,
  discount_amount     numeric(18, 2) not null default 0,
  tax_amount          numeric(18, 2) not null default 0,
  shipping_amount     numeric(18, 2) not null default 0,
  rounding_amount     numeric(18, 2) not null default 0,
  total_amount        numeric(18, 2) not null default 0,
  -- Totals converted to base currency at exchange_rate
  base_total_amount   numeric(18, 2) not null default 0,

  -- Settlement
  paid_amount         numeric(18, 2) not null default 0,
  balance_amount      numeric(18, 2) not null default 0,
  applied_amount      numeric(18, 2) not null default 0,   -- for credit notes

  status              app.doc_status not null default 'draft',
  -- Fulfilment state used by SO -> DO -> Invoice chaining
  fulfilment_status   text not null default 'pending'
                      check (fulfilment_status in ('pending', 'partial', 'fulfilled', 'cancelled')),

  -- e-Invoice linkage (see 0007_einvoice.sql)
  einvoice_id         uuid,
  einvoice_status     text not null default 'not_applicable'
                      check (einvoice_status in
                        ('not_applicable', 'pending', 'submitted', 'valid', 'invalid', 'cancelled', 'rejected')),
  is_consolidated     boolean not null default false,

  -- GL
  gl_entry_id         uuid references public.gl_entries (id) on delete set null,
  posted_at           timestamptz,
  posted_by           uuid references auth.users (id),

  -- Sales attribution
  salesperson_id      uuid references auth.users (id),
  opportunity_id      uuid,

  notes               text,
  internal_notes      text,
  terms_conditions    text,
  attachments         jsonb not null default '[]'::jsonb,
  custom_fields       jsonb not null default '{}'::jsonb,

  created_by          uuid references auth.users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,

  unique (org_id, doc_type, doc_no)
);

create index on public.sales_documents (org_id, doc_type, doc_date desc);
create index on public.sales_documents (org_id, contact_id);
create index on public.sales_documents (org_id, status);
create index on public.sales_documents (org_id, doc_type, status) where deleted_at is null;
create index on public.sales_documents (parent_id) where parent_id is not null;
create index on public.sales_documents (org_id, due_date) where balance_amount > 0;
create index on public.sales_documents (doc_no);

comment on column public.sales_documents.base_total_amount is
  'total_amount * exchange_rate, stored so reports avoid recomputing FX.';

-- ---------------------------------------------------------------------
-- Sales document lines
-- ---------------------------------------------------------------------
create table public.sales_document_lines (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  document_id         uuid not null references public.sales_documents (id) on delete cascade,
  line_no             integer not null,
  line_type           text not null default 'item'
                      check (line_type in ('item', 'description', 'subtotal', 'discount')),

  item_id             uuid references public.items (id) on delete set null,
  description         text not null default '',
  -- MyInvois requires a classification code on every e-Invoice line.
  classification_code text references public.ref_classification_codes (code),

  quantity            numeric(18, 4) not null default 1,
  uom_code            text references public.ref_uom_codes (code),
  unit_price          numeric(18, 4) not null default 0,

  discount_percent    numeric(9, 4) not null default 0,
  discount_amount     numeric(18, 2) not null default 0,

  tax_code_id         uuid references public.tax_codes (id),
  tax_rate            numeric(9, 4) not null default 0,
  tax_amount          numeric(18, 2) not null default 0,
  is_tax_inclusive    boolean not null default false,

  line_subtotal       numeric(18, 2) not null default 0,   -- qty * price - discount
  line_total          numeric(18, 2) not null default 0,   -- incl. tax

  -- Fulfilment tracking (quantity already delivered / invoiced downstream)
  quantity_fulfilled  numeric(18, 4) not null default 0,
  quantity_invoiced   numeric(18, 4) not null default 0,

  warehouse_id        uuid references public.warehouses (id) on delete set null,
  account_id          uuid references public.accounts (id) on delete set null,
  cost_amount         numeric(18, 2) not null default 0,   -- COGS snapshot at posting

  project_code        text,
  department_code     text,
  custom_fields       jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  unique (document_id, line_no)
);

create index on public.sales_document_lines (document_id);
create index on public.sales_document_lines (org_id, item_id);

-- ---------------------------------------------------------------------
-- Receipts (customer payments)
-- ---------------------------------------------------------------------
create table public.receipts (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  receipt_no        text not null,
  receipt_date      date not null default current_date,
  contact_id        uuid not null references public.contacts (id) on delete restrict,

  payment_mode_code text references public.ref_payment_modes (code),
  bank_account_id   uuid references public.bank_accounts (id),
  reference         text,             -- cheque no, transaction id
  cheque_date       date,

  currency          char(3) not null default 'MYR',
  exchange_rate     numeric(18, 8) not null default 1,
  amount            numeric(18, 2) not null check (amount >= 0),
  base_amount       numeric(18, 2) not null default 0,
  -- Amount not yet applied to any invoice (customer deposit / advance)
  unapplied_amount  numeric(18, 2) not null default 0,
  bank_charges      numeric(18, 2) not null default 0,
  fx_gain_loss      numeric(18, 2) not null default 0,

  status            app.doc_status not null default 'draft',
  gl_entry_id       uuid references public.gl_entries (id) on delete set null,
  posted_at         timestamptz,
  posted_by         uuid references auth.users (id),

  notes             text,
  attachments       jsonb not null default '[]'::jsonb,
  created_by        uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (org_id, receipt_no)
);

create index on public.receipts (org_id, receipt_date desc);
create index on public.receipts (org_id, contact_id);

-- Allocation of a receipt (or credit note) against invoices
create table public.payment_allocations (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  -- Exactly one source: a receipt, a supplier payment, or a credit note
  receipt_id      uuid references public.receipts (id) on delete cascade,
  payment_id      uuid,                -- refs purchase_payments, added in 0006
  credit_note_id  uuid references public.sales_documents (id) on delete cascade,
  -- Target document being settled
  invoice_id      uuid references public.sales_documents (id) on delete cascade,
  bill_id         uuid,                -- refs purchase_documents, added in 0006

  amount          numeric(18, 2) not null check (amount > 0),
  discount_amount numeric(18, 2) not null default 0,
  allocated_at    timestamptz not null default now(),
  allocated_by    uuid references auth.users (id),
  created_at      timestamptz not null default now(),

  constraint payment_allocations_source_ck check (
    num_nonnulls(receipt_id, payment_id, credit_note_id) = 1
  ),
  constraint payment_allocations_target_ck check (
    num_nonnulls(invoice_id, bill_id) = 1
  )
);

create index on public.payment_allocations (org_id, invoice_id);
create index on public.payment_allocations (receipt_id);
create index on public.payment_allocations (credit_note_id);

create trigger set_updated_at before update on public.sales_documents
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.sales_document_lines
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.receipts
  for each row execute function app.set_updated_at();

-- =====================================================================
-- iAkauntan :: 0006 purchases, inventory and banking
-- Purchase Request -> Purchase Order -> Goods Received -> Bill -> Payment
-- Stock movements with weighted average costing.
-- =====================================================================

create type app.purchase_doc_type as enum (
  'purchase_request', 'purchase_order', 'goods_received', 'bill',
  'purchase_credit_note', 'purchase_debit_note', 'purchase_return'
);

-- ---------------------------------------------------------------------
-- Purchase document header
-- ---------------------------------------------------------------------
create table public.purchase_documents (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  doc_type            app.purchase_doc_type not null,
  doc_no              text not null,
  doc_date            date not null default current_date,

  contact_id          uuid not null references public.contacts (id) on delete restrict,
  contact_person_id   uuid references public.contact_persons (id) on delete set null,

  -- Supplier's own invoice number; needed for SST and self-billed e-Invoice
  supplier_doc_no     text,
  supplier_doc_date   date,
  reference           text,
  parent_id           uuid references public.purchase_documents (id) on delete set null,
  original_bill_id    uuid references public.purchase_documents (id) on delete set null,

  due_date            date,
  expected_date       date,
  payment_term_id     uuid references public.payment_terms (id),

  currency            char(3) not null default 'MYR' references public.ref_currencies (code),
  exchange_rate       numeric(18, 8) not null default 1 check (exchange_rate > 0),

  subtotal            numeric(18, 2) not null default 0,
  discount_percent    numeric(9, 4) not null default 0,
  discount_amount     numeric(18, 2) not null default 0,
  tax_amount          numeric(18, 2) not null default 0,
  shipping_amount     numeric(18, 2) not null default 0,
  rounding_amount     numeric(18, 2) not null default 0,
  total_amount        numeric(18, 2) not null default 0,
  base_total_amount   numeric(18, 2) not null default 0,

  paid_amount         numeric(18, 2) not null default 0,
  balance_amount      numeric(18, 2) not null default 0,

  status              app.doc_status not null default 'draft',
  fulfilment_status   text not null default 'pending'
                      check (fulfilment_status in ('pending', 'partial', 'fulfilled', 'cancelled')),

  -- Self-billed e-Invoice: required when buying from foreign or
  -- non-registered suppliers under LHDN rules.
  requires_self_billed boolean not null default false,
  einvoice_id         uuid,
  einvoice_status     text not null default 'not_applicable'
                      check (einvoice_status in
                        ('not_applicable', 'pending', 'submitted', 'valid', 'invalid', 'cancelled', 'rejected')),

  gl_entry_id         uuid references public.gl_entries (id) on delete set null,
  posted_at           timestamptz,
  posted_by           uuid references auth.users (id),

  approved_by         uuid references auth.users (id),
  approved_at         timestamptz,

  notes               text,
  internal_notes      text,
  attachments         jsonb not null default '[]'::jsonb,
  custom_fields       jsonb not null default '{}'::jsonb,

  created_by          uuid references auth.users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  unique (org_id, doc_type, doc_no)
);

create index on public.purchase_documents (org_id, doc_type, doc_date desc);
create index on public.purchase_documents (org_id, contact_id);
create index on public.purchase_documents (org_id, status);
create index on public.purchase_documents (org_id, due_date) where balance_amount > 0;

-- ---------------------------------------------------------------------
-- Purchase document lines
-- ---------------------------------------------------------------------
create table public.purchase_document_lines (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  document_id         uuid not null references public.purchase_documents (id) on delete cascade,
  line_no             integer not null,
  line_type           text not null default 'item'
                      check (line_type in ('item', 'description', 'subtotal', 'discount')),

  item_id             uuid references public.items (id) on delete set null,
  description         text not null default '',
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

  line_subtotal       numeric(18, 2) not null default 0,
  line_total          numeric(18, 2) not null default 0,

  quantity_received   numeric(18, 4) not null default 0,
  quantity_billed     numeric(18, 4) not null default 0,

  warehouse_id        uuid references public.warehouses (id) on delete set null,
  account_id          uuid references public.accounts (id) on delete set null,

  project_code        text,
  department_code     text,
  custom_fields       jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (document_id, line_no)
);

create index on public.purchase_document_lines (document_id);
create index on public.purchase_document_lines (org_id, item_id);

-- ---------------------------------------------------------------------
-- Supplier payments
-- ---------------------------------------------------------------------
create table public.purchase_payments (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  payment_no        text not null,
  payment_date      date not null default current_date,
  contact_id        uuid not null references public.contacts (id) on delete restrict,

  payment_mode_code text references public.ref_payment_modes (code),
  bank_account_id   uuid references public.bank_accounts (id),
  reference         text,
  cheque_date       date,

  currency          char(3) not null default 'MYR',
  exchange_rate     numeric(18, 8) not null default 1,
  amount            numeric(18, 2) not null check (amount >= 0),
  base_amount       numeric(18, 2) not null default 0,
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
  unique (org_id, payment_no)
);

create index on public.purchase_payments (org_id, payment_date desc);
create index on public.purchase_payments (org_id, contact_id);

-- Wire up the deferred foreign keys from payment_allocations (0005).
alter table public.payment_allocations
  add constraint payment_allocations_payment_fk
    foreign key (payment_id) references public.purchase_payments (id) on delete cascade,
  add constraint payment_allocations_bill_fk
    foreign key (bill_id) references public.purchase_documents (id) on delete cascade;

create index on public.payment_allocations (org_id, bill_id) where bill_id is not null;
create index on public.payment_allocations (payment_id) where payment_id is not null;

-- ---------------------------------------------------------------------
-- Inventory movements
-- ---------------------------------------------------------------------
create type app.stock_movement_type as enum (
  'purchase_receipt', 'purchase_return', 'sales_delivery', 'sales_return',
  'adjustment_in', 'adjustment_out', 'transfer_in', 'transfer_out',
  'opening_balance', 'assembly_in', 'assembly_out', 'write_off'
);

create table public.stock_movements (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  movement_no       text not null,
  movement_date     date not null default current_date,
  movement_type     app.stock_movement_type not null,

  item_id           uuid not null references public.items (id) on delete restrict,
  warehouse_id      uuid not null references public.warehouses (id) on delete restrict,

  -- Signed: positive increases stock, negative decreases it.
  quantity          numeric(18, 4) not null,
  unit_cost         numeric(18, 6) not null default 0,
  total_cost        numeric(18, 2) not null default 0,

  -- Running snapshot after this movement, for FIFO/valuation reporting
  balance_quantity  numeric(18, 4) not null default 0,
  balance_value     numeric(18, 2) not null default 0,
  average_cost_after numeric(18, 6) not null default 0,

  source_table      text,
  source_id         uuid,
  source_line_id    uuid,

  batch_no          text,
  serial_no         text,
  expiry_date       date,

  notes             text,
  gl_entry_id       uuid references public.gl_entries (id) on delete set null,
  created_by        uuid references auth.users (id),
  created_at        timestamptz not null default now()
);

create index on public.stock_movements (org_id, item_id, movement_date);
create index on public.stock_movements (org_id, warehouse_id);
create index on public.stock_movements (source_table, source_id);

-- Denormalised per item/warehouse stock level for fast lookups
create table public.stock_levels (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  item_id         uuid not null references public.items (id) on delete cascade,
  warehouse_id    uuid not null references public.warehouses (id) on delete cascade,
  quantity        numeric(18, 4) not null default 0,
  reserved_quantity numeric(18, 4) not null default 0,
  value           numeric(18, 2) not null default 0,
  average_cost    numeric(18, 6) not null default 0,
  last_movement_at timestamptz,
  updated_at      timestamptz not null default now(),
  unique (item_id, warehouse_id)
);

create index on public.stock_levels (org_id, item_id);

-- Stock adjustments / stock takes
create table public.stock_adjustments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  adjustment_no text not null,
  adjustment_date date not null default current_date,
  warehouse_id  uuid not null references public.warehouses (id),
  reason        text,
  adjustment_type text not null default 'stock_take'
                check (adjustment_type in ('stock_take', 'write_off', 'revaluation', 'opening')),
  account_id    uuid references public.accounts (id),
  status        app.doc_status not null default 'draft',
  gl_entry_id   uuid references public.gl_entries (id) on delete set null,
  posted_at     timestamptz,
  notes         text,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, adjustment_no)
);

create table public.stock_adjustment_lines (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  adjustment_id   uuid not null references public.stock_adjustments (id) on delete cascade,
  line_no         integer not null,
  item_id         uuid not null references public.items (id) on delete restrict,
  system_quantity numeric(18, 4) not null default 0,
  counted_quantity numeric(18, 4) not null default 0,
  difference      numeric(18, 4) not null default 0,
  unit_cost       numeric(18, 6) not null default 0,
  total_cost      numeric(18, 2) not null default 0,
  notes           text,
  unique (adjustment_id, line_no)
);

-- ---------------------------------------------------------------------
-- Banking
-- ---------------------------------------------------------------------
create table public.bank_transactions (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  bank_account_id   uuid not null references public.bank_accounts (id) on delete cascade,
  transaction_date  date not null,
  value_date        date,
  description       text,
  reference         text,
  -- Signed: positive = money in, negative = money out
  amount            numeric(18, 2) not null,
  running_balance   numeric(18, 2),
  transaction_type  text not null default 'other'
                    check (transaction_type in
                      ('deposit', 'withdrawal', 'transfer', 'charge', 'interest', 'other')),

  -- Reconciliation
  is_reconciled     boolean not null default false,
  reconciled_at     timestamptz,
  reconciliation_id uuid,
  -- Link to the accounting document that explains this line
  matched_table     text,
  matched_id        uuid,

  gl_entry_id       uuid references public.gl_entries (id) on delete set null,
  import_batch_id   uuid,
  raw_data          jsonb,
  created_by        uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index on public.bank_transactions (org_id, bank_account_id, transaction_date desc);
create index on public.bank_transactions (org_id, is_reconciled);

create table public.bank_reconciliations (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  bank_account_id   uuid not null references public.bank_accounts (id) on delete cascade,
  statement_date    date not null,
  statement_balance numeric(18, 2) not null,
  book_balance      numeric(18, 2) not null default 0,
  difference        numeric(18, 2) not null default 0,
  status            text not null default 'in_progress'
                    check (status in ('in_progress', 'completed')),
  completed_at      timestamptz,
  completed_by      uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.bank_transactions
  add constraint bank_transactions_reconciliation_fk
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

-- ---------------------------------------------------------------------
-- Expense claims (common SME need, posts straight to GL)
-- ---------------------------------------------------------------------
create table public.expenses (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id) on delete cascade,
  expense_no        text not null,
  expense_date      date not null default current_date,
  contact_id        uuid references public.contacts (id) on delete set null,
  account_id        uuid not null references public.accounts (id) on delete restrict,
  bank_account_id   uuid references public.bank_accounts (id),
  payment_mode_code text references public.ref_payment_modes (code),

  description       text,
  reference         text,
  currency          char(3) not null default 'MYR',
  exchange_rate     numeric(18, 8) not null default 1,
  amount            numeric(18, 2) not null check (amount >= 0),
  tax_code_id       uuid references public.tax_codes (id),
  tax_amount        numeric(18, 2) not null default 0,
  total_amount      numeric(18, 2) not null default 0,

  is_billable       boolean not null default false,
  billed_to_id      uuid references public.contacts (id) on delete set null,
  project_code      text,

  status            app.doc_status not null default 'draft',
  gl_entry_id       uuid references public.gl_entries (id) on delete set null,
  posted_at         timestamptz,
  receipt_url       text,
  attachments       jsonb not null default '[]'::jsonb,
  created_by        uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (org_id, expense_no)
);

create index on public.expenses (org_id, expense_date desc);

create trigger set_updated_at before update on public.purchase_documents
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.purchase_document_lines
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.purchase_payments
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.stock_adjustments
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.bank_transactions
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.bank_reconciliations
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.expenses
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.stock_levels
  for each row execute function app.set_updated_at();

-- =====================================================================
-- iAkauntan :: 0021 legal firm accounting (add-on module 'legal')
--
-- Built around the Solicitors' Accounts Rules: money held for a client
-- is not the firm's money. It sits in a designated client bank account,
-- is tracked per matter, and a matter may never draw more than it holds.
-- =====================================================================

create type app.matter_status as enum
  ('open', 'on_hold', 'closed', 'archived');

create type app.client_txn_type as enum (
  'receipt',            -- money received from or for the client
  'payment',            -- paid out on the client's behalf
  'transfer_to_office', -- settling a rendered bill from client funds
  'refund',             -- returned to the client
  'transfer_in',        -- moved from another matter
  'transfer_out'
);

-- A designated client account is a bank account holding client money.
alter table public.bank_accounts
  add column if not exists is_client_account boolean not null default false;

comment on column public.bank_accounts.is_client_account is
  'Designated client account under the Solicitors Accounts Rules. Client money must never sit in an office account.';

-- ---------------------------------------------------------------------
-- Matters (files)
-- ---------------------------------------------------------------------
create table public.matters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_no text not null,
  name text not null,
  description text,
  client_id uuid not null references public.contacts (id) on delete restrict,

  matter_type text,          -- conveyancing, litigation, corporate, probate…
  practice_area text,
  court_reference text,
  opposing_party text,

  responsible_solicitor uuid references auth.users (id),
  fee_earner uuid references auth.users (id),

  status app.matter_status not null default 'open',
  opened_date date not null default current_date,
  closed_date date,

  currency char(3) not null default 'MYR',
  estimated_fees numeric(18, 2) not null default 0,
  agreed_fee numeric(18, 2),
  hourly_rate numeric(18, 2) not null default 0,
  -- Money the client is asked to place on account before work starts.
  deposit_required numeric(18, 2) not null default 0,

  notes text,
  custom_fields jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (org_id, matter_no)
);

create index on public.matters (org_id, status) where deleted_at is null;
create index on public.matters (org_id, client_id);
create index on public.matters (org_id, responsible_solicitor);

create trigger set_updated_at before update on public.matters
  for each row execute function app.set_updated_at();

-- Bills and receipts can be attributed to a matter.
alter table public.sales_documents
  add column if not exists matter_id uuid references public.matters (id) on delete set null;
create index on public.sales_documents (matter_id) where matter_id is not null;

-- ---------------------------------------------------------------------
-- Client account ledger
--
-- Every movement of client money, analysed by matter. The signed amount
-- is what the guard below sums, so a matter can never go into deficit.
-- ---------------------------------------------------------------------
create table public.client_account_transactions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid not null references public.matters (id) on delete restrict,
  transaction_no text not null,
  transaction_date date not null default current_date,
  transaction_type app.client_txn_type not null,

  bank_account_id uuid references public.bank_accounts (id),
  -- Positive increases client funds held, negative reduces them.
  amount numeric(18, 2) not null,
  currency char(3) not null default 'MYR',

  description text,
  reference text,
  payee text,
  payment_mode_code text references public.ref_payment_modes (code),

  -- Set when this movement settles a rendered bill.
  invoice_id uuid references public.sales_documents (id) on delete set null,

  status app.doc_status not null default 'draft',
  gl_entry_id uuid references public.gl_entries (id) on delete set null,
  posted_at timestamptz,
  posted_by uuid references auth.users (id),

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, transaction_no)
);

create index on public.client_account_transactions (org_id, matter_id, transaction_date);
create index on public.client_account_transactions (org_id, status);

create trigger set_updated_at before update on public.client_account_transactions
  for each row execute function app.set_updated_at();

-- The core statutory control: a matter may not spend money it does not
-- hold. Without this, one client's funds could quietly cover another's.
create or replace function app.assert_client_funds()
returns trigger language plpgsql as $$
declare
  v_matter_id uuid := coalesce(new.matter_id, old.matter_id);
  v_balance numeric(18, 2);
  v_matter_no text;
begin
  select coalesce(sum(amount), 0) into v_balance
    from public.client_account_transactions
   where matter_id = v_matter_id
     and status <> 'void';

  if v_balance < 0 then
    select matter_no into v_matter_no from public.matters where id = v_matter_id;
    raise exception
      'Client account for matter % would be overdrawn by %. Client money '
      'held for one matter cannot fund another.',
      v_matter_no, to_char(-v_balance, 'FM999999990.00')
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;

create constraint trigger assert_client_funds
  after insert or update or delete on public.client_account_transactions
  deferrable initially deferred
  for each row execute function app.assert_client_funds();

-- ---------------------------------------------------------------------
-- Time recording
-- ---------------------------------------------------------------------
create table public.time_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid not null references public.matters (id) on delete cascade,
  user_id uuid references auth.users (id),

  entry_date date not null default current_date,
  description text not null,
  activity_code text,          -- drafting, attendance, research, court…

  minutes integer not null check (minutes > 0),
  hourly_rate numeric(18, 2) not null default 0,
  amount numeric(18, 2) not null default 0,

  is_billable boolean not null default true,
  is_billed boolean not null default false,
  invoice_id uuid references public.sales_documents (id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.time_entries (org_id, matter_id, entry_date);
create index on public.time_entries (org_id, user_id, entry_date);
create index on public.time_entries (matter_id) where not is_billed and is_billable;

create trigger set_updated_at before update on public.time_entries
  for each row execute function app.set_updated_at();

-- Value the entry from its duration and rate.
create or replace function app.calc_time_entry()
returns trigger language plpgsql as $$
begin
  new.amount := round(new.minutes / 60.0 * coalesce(new.hourly_rate, 0), 2);
  return new;
end;
$$;

create trigger calc_amount before insert or update on public.time_entries
  for each row execute function app.calc_time_entry();

-- ---------------------------------------------------------------------
-- Disbursements paid on the client's behalf
-- ---------------------------------------------------------------------
create table public.disbursements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid not null references public.matters (id) on delete cascade,

  disbursement_date date not null default current_date,
  description text not null,
  supplier_id uuid references public.contacts (id) on delete set null,

  amount numeric(18, 2) not null,
  tax_amount numeric(18, 2) not null default 0,
  -- Paid from office money (recoverable) or from the client's funds.
  paid_from text not null default 'office'
             check (paid_from in ('office', 'client')),

  is_billable boolean not null default true,
  is_billed boolean not null default false,
  invoice_id uuid references public.sales_documents (id) on delete set null,

  reference text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.disbursements (org_id, matter_id);
create index on public.disbursements (matter_id) where not is_billed and is_billable;

create trigger set_updated_at before update on public.disbursements
  for each row execute function app.set_updated_at();

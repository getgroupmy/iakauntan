-- What a customer bought, and what they paid with.
--
-- ## Rounding belongs to the tender, not to the document
--
-- Bank Negara's rounding mechanism applies to the amount settled *in
-- cash*. A basket of RM10.03 is RM10.05 across the counter and RM10.03
-- on a card, and the same basket paid RM5.00 cash and the rest by card
-- rounds only the five ringgit's worth. The rule is about the coins
-- that exist, not about the invoice.
--
-- This system already rounds — `app.round_amount`, applied by the
-- totals trigger to every sales document using the *organization's*
-- rounding method. That is right for a business that settles in cash
-- and wrong for a till, because a till does not know which it is until
-- the customer decides at the moment of payment. A company set to
-- `nearest_5cent` would round a card sale by two sen and hand the
-- difference to nobody.
--
-- So the arithmetic here works the other way round: total the basket
-- exactly, subtract what is being paid by anything other than cash, and
-- round *what is left* to five sen. That number is what the drawer
-- takes. Everything else follows from it, including the change.
--
-- ## Change is not a negative tender
--
-- A customer handing over RM50 for a RM43.15 basket has tendered
-- RM50.00 and been given RM6.85. Recording it as a tender of RM43.15
-- loses the fact that a fifty went into the drawer, which is exactly
-- what the cash-up needs to know. So the tender carries both, and the
-- drawer's expectation is `amount - change_given` — which is what
-- `app.pos_expected_cash` in 0206 already reads.
--
-- Only cash gives change. A card terminal that hands back money is a
-- refund, not change, and belongs to a different act entirely.
--
-- ## A parked sale is not an order
--
-- It is a basket somebody set aside — the customer went back for milk,
-- or the queue moved on. It holds no stock, owes no money and posts
-- nothing. That is why a shift cannot close over one: it is a decision
-- nobody has made yet, and the drawer will not balance until they do.
--
-- ## The client's own id
--
-- `client_uuid` is here from the beginning rather than added when the
-- offline work arrives, because it is the only thing that can make an
-- ingest idempotent, and a column added later is a column that half the
-- rows are missing. A till generates it before it tries to send.

do $$ begin
  create type app.pos_tender_kind as enum (
    'cash', 'card', 'ewallet', 'bank_transfer', 'voucher',
    'on_account', 'loyalty');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.pos_sale_status as enum ('parked', 'completed', 'voided');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- What the till will take
-- ---------------------------------------------------------------------
create table if not exists public.pos_tender_types (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  code        text not null,
  name        text not null,
  kind        app.pos_tender_kind not null,

  -- The MyInvois payment mode this reports as. Already a reference
  -- table, already the codes LHDN expects, so a till has nothing new to
  -- learn and an e-Invoice raised from a sale says how it was paid.
  payment_mode_code text references public.ref_payment_modes(code),

  -- Where the money lands. Cash goes to the till's cash-on-hand
  -- account; a card goes to the merchant account it settles into, days
  -- later and net of fees. Pointing both at the current account is the
  -- mistake that makes a bank reconciliation impossible.
  bank_account_id uuid references public.bank_accounts(id) on delete restrict,

  -- Cash counts in the drawer and gives change. A card does neither.
  -- Held as columns rather than inferred from `kind` because a shop
  -- that takes cheques over the counter puts them in the drawer, and a
  -- voucher scheme might or might not give change depending on whose
  -- vouchers they are.
  counts_in_drawer boolean not null default false,
  gives_change     boolean not null default false,
  opens_drawer     boolean not null default false,

  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

comment on column public.pos_tender_types.gives_change is
  'Only cash gives change. A terminal handing money back is a refund, '
  'which is a different act with its own paperwork.';

-- ---------------------------------------------------------------------
-- The sale
-- ---------------------------------------------------------------------
create table if not exists public.pos_sales (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  shift_id      uuid not null references public.pos_shifts(id) on delete restrict,
  register_id   uuid not null references public.pos_registers(id) on delete restrict,
  outlet_id     uuid not null references public.pos_outlets(id) on delete restrict,

  sale_no       text not null,
  status        app.pos_sale_status not null default 'parked',

  -- Generated on the device before it tries to send. See the header.
  client_uuid   uuid,

  -- Null until somebody says who they are. Resolved to the outlet's
  -- walk-in contact when the sale completes, because a document that
  -- owes money must know who owed it.
  contact_id    uuid references public.contacts(id) on delete restrict,

  -- The basket, exactly, before anything is rounded.
  subtotal      numeric(18,2) not null default 0,
  discount_amount numeric(18,2) not null default 0,
  tax_amount    numeric(18,2) not null default 0,
  -- What five-sen rounding did to the cash portion. Zero on a card-only
  -- sale, and that is the whole point.
  rounding_amount numeric(18,2) not null default 0,
  total_amount  numeric(18,2) not null default 0,

  -- What it became. Null while parked; a real invoice and receipt the
  -- moment it completes.
  invoice_id    uuid references public.sales_documents(id) on delete restrict,
  receipt_id    uuid references public.receipts(id) on delete restrict,

  sold_by       uuid references auth.users(id) on delete set null,
  opened_at     timestamptz not null default now(),
  completed_at  timestamptz,
  voided_at     timestamptz,
  void_reason   text,

  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, sale_no),
  constraint pos_sales_completed_ck check (
    (status = 'completed') = (completed_at is not null)),
  constraint pos_sales_voided_ck check (
    (status = 'voided') = (voided_at is not null)),
  -- A completed sale is a posted invoice and a posted receipt. Anything
  -- else is a sale that took money and recorded nothing.
  constraint pos_sales_documents_ck check (
    status <> 'completed' or (invoice_id is not null and receipt_id is not null))
);

-- One sale per client id, so a till that sends twice lands once. Partial
-- because a sale rung up on a connected register never generates one.
create unique index if not exists pos_sales_client_uuid_idx
  on public.pos_sales (org_id, client_uuid) where client_uuid is not null;

create index if not exists pos_sales_shift_idx
  on public.pos_sales (shift_id, status);
create index if not exists pos_sales_org_idx
  on public.pos_sales (org_id, opened_at desc);

create table if not exists public.pos_sale_lines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  sale_id     uuid not null references public.pos_sales(id) on delete cascade,
  line_no     integer not null,

  item_id     uuid references public.items(id) on delete restrict,
  description text not null default '',
  quantity    numeric(18,4) not null default 1,
  uom_code    text references public.ref_uom_codes(code),
  unit_price  numeric(18,4) not null default 0,

  discount_percent numeric(9,4) not null default 0,
  discount_amount  numeric(18,2) not null default 0,

  tax_code_id uuid references public.tax_codes(id),
  tax_rate    numeric(9,4) not null default 0,
  tax_amount  numeric(18,2) not null default 0,
  -- Whether `unit_price` already contains the tax. Copied from the
  -- outlet at the moment the line is rung up rather than read from it
  -- later, because a shop that switches to tax-inclusive pricing must
  -- not retrospectively change what yesterday's customer was charged.
  is_tax_inclusive boolean not null default false,

  line_subtotal numeric(18,2) not null default 0,
  line_total    numeric(18,2) not null default 0,

  warehouse_id uuid references public.warehouses(id) on delete set null,
  note         text,
  created_at   timestamptz not null default now(),
  unique (sale_id, line_no)
);

create index if not exists pos_sale_lines_sale_idx on public.pos_sale_lines (sale_id);

create table if not exists public.pos_tenders (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id) on delete cascade,
  sale_id        uuid not null references public.pos_sales(id) on delete cascade,
  tender_type_id uuid references public.pos_tender_types(id) on delete restrict,

  -- Copied rather than joined, because a shop that retires a tender
  -- type must not change what last month's drawer was counted against.
  kind           app.pos_tender_kind not null,

  -- What the customer handed over, and what they got back. See the
  -- header: recording only the net loses the fifty that went in.
  amount         numeric(18,2) not null,
  change_given   numeric(18,2) not null default 0,

  -- Terminal approval code, e-wallet transaction id, voucher serial.
  reference      text,
  created_at     timestamptz not null default now(),

  constraint pos_tenders_amount_ck check (amount > 0),
  constraint pos_tenders_change_ck check (change_given >= 0),
  -- Change can never exceed what was handed over.
  constraint pos_tenders_net_ck check (change_given <= amount)
);

create index if not exists pos_tenders_sale_idx on public.pos_tenders (sale_id);

-- ---------------------------------------------------------------------
-- What the drawer should be asked for
-- ---------------------------------------------------------------------
--
-- The whole rounding rule in one function, so there is one place to
-- argue with.
--
--   p_total      the basket, exact, to the sen
--   p_non_cash   what is being settled by card, wallet, voucher, credit
--   p_round      whether this company rounds at all
--
-- Returns the cash to collect, rounded to the nearest five sen. Never
-- negative: a customer who has already covered the basket by card owes
-- no cash, and a non-cash tender larger than the basket is an
-- over-payment to be refunded rather than a negative demand for coins.
create or replace function app.pos_cash_due(
  p_total    numeric,
  p_non_cash numeric default 0,
  p_round    boolean default true)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when greatest(coalesce(p_total, 0) - coalesce(p_non_cash, 0), 0) = 0 then 0
    when coalesce(p_round, true)
      -- 5 sen: multiply by 20, round, divide back. The same mechanism
      -- app.round_amount uses, applied to a different number.
      then round(greatest(p_total - coalesce(p_non_cash, 0), 0) * 20) / 20
    else round(greatest(p_total - coalesce(p_non_cash, 0), 0), 2)
  end;
$$;

grant execute on function app.pos_cash_due(numeric, numeric, boolean) to authenticated;

-- What rounding did, which is what gets posted to the rounding account.
-- Positive means the customer paid more than the basket; negative less.
create or replace function app.pos_rounding_adjustment(
  p_total    numeric,
  p_non_cash numeric default 0,
  p_round    boolean default true)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select round(
    app.pos_cash_due(p_total, p_non_cash, p_round)
      - greatest(coalesce(p_total, 0) - coalesce(p_non_cash, 0), 0), 2);
$$;

grant execute on function app.pos_rounding_adjustment(numeric, numeric, boolean)
  to authenticated;

comment on function app.pos_cash_due(numeric, numeric, boolean) is
  'The coins to collect: the basket less anything settled by other '
  'means, rounded to five sen. Rounding belongs to the cash and not to '
  'the document — the same basket is 10.05 across the counter and 10.03 '
  'on a card.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_tender_types enable row level security;
alter table public.pos_sales        enable row level security;
alter table public.pos_sale_lines   enable row level security;
alter table public.pos_tenders      enable row level security;

create policy pos_tender_types_read on public.pos_tender_types for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_tender_types_write on public.pos_tender_types for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- A sale, its lines and its tenders are read-only to the API for the
-- same reason a shift is: they are written by functions that check a
-- drawer is open, price the line and prove the money adds up. A client
-- that could insert its own tender could tell the drawer it had been
-- paid.
create policy pos_sales_read on public.pos_sales for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_sale_lines_read on public.pos_sale_lines for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_tenders_read on public.pos_tenders for select
  using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_tender_types to authenticated;
grant select on public.pos_sales      to authenticated;
grant select on public.pos_sale_lines to authenticated;
grant select on public.pos_tenders    to authenticated;

create trigger set_updated_at before update on public.pos_tender_types
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_sales
  for each row execute function app.set_updated_at();

comment on table public.pos_sales is
  'One customer at one till. Parked means a basket set aside — it holds '
  'no stock and owes nothing. Completed means a posted invoice and a '
  'posted receipt exist, which the check constraint insists on: '
  'anything else is a sale that took money and recorded nothing.';

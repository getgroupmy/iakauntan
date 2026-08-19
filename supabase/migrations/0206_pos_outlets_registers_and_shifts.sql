-- Selling across a counter.
--
-- Everything this system does with a sale assumes somebody typed it
-- afterwards: an invoice is raised, sent, and settled days later by a
-- payment that has to be matched back. A shop does the opposite. The
-- money arrives first, the customer leaves, and the paperwork has to
-- have happened already.
--
-- ## What a point of sale actually is, here
--
-- Not a new ledger. A till that produces the documents this database
-- already understands — an invoice and a receipt against it — at the
-- moment the customer pays, rather than a parallel set of books that
-- has to be reconciled to them later. Every report already written
-- (ageing, revenue, SST, the trial balance) then includes the shop
-- without knowing there is one.
--
-- That decision is the whole design. It is why there is no
-- `pos_journal`, no nightly export, and no "sync to accounting" step to
-- get wrong.
--
-- ## Three things, and they are not the same thing
--
--   outlet    a place that trades. Has an address on the receipt, a
--             warehouse the stock leaves from, and a business type.
--   register  a till inside an outlet. A counter terminal, a tablet, a
--             phone in an apron, a kiosk in a doorway.
--   shift     one person's custody of one drawer, from the float they
--             counted in to the cash they counted out.
--
-- Conflating the register and the shift is the common mistake and it
-- costs you the only question the drawer is for: *who* was short, and
-- when. Two people on one till across a day is one register and two
-- shifts.
--
-- ## A shift is not an accounting period
--
-- It reconciles cash. It does not post anything, and closing one does
-- not release the day's takings into the ledger — the sales already
-- did that, one at a time, as they happened. What a close produces is
-- the difference between what the drawer should hold and what somebody
-- counted, which is a fact about a person rather than about revenue.
--
-- Building it the other way round — batch the day, post at close — is
-- how a shop ends up unable to answer "what did we sell at 11am" and
-- unable to close because one sale in the batch will not post.
--
-- ## Business type belongs to the outlet
--
-- Not to the company. A hotel runs a restaurant, a spa and a gift shop
-- under one registration, and they are three different tills with three
-- different screens. Putting the type on the company forces such a
-- business into three companies, which is a lie about who they are and
-- breaks their consolidated accounts.
--
-- ## The walk-in
--
-- `sales_documents.contact_id` is not null, and rightly: a document
-- that owes money must know who owes it. But most shop sales are to
-- somebody who will never be a contact, and creating a row per stranger
-- would turn the customer list into a receipt log.
--
-- So each outlet names one contact to bill anonymous sales to. It is an
-- ordinary contact, so the ageing and the ledger need no special case,
-- and the moment a buyer gives a name or a TIN the sale is billed to
-- them instead.

-- ---------------------------------------------------------------------
-- The vocabulary
-- ---------------------------------------------------------------------
do $$ begin
  create type app.pos_business_type as enum (
    'retail',          -- clothing, electronics, convenience
    'food_beverage',   -- sit-down, cafe, quick service
    'mobile',          -- food truck, market stall, delivery
    'service',         -- salon, spa, gym
    'kiosk'            -- the customer serves themselves
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.pos_shift_status as enum ('open', 'counting', 'closed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- A place that trades
-- ---------------------------------------------------------------------
create table if not exists public.pos_outlets (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  code          text not null,
  name          text not null,

  business_type app.pos_business_type not null default 'retail',

  -- Where the stock leaves from. Not optional in spirit: a till that
  -- sells from "the company" cannot tell you what is on its own
  -- shelves, and 0205 has just made forecasting per location reachable
  -- precisely so a shop can be asked what it is running out of.
  warehouse_id  uuid references public.warehouses(id) on delete restrict,

  -- A branch registered in its own right prints its own registration
  -- number on the receipt. Null means the company's own.
  branch_id     uuid references public.branches(id) on delete set null,

  -- Who anonymous sales are billed to. See the header.
  walk_in_contact_id uuid references public.contacts(id) on delete restrict,

  -- What the customer reads at the top and bottom of the slip.
  receipt_header text,
  receipt_footer text,

  -- The lines on the price tags. Malaysian retail quotes tax-inclusive
  -- prices and Malaysian wholesale does not, and getting this wrong
  -- overcharges or undercharges by the SST rate on every sale.
  prices_include_tax boolean not null default true,

  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (org_id, code)
);

create index if not exists pos_outlets_org_idx
  on public.pos_outlets (org_id) where deleted_at is null;

-- ---------------------------------------------------------------------
-- A till inside it
-- ---------------------------------------------------------------------
create table if not exists public.pos_registers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  outlet_id   uuid not null references public.pos_outlets(id) on delete cascade,
  code        text not null,
  name        text not null,

  -- What this till is, when it is not simply what the outlet is. A
  -- kiosk in the corner of a restaurant is a kiosk; the counter beside
  -- it is not.
  business_type app.pos_business_type,

  -- Free text about the hardware, for the person who has to find it:
  -- "front counter, left" beats a uuid when a drawer will not open.
  device_note text,

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (org_id, code)
);

create index if not exists pos_registers_outlet_idx
  on public.pos_registers (org_id, outlet_id) where deleted_at is null;

comment on column public.pos_registers.business_type is
  'Overrides the outlet''s type for this till. Null means "whatever the '
  'outlet is", which is the answer for every register in a shop that '
  'only does one thing.';

-- ---------------------------------------------------------------------
-- One person's custody of one drawer
-- ---------------------------------------------------------------------
create table if not exists public.pos_shifts (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id) on delete cascade,
  register_id    uuid not null references public.pos_registers(id) on delete restrict,

  shift_no       text not null,
  status         app.pos_shift_status not null default 'open',

  opened_by      uuid references auth.users(id) on delete set null,
  opened_at      timestamptz not null default now(),
  -- Counted, not assumed. A float nobody counted is a variance nobody
  -- can explain.
  opening_float  numeric(18,2) not null default 0,

  closed_by      uuid references auth.users(id) on delete set null,
  closed_at      timestamptz,

  -- What the person counted out of the drawer.
  declared_cash  numeric(18,2),
  -- What the sales say should have been in it: float plus cash taken
  -- less cash paid out and change given. Written at close from the
  -- tenders rather than accumulated as they happen, for the same
  -- reason 0081 derives transfer progress — a running total is wrong
  -- the moment a sale is voided.
  expected_cash  numeric(18,2),
  -- declared - expected. Positive is over, negative is short. Stored
  -- rather than computed on read so the number somebody signed off on
  -- is the number that stays.
  variance       numeric(18,2),

  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  unique (org_id, shift_no),
  constraint pos_shifts_float_ck check (opening_float >= 0),
  -- A closed shift has been counted; an open one has not.
  constraint pos_shifts_closed_ck check (
    (status = 'closed') = (closed_at is not null)),
  constraint pos_shifts_counted_ck check (
    status <> 'closed' or declared_cash is not null)
);

-- The question the till asks on every single action: is there a shift
-- open on this register, and which one.
create unique index if not exists pos_shifts_one_open_per_register
  on public.pos_shifts (register_id) where status <> 'closed';

create index if not exists pos_shifts_org_idx
  on public.pos_shifts (org_id, opened_at desc);

comment on index public.pos_shifts_one_open_per_register is
  'One drawer, one person, one shift. Two open shifts on a till make '
  'the variance meaningless because neither person can be asked about '
  'it, so the database refuses rather than the screen remembering to.';

-- ---------------------------------------------------------------------
-- What the company has decided about selling
-- ---------------------------------------------------------------------
create table if not exists public.pos_settings (
  org_id                uuid primary key
                          references public.organizations(id) on delete cascade,

  -- Bank Negara's rounding mechanism, which applies to the *cash*
  -- total and not to the card total. A basket of 10.03 is 10.05 in
  -- cash and 10.03 on a card, and a system that rounds the invoice
  -- rather than the tender charges the wrong customer the wrong two
  -- sen every time. The arithmetic lives in the next migration; this
  -- is the switch that says whether to do it at all.
  round_cash_to_5sen    boolean not null default true,

  -- Whether a till may sell stock it does not have. A supermarket says
  -- no; a food truck that has not counted its buns says yes, and would
  -- rather take the money than argue with the customer.
  allow_negative_stock  boolean not null default false,

  -- How long a parked sale survives before it is somebody's problem.
  park_expiry_hours     integer not null default 24,

  -- Whether a shift may close with a variance, and how big before
  -- somebody senior has to say so. Null means never blocked.
  variance_tolerance    numeric(18,2),

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint pos_settings_park check (park_expiry_hours between 1 and 720),
  constraint pos_settings_tolerance check (
    variance_tolerance is null or variance_tolerance >= 0)
);

-- ---------------------------------------------------------------------
-- Who may look, and who may sell
-- ---------------------------------------------------------------------
alter table public.pos_outlets   enable row level security;
alter table public.pos_registers enable row level security;
alter table public.pos_shifts    enable row level security;
alter table public.pos_settings  enable row level security;

create policy pos_outlets_read on public.pos_outlets for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_outlets_write on public.pos_outlets for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_registers_read on public.pos_registers for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_registers_write on public.pos_registers for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_settings_read on public.pos_settings for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_settings_write on public.pos_settings for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Shifts are read-only to the API. A drawer is opened and closed
-- through functions that count what is in it; letting the client write
-- the row directly would let it write its own variance, which is the
-- one number the whole record exists to protect.
create policy pos_shifts_read on public.pos_shifts for select
  using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_outlets   to authenticated;
grant select, insert, update, delete on public.pos_registers to authenticated;
grant select, insert, update, delete on public.pos_settings  to authenticated;
grant select                         on public.pos_shifts    to authenticated;

create trigger set_updated_at before update on public.pos_outlets
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_registers
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_shifts
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.pos_settings
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('pos', 'Point of Sale',
   'Sell across a counter, from a tablet, out of a van or from a kiosk: '
   'registers and cash-up shifts, tender and change with Bank Negara '
   'rounding, and every sale landing as a real invoice and receipt in '
   'the same ledger as the rest of the business rather than a till roll '
   'somebody keys in afterwards',
   false, 79, 20)
on conflict (code) do nothing;

comment on table public.pos_outlets is
  'A place that trades. Carries the warehouse stock leaves from, the '
  'business type that decides what the till looks like, and the contact '
  'anonymous sales are billed to.';

comment on table public.pos_shifts is
  'One person''s custody of one drawer. Reconciles cash and posts '
  'nothing — the sales posted themselves as they happened, so a close '
  'that fails cannot strand a day''s revenue.';

-- ---------------------------------------------------------------------
-- What a till's paperwork is called
-- ---------------------------------------------------------------------
--
-- Restated from the definition that is *current* — 0133's, which is the
-- one running in production — and not from 0009's, which is where the
-- function was born.
--
-- That distinction cost a build. "Restate in full rather than patch" is
-- the right practice and it is only half the rule: the base has to be
-- the newest version. Eight migrations have touched this `case` since
-- 0009, and a restatement from the original silently dropped three arms
-- that 0099, 0101 and 0133 had added — `withholding`, `bank_transfer`
-- and `manufacturing_order`. A diff against 0009 showed exactly the two
-- additions I expected, which is precisely why it was reassuring and
-- wrong.
--
-- What that would have done is worse than it looks. Nothing already
-- numbered would move, because a prefix is copied into
-- `number_sequences` the first time a type is used. But the next
-- company to raise its first withholding certificate would have got
-- `WIT-` instead of `WHT-`, and kept it forever, and nothing would have
-- said so.
--
-- The gate that caught it was the search_path one, which this
-- restatement had also reverted — 0159 pinned every function and 0009
-- predates it. It caught the right file for the wrong reason. The
-- md5 body check I use to verify restatements cannot see `proconfig` at
-- all, and would have been just as blind to the lost arms had I run it
-- against 0009 rather than against production.
--
-- ## Why the two POS types need naming at all
--
-- Without them both fall to the `else`, which takes the first three
-- letters: a shift and a sale would both be numbered `POS-`, from two
-- different sequences, and the two series would interleave on screen
-- with no way to tell which was which.
create or replace function app.default_doc_prefix(p_doc_type text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    when 'contact'              then 'C-'
    when 'item'                 then 'I-'
    when 'withholding'          then 'WHT-'
    when 'bank_transfer'        then 'TRF-'
    when 'manufacturing_order'  then 'MO-'
    when 'pos_shift'            then 'SH-'
    when 'pos_sale'             then 'POS-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- Opening a drawer
-- ---------------------------------------------------------------------
--
-- Takes the float as an argument because it is a count, not a
-- carry-forward. The previous shift's closing cash is not this shift's
-- opening float — somebody banked it, or took it home, or left it in
-- and counted it again — and assuming otherwise manufactures a variance
-- on the first sale of the day.
create or replace function public.open_pos_shift(
  p_register uuid,
  p_float    numeric default 0,
  p_notes    text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   uuid;
  v_shift uuid;
  v_no    text;
begin
  select r.org_id into v_org
    from public.pos_registers r
   where r.id = p_register and r.deleted_at is null and r.is_active;
  if v_org is null then
    raise exception 'That register does not exist, or has been retired.'
      using errcode = 'P0002';
  end if;

  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to open a till for this organization'
      using errcode = '42501';
  end if;

  if p_float < 0 then
    raise exception 'A float cannot be negative.' using errcode = '23514';
  end if;

  -- Said plainly rather than left to the unique index, because "duplicate
  -- key value violates constraint pos_shifts_one_open_per_register" is
  -- not something to show somebody holding a queue of customers.
  if exists (select 1 from public.pos_shifts s
              where s.register_id = p_register and s.status <> 'closed') then
    raise exception
      'This till already has a shift open. Close it before starting another.'
      using errcode = '23505';
  end if;

  v_no := app.next_document_number_internal(v_org, 'pos_shift');

  insert into public.pos_shifts
    (org_id, register_id, shift_no, status, opened_by, opening_float, notes)
  values
    (v_org, p_register, v_no, 'open', auth.uid(), p_float, p_notes)
  returning id into v_shift;

  return v_shift;
end;
$$;

revoke all on function public.open_pos_shift(uuid, numeric, text) from public, anon;
grant execute on function public.open_pos_shift(uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- What the drawer should hold
-- ---------------------------------------------------------------------
--
-- Derived from the shift's own cash tenders every time it is asked,
-- never accumulated. A counter incremented per sale is wrong the moment
-- one is voided, and a shift that cannot be trusted to say what it
-- expects is a shift whose variance means nothing.
--
-- Returns the float alone until there is anything to add to it, which
-- is the correct answer for a till that has opened and not yet sold.
--
-- The tenders themselves arrive in the next migration; this reads a
-- table that does not exist yet, so it is written to survive that:
-- `to_regclass` is null until `pos_tenders` is created, and until then
-- the expected cash is the float. That is not a placeholder — it is the
-- true answer for a database where no sale can yet have been made.
create or replace function app.pos_expected_cash(p_shift uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_float numeric;
  v_cash  numeric := 0;
begin
  select s.opening_float into v_float
    from public.pos_shifts s where s.id = p_shift;
  if v_float is null then
    return null;
  end if;

  if to_regclass('public.pos_tenders') is not null then
    execute
      'select coalesce(sum(t.amount - t.change_given), 0)
         from public.pos_tenders t
         join public.pos_sales sa on sa.id = t.sale_id
        where sa.shift_id = $1
          and t.kind = ''cash''
          and sa.status = ''completed'''
      into v_cash using p_shift;
  end if;

  return round(v_float + coalesce(v_cash, 0), 2);
end;
$$;

revoke all on function app.pos_expected_cash(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Closing it
-- ---------------------------------------------------------------------
--
-- The declared figure is what somebody counted, and it is required.
-- A close that lets the counted cash default to the expected cash is a
-- close that always balances, which is worse than no cash control at
-- all because it looks like one.
create or replace function public.close_pos_shift(
  p_shift    uuid,
  p_declared numeric,
  p_notes    text default null)
returns table (
  expected_cash numeric,
  declared_cash numeric,
  variance      numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org       uuid;
  v_status    app.pos_shift_status;
  v_expected  numeric;
  v_variance  numeric;
  v_tolerance numeric;
  v_open      integer;
begin
  select s.org_id, s.status into v_org, v_status
    from public.pos_shifts s where s.id = p_shift;
  if v_org is null then
    raise exception 'No such shift.' using errcode = 'P0002';
  end if;

  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to close a till for this organization'
      using errcode = '42501';
  end if;

  if v_status = 'closed' then
    raise exception 'That shift was already closed.' using errcode = '23514';
  end if;

  if p_declared is null or p_declared < 0 then
    raise exception
      'Count the drawer. A shift cannot be closed without a figure.'
      using errcode = '23514';
  end if;

  -- A sale left parked is a customer's shopping still on the screen and
  -- possibly their money in the drawer. Closing over it loses both.
  if to_regclass('public.pos_sales') is not null then
    execute
      'select count(*) from public.pos_sales
        where shift_id = $1 and status = ''parked'''
      into v_open using p_shift;
    if coalesce(v_open, 0) > 0 then
      raise exception
        '% sale(s) are still parked on this till. Finish or void them '
        'before closing.', v_open
        using errcode = '23514';
    end if;
  end if;

  v_expected := app.pos_expected_cash(p_shift);
  v_variance := round(p_declared - v_expected, 2);

  select ps.variance_tolerance into v_tolerance
    from public.pos_settings ps where ps.org_id = v_org;

  if v_tolerance is not null and abs(v_variance) > v_tolerance
     and not app.can_admin(v_org) then
    raise exception
      'The drawer is out by %. Only a manager can close a shift more '
      'than % out.', v_variance, v_tolerance
      using errcode = '42501';
  end if;

  update public.pos_shifts s
     set status = 'closed',
         closed_by = auth.uid(),
         closed_at = now(),
         declared_cash = p_declared,
         expected_cash = v_expected,
         variance = v_variance,
         notes = coalesce(p_notes, s.notes)
   where s.id = p_shift;

  expected_cash := v_expected;
  declared_cash := p_declared;
  variance := v_variance;
  return next;
end;
$$;

revoke all on function public.close_pos_shift(uuid, numeric, text) from public, anon;
grant execute on function public.close_pos_shift(uuid, numeric, text) to authenticated;

comment on function public.open_pos_shift(uuid, numeric, text) is
  'Opens a drawer with a counted float. The previous shift''s closing '
  'cash is deliberately not carried forward: somebody banked it, or did '
  'not, and assuming manufactures a variance on the first sale.';

comment on function public.close_pos_shift(uuid, numeric, text) is
  'Counts a drawer out. The declared figure is required — a close that '
  'defaults it to the expected cash always balances, which looks like '
  'cash control and is not.';

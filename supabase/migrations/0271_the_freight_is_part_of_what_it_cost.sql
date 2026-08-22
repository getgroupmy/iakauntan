-- =====================================================================
-- The freight is part of what it cost
--
-- An importer pays for the goods on one invoice and for getting them
-- here on three or four others: ocean freight, insurance, customs duty,
-- port charges, the forwarder's fee. Every one of those is part of what
-- the stock cost, and until they are on it the gross margin is wrong in
-- both directions -- the cost of sales is understated by the freight and
-- the operating expenses are overstated by exactly the same money.
--
-- A landed cost run is the correction. It names some posted bills, some
-- charges, and how to spread them; it adds the money to the stock and
-- takes it back off the account the charge was coded to.
--
-- ---------------------------------------------------------------------
-- Value with no quantity
--
-- Nothing arrives. The shelf holds what it held and it is worth more
-- than it was, so `app.apply_stock_movement` -- which has derived a
-- movement's value from quantity times unit cost since 0009 -- needs
-- one arm where the money is the input and the quantity is nil. That is
-- the whole mechanical change; the weighted average then rises by
-- itself, and every later sale of the item costs correctly without
-- anything else knowing this happened.
--
-- ---------------------------------------------------------------------
-- What has already been sold cannot be capitalised
--
-- A freight invoice arrives in March for goods received in January, and
-- half of them are gone. The half still on the shelf takes its share of
-- the freight; the half that was sold cannot, because the sale is
-- posted and its cost is history. That money stays on the expense
-- account it was coded to, which is where it belongs -- it was a cost of
-- the goods that were sold, and it is sitting in the profit and loss of
-- the period they were sold in.
--
-- So each allocation is apportioned by the basis and then pro-rated by
-- what is left on hand. `landed_cost_allocations` records both numbers,
-- because the difference between them is a question somebody will ask.
--
-- ---------------------------------------------------------------------
-- Two bases, not three
--
-- By value and by quantity. AutoCount offers weight and volume too, and
-- `items` has no weight or volume column, so offering them would mean
-- a picker whose answer is always zero. When a weight column exists the
-- basis enum takes another value and the apportioning function takes
-- another branch; until then this says what it can actually do.
-- =====================================================================

-- A landed cost movement is its own kind of thing on a stock card, and
-- the literal is resolved when the functions below run -- which is after
-- this migration has committed. Same reason 0133 gives.
alter type app.stock_movement_type add value if not exists 'landed_cost';

create type app.landed_cost_status as enum ('draft', 'posted', 'cancelled');
create type app.landed_cost_basis  as enum ('value', 'quantity');

-- ---------------------------------------------------------------------
-- Where a charge comes off, when nobody says
-- ---------------------------------------------------------------------
--
-- `5400 Freight and Import Duty` has been in the seeded chart since
-- 0071 with nothing ever posting to it. This is what it was for.
create or replace function app.landed_cost_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5400' and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5400', 'Freight and Import Duty', 'expense',
          'cost_of_sales', false, true, 5400,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app.landed_cost_account(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Its own number series
-- ---------------------------------------------------------------------
--
-- Re-created from 0265, which is the last migration to define it, with
-- one line added. The fallback would have given 'LAN-'.
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
    when 'stock_transfer'       then 'STN-'
    when 'landed_cost'          then 'LC-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------
create table public.landed_cost_runs (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  run_no       text not null,
  run_date     date not null default current_date,
  status       app.landed_cost_status not null default 'draft',
  notes        text,

  gl_entry_id  uuid references public.gl_entries(id),
  posted_at    timestamptz,
  posted_by    uuid references auth.users(id),
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (org_id, run_no)
);

-- Which bills the charges are being spread over. Several, because one
-- container holds three suppliers' goods and one bill of lading covers
-- all of it.
create table public.landed_cost_targets (
  id       uuid primary key default gen_random_uuid(),
  org_id   uuid not null references public.organizations(id) on delete cascade,
  run_id   uuid not null references public.landed_cost_runs(id) on delete cascade,
  bill_id  uuid not null references public.purchase_documents(id)
             on delete restrict,
  unique (run_id, bill_id)
);

-- What is being spread. Each charge names the account it comes off,
-- because freight, duty and insurance are three different accounts and
-- a run that relieved one of them for all three would be a lie in the
-- profit and loss.
create table public.landed_cost_charges (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  run_id       uuid not null references public.landed_cost_runs(id) on delete cascade,
  line_no      integer not null,
  description  text not null,
  amount       numeric(18, 2) not null check (amount > 0),
  basis        app.landed_cost_basis not null default 'value',
  account_id   uuid not null references public.accounts(id),

  -- The bill the charge itself came in on, when there was one. Kept for
  -- the trail, not used in the arithmetic: the money is already in the
  -- ledger by the time a run touches it.
  source_bill_id uuid references public.purchase_documents(id),
  unique (run_id, line_no)
);

-- What each goods line ended up carrying. Written at posting, and the
-- reason the run can be explained afterwards.
create table public.landed_cost_allocations (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  run_id        uuid not null references public.landed_cost_runs(id) on delete cascade,
  bill_id       uuid not null references public.purchase_documents(id),
  bill_line_id  uuid not null references public.purchase_document_lines(id)
                  on delete cascade,
  item_id       uuid not null references public.items(id),
  warehouse_id  uuid not null references public.warehouses(id),

  -- The line's share of the charges, before anything is asked about
  -- what is left on the shelf.
  amount        numeric(18, 2) not null,

  -- And how much of that share actually went onto stock. The difference
  -- is the freight on goods already sold, which stays on the expense
  -- account it was coded to.
  capitalised   numeric(18, 2) not null default 0,
  on_hand       numeric(18, 4) not null default 0,
  received      numeric(18, 4) not null default 0,

  movement_id   uuid references public.stock_movements(id),
  created_at    timestamptz not null default now()
);

create index landed_cost_runs_org_idx        on public.landed_cost_runs (org_id, run_date desc);
create index landed_cost_targets_run_idx     on public.landed_cost_targets (run_id);
create index landed_cost_targets_bill_idx    on public.landed_cost_targets (bill_id);
create index landed_cost_charges_run_idx     on public.landed_cost_charges (run_id);
create index landed_cost_allocations_run_idx on public.landed_cost_allocations (run_id);
create index landed_cost_allocations_line_idx
  on public.landed_cost_allocations (bill_line_id);

create trigger landed_cost_runs_touch before update on public.landed_cost_runs
  for each row execute function app.set_updated_at();

comment on table public.landed_cost_runs is
  'Freight, duty and insurance being put onto the cost of the goods they brought in.';
comment on column public.landed_cost_allocations.capitalised is
  'How much of this line''s share actually went onto stock. Lower than amount when some of the goods had already been sold, and the difference stays on the expense account the charge was coded to.';

-- ---------------------------------------------------------------------
-- Value with no quantity
-- ---------------------------------------------------------------------
--
-- Re-created from 0009, which is the only migration that has ever
-- defined it, with one arm added. Everything else is carried across
-- unchanged and deliberately: this function is the whole of weighted
-- average costing, and a replacement that quietly dropped a line of it
-- would be wrong in every stock figure in the system.
create or replace function app.apply_stock_movement()
returns trigger
language plpgsql
-- 0023 swept a pinned search_path onto every function that existed
-- then, and re-creating one drops what the sweep applied.
set search_path = public, pg_temp
as $$
declare
  v_level     public.stock_levels;
  v_old_qty   numeric(18, 4) := 0;
  v_old_value numeric(18, 2) := 0;
  v_old_avg   numeric(18, 6) := 0;
  v_new_qty   numeric(18, 4);
  v_new_value numeric(18, 2);
  v_new_avg   numeric(18, 6);
  v_cost      numeric(18, 2);
begin
  insert into public.stock_levels (org_id, item_id, warehouse_id)
  values (new.org_id, new.item_id, new.warehouse_id)
  on conflict (item_id, warehouse_id) do nothing;

  select * into v_level
    from public.stock_levels
   where item_id = new.item_id and warehouse_id = new.warehouse_id
   for update;

  v_old_qty   := coalesce(v_level.quantity, 0);
  v_old_value := coalesce(v_level.value, 0);
  v_old_avg   := coalesce(v_level.average_cost, 0);

  if new.movement_type = 'landed_cost' then
    -- 0271. Nothing arrives and the shelf is worth more. This is the
    -- one movement where the money is the input rather than the
    -- product of quantity and unit cost, so total_cost is read as the
    -- caller wrote it.
    v_cost      := round(coalesce(new.total_cost, 0), 2);
    v_new_qty   := v_old_qty;
    v_new_value := v_old_value + v_cost;
  elsif new.quantity >= 0 then
    -- Inbound: unit_cost comes from the source document.
    v_cost      := round(new.quantity * new.unit_cost, 2);
    v_new_qty   := v_old_qty + new.quantity;
    v_new_value := v_old_value + v_cost;
  else
    -- Outbound: valued at the current weighted average.
    if new.unit_cost = 0 then
      new.unit_cost := v_old_avg;
    end if;
    v_cost      := round(new.quantity * new.unit_cost, 2);   -- negative
    v_new_qty   := v_old_qty + new.quantity;
    v_new_value := v_old_value + v_cost;
  end if;

  -- Guard against a negative valuation when stock runs to zero.
  if v_new_qty = 0 then
    v_new_value := 0;
    v_new_avg   := v_old_avg;
  else
    v_new_avg := round(v_new_value / v_new_qty, 6);
  end if;

  new.total_cost         := v_cost;
  new.balance_quantity   := v_new_qty;
  new.balance_value      := v_new_value;
  new.average_cost_after := v_new_avg;

  update public.stock_levels
     set quantity = v_new_qty,
         value = v_new_value,
         average_cost = v_new_avg,
         last_movement_at = now()
   where id = v_level.id;

  -- Roll the per-warehouse figures up onto the item.
  update public.items i
     set quantity_on_hand = (
           select coalesce(sum(sl.quantity), 0)
             from public.stock_levels sl where sl.item_id = i.id),
         average_cost = (
           select case when coalesce(sum(sl.quantity), 0) = 0 then i.average_cost
                       else round(sum(sl.value) / sum(sl.quantity), 6) end
             from public.stock_levels sl where sl.item_id = i.id)
   where i.id = new.item_id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- A movement of nothing has no units to name
-- ---------------------------------------------------------------------
--
-- `app.materialise_movement_lots` raises for a tracked item on a source
-- it does not recognise, which is the invariant that has caught three
-- real bugs and should stay exactly that strict. A landed cost movement
-- is not a new source to teach it about, though -- it moves no units, so
-- there is nothing to allocate under any rule.
--
-- The condition therefore goes on the trigger rather than into the
-- function: re-copying two hundred lines of lot arithmetic to add an
-- early return is how 0267 silently reverted 0152. `quantity <> 0` says
-- the same thing without touching any of it, and the deferred
-- constraint trigger still checks that what was named adds up to what
-- moved -- nil to nil.
drop trigger if exists stock_movements_lots_1_materialise
  on public.stock_movements;
create trigger stock_movements_lots_1_materialise
  after insert on public.stock_movements
  for each row when (new.quantity <> 0)
  execute function app.materialise_movement_lots();

-- ---------------------------------------------------------------------
-- Writing one down
-- ---------------------------------------------------------------------
create or replace function public.upsert_landed_cost_run(
  p_id      uuid,
  p_org     uuid,
  p_date    date,
  p_bills   jsonb,
  p_charges jsonb,
  p_notes   text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id   uuid := p_id;
  v_row  public.landed_cost_runs;
  v_e    jsonb;
  v_n    integer := 0;
  v_bill public.purchase_documents;
  v_acct uuid;
begin
  if not app.can_write_module(p_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;

  if v_id is not null then
    select * into v_row from public.landed_cost_runs where id = v_id;
    if v_row.id is null or v_row.org_id <> p_org then
      raise exception 'No such landed cost run.' using errcode = 'P0002';
    end if;
    if v_row.status <> 'draft' then
      raise exception
        'That run is already %, and what it did to the stock cannot be '
        'rewritten by editing it.', v_row.status using errcode = '23514';
    end if;
    update public.landed_cost_runs
       set run_date = coalesce(p_date, run_date), notes = p_notes
     where id = v_id;
    delete from public.landed_cost_targets where run_id = v_id;
    delete from public.landed_cost_charges where run_id = v_id;
  else
    insert into public.landed_cost_runs
      (org_id, run_no, run_date, notes, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'landed_cost'),
            coalesce(p_date, current_date), p_notes, auth.uid())
    returning id into v_id;
  end if;

  for v_e in select * from jsonb_array_elements(coalesce(p_bills, '[]'::jsonb))
  loop
    select * into v_bill from public.purchase_documents
     where id = (v_e->>'bill')::uuid and org_id = p_org;
    if v_bill.id is null then
      raise exception 'No such bill.' using errcode = 'P0002';
    end if;
    -- Only a posted bill has moved any stock, and freight can only go
    -- onto stock that is there.
    if v_bill.status not in ('posted', 'partial', 'completed') then
      raise exception
        'Bill % is still %, so nothing it names is on a shelf yet.',
        v_bill.doc_no, v_bill.status using errcode = '23514';
    end if;
    insert into public.landed_cost_targets (org_id, run_id, bill_id)
    values (p_org, v_id, v_bill.id)
    on conflict (run_id, bill_id) do nothing;
  end loop;

  for v_e in select * from jsonb_array_elements(coalesce(p_charges, '[]'::jsonb))
  loop
    v_n := v_n + 1;
    v_acct := nullif(v_e->>'account', '')::uuid;
    if v_acct is null then
      v_acct := app.landed_cost_account(p_org);
    elsif not exists (select 1 from public.accounts a
                       where a.id = v_acct and a.org_id = p_org
                         and not a.is_group) then
      raise exception 'No such account.' using errcode = 'P0002';
    end if;

    insert into public.landed_cost_charges
      (org_id, run_id, line_no, description, amount, basis, account_id,
       source_bill_id)
    values (p_org, v_id, v_n,
            coalesce(nullif(v_e->>'description', ''), 'Charge ' || v_n),
            round((v_e->>'amount')::numeric, 2),
            coalesce(nullif(v_e->>'basis', ''), 'value')::app.landed_cost_basis,
            v_acct,
            nullif(v_e->>'bill', '')::uuid);
  end loop;

  return v_id;
end;
$$;

revoke all on function public.upsert_landed_cost_run(uuid, uuid, date, jsonb, jsonb, text)
  from public, anon;
grant execute on function public.upsert_landed_cost_run(uuid, uuid, date, jsonb, jsonb, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- The goods the charges land on
-- ---------------------------------------------------------------------
--
-- Item lines on the target bills, for items that actually hold stock. A
-- service line typed on the same import bill -- the forwarder's handling
-- fee, say -- is not goods and does not absorb freight.
--
-- `received` is the base quantity, so a bill written in cartons spreads
-- by the pieces that came in rather than by the boxes they came in.
-- 0270 is what makes that number exist.
create or replace function app.landed_cost_lines(p_run uuid)
returns table (
  bill_line_id uuid,
  bill_id      uuid,
  bill_no      text,
  item_id      uuid,
  item_code    text,
  description  text,
  warehouse_id uuid,
  received     numeric,
  on_hand      numeric,
  line_value   numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, d.id, d.doc_no, l.item_id, i.code, l.description,
         coalesce(l.warehouse_id, (select w.id from public.warehouses w
                                    where w.org_id = d.org_id
                                      and w.is_default limit 1)),
         coalesce(l.base_quantity, l.quantity),
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = l.item_id
                      and sl.warehouse_id = coalesce(l.warehouse_id,
                            (select w.id from public.warehouses w
                              where w.org_id = d.org_id
                                and w.is_default limit 1))), 0),
         round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2)
    from public.landed_cost_targets t
    join public.purchase_documents d on d.id = t.bill_id
    join public.purchase_document_lines l on l.document_id = d.id
    join public.items i on i.id = l.item_id
   where t.run_id = p_run
     and l.line_type = 'item'
     and i.track_inventory
     and coalesce(l.base_quantity, l.quantity) > 0;
$$;

revoke all on function app.landed_cost_lines(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What each line would take, before anybody commits to it
-- ---------------------------------------------------------------------
--
-- The same arithmetic the posting function runs, exposed on its own so
-- the screen can show the answer while the charges are still being
-- typed. Posting calls this rather than repeating it, because two
-- copies of an apportionment drift and the one that drifts is the one
-- nobody was looking at.
--
-- Charges are grouped by basis before they are spread rather than
-- rounded one at a time. Two freight invoices both spread by value are
-- the same spread; rounding them separately would put a sen somewhere
-- for no reason a reader could find.
create or replace function public.landed_cost_preview(p_run uuid)
returns table (
  bill_line_id uuid,
  bill_id      uuid,
  bill_no      text,
  item_id      uuid,
  item_code    text,
  description  text,
  warehouse_id uuid,
  received     numeric,
  on_hand      numeric,
  line_value   numeric,
  amount       numeric,
  capitalised  numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run    public.landed_cost_runs;
  v_n      integer;
  v_qty    numeric;
  v_val    numeric;
  v_by_qty numeric;
  v_by_val numeric;
begin
  select * into v_run from public.landed_cost_runs where id = p_run;
  if v_run.id is null then
    raise exception 'No such landed cost run.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_run.org_id, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  select count(*), coalesce(sum(g.received), 0), coalesce(sum(g.line_value), 0)
    into v_n, v_qty, v_val
    from app.landed_cost_lines(p_run) g;

  if v_n = 0 then
    raise exception
      'Those bills have no stocked goods on them, so there is nothing '
      'for the charges to land on.' using errcode = '23514';
  end if;

  select coalesce(sum(c.amount) filter (where c.basis = 'quantity'), 0),
         coalesce(sum(c.amount) filter (where c.basis = 'value'), 0)
    into v_by_qty, v_by_val
    from public.landed_cost_charges c where c.run_id = p_run;

  if v_by_val > 0 and v_val = 0 then
    raise exception
      'A charge is spread by value and those goods were billed at '
      'nothing. Spread it by quantity instead.' using errcode = '23514';
  end if;

  return query
  with spread as (
    select g.*,
           round(v_by_qty * g.received / nullif(v_qty, 0), 2)
         + round(v_by_val * g.line_value / nullif(v_val, 0), 2) as share
      from app.landed_cost_lines(p_run) g
  ),
  -- The rounding remainder, onto the largest line. A charge has to be
  -- spread completely: a sen left behind would sit on the expense
  -- account for ever with nothing to explain it.
  settled as (
    select s.*,
           s.share + case
             when row_number() over (order by s.share desc, s.bill_line_id) = 1
               then v_by_qty + v_by_val - sum(s.share) over ()
             else 0 end as amount
      from spread s
  )
  select t.bill_line_id, t.bill_id, t.bill_no, t.item_id, t.item_code,
         t.description, t.warehouse_id, t.received, t.on_hand, t.line_value,
         t.amount,
         -- And what of that share can actually go onto stock: the part
         -- of the line that is still there.
         case when t.received <= 0 then 0::numeric
              else round(t.amount * least(t.on_hand, t.received)
                         / t.received, 2) end
    from settled t
   order by t.bill_no, t.item_code;
end;
$$;

revoke all on function public.landed_cost_preview(uuid) from public, anon;
grant execute on function public.landed_cost_preview(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Posting it
-- ---------------------------------------------------------------------
create or replace function public.post_landed_cost_run(p_run uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run     public.landed_cost_runs;
  v_row     record;
  v_charge  record;
  v_mv      uuid;
  v_inv     uuid;
  v_cap     numeric(18, 2) := 0;
  v_charged numeric(18, 2) := 0;
  v_ratio   numeric;
  v_credit  numeric(18, 2);
  v_left    numeric(18, 2);
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
begin
  select * into v_run from public.landed_cost_runs where id = p_run;
  if v_run.id is null then
    raise exception 'No such landed cost run.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_run.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_run.status <> 'draft' then
    raise exception 'That run is already %.', v_run.status
      using errcode = '23514';
  end if;

  select coalesce(sum(c.amount), 0) into v_charged
    from public.landed_cost_charges c where c.run_id = p_run;
  if v_charged <= 0 then
    raise exception 'A run with no charges has nothing to spread.'
      using errcode = '23514';
  end if;

  select id into v_inv from public.accounts
   where org_id = v_run.org_id and code = '1310' and not is_group;
  if v_inv is null then
    raise exception 'This company has no inventory account.'
      using errcode = 'P0002';
  end if;

  for v_row in select * from public.landed_cost_preview(p_run) loop
    v_mv := null;
    if v_row.capitalised <> 0 then
      insert into public.stock_movements
        (org_id, movement_no, movement_date, movement_type, item_id,
         warehouse_id, quantity, unit_cost, total_cost,
         source_table, source_id, source_line_id, created_by, notes)
      values (v_run.org_id,
              app.next_document_number_internal(v_run.org_id, 'stock_movement'),
              v_run.run_date, 'landed_cost', v_row.item_id, v_row.warehouse_id,
              0, 0, v_row.capitalised,
              'landed_cost_runs', p_run, v_row.bill_line_id, auth.uid(),
              'Landed cost ' || v_run.run_no)
      returning id into v_mv;
      v_cap := v_cap + v_row.capitalised;
    end if;

    insert into public.landed_cost_allocations
      (org_id, run_id, bill_id, bill_line_id, item_id, warehouse_id,
       amount, capitalised, on_hand, received, movement_id)
    values (v_run.org_id, p_run, v_row.bill_id, v_row.bill_line_id,
            v_row.item_id, v_row.warehouse_id, v_row.amount,
            v_row.capitalised, v_row.on_hand, v_row.received, v_mv);
  end loop;

  if v_cap = 0 then
    raise exception
      'Every one of those goods has already been sold, so there is no '
      'stock left for the charges to sit on. They stay where they were '
      'coded, which is where the cost of those sales belongs.'
      using errcode = '23514';
  end if;

  -- What is being capitalised comes off the charge accounts in the
  -- proportion they were charged in, and the last one takes the
  -- rounding so the entry balances to the sen.
  v_ratio := v_cap / v_charged;
  v_left  := v_cap;
  for v_charge in
    select c.* from public.landed_cost_charges c
     where c.run_id = p_run order by c.line_no
  loop
    v_credit := round(v_charge.amount * v_ratio, 2);
    if v_charge.line_no = (select max(c2.line_no)
                             from public.landed_cost_charges c2
                            where c2.run_id = p_run) then
      v_credit := v_left;
    end if;
    v_left := v_left - v_credit;
    if v_credit <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_charge.account_id,
        'description', v_charge.description,
        'debit', greatest(-v_credit, 0), 'credit', greatest(v_credit, 0));
    end if;
  end loop;

  v_lines := v_lines || jsonb_build_object(
    'account_id', v_inv,
    'description', 'Landed cost ' || v_run.run_no,
    'debit', greatest(v_cap, 0), 'credit', greatest(-v_cap, 0));

  v_entry := app.create_gl_entry_internal(
    v_run.org_id, v_run.run_date, 'stock_movement', v_lines,
    'Landed cost ' || v_run.run_no, 'landed_cost_runs', p_run);

  update public.stock_movements
     set gl_entry_id = v_entry
   where source_table = 'landed_cost_runs' and source_id = p_run
     and gl_entry_id is null;

  update public.landed_cost_runs
     set status = 'posted', gl_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid()
   where id = p_run;

  return v_entry;
end;
$$;

revoke all on function public.post_landed_cost_run(uuid) from public, anon;
grant execute on function public.post_landed_cost_run(uuid) to authenticated;

comment on function public.post_landed_cost_run(uuid) is
  'Puts a run''s charges onto the cost of the goods that are still on the shelf, and takes the same money back off the accounts they were coded to. What was already sold keeps its share on the expense account, because the sale that carried it is posted.';

-- ---------------------------------------------------------------------
-- Changing your mind, while you still can
-- ---------------------------------------------------------------------
create or replace function public.cancel_landed_cost_run(p_run uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_run public.landed_cost_runs;
begin
  select * into v_run from public.landed_cost_runs where id = p_run;
  if v_run.id is null then
    raise exception 'No such landed cost run.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_run.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_run.status <> 'draft' then
    raise exception
      'That run is %. Stock it has already revalued is undone with a '
      'stock adjustment, not by cancelling the paperwork.', v_run.status
      using errcode = '23514';
  end if;
  update public.landed_cost_runs set status = 'cancelled' where id = p_run;
  return true;
end;
$$;

revoke all on function public.cancel_landed_cost_run(uuid) from public, anon;
grant execute on function public.cancel_landed_cost_run(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------
create or replace function public.landed_cost_runs_list(
  p_org uuid, p_status text default null)
returns table (
  id          uuid,
  run_no      text,
  run_date    date,
  status      text,
  notes       text,
  bills       bigint,
  charges     bigint,
  total       numeric,
  capitalised numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select r.id, r.run_no, r.run_date, r.status::text, r.notes,
           (select count(*) from public.landed_cost_targets t
             where t.run_id = r.id),
           (select count(*) from public.landed_cost_charges c
             where c.run_id = r.id),
           (select coalesce(sum(c.amount), 0) from public.landed_cost_charges c
             where c.run_id = r.id),
           (select coalesce(sum(a.capitalised), 0)
              from public.landed_cost_allocations a where a.run_id = r.id)
      from public.landed_cost_runs r
     where r.org_id = p_org
       and (p_status is null or r.status::text = p_status)
     order by r.run_date desc, r.run_no desc;
end;
$$;

revoke all on function public.landed_cost_runs_list(uuid, text) from public, anon;
grant execute on function public.landed_cost_runs_list(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.landed_cost_runs        enable row level security;
alter table public.landed_cost_targets     enable row level security;
alter table public.landed_cost_charges     enable row level security;
alter table public.landed_cost_allocations enable row level security;

create policy landed_cost_runs_read on public.landed_cost_runs for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy landed_cost_targets_read on public.landed_cost_targets for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy landed_cost_charges_read on public.landed_cost_charges for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy landed_cost_allocations_read on public.landed_cost_allocations
  for select to authenticated using (app.can_read_module(org_id, 'inventory'));

-- No write policies. A run that a client could update directly could be
-- marked posted without a movement or a ledger entry, and the stock
-- would then be worth whatever the client said it was.
revoke all on public.landed_cost_runs        from anon, authenticated;
revoke all on public.landed_cost_targets     from anon, authenticated;
revoke all on public.landed_cost_charges     from anon, authenticated;
revoke all on public.landed_cost_allocations from anon, authenticated;

grant select on public.landed_cost_runs        to authenticated;
grant select on public.landed_cost_targets     to authenticated;
grant select on public.landed_cost_charges     to authenticated;
grant select on public.landed_cost_allocations to authenticated;

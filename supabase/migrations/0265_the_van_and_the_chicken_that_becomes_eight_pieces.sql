-- =====================================================================
-- The central kitchen, the van, and the chicken that becomes eight
-- pieces
--
-- Two things this schema described and never built.
--
-- `app.stock_movement_type` has had `transfer_in` and `transfer_out`
-- since 0006. Nothing has ever written either. `warehouses` has existed
-- just as long, 0206 gives every outlet one, and 0205 made forecasting
-- ask each location what it is running out of — but there has never been
-- a way to move a case of anything from one of them to another. A chain
-- with a central kitchen has had to fake it with two stock adjustments,
-- which loses the audit trail, loses the valuation, and posts two
-- unexplained entries to 5900 instead of none.
--
-- `1320 Goods in Transit` has been in the seeded chart since 0071, for
-- the same never. It is the account this migration finally needs.
--
-- ---------------------------------------------------------------------
-- A transfer is two events, not one
--
-- The van leaves at six and arrives at seven. In between the stock has
-- left the kitchen and has not reached the shop, and a system that
-- models the transfer as one instant is a system that cannot answer
-- "where is it" for the hour that matters — nor "we sent ten and nine
-- arrived", which is the whole reason anybody counts a delivery in.
--
-- So: `send` takes it out of the source at the source's weighted
-- average and parks the value in 1320. `receive` counts it in, puts
-- what arrived into the destination at the same unit cost it left at,
-- and clears 1320. Value is conserved to the sen, because both legs use
-- one number read back off the outbound movement rather than two
-- averages computed a minute apart.
--
-- A shortfall is not silently absorbed. Ten sent and nine received is
-- one unit's worth of value that left inventory and never arrived, and
-- it is written to 5900 Inventory Adjustment where a shrinkage belongs
-- — visible, named, and attached to the transfer that lost it.
--
-- Receiving *more* than was sent is refused. There is no such thing:
-- either the count going out was wrong, in which case fix it before it
-- leaves, or something else got into the van, in which case it is not
-- this transfer.
--
-- ---------------------------------------------------------------------
-- A conversion is one thing becoming several
--
-- A kitchen buys whole chickens and sells breasts, thighs and wings. A
-- grocer buys a 20kg sack and sells 500g packs. Neither is a recipe —
-- there is no dish and no sale involved — and neither is worth a
-- manufacturing order, which wants a plan, a confirmation and a work
-- centre for something a cook does with a knife in four minutes.
--
-- `run_item_conversion` takes one item out and puts several in, at the
-- same total value. The split is `cost_share`, a percentage per output
-- that must total exactly 100. That is the only interesting arithmetic
-- here and it is the one the test is built around: a chicken that cost
-- twelve ringgit has to still be twelve ringgit of inventory when it is
-- four pieces, or the shop has invented or destroyed stock value by
-- cutting something up.
--
-- Both legs are `assembly_out`/`assembly_in` and neither posts a
-- journal, because nothing left 1310 — the value moved between items
-- inside the same account. The manufacturing module posts a journal
-- because conversion *cost* is added there; here nothing is added, and
-- a pair of entries that net to zero is noise in the ledger.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where the value sits while the van is moving
-- ---------------------------------------------------------------------
--
-- 1320 is in the seeded chart, but a company created before 0071 — or
-- one whose chart was edited — may not have it. Made rather than
-- assumed, the way 0133 makes its absorption account.
create or replace function app.goods_in_transit_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '1320' and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '1320', 'Goods in Transit', 'asset', 'inventory',
          false, true, 1320,
          (select id from public.accounts
            where org_id = p_org_id and code = '1300'))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app.goods_in_transit_account(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The transfer
-- ---------------------------------------------------------------------
do $$ begin
  create type app.stock_transfer_status as enum
    ('draft', 'sent', 'received', 'cancelled');
exception when duplicate_object then null; end $$;

create table public.stock_transfers (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id)
                      on delete cascade,
  transfer_no       text not null,
  transfer_date     date not null default current_date,

  from_warehouse_id uuid not null references public.warehouses(id)
                      on delete restrict,
  to_warehouse_id   uuid not null references public.warehouses(id)
                      on delete restrict,

  status            app.stock_transfer_status not null default 'draft',
  notes             text,

  sent_at           timestamptz,
  sent_by           uuid references auth.users(id),
  received_at       timestamptz,
  received_by       uuid references auth.users(id),

  -- The journal that parked the value in transit, and the one that
  -- took it out again. Two, because they happen an hour apart and a
  -- single column would lose the first.
  send_entry_id     uuid references public.gl_entries(id) on delete set null,
  receipt_entry_id  uuid references public.gl_entries(id) on delete set null,

  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  unique (org_id, transfer_no),
  constraint stock_transfers_two_places check (from_warehouse_id <> to_warehouse_id)
);

create index stock_transfers_org_idx on public.stock_transfers (org_id);
create index stock_transfers_open_idx on public.stock_transfers (org_id, status)
  where status = 'sent';

create table public.stock_transfer_lines (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id)
                      on delete cascade,
  transfer_id       uuid not null references public.stock_transfers(id)
                      on delete cascade,
  line_no           integer not null,

  item_id           uuid not null references public.items(id) on delete restrict,

  -- What somebody wrote on the note, in whatever unit they wrote it in.
  quantity          numeric(18, 6) not null check (quantity > 0),
  uom_code          text not null references public.ref_uom_codes(code),

  -- And the same thing in the item's own unit, resolved when it is
  -- sent rather than when it is typed. Stored rather than recomputed:
  -- a pack size edited next month must not retrospectively change what
  -- left the kitchen last Tuesday.
  sent_quantity     numeric(18, 6),
  sent_unit_cost    numeric(18, 6),

  -- What the shop counted in. Null until it is received.
  received_quantity numeric(18, 6),

  note              text,
  created_at        timestamptz not null default now(),
  unique (transfer_id, line_no)
);

create index stock_transfer_lines_transfer_idx
  on public.stock_transfer_lines (transfer_id);

-- ---------------------------------------------------------------------
-- Numbering
-- ---------------------------------------------------------------------
--
-- Copied whole from 0206 for one line. Everybody who has ever worked in
-- a warehouse calls it a transfer note, and TRF- was already taken by
-- the bank.
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
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- Writing one down
-- ---------------------------------------------------------------------
create or replace function public.upsert_stock_transfer(
  p_id     uuid,
  p_org    uuid,
  p_from   uuid,
  p_to     uuid,
  p_date   date,
  p_lines  jsonb,
  p_notes  text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid := p_id;
  v_status app.stock_transfer_status;
  v_e      jsonb;
  v_no     integer := 0;
  v_item   uuid;
  v_qty    numeric;
  v_uom    text;
begin
  if not app.can_write_module(p_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A transfer needs somewhere to leave and somewhere to go.'
      using errcode = '23502';
  end if;
  if p_from = p_to then
    raise exception 'That is the same store twice.' using errcode = '23514';
  end if;
  if not exists (select 1 from public.warehouses w
                  where w.id = p_from and w.org_id = p_org)
     or not exists (select 1 from public.warehouses w
                     where w.id = p_to and w.org_id = p_org) then
    raise exception 'One of those stores is not this company''s.'
      using errcode = 'P0002';
  end if;

  if v_id is null then
    insert into public.stock_transfers (
      org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id,
      notes, created_by)
    values (
      p_org, app.next_document_number_internal(p_org, 'stock_transfer'),
      coalesce(p_date, current_date), p_from, p_to,
      nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
    returning id into v_id;
  else
    select t.status into v_status
      from public.stock_transfers t where t.id = v_id and t.org_id = p_org;
    if v_status is null then
      raise exception 'No such transfer.' using errcode = 'P0002';
    end if;
    -- Once the van has gone, the note is a record of what went on it.
    if v_status <> 'draft' then
      raise exception
        'That transfer has already been sent, so what is on it is what '
        'left. Receive it and adjust the difference.'
        using errcode = '23514';
    end if;
    update public.stock_transfers t
       set transfer_date = coalesce(p_date, t.transfer_date),
           from_warehouse_id = p_from,
           to_warehouse_id = p_to,
           notes = nullif(btrim(coalesce(p_notes, '')), ''),
           updated_at = now()
     where t.id = v_id;
  end if;

  delete from public.stock_transfer_lines l where l.transfer_id = v_id;

  for v_e in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_item := (v_e ->> 'item')::uuid;
    v_qty  := (v_e ->> 'quantity')::numeric;
    v_uom  := coalesce(nullif(v_e ->> 'uom', ''),
                       (select i.uom_code from public.items i where i.id = v_item));

    if v_item is null or coalesce(v_qty, 0) <= 0 then
      raise exception 'Every line needs an item and a quantity.'
        using errcode = '23514';
    end if;
    if not exists (select 1 from public.items i
                    where i.id = v_item and i.org_id = p_org
                      and i.deleted_at is null and i.track_inventory) then
      raise exception
        'One of those is not an item this company keeps stock of, so '
        'there is nothing of it to move.'
        using errcode = '23514';
    end if;
    -- Proved now rather than when the van is loaded.
    perform app.uom_qty(v_item, v_qty, v_uom);

    v_no := v_no + 1;
    insert into public.stock_transfer_lines (
      org_id, transfer_id, line_no, item_id, quantity, uom_code, note)
    values (
      p_org, v_id, v_no, v_item, v_qty, v_uom, nullif(v_e ->> 'note', ''));
  end loop;

  return v_id;
end;
$$;

revoke all on function public.upsert_stock_transfer(
  uuid, uuid, uuid, uuid, date, jsonb, text) from public, anon;
grant execute on function public.upsert_stock_transfer(
  uuid, uuid, uuid, uuid, date, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- Loading the van
-- ---------------------------------------------------------------------
--
-- Takes the stock out of the source at the source's own weighted
-- average, and parks the value in 1320 rather than leaving the ledger
-- disagreeing with the stock card for the hour the van is moving.
create or replace function public.send_stock_transfer(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_t      public.stock_transfers;
  v_line   record;
  v_qty    numeric;
  v_cost   numeric;
  v_total  numeric := 0;
  v_mv     uuid;
  v_lines  jsonb;
  v_entry  uuid;
  v_inv    uuid;
  v_transit uuid;
  v_neg    boolean;
begin
  select * into v_t from public.stock_transfers where id = p_id;
  if v_t.id is null then
    raise exception 'No such transfer.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_t.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_t.status <> 'draft' then
    raise exception 'That transfer is already %.', v_t.status
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.stock_transfer_lines l
                  where l.transfer_id = p_id) then
    raise exception 'There is nothing on this transfer to send.'
      using errcode = '23514';
  end if;

  select coalesce(ps.allow_negative_stock, false) into v_neg
    from public.pos_settings ps where ps.org_id = v_t.org_id;
  v_neg := coalesce(v_neg, false);

  for v_line in
    select l.*, i.name as item_name, i.uom_code as base_uom
      from public.stock_transfer_lines l
      join public.items i on i.id = l.item_id
     where l.transfer_id = p_id
     order by l.line_no
  loop
    v_qty := round(app.uom_qty(v_line.item_id, v_line.quantity, v_line.uom_code), 6);

    -- A kitchen cannot send what it does not have. Unlike the till,
    -- which takes the money and argues later, nothing is lost by
    -- refusing here: the van has not left.
    if not v_neg then
      if coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = v_line.item_id
                      and sl.warehouse_id = v_t.from_warehouse_id), 0) < v_qty then
        raise exception
          'There is not that much % in the store it is leaving.',
          v_line.item_name
          using errcode = '23514';
      end if;
    end if;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id,
      source_line_id, notes, created_by)
    values (
      v_t.org_id,
      app.next_document_number_internal(v_t.org_id, 'stock_movement'),
      v_t.transfer_date, 'transfer_out', v_line.item_id,
      v_t.from_warehouse_id, -v_qty, 0,
      'stock_transfers', p_id, v_line.id,
      'Transfer ' || v_t.transfer_no, auth.uid())
    returning id into v_mv;

    -- Read back, not recomputed. The trigger substituted the weighted
    -- average for the zero above, and the leg that arrives an hour
    -- later has to use that same number or the two will not net off.
    select sm.unit_cost, -sm.total_cost into v_cost, v_qty
      from public.stock_movements sm where sm.id = v_mv;
    v_total := v_total + v_qty;

    update public.stock_transfer_lines l
       set sent_quantity  = round(
             app.uom_qty(l.item_id, l.quantity, l.uom_code), 6),
           sent_unit_cost = v_cost
     where l.id = v_line.id;
  end loop;

  if round(v_total, 2) <> 0 then
    v_inv     := (select a.id from public.accounts a
                   where a.org_id = v_t.org_id and a.code = '1310');
    v_transit := app.goods_in_transit_account(v_t.org_id);
    if v_inv is null then
      raise exception 'No inventory account (1310) in the chart.'
        using errcode = 'P0002';
    end if;

    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_transit,
        'description', 'In transit ' || v_t.transfer_no,
        'debit', round(v_total, 2), 'credit', 0),
      jsonb_build_object('account_id', v_inv,
        'description', 'Sent ' || v_t.transfer_no,
        'debit', 0, 'credit', round(v_total, 2)));

    v_entry := app.create_gl_entry_internal(
      v_t.org_id, v_t.transfer_date, 'stock_movement', v_lines,
      'Stock transfer ' || v_t.transfer_no, 'stock_transfers', p_id);

    update public.stock_movements sm set gl_entry_id = v_entry
     where sm.source_table = 'stock_transfers' and sm.source_id = p_id
       and sm.gl_entry_id is null;
  end if;

  update public.stock_transfers t
     set status = 'sent', sent_at = now(), sent_by = auth.uid(),
         send_entry_id = v_entry, updated_at = now()
   where t.id = p_id;

  return v_entry;
end;
$$;

revoke all on function public.send_stock_transfer(uuid) from public, anon;
grant execute on function public.send_stock_transfer(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Counting it in
-- ---------------------------------------------------------------------
--
-- `p_counts` is `[{"line": <uuid>, "quantity": <n>}]` in the item's own
-- unit. A line nobody counted is taken as having arrived in full: a
-- shop that ticks the two short lines and leaves the other eight alone
-- is doing the sensible thing, and making it enumerate everything is
-- how a receipt screen goes unused.
create or replace function public.receive_stock_transfer(
  p_id     uuid,
  p_counts jsonb default '[]'::jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_t       public.stock_transfers;
  v_line    record;
  v_got     numeric;
  v_arrived numeric := 0;
  v_short   numeric := 0;
  v_lines   jsonb;
  v_entry   uuid;
  v_inv     uuid;
  v_transit uuid;
  v_shrink  uuid;
begin
  select * into v_t from public.stock_transfers where id = p_id;
  if v_t.id is null then
    raise exception 'No such transfer.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_t.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_t.status <> 'sent' then
    raise exception
      'That transfer is %, so there is nothing on its way to receive.',
      v_t.status using errcode = '23514';
  end if;

  for v_line in
    select l.*, i.name as item_name
      from public.stock_transfer_lines l
      join public.items i on i.id = l.item_id
     where l.transfer_id = p_id
     order by l.line_no
  loop
    select (e ->> 'quantity')::numeric into v_got
      from jsonb_array_elements(coalesce(p_counts, '[]'::jsonb)) e
     where (e ->> 'line')::uuid = v_line.id;
    v_got := coalesce(v_got, v_line.sent_quantity);

    if v_got < 0 then
      raise exception 'A count cannot be negative.' using errcode = '23514';
    end if;
    -- See the header: there is no such thing as receiving more than
    -- was sent.
    if v_got > v_line.sent_quantity then
      raise exception
        'Only % of % was sent, so % of it cannot have arrived.',
        v_line.sent_quantity, v_line.item_name, v_got
        using errcode = '23514';
    end if;

    update public.stock_transfer_lines l
       set received_quantity = v_got where l.id = v_line.id;

    if v_got > 0 then
      insert into public.stock_movements (
        org_id, movement_no, movement_date, movement_type, item_id,
        warehouse_id, quantity, unit_cost, source_table, source_id,
        source_line_id, notes, created_by)
      values (
        v_t.org_id,
        app.next_document_number_internal(v_t.org_id, 'stock_movement'),
        current_date, 'transfer_in', v_line.item_id,
        v_t.to_warehouse_id, v_got,
        -- The price it left at. An inbound movement is taken at the
        -- cost it is given, and taking it in at the destination's own
        -- average would move value between two warehouses that are
        -- supposed to be one company's stock.
        coalesce(v_line.sent_unit_cost, 0),
        'stock_transfers', p_id, v_line.id,
        'Received ' || v_t.transfer_no, auth.uid());
    end if;

    v_arrived := v_arrived + round(v_got * coalesce(v_line.sent_unit_cost, 0), 2);
    v_short   := v_short
      + round((v_line.sent_quantity - v_got) * coalesce(v_line.sent_unit_cost, 0), 2);
  end loop;

  if round(v_arrived, 2) <> 0 or round(v_short, 2) <> 0 then
    v_inv     := (select a.id from public.accounts a
                   where a.org_id = v_t.org_id and a.code = '1310');
    v_transit := app.goods_in_transit_account(v_t.org_id);

    v_lines := '[]'::jsonb;
    if round(v_arrived, 2) <> 0 then
      v_lines := v_lines || jsonb_build_object('account_id', v_inv,
        'description', 'Received ' || v_t.transfer_no,
        'debit', round(v_arrived, 2), 'credit', 0);
    end if;
    if round(v_short, 2) <> 0 then
      -- What left and never arrived. 5900 is where 0087 already puts a
      -- stock difference nobody can explain, and a transfer that loses
      -- a case is exactly that.
      v_shrink := (select a.id from public.accounts a
                    where a.org_id = v_t.org_id and a.code = '5900');
      if v_shrink is null then
        raise exception 'No inventory adjustment account (5900) in the chart.'
          using errcode = 'P0002';
      end if;
      v_lines := v_lines || jsonb_build_object('account_id', v_shrink,
        'description', 'Short on ' || v_t.transfer_no,
        'debit', round(v_short, 2), 'credit', 0);
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', v_transit,
      'description', 'Out of transit ' || v_t.transfer_no,
      'debit', 0, 'credit', round(v_arrived + v_short, 2));

    v_entry := app.create_gl_entry_internal(
      v_t.org_id, current_date, 'stock_movement', v_lines,
      'Stock transfer received ' || v_t.transfer_no, 'stock_transfers', p_id);

    update public.stock_movements sm set gl_entry_id = v_entry
     where sm.source_table = 'stock_transfers' and sm.source_id = p_id
       and sm.movement_type = 'transfer_in' and sm.gl_entry_id is null;
  end if;

  update public.stock_transfers t
     set status = 'received', received_at = now(), received_by = auth.uid(),
         receipt_entry_id = v_entry, updated_at = now()
   where t.id = p_id;

  return v_entry;
end;
$$;

revoke all on function public.receive_stock_transfer(uuid, jsonb)
  from public, anon;
grant execute on function public.receive_stock_transfer(uuid, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Changing your mind, while that is still possible
-- ---------------------------------------------------------------------
--
-- Only a draft. A sent transfer has moved stock and posted a journal,
-- and undoing those is what receiving it back the other way is for.
create or replace function public.cancel_stock_transfer(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.stock_transfers;
begin
  select * into v_t from public.stock_transfers where id = p_id;
  if v_t.id is null then
    return false;
  end if;
  if not app.can_write_module(v_t.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_t.status <> 'draft' then
    raise exception
      'That transfer is % — the stock has already moved. Send it back '
      'the other way rather than pretending it did not.', v_t.status
      using errcode = '23514';
  end if;
  update public.stock_transfers t
     set status = 'cancelled', updated_at = now() where t.id = p_id;
  return true;
end;
$$;

revoke all on function public.cancel_stock_transfer(uuid) from public, anon;
grant execute on function public.cancel_stock_transfer(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Reading transfers back
-- ---------------------------------------------------------------------
create or replace function public.stock_transfers_list(
  p_org    uuid,
  p_status app.stock_transfer_status default null)
returns table (
  id             uuid,
  transfer_no    text,
  transfer_date  date,
  from_warehouse text,
  to_warehouse   text,
  status         app.stock_transfer_status,
  line_count     integer,
  value          numeric,
  shortfall      numeric,
  notes          text)
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
  select t.id, t.transfer_no, t.transfer_date, wf.name, wt.name, t.status,
         (select count(*)::integer from public.stock_transfer_lines l
           where l.transfer_id = t.id),
         coalesce((select round(sum(l.sent_quantity * l.sent_unit_cost), 2)
                     from public.stock_transfer_lines l
                    where l.transfer_id = t.id), 0),
         coalesce((select round(sum(
                     (l.sent_quantity - coalesce(l.received_quantity, l.sent_quantity))
                       * l.sent_unit_cost), 2)
                     from public.stock_transfer_lines l
                    where l.transfer_id = t.id), 0),
         t.notes
    from public.stock_transfers t
    join public.warehouses wf on wf.id = t.from_warehouse_id
    join public.warehouses wt on wt.id = t.to_warehouse_id
   where t.org_id = p_org
     and (p_status is null or t.status = p_status)
   order by t.transfer_date desc, t.transfer_no desc;
end;
$$;

revoke all on function public.stock_transfers_list(uuid, app.stock_transfer_status)
  from public, anon;
grant execute on function public.stock_transfers_list(uuid, app.stock_transfer_status)
  to authenticated;

create or replace function public.stock_transfer_lines_for(p_transfer uuid)
returns table (
  id                uuid,
  line_no           integer,
  item_id           uuid,
  item_name         text,
  item_code         text,
  quantity          numeric,
  uom_code          text,
  base_uom          text,
  sent_quantity     numeric,
  sent_unit_cost    numeric,
  received_quantity numeric,
  note              text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select t.org_id into v_org from public.stock_transfers t where t.id = p_transfer;
  if v_org is null then
    raise exception 'No such transfer.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select l.id, l.line_no, l.item_id, i.name, i.code, l.quantity, l.uom_code,
         i.uom_code, l.sent_quantity, l.sent_unit_cost, l.received_quantity,
         l.note
    from public.stock_transfer_lines l
    join public.items i on i.id = l.item_id
   where l.transfer_id = p_transfer
   order by l.line_no;
end;
$$;

revoke all on function public.stock_transfer_lines_for(uuid) from public, anon;
grant execute on function public.stock_transfer_lines_for(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- One thing becoming several
-- ---------------------------------------------------------------------
create table public.item_conversions (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  code           text not null,
  name           text not null,

  from_item_id   uuid not null references public.items(id) on delete restrict,
  from_quantity  numeric(18, 6) not null check (from_quantity > 0),
  from_uom_code  text not null references public.ref_uom_codes(code),

  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (org_id, code)
);

create index item_conversions_org_idx on public.item_conversions (org_id)
  where is_active;

create table public.item_conversion_outputs (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  conversion_id uuid not null references public.item_conversions(id)
                  on delete cascade,
  line_no       integer not null,

  item_id       uuid not null references public.items(id) on delete restrict,
  quantity      numeric(18, 6) not null check (quantity > 0),
  uom_code      text not null references public.ref_uom_codes(code),

  -- What share of the input's value this output carries. Percentages
  -- rather than prices, because the input's cost changes every time
  -- the shop buys another one and the split does not: a breast is
  -- worth more of a chicken than a wing is, whatever the chicken cost.
  cost_share    numeric(9, 4) not null check (cost_share > 0),

  unique (conversion_id, line_no)
);

create index item_conversion_outputs_conv_idx
  on public.item_conversion_outputs (conversion_id);

create or replace function public.upsert_item_conversion(
  p_id     uuid,
  p_org    uuid,
  p_code   text,
  p_name   text,
  p_item   uuid,
  p_qty    numeric,
  p_uom    text,
  p_outputs jsonb,
  p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id    uuid := p_id;
  v_e     jsonb;
  v_no    integer := 0;
  v_share numeric := 0;
  v_item  uuid;
  v_qty   numeric;
  v_uom   text;
begin
  if not app.can_write_module(p_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_code), '') = '' or coalesce(btrim(p_name), '') = '' then
    raise exception 'A conversion needs a code and a name.'
      using errcode = '23514';
  end if;
  if coalesce(p_qty, 0) <= 0 then
    raise exception 'A conversion has to start with something.'
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.items i
                  where i.id = p_item and i.org_id = p_org
                    and i.deleted_at is null and i.track_inventory) then
    raise exception
      'What goes in has to be something this company keeps stock of.'
      using errcode = '23514';
  end if;
  perform app.uom_qty(p_item, p_qty, coalesce(p_uom,
    (select i.uom_code from public.items i where i.id = p_item)));

  if jsonb_array_length(coalesce(p_outputs, '[]'::jsonb)) = 0 then
    raise exception 'A conversion has to produce something.'
      using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.item_conversions (
      org_id, code, name, from_item_id, from_quantity, from_uom_code, is_active)
    values (
      p_org, btrim(p_code), btrim(p_name), p_item, p_qty,
      coalesce(p_uom, (select i.uom_code from public.items i where i.id = p_item)),
      coalesce(p_active, true))
    returning id into v_id;
  else
    update public.item_conversions c
       set code = btrim(p_code), name = btrim(p_name),
           from_item_id = p_item, from_quantity = p_qty,
           from_uom_code = coalesce(p_uom,
             (select i.uom_code from public.items i where i.id = p_item)),
           is_active = coalesce(p_active, true), updated_at = now()
     where c.id = v_id and c.org_id = p_org;
    if not found then
      raise exception 'No such conversion.' using errcode = 'P0002';
    end if;
  end if;

  delete from public.item_conversion_outputs o where o.conversion_id = v_id;

  for v_e in select * from jsonb_array_elements(p_outputs)
  loop
    v_item := (v_e ->> 'item')::uuid;
    v_qty  := (v_e ->> 'quantity')::numeric;
    v_uom  := coalesce(nullif(v_e ->> 'uom', ''),
                       (select i.uom_code from public.items i where i.id = v_item));

    if v_item is null or coalesce(v_qty, 0) <= 0 then
      raise exception 'Every output needs an item and a quantity.'
        using errcode = '23514';
    end if;
    if v_item = p_item then
      raise exception 'A conversion that produces what it consumes is not one.'
        using errcode = '23514';
    end if;
    if not exists (select 1 from public.items i
                    where i.id = v_item and i.org_id = p_org
                      and i.deleted_at is null and i.track_inventory) then
      raise exception
        'What comes out has to be something this company keeps stock of, '
        'or the value has nowhere to land.'
        using errcode = '23514';
    end if;
    perform app.uom_qty(v_item, v_qty, v_uom);

    v_no := v_no + 1;
    v_share := v_share + coalesce((v_e ->> 'share')::numeric, 0);
    insert into public.item_conversion_outputs (
      org_id, conversion_id, line_no, item_id, quantity, uom_code, cost_share)
    values (
      p_org, v_id, v_no, v_item, v_qty, v_uom,
      coalesce((v_e ->> 'share')::numeric, 0));
  end loop;

  -- The one rule that makes this arithmetic rather than opinion. A
  -- chicken that cost twelve ringgit is twelve ringgit of inventory
  -- after it has been cut up; a split that does not add to a hundred
  -- invents or destroys stock value with a knife.
  if round(v_share, 4) <> 100 then
    raise exception
      'The shares add up to %, not 100. What a thing is worth cannot '
      'change by cutting it up.', round(v_share, 4)
      using errcode = '23514';
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_item_conversion(
  uuid, uuid, text, text, uuid, numeric, text, jsonb, boolean)
  from public, anon;
grant execute on function public.upsert_item_conversion(
  uuid, uuid, text, text, uuid, numeric, text, jsonb, boolean)
  to authenticated;

create or replace function public.delete_item_conversion(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select c.org_id into v_org from public.item_conversions c where c.id = p_id;
  if v_org is null then
    return false;
  end if;
  if not app.can_write_module(v_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  delete from public.item_conversions c where c.id = p_id;
  return true;
end;
$$;

revoke all on function public.delete_item_conversion(uuid) from public, anon;
grant execute on function public.delete_item_conversion(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Doing it
-- ---------------------------------------------------------------------
--
-- No journal. Value moves between items inside 1310 and a pair of
-- entries that net to zero is noise in a ledger somebody has to read.
-- The stock card carries the whole story, which is where a stock
-- question belongs.
create or replace function public.run_item_conversion(
  p_conversion uuid,
  p_times      numeric default 1,
  p_warehouse  uuid default null)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c     public.item_conversions;
  v_wh    uuid;
  v_qty   numeric;
  v_value numeric;
  v_out   record;
  v_share numeric;
  v_oqty  numeric;
  v_neg   boolean;
begin
  select * into v_c from public.item_conversions where id = p_conversion;
  if v_c.id is null then
    raise exception 'No such conversion.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if not v_c.is_active then
    raise exception 'That conversion has been switched off.'
      using errcode = '23514';
  end if;
  if coalesce(p_times, 0) <= 0 then
    raise exception 'How many times?' using errcode = '23514';
  end if;

  v_wh := coalesce(p_warehouse,
                   (select w.id from public.warehouses w
                     where w.org_id = v_c.org_id and w.is_default limit 1));
  if v_wh is null then
    raise exception 'This company has no store to do it in.'
      using errcode = 'P0002';
  end if;

  v_qty := round(
    app.uom_qty(v_c.from_item_id, v_c.from_quantity, v_c.from_uom_code)
      * p_times, 6);

  select coalesce(ps.allow_negative_stock, false) into v_neg
    from public.pos_settings ps where ps.org_id = v_c.org_id;
  if not coalesce(v_neg, false) then
    if coalesce((select sl.quantity from public.stock_levels sl
                  where sl.item_id = v_c.from_item_id
                    and sl.warehouse_id = v_wh), 0) < v_qty then
      raise exception 'There is not that much of it in the store.'
        using errcode = '23514';
    end if;
  end if;

  insert into public.stock_movements (
    org_id, movement_no, movement_date, movement_type, item_id,
    warehouse_id, quantity, unit_cost, source_table, source_id, notes,
    created_by)
  values (
    v_c.org_id,
    app.next_document_number_internal(v_c.org_id, 'stock_movement'),
    current_date, 'assembly_out', v_c.from_item_id, v_wh, -v_qty, 0,
    'item_conversions', p_conversion, v_c.name, auth.uid());

  -- What it was actually worth, at the average the trigger just used.
  select -sm.total_cost into v_value
    from public.stock_movements sm
   where sm.source_table = 'item_conversions' and sm.source_id = p_conversion
     and sm.item_id = v_c.from_item_id
   order by sm.created_at desc limit 1;
  v_value := coalesce(v_value, 0);

  for v_out in
    select o.*, i.name as item_name
      from public.item_conversion_outputs o
      join public.items i on i.id = o.item_id
     where o.conversion_id = p_conversion
     order by o.line_no
  loop
    v_oqty  := round(app.uom_qty(v_out.item_id, v_out.quantity, v_out.uom_code)
                       * p_times, 6);
    v_share := round(v_value * v_out.cost_share / 100.0, 2);

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id, notes,
      created_by)
    values (
      v_c.org_id,
      app.next_document_number_internal(v_c.org_id, 'stock_movement'),
      current_date, 'assembly_in', v_out.item_id, v_wh, v_oqty,
      case when v_oqty = 0 then 0 else round(v_share / v_oqty, 6) end,
      'item_conversions', p_conversion, v_c.name, auth.uid());
  end loop;

  return round(v_value, 2);
end;
$$;

revoke all on function public.run_item_conversion(uuid, numeric, uuid)
  from public, anon;
grant execute on function public.run_item_conversion(uuid, numeric, uuid)
  to authenticated;

create or replace function public.item_conversions_list(p_org uuid)
returns table (
  id            uuid,
  code          text,
  name          text,
  from_item_id  uuid,
  from_item     text,
  from_quantity numeric,
  from_uom_code text,
  on_hand       numeric,
  output_count  integer,
  is_active     boolean)
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
  select c.id, c.code, c.name, c.from_item_id, i.name, c.from_quantity,
         c.from_uom_code, i.quantity_on_hand,
         (select count(*)::integer from public.item_conversion_outputs o
           where o.conversion_id = c.id),
         c.is_active
    from public.item_conversions c
    join public.items i on i.id = c.from_item_id
   where c.org_id = p_org
   order by c.name;
end;
$$;

revoke all on function public.item_conversions_list(uuid) from public, anon;
grant execute on function public.item_conversions_list(uuid) to authenticated;

create or replace function public.item_conversion_outputs_for(p_conversion uuid)
returns table (
  line_no    integer,
  item_id    uuid,
  item_name  text,
  quantity   numeric,
  uom_code   text,
  cost_share numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select c.org_id into v_org from public.item_conversions c where c.id = p_conversion;
  if v_org is null then
    raise exception 'No such conversion.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select o.line_no, o.item_id, i.name, o.quantity, o.uom_code, o.cost_share
    from public.item_conversion_outputs o
    join public.items i on i.id = o.item_id
   where o.conversion_id = p_conversion
   order by o.line_no;
end;
$$;

revoke all on function public.item_conversion_outputs_for(uuid)
  from public, anon;
grant execute on function public.item_conversion_outputs_for(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.stock_transfers          enable row level security;
alter table public.stock_transfer_lines     enable row level security;
alter table public.item_conversions         enable row level security;
alter table public.item_conversion_outputs  enable row level security;

create policy stock_transfers_read on public.stock_transfers for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy stock_transfer_lines_read on public.stock_transfer_lines for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy item_conversions_read on public.item_conversions for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy item_conversion_outputs_read on public.item_conversion_outputs
  for select to authenticated using (app.can_read_module(org_id, 'inventory'));

-- No write policies. A transfer's state machine is the whole feature:
-- a client that could update `status` directly could mark stock
-- received without moving it, and one that could write an output row
-- could break the hundred-per-cent rule that keeps the value honest.

revoke all on public.stock_transfers         from anon, authenticated;
revoke all on public.stock_transfer_lines    from anon, authenticated;
revoke all on public.item_conversions        from anon, authenticated;
revoke all on public.item_conversion_outputs from anon, authenticated;

grant select on public.stock_transfers         to authenticated;
grant select on public.stock_transfer_lines    to authenticated;
grant select on public.item_conversions        to authenticated;
grant select on public.item_conversion_outputs to authenticated;

create trigger set_updated_at before update on public.stock_transfers
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.item_conversions
  for each row execute function app.set_updated_at();

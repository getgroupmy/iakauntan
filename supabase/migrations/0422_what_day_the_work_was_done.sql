-- ---------------------------------------------------------------------
-- What day the work was done
--
-- The third of the four. `0420` carries the reasoning.
--
-- What a factory consumed and produced, what a conversion turned into
-- what, when a stock transfer was raised and when it arrived, the day
-- freight was apportioned over what it cost, the day a forecast became
-- a purchase order -- and with it the exchange rate looked up for that
-- day -- the day somebody's onboarding starts, and the day a deal was
-- won or lost.
--
-- Two are not postings and are here because they read the same clock.
--
-- `public.create_fiscal_year` derives a first year from the year
-- `current_date` falls in. On the first of January, for eight hours, a
-- new organization was given the previous year.
--
-- `app.track_opportunity_stage` is a trigger: it dates the close when
-- the stage moves to won or lost. A deal closed at nine in the morning
-- in Kuala Lumpur was recorded as closed the day before, which is a
-- fact about a sales month that somebody is measured on.
-- ---------------------------------------------------------------------

-- The day a manufacturing order consumed and produced.
create or replace function public.post_manufacturing_order(
  p_mo_id uuid,
  p_quantity_done numeric default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_mo public.manufacturing_orders;
  v_done numeric;
  v_ratio numeric;
  v_component_cost numeric(18, 2) := 0;
  v_conversion numeric(18, 2) := 0;
  v_finished numeric(18, 2);
  v_row record;
  v_movement_cost numeric(18, 2);
  v_entry uuid;
  v_inventory uuid;
  v_absorbed uuid;
  v_lines jsonb := '[]'::jsonb;
begin
  select * into v_mo from public.manufacturing_orders where id = p_mo_id
    for update;
  if v_mo.id is null then
    raise exception 'No such manufacturing order' using errcode = 'P0002';
  end if;
  if not app.can_post(v_mo.org_id) then
    raise exception 'You may not post a manufacturing order'
      using errcode = '42501';
  end if;
  if v_mo.posted_at is not null then
    raise exception 'This order has already been posted'
      using errcode = '22023';
  end if;
  if v_mo.status not in ('confirmed', 'in_progress') then
    raise exception 'Only a confirmed order can be posted; this one is %',
      v_mo.status using errcode = '22023';
  end if;

  v_done := coalesce(p_quantity_done, v_mo.quantity);
  if v_done <= 0 then
    raise exception 'Nothing was produced' using errcode = '22023';
  end if;

  -- A short run consumes proportionally less. Costing the whole recipe
  -- against half an output is how a finished item ends up carried at
  -- twice what it is worth.
  v_ratio := v_done / v_mo.quantity;

  select id into v_inventory from public.accounts
   where org_id = v_mo.org_id and code = '1310' and not is_group limit 1;
  if v_inventory is null then
    raise exception 'The chart of accounts has no inventory account'
      using errcode = '22023';
  end if;
  v_absorbed := app.absorption_account(v_mo.org_id);

  -- Components out, at what they are carried at. `assembly_out` and
  -- `assembly_in` were in `app.stock_movement_type` from 0006 and had
  -- never had a caller — they were put there for exactly this.
  for v_row in
    select c.*, i.code as item_code
      from public.mo_components c
      join public.items i on i.id = c.item_id
     where c.mo_id = p_mo_id
  loop
    insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, source_table, source_id)
    values (v_mo.org_id,
            v_mo.order_no || '-C-' || substr(v_row.id::text, 1, 8),
            app.today(), 'assembly_out', v_row.item_id, v_mo.warehouse_id,
            -round(v_row.quantity_required * v_ratio, 4),
            'manufacturing_orders', p_mo_id)
    returning total_cost into v_movement_cost;

    -- `total_cost` comes back negative on an issue; the order records
    -- what it consumed, which is a positive amount of money.
    v_component_cost := v_component_cost + abs(v_movement_cost);

    update public.mo_components
       set quantity_issued = round(v_row.quantity_required * v_ratio, 4),
           total_cost = abs(v_movement_cost),
           unit_cost = case when v_row.quantity_required = 0 then 0
                       else round(abs(v_movement_cost) /
                                  round(v_row.quantity_required * v_ratio, 4), 6)
                       end
     where id = v_row.id;
  end loop;

  -- Conversion, at each work centre's rate. Actual minutes where they
  -- were recorded, planned where they were not — a shop that has not
  -- booked its time still has to cost its output.
  select coalesce(sum(round(
           (case when o.actual_minutes > 0 then o.actual_minutes
                 else o.planned_minutes * v_ratio end) / 60.0
           * w.cost_per_hour, 2)), 0)
    into v_conversion
    from public.mo_operations o
    join public.work_centres w on w.id = o.work_centre_id
   where o.mo_id = p_mo_id;

  v_finished := v_component_cost + v_conversion;

  -- Finished goods in, at what they cost to make.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table, source_id)
  values (v_mo.org_id, v_mo.order_no || '-F', app.today(), 'assembly_in',
          v_mo.item_id, v_mo.warehouse_id, v_done,
          round(v_finished / v_done, 6), 'manufacturing_orders', p_mo_id);

  -- The ledger, mirroring it. Inventory rises by the finished value and
  -- falls by the components; the difference is the conversion cost,
  -- taken back out of the profit and loss so the wages already expensed
  -- are not counted a second time.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_inventory, 'debit', v_finished,
                       'credit', 0,
                       'description', 'Finished ' || v_mo.order_no),
    jsonb_build_object('account_id', v_inventory, 'debit', 0,
                       'credit', v_component_cost,
                       'description', 'Components ' || v_mo.order_no),
    jsonb_build_object('account_id', v_absorbed, 'debit', 0,
                       'credit', v_conversion,
                       'description', 'Conversion ' || v_mo.order_no));

  v_entry := app.create_gl_entry_internal(
    v_mo.org_id, app.today(), 'manufacturing', v_lines,
    'Manufacturing order ' || v_mo.order_no,
    'manufacturing_orders', p_mo_id);

  update public.manufacturing_orders
     set status = 'done',
         quantity_done = v_done,
         component_cost = v_component_cost,
         conversion_cost = v_conversion,
         posted_at = now(),
         gl_entry_id = v_entry,
         updated_at = now()
   where id = p_mo_id;

  return v_entry;
end; $$;

-- The day a chicken became eight pieces.
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
  v_track text;
  v_run   uuid := gen_random_uuid();
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

  select i.tracking into v_track from public.items i where i.id = v_c.from_item_id;
  if v_track is not null and v_track <> 'none'
     and app.lot_available(v_c.from_item_id, v_wh) < v_qty then
    raise exception
      'The batches of it in that store come to %, which is less than the % '
      'this would cut up.',
      round(app.lot_available(v_c.from_item_id, v_wh), 4), round(v_qty, 4)
      using errcode = '23514';
  end if;

  insert into public.stock_movements (
    org_id, movement_no, movement_date, movement_type, item_id,
    warehouse_id, quantity, unit_cost, source_table, source_id,
    source_line_id, notes, created_by)
  values (
    v_c.org_id,
    app.next_document_number_internal(v_c.org_id, 'stock_movement'),
    app.today(), 'assembly_out', v_c.from_item_id, v_wh, -v_qty, 0,
    'item_conversions', p_conversion, v_run, v_c.name, auth.uid());

  select -sm.total_cost into v_value
    from public.stock_movements sm
   where sm.source_table = 'item_conversions' and sm.source_line_id = v_run
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
      warehouse_id, quantity, unit_cost, source_table, source_id,
      source_line_id, notes, created_by)
    values (
      v_c.org_id,
      app.next_document_number_internal(v_c.org_id, 'stock_movement'),
      app.today(), 'assembly_in', v_out.item_id, v_wh, v_oqty,
      case when v_oqty = 0 then 0 else round(v_share / v_oqty, 6) end,
      'item_conversions', p_conversion, v_run, v_c.name, auth.uid());
  end loop;

  return round(v_value, 2);
end;
$$;

-- The day a transfer arrived at the other warehouse.
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
        app.today(), 'transfer_in', v_line.item_id,
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
      v_t.org_id, app.today(), 'stock_movement', v_lines,
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

-- And the day it was raised.
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
      coalesce(p_date, app.today()), p_from, p_to,
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

-- The day freight was apportioned over what it cost.
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
            coalesce(p_date, app.today()), p_notes, auth.uid())
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

-- The day a forecast became a purchase order, and the rate on it.
-- `0205` wrote this as `create function` after dropping the three-argument
-- version it replaced. Restated here, there is nothing to drop.
create or replace function public.create_po_from_suggestions(
  p_org           uuid,
  p_lines         jsonb default null,
  p_expected_date date default null,
  p_warehouse     uuid default null)
returns table (
  document_id    uuid,
  doc_no         text,
  supplier_id    uuid,
  supplier_name  text,
  line_count     integer,
  total_quantity numeric,
  note           text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run       uuid;
  v_sup       record;
  v_row       record;
  v_doc       uuid;
  v_no        text;
  v_line_no   integer;
  v_price     numeric;
  v_tax_code  uuid;
  v_tax_rate  numeric;
  v_currency  char(3);
  v_rate      numeric;
  v_qty       numeric;
  v_expected  date;
  v_orphans   text[];
  v_orphan_q  numeric;
begin
  if not app.can_read_module(p_org, 'forecasting') then
    raise exception 'not permitted to read forecasting for this organization'
      using errcode = '42501';
  end if;

  -- Raising a purchase order is a purchasing act, whoever asked for it.
  -- A forecasting licence is not a licence to commit the company to
  -- buying something.
  if not app.can_write_module(p_org, 'purchases') then
    raise exception 'not permitted to raise purchase orders for this organization'
      using errcode = '42501';
  end if;

  select r.id into v_run
    from public.forecast_runs r
   where r.org_id = p_org
     and r.warehouse_id is not distinct from p_warehouse
   order by r.run_at desc
   limit 1;

  if v_run is null then
    raise exception
      'No forecast has been run for this organization and location yet.'
      using errcode = 'P0002';
  end if;

  for v_sup in
    select w.supplier_id as sup, c.name as sup_name,
           coalesce(c.currency, 'MYR')::char(3) as sup_currency,
           c.payment_term_id as sup_term, max(w.lead_time_days) as max_lead
      from app.forecast_wanted(p_org, v_run, p_lines) w
      join public.contacts c on c.id = w.supplier_id
     group by w.supplier_id, c.name, c.currency, c.payment_term_id
     order by c.name
  loop
    v_currency := v_sup.sup_currency;

    -- A foreign supplier with no rate on file is that supplier's
    -- problem, not the whole replenishment's. Their order is left out
    -- with a reason rather than aborting the orders that can be raised.
    begin
      v_rate := app.exchange_rate_for(p_org, v_currency, app.today());
    exception
      when sqlstate 'P0002' or sqlstate '23514' then
        v_rate := null;
    end;

    if v_rate is null then
      select count(*), coalesce(sum(w.want), 0)
        into line_count, total_quantity
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup;
      document_id := null;
      doc_no := null;
      supplier_id := v_sup.sup;
      supplier_name := v_sup.sup_name;
      note := format('No exchange rate for %s on or before today, so no '
                     'order was raised. Enter one and try again.', v_currency);
      return next;
      continue;
    end if;

    -- Far enough out to be there when it is needed: the longest lead
    -- time on the order, because the document carries one date and the
    -- slowest line sets it.
    v_expected := coalesce(p_expected_date,
                           app.today() + ceil(v_sup.max_lead)::integer);

    v_no := app.next_document_number_internal(p_org, 'purchase_order');

    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, expected_date, contact_id,
      payment_term_id, currency, exchange_rate, status, created_by,
      internal_notes)
    values (
      p_org, 'purchase_order', v_no, app.today(), v_expected, v_sup.sup,
      v_sup.sup_term, v_currency, v_rate, 'draft', auth.uid(),
      'Raised from the inventory forecast of ' || app.today()::text)
    returning id into v_doc;

    v_line_no := 0;
    v_qty     := 0;

    for v_row in
      select w.*
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup
       order by w.item_code
    loop
      -- What this was last bought for: from this supplier by preference,
      -- and in this order's currency, because a price in another
      -- currency is not a price. Falls back to the item's cost.
      select l.unit_price into v_price
        from public.purchase_document_lines l
        join public.purchase_documents d on d.id = l.document_id
       where l.org_id = p_org
         and l.item_id = v_row.item_id
         and d.doc_type in ('bill', 'purchase_order')
         and d.status <> 'void'
         and d.deleted_at is null
         and d.currency = v_currency
       order by (d.contact_id = v_sup.sup) desc,
                d.doc_date desc, d.created_at desc
       limit 1;

      v_price := coalesce(v_price, v_row.cost_price, 0);

      v_tax_code := v_row.purchase_tax_code_id;
      v_tax_rate := 0;
      if v_tax_code is not null then
        select t.rate into v_tax_rate
          from public.tax_codes t
         where t.id = v_tax_code and t.is_active;
        if v_tax_rate is null then
          -- Deactivated since the item was set up. Ordering with no tax
          -- is better than ordering at a rate nobody can charge.
          v_tax_code := null;
          v_tax_rate := 0;
        end if;
      end if;

      v_line_no := v_line_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price,
        tax_code_id, tax_rate, warehouse_id, forecast_line_id)
      values (
        p_org, v_doc, v_line_no, 'item', v_row.item_id, v_row.item_name,
        v_row.classification_code, v_row.want, v_row.uom_code, v_price,
        v_tax_code, v_tax_rate, v_row.warehouse_id, v_row.line_id);

      v_qty := v_qty + v_row.want;
    end loop;

    document_id := v_doc;
    doc_no := v_no;
    supplier_id := v_sup.sup;
    supplier_name := v_sup.sup_name;
    line_count := v_line_no;
    total_quantity := v_qty;
    note := null;
    return next;
  end loop;

  -- And the ones nobody can be asked to supply.
  select array_agg(w.item_code order by w.item_code), coalesce(sum(w.want), 0)
    into v_orphans, v_orphan_q
    from app.forecast_wanted(p_org, v_run, p_lines) w
   where w.supplier_id is null;

  if coalesce(array_length(v_orphans, 1), 0) > 0 then
    document_id := null;
    doc_no := null;
    supplier_id := null;
    supplier_name := null;
    line_count := array_length(v_orphans, 1);
    total_quantity := v_orphan_q;
    note := format(
      '%s item(s) have no supplier and were not ordered: %s. Set a '
      'preferred supplier on the item, or a supplier in its forecast '
      'parameters.',
      array_length(v_orphans, 1), array_to_string(v_orphans, ', '));
    return next;
  end if;

  return;
end;
$$;

-- The day somebody's onboarding starts.
create or replace function public.start_onboarding(
  p_employee_id uuid,
  p_template_id uuid default null,
  p_start_date date default null,
  p_kind text default 'onboarding')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org       uuid;
  v_hire      date;
  v_checklist uuid;
  v_start     date;
  v_n         integer;
begin
  select org_id, hire_date into v_org, v_hire
    from public.employees where id = p_employee_id;
  if v_org is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_org) then
    raise exception 'Only HR may start an onboarding checklist'
      using errcode = '42501';
  end if;
  if p_kind not in ('onboarding', 'offboarding') then
    raise exception 'Unknown checklist kind %', p_kind using errcode = '22023';
  end if;

  if p_template_id is not null
     and not exists (select 1 from public.onboarding_templates
                      where id = p_template_id and org_id = v_org) then
    raise exception 'That template belongs to another organization'
      using errcode = '42501';
  end if;

  -- An offboarding starts today; an onboarding starts on the hire date,
  -- which is usually in the future when somebody sets this up.
  v_start := coalesce(p_start_date,
    case when p_kind = 'onboarding' then v_hire else app.today() end,
    app.today());

  if exists (select 1 from public.onboarding_checklists
              where employee_id = p_employee_id and kind = p_kind
                and completed_at is null) then
    raise exception 'This employee already has an open % checklist', p_kind
      using errcode = '22023';
  end if;

  insert into public.onboarding_checklists
    (org_id, employee_id, template_id, kind, start_date)
  values (v_org, p_employee_id, p_template_id, p_kind, v_start)
  returning id into v_checklist;

  insert into public.onboarding_tasks
    (org_id, checklist_id, title, description, category, due_date,
     is_mandatory, sort_order)
  select v_org, v_checklist, i.title, i.description, i.category,
         v_start + i.due_offset_days, i.is_mandatory, i.sort_order
    from public.onboarding_template_items i
   where i.template_id = p_template_id
   order by i.sort_order;

  get diagnostics v_n = row_count;

  -- An empty template produces an empty checklist, which looks finished
  -- from every angle without anybody having done anything.
  if p_template_id is not null and v_n = 0 then
    raise exception 'That template has no items in it' using errcode = '23514';
  end if;

  return v_checklist;
end;
$$;

-- The day a deal was won or lost.
create or replace function public.close_opportunity(
  p_opportunity uuid,
  p_outcome text,
  p_reason text default null,
  p_competitor text default null,
  p_closed_on date default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_o      public.opportunities;
  v_stage  uuid;
  v_type   text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to close a deal' using errcode = '42501';
  end if;
  if p_outcome not in ('won', 'lost', 'abandoned') then
    raise exception
      'A deal closes as won, lost or abandoned; got %.', p_outcome
      using errcode = '22023';
  end if;
  if v_o.status <> 'open' then
    raise exception 'That deal is already closed as %.', v_o.status
      using errcode = '23514';
  end if;

  -- The point of the whole migration.
  if p_outcome <> 'won' and v_reason is null then
    raise exception
      'Say why it was %. A pipeline that records that deals died and not '
      'why cannot answer the only question it is for.', p_outcome
      using errcode = '23514';
  end if;

  -- The column the card lands in. Abandoned has no column of its own and
  -- should not: the board needs somewhere to put it, and the difference
  -- lives in the status.
  v_type := case when p_outcome = 'won' then 'won' else 'lost' end;
  select s.id into v_stage
    from public.pipeline_stages s
   where s.pipeline_id = v_o.pipeline_id and s.stage_type = v_type
   order by s.sort_order desc limit 1;
  if v_stage is null then
    raise exception
      'This pipeline has no % stage to close into. Add one in the '
      'pipeline setup first.', v_type using errcode = 'P0002';
  end if;

  -- First the stage, which lets `0009`'s trigger write the stage
  -- history, the probability and the close date exactly as a drag would.
  update public.opportunities
     set stage_id = v_stage, updated_at = now()
   where id = p_opportunity;

  -- Then the answers. `status` is set here rather than above because the
  -- trigger derives it from the stage and would overwrite it.
  update public.opportunities set
    status            = p_outcome,
    actual_close_date = coalesce(p_closed_on, actual_close_date, app.today()),
    won_reason        = case when p_outcome = 'won' then v_reason else null end,
    lost_reason       = case when p_outcome = 'won' then null else v_reason end,
    competitor        = nullif(trim(coalesce(p_competitor, '')), ''),
    updated_at        = now()
  where id = p_opportunity;
end $$;

-- And the trigger that dates it when the stage moves.
-- `0009` wrote this with no search_path and `0023`'s sweep pinned it
-- afterwards, by `alter function`. A restatement that copies only the
-- body loses that -- which is what `0206` warned about in as many words:
-- "the md5 body check I use to verify restatements cannot see
-- `proconfig`". `supabase/tests/search_path.sql` caught it; it is pinned
-- here rather than left for the sweep to catch again.
--
-- Restating it also tightens one privilege, measured rather than
-- assumed: it was the only one of the forty-three whose `proacl` was
-- still null, so PUBLIC held EXECUTE on it implicitly. `0165`'s event
-- trigger strips PUBLIC and anon from every function as it is created,
-- so it comes back as `{postgres=X/postgres}`. Nothing loses anything
-- it was using -- a trigger function is called by its trigger, which
-- runs as the table's owner -- and `0165` is the reason the implicit
-- grant was wrong in the first place.
create or replace function app.track_opportunity_stage()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_stage public.pipeline_stages;
begin
  new.weighted_amount := round(coalesce(new.amount, 0) * coalesce(new.probability, 0) / 100.0, 2);

  if tg_op = 'UPDATE' and new.stage_id is distinct from old.stage_id then
    new.stage_changed_at := now();

    select * into v_stage from public.pipeline_stages where id = new.stage_id;
    if found then
      new.probability      := v_stage.probability;
      new.weighted_amount  := round(coalesce(new.amount, 0) * v_stage.probability / 100.0, 2);
      new.status := case v_stage.stage_type
        when 'won'  then 'won'
        when 'lost' then 'lost'
        else 'open'
      end;
      if v_stage.stage_type in ('won', 'lost') and new.actual_close_date is null then
        new.actual_close_date := app.today();
      end if;
    end if;

    insert into public.opportunity_stage_history (
      org_id, opportunity_id, from_stage_id, to_stage_id, days_in_stage, changed_by
    ) values (
      new.org_id, new.id, old.stage_id, new.stage_id,
      greatest(0, extract(day from now() - old.stage_changed_at)::integer),
      auth.uid()
    );
  end if;

  return new;
end;
$$;

-- Which year a new organization's first fiscal year runs to.
create or replace function public.create_fiscal_year(
  p_org_id uuid, p_start_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org public.organizations; v_start date; v_end date; v_fy_id uuid;
  v_last date; v_p_start date; v_p_end date; i integer;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if not found then raise exception 'Organization % not found', p_org_id; end if;
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select max(end_date) into v_last from public.fiscal_years where org_id = p_org_id;

  if p_start_date is not null then
    v_start := p_start_date;
  elsif v_last is not null then
    v_start := (v_last + interval '1 day')::date;
  else
    v_end := (date_trunc('month', make_date(extract(year from app.today())::int,
                v_org.fiscal_year_end_month, 1))
              + interval '1 month' - interval '1 day')::date;
    if v_org.fiscal_year_end_day < 28 then
      v_end := make_date(extract(year from v_end)::int,
                 v_org.fiscal_year_end_month, v_org.fiscal_year_end_day);
    end if;
    if v_end < app.today() then v_end := (v_end + interval '1 year')::date; end if;
    v_start := (v_end - interval '1 year' + interval '1 day')::date;
  end if;

  v_end := (v_start + interval '1 year' - interval '1 day')::date;

  if exists (select 1 from public.fiscal_years f
              where f.org_id = p_org_id
                and f.start_date <= v_end and f.end_date >= v_start) then
    raise exception 'A fiscal year already covers % to %', v_start, v_end
      using errcode = '23505';
  end if;

  insert into public.fiscal_years (org_id, name, start_date, end_date)
  values (p_org_id,
          case when extract(year from v_start) = extract(year from v_end)
               then extract(year from v_start)::text
               else extract(year from v_start)::text || '/' ||
                    extract(year from v_end)::text end,
          v_start, v_end)
  returning id into v_fy_id;

  for i in 0 .. 11 loop
    v_p_start := (v_start + (i || ' months')::interval)::date;
    v_p_end := (v_p_start + interval '1 month' - interval '1 day')::date;
    insert into public.fiscal_periods
      (org_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),
            v_p_start, v_p_end);
  end loop;

  return v_fy_id;
end; $$;

-- And the day the organization itself was created.
CREATE OR REPLACE FUNCTION public.create_organization(p_name text, p_slug text DEFAULT NULL::text, p_entity_type app.entity_type DEFAULT 'sdn_bhd'::app.entity_type, p_registration_no text DEFAULT NULL::text, p_tin text DEFAULT NULL::text, p_msic_code text DEFAULT NULL::text, p_business_activity text DEFAULT NULL::text, p_state_code text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_postcode text DEFAULT NULL::text, p_address_line1 text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_is_sst_registered boolean DEFAULT false, p_sst_registration_no text DEFAULT NULL::text, p_fiscal_year_end_month smallint DEFAULT 12, p_country_code text DEFAULT 'MYS'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org_id uuid; v_slug text; v_ar_id uuid; v_ap_id uuid;
  v_out_tax_id uuid; v_in_tax_id uuid; v_svc_tax uuid; v_na_tax uuid;
  v_pipeline_id uuid; v_suffix integer := 0; v_base text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  v_base := trim(both '-' from regexp_replace(lower(coalesce(p_slug, p_name)), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'org'; end if;
  v_slug := v_base;
  while exists (select 1 from public.organizations o where o.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.organizations (
    name, legal_name, slug, entity_type, registration_no, tin, msic_code,
    business_activity, state_code, city, postcode, address_line1,
    phone, email, is_sst_registered, sst_registration_no,
    fiscal_year_end_month, einvoice_tin, einvoice_id_value, einvoice_id_type,
    books_start_date, country_code, created_by
  ) values (
    p_name, p_name, v_slug, p_entity_type, p_registration_no, p_tin, p_msic_code,
    p_business_activity, p_state_code, p_city, p_postcode, p_address_line1,
    p_phone, p_email, p_is_sst_registered, p_sst_registration_no,
    p_fiscal_year_end_month, p_tin, p_registration_no, 'BRN',
    app.today(), coalesce(nullif(btrim(p_country_code), ''), 'MYS'),
    auth.uid()
  ) returning id into v_org_id;

  perform app.seed_chart_of_accounts(v_org_id);

  select id into v_ar_id from public.accounts where org_id = v_org_id and code = '1210';
  select id into v_ap_id from public.accounts where org_id = v_org_id and code = '2110';
  select id into v_out_tax_id from public.accounts where org_id = v_org_id and code = '2130';
  select id into v_in_tax_id from public.accounts where org_id = v_org_id and code = '1410';

  insert into public.tax_codes (
    org_id, code, name, tax_type_code, rate, applies_to,
    sales_tax_account_id, purchase_tax_account_id, is_exempt, is_default
  ) values
    (v_org_id,'NA','Not Applicable','06',0,'both',v_out_tax_id,v_in_tax_id,false,true),
    (v_org_id,'ST8','Service Tax 8%','02',8,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'ST6','Service Tax 6%','02',6,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'SL10','Sales Tax 10%','01',10,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'SL5','Sales Tax 5%','01',5,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'TTX','Tourism Tax','03',0,'sales',v_out_tax_id,null,false,false),
    (v_org_id,'EXM','Exempt','E',0,'both',v_out_tax_id,v_in_tax_id,true,false),
    (v_org_id,'ZR','Zero Rated / Export','06',0,'sales',v_out_tax_id,null,false,false)
  on conflict (org_id, code) do nothing;

  select id into v_na_tax from public.tax_codes where org_id = v_org_id and code = 'NA';
  select id into v_svc_tax from public.tax_codes where org_id = v_org_id and code = 'ST8';

  update public.organizations
     set default_sales_tax_code_id = case when p_is_sst_registered then v_svc_tax else v_na_tax end,
         default_purchase_tax_code_id = case when p_is_sst_registered then v_svc_tax else v_na_tax end
   where id = v_org_id;

  insert into public.payment_terms (org_id, code, name, days, term_type, is_default) values
    (v_org_id,'COD','Cash on Delivery',0,'cod',false),
    (v_org_id,'PREPAID','Prepaid',0,'prepaid',false),
    (v_org_id,'NET7','7 Days',7,'net',false),
    (v_org_id,'NET14','14 Days',14,'net',false),
    (v_org_id,'NET30','30 Days',30,'net',true),
    (v_org_id,'NET60','60 Days',60,'net',false),
    (v_org_id,'NET90','90 Days',90,'net',false),
    (v_org_id,'EOM30','End of Month + 30',30,'eom',false)
  on conflict (org_id, code) do nothing;

  insert into public.warehouses (org_id, code, name, is_default, state_code, city)
  values (v_org_id, 'MAIN', 'Main Warehouse', true, p_state_code, p_city)
  on conflict (org_id, code) do nothing;

  insert into public.price_levels (org_id, code, name, is_default) values
    (v_org_id,'STD','Standard Price',true),
    (v_org_id,'WHL','Wholesale',false),
    (v_org_id,'RTL','Retail',false)
  on conflict (org_id, code) do nothing;

  insert into public.pipelines (org_id, name, description, is_default)
  values (v_org_id, 'Sales Pipeline', 'Default sales process', true)
  returning id into v_pipeline_id;

  insert into public.pipeline_stages (org_id, pipeline_id, name, probability, stage_type, color, sort_order) values
    (v_org_id,v_pipeline_id,'Qualification',10,'open','#94A3B8',1),
    (v_org_id,v_pipeline_id,'Needs Analysis',25,'open','#60A5FA',2),
    (v_org_id,v_pipeline_id,'Proposal Sent',50,'open','#818CF8',3),
    (v_org_id,v_pipeline_id,'Negotiation',75,'open','#FBBF24',4),
    (v_org_id,v_pipeline_id,'Closed Won',100,'won','#34D399',5),
    (v_org_id,v_pipeline_id,'Closed Lost',0,'lost','#F87171',6);

  perform public.create_fiscal_year(v_org_id, null);

  update public.profiles set last_org_id = v_org_id where id = auth.uid();
  return v_org_id;
end; $function$;

-- =====================================================================
-- iAkauntan :: 0152 opening stock
--
-- The last piece of a migration. 0150 brought the unpaid invoices and
-- bills across, 0151 brought the trial balance and squared 3900 off, and
-- both of them said the same thing about stock: the inventory *figure*
-- can be carried over, but there is nothing behind it. 0151 warns in so
-- many words that until quantities are entered, cost of sales takes an
-- average of nothing.
--
-- This enters the quantities.
--
-- ---------------------------------------------------------------------
-- Nothing is posted to the ledger
--
-- The same rule the control accounts follow in 0151, for the same
-- reason. The inventory balance came in with the trial balance; posting
-- it again here would double it. So this writes stock movements, which
-- give quantity on hand and — the part that matters afterwards — a
-- weighted average cost for every item, and posts no journal at all.
--
-- What it does instead is **compare**. The value of the stock brought in
-- against the balance already sitting in the inventory accounts, as a
-- row at the end of the file. Agreement means the migration is whole;
-- disagreement is a number somebody can go and find, and is reported
-- rather than adjusted, because an automatic adjustment here would be
-- writing off stock nobody has looked at.
--
-- ---------------------------------------------------------------------
-- Lots, and why the trigger had to change
--
-- `app.materialise_movement_lots` fires on every stock movement and, for
-- an item tracked by batch or serial, reads the lots off
-- `document_line_lots` — which is keyed to a line of a sales document, a
-- purchase document or a stock adjustment. An opening movement belongs
-- to none of those, so the trigger would find no lots and refuse the
-- insert.
--
-- Rather than invent a fourth document to hang lot lines off, the
-- trigger now stands aside for `source_table = 'opening_stock'` and this
-- importer writes the lot and its movement row itself. That is a
-- narrower change than it looks: the trigger's job is to turn *document
-- lines* into lot movements, and an opening balance has no document.
-- Everything else it refuses, it still refuses.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The trigger stands aside for an opening balance
--
-- Otherwise identical to 0106's. The early return is the only change,
-- and it is deliberately narrow: any other source table with a tracked
-- item and no lot lines is still refused, which is the check that stops
-- a tracked item being received without anybody naming what arrived.
-- ---------------------------------------------------------------------
create or replace function app.materialise_movement_lots()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_track text;
  v_code  text;
  v_sign  numeric := sign(new.quantity);
  v_found integer := 0;
  r       record;
  v_lot   uuid;
begin
  select i.tracking, i.code into v_track, v_code
    from public.items i where i.id = new.item_id;

  if v_track is null or v_track = 'none' then
    return null;
  end if;

  -- An opening balance has no document line to read lots from, so
  -- `import_opening_stock` writes them itself and this stands aside.
  if new.source_table = 'opening_stock' then
    return null;
  end if;

  for r in
    select d.lot_ref, d.quantity, d.expiry_date, d.manufactured_on,
           d.supplier_lot_ref
      from public.document_line_lots d
     where new.source_line_id is not null
       and ((new.source_table = 'sales_documents'    and d.sales_line_id = new.source_line_id)
         or (new.source_table = 'purchase_documents' and d.purchase_line_id = new.source_line_id)
         or (new.source_table = 'stock_adjustments'  and d.adjustment_line_id = new.source_line_id))
  loop
    insert into public.stock_lots
      (org_id, item_id, lot_ref, kind, expiry_date, manufactured_on,
       supplier_lot_ref)
    values (new.org_id, new.item_id, r.lot_ref, v_track,
            r.expiry_date, r.manufactured_on, r.supplier_lot_ref)
    on conflict (org_id, item_id, lot_ref) do update
      set expiry_date      = coalesce(excluded.expiry_date, stock_lots.expiry_date),
          manufactured_on  = coalesce(excluded.manufactured_on,
                                      stock_lots.manufactured_on),
          supplier_lot_ref = coalesce(excluded.supplier_lot_ref,
                                      stock_lots.supplier_lot_ref),
          updated_at       = now()
    returning id into v_lot;

    insert into public.stock_movement_lots
      (org_id, movement_id, lot_id, quantity)
    values (new.org_id, new.id, v_lot, r.quantity * v_sign);

    v_found := v_found + 1;
  end loop;

  if v_found = 0 then
    raise exception
      'Item % is tracked by %, so every unit has to be named before this '
      'can be posted. Nothing was recorded against this line.',
      v_code, v_track using errcode = '23514';
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- The importer
-- ---------------------------------------------------------------------
create or replace function public.import_opening_stock(
  p_org_id uuid,
  p_rows jsonb,
  p_as_at date,
  p_commit boolean default false)
returns table (row_no integer, code text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_item_code text; v_wh_code text; v_lot_ref text;
  v_qty numeric; v_cost numeric; v_expiry date;
  v_problem text; v_kind text; v_key text;
  v_item_id uuid; v_tracking text; v_tracked boolean;
  v_wh_id uuid; v_default_wh uuid;
  v_value numeric := 0;
  v_ledger numeric;
  v_movement_id uuid; v_lot_id uuid;
begin
  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;
    v_kind := 'ok';

    v_item_code := app.import_text(r, 'item_code');
    v_wh_code   := app.import_text(r, 'warehouse_code');
    v_lot_ref   := app.import_text(r, 'lot_no');
    v_qty       := app.import_number(app.import_text(r, 'quantity'), null);
    v_cost      := app.import_number(app.import_text(r, 'unit_cost'), null);
    v_expiry    := app.import_date(app.import_text(r, 'expiry_date'));

    v_item_id := null; v_tracking := null; v_wh_id := null;
    v_tracked := null;
    if v_item_code is not null then
      select it.id, it.tracking, it.track_inventory
        into v_item_id, v_tracking, v_tracked
        from public.items it
       where it.org_id = p_org_id and lower(it.code) = lower(v_item_code)
         and it.deleted_at is null;
    end if;
    if v_wh_code is not null then
      select w.id into v_wh_id from public.warehouses w
       where w.org_id = p_org_id and lower(w.code) = lower(v_wh_code);
    end if;

    -- One line per item, warehouse and lot. Two lines for the same three
    -- would both post, which is a quantity nobody counted.
    v_key := lower(coalesce(v_item_code, '')) || '|'
          || lower(coalesce(v_wh_code, '')) || '|'
          || lower(coalesce(v_lot_ref, ''));

    if v_item_code is null then
      v_problem := 'No item code.';
    elsif v_item_id is null then
      v_problem := format(
        '%s is not an item here. Import the item list first.', v_item_code);
    elsif not coalesce(v_tracked, false) then
      -- A service or a non-stock item has no quantity to hold, and
      -- giving it one produces a stock figure that never moves.
      v_problem := format(
        '%s is not stock-tracked, so it has no quantity to bring in.',
        v_item_code);
    elsif v_key = any (v_seen) then
      v_problem := format(
        '%s is in this file more than once for the same warehouse and lot.',
        v_item_code);
    elsif v_wh_code is not null and v_wh_id is null then
      v_problem := format('%s is not a warehouse here.', v_wh_code);
    elsif app.import_text(r, 'quantity') is null then
      v_problem := 'No quantity.';
    elsif v_qty is null then
      v_problem := format('"%s" is not a quantity.',
                          app.import_text(r, 'quantity'));
    elsif v_qty <= 0 then
      -- Negative stock is a real state and not one to *open* with: it
      -- means something was issued that was never received, which is a
      -- correction to make after the migration rather than during it.
      v_problem := 'An opening quantity has to be more than nothing.';
    elsif app.import_text(r, 'unit_cost') is null then
      v_problem := 'No unit cost. It is what cost of sales will be '
                || 'charged at until the next purchase.';
    elsif v_cost is null then
      v_problem := format('"%s" is not a cost.',
                          app.import_text(r, 'unit_cost'));
    elsif v_cost < 0 then
      v_problem := 'A cost cannot be negative.';
    elsif v_tracking <> 'none' and v_lot_ref is null then
      v_problem := format(
        '%s is tracked by %s, so the opening quantity has to say which '
        '%s it is.', v_item_code, v_tracking,
        case when v_tracking = 'serial' then 'serial number' else 'batch' end);
    elsif v_tracking = 'none' and v_lot_ref is not null then
      v_problem := format(
        '%s is not tracked by batch or serial, so a lot number here would '
        'be recorded and never looked at.', v_item_code);
    elsif exists (select 1 from public.stock_movements m
                   where m.org_id = p_org_id and m.item_id = v_item_id)
    then
      -- Opening means opening. An item that has already moved has a
      -- history, and adding to it here would be an adjustment wearing
      -- the wrong name.
      v_problem := format(
        '%s has already moved in this system. An opening balance is for '
        'stock that has not.', v_item_code);
    end if;

    if v_problem is null then
      v_seen := v_seen || v_key;
      v_value := v_value + round(v_qty * v_cost, 2);
    else
      v_kind := 'error';
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_item_code, ''),
      'status', v_kind,
      'message', coalesce(v_problem, ''));
  end loop;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  -- What the ledger already says stock is worth. Read whether or not
  -- this is a commit, because the comparison is the reason somebody runs
  -- the preview.
  select round(coalesce(sum(l.debit - l.credit), 0), 2) into v_ledger
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id and a.account_subtype = 'inventory'
     and e.status = 'posted' and e.entry_date <= p_as_at;

  if p_commit then
    if exists (select 1 from public.stock_movements m
                where m.org_id = p_org_id
                  and m.movement_type = 'opening_balance')
    then
      raise exception
        'Opening stock has already been brought into this company.'
        using errcode = '22023';
    end if;

    v_default_wh := public.ensure_default_warehouse(p_org_id);

    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_item_code := app.import_text(r, 'item_code');
      v_wh_code   := app.import_text(r, 'warehouse_code');
      v_lot_ref   := app.import_text(r, 'lot_no');
      v_qty       := app.import_number(app.import_text(r, 'quantity'), null);
      v_cost      := app.import_number(app.import_text(r, 'unit_cost'), null);
      v_expiry    := app.import_date(app.import_text(r, 'expiry_date'));

      select it.id, it.tracking into v_item_id, v_tracking
        from public.items it
       where it.org_id = p_org_id and lower(it.code) = lower(v_item_code)
         and it.deleted_at is null;

      v_wh_id := v_default_wh;
      if v_wh_code is not null then
        select w.id into v_wh_id from public.warehouses w
         where w.org_id = p_org_id and lower(w.code) = lower(v_wh_code);
      end if;

      insert into public.stock_movements (
        org_id, movement_no, movement_date, movement_type,
        item_id, warehouse_id, quantity, unit_cost,
        source_table, notes, created_by)
      values (
        p_org_id,
        app.next_document_number_internal(p_org_id, 'stock_movement'),
        p_as_at, 'opening_balance'::app.stock_movement_type,
        v_item_id, v_wh_id, v_qty, v_cost,
        'opening_stock',
        'Opening stock brought forward on ' || p_as_at, auth.uid())
      returning id into v_movement_id;

      -- Written here rather than by the trigger, which stands aside for
      -- this source table because there is no document line to read.
      if v_tracking <> 'none' then
        insert into public.stock_lots
          (org_id, item_id, lot_ref, kind, expiry_date)
        values (p_org_id, v_item_id, v_lot_ref, v_tracking, v_expiry)
        on conflict (org_id, item_id, lot_ref) do update
          set expiry_date = coalesce(excluded.expiry_date,
                                     stock_lots.expiry_date),
              updated_at = now()
        returning id into v_lot_id;

        insert into public.stock_movement_lots
          (org_id, movement_id, lot_id, quantity)
        values (p_org_id, v_movement_id, v_lot_id, v_qty);
      end if;
    end loop;

    v_results := (
      select jsonb_agg(
               case when x ->> 'status' = 'ok'
                    then jsonb_set(x, '{status}', '"imported"')
                    else x end)
        from jsonb_array_elements(v_results) x);
  end if;

  -- The comparison, as a row of its own. Last, because it is about the
  -- file rather than any line in it.
  if v_bad = 0 then
    v_results := v_results || jsonb_build_object(
      'row_no', i + 1,
      'code', '',
      'status', case when round(v_value - v_ledger, 2) = 0
                     then 'ok' else 'warning' end,
      'message', case when round(v_value - v_ledger, 2) = 0
        then format(
          'The stock in this file is worth %s, which is what the '
          'inventory accounts already say.',
          to_char(v_value, 'FM999999999990.00'))
        else format(
          'The stock in this file is worth %s and the inventory accounts '
          'say %s, a difference of %s. Neither is adjusted to the other — '
          'writing off stock nobody has looked at is not something this '
          'should do on its own.',
          to_char(v_value, 'FM999999999990.00'),
          to_char(v_ledger, 'FM999999999990.00'),
          to_char(v_value - v_ledger, 'FM999999999990.00')) end);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status',
           x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end $$;

revoke all on function public.import_opening_stock(uuid, jsonb, date, boolean)
  from public, anon;
grant execute on function public.import_opening_stock(uuid, jsonb, date, boolean)
  to authenticated;

comment on function public.import_opening_stock(uuid, jsonb, date, boolean) is
  'Opening stock quantities and costs. Writes movements and average '
  'costs but no journal — the inventory balance came in with the trial '
  'balance — and compares the two, reporting any difference rather than '
  'adjusting either to the other.';

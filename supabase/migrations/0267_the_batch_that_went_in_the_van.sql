-- =====================================================================
-- The batch a recipe took, the batch that went in the van, and the
-- batch a chicken's pieces belong to
--
-- 0106 made a promise: an item with `tracking` set to batch or serial
-- has every unit of every movement named, and `check_movement_lots`
-- enforces it as a deferred constraint. `materialise_movement_lots`
-- keeps the promise by copying the lot lines a *document* carried, and
-- it knows exactly three documents — sales, purchases, stock
-- adjustments. Anything else, it raises:
--
--     Item SANTAN is tracked by batch, so every unit has to be named
--     before this can be posted. Nothing was recorded against this line.
--
-- 0264 and 0265 then wrote movements from three new places, and none of
-- them is one of those three. The consequences, in order of how much
-- they cost:
--
--   * A recipe whose ingredient is batch-tracked makes the sale
--     completion trigger raise. By then the invoice is posted and the
--     customer has paid, so the whole transaction rolls back and the
--     till reports a failure for a sale that visibly happened. This is
--     live.
--   * A transfer refuses any tracked item, so a central kitchen that
--     batches its santan cannot send any to a shop.
--   * A conversion refuses a tracked input, so a chicken with a batch
--     number cannot be cut up.
--
-- Latent rather than burning: `items.tracking` defaults to `none` and a
-- shop has to turn it on. But it turns "we started tracking batches" into
-- "no sale completes", which is not a thing to leave lying about.
--
-- ---------------------------------------------------------------------
-- Replaced from 0152, not from 0106
--
-- `materialise_movement_lots` has been re-created once already: 0152
-- added an arm so an opening balance, which has no document line to
-- read lots off, writes its own. A replacement built from 0106's copy
-- silently reverts that. This one carries it, and `opening_stock.sql`
-- is the test that says so.
--
-- ---------------------------------------------------------------------
-- Nothing here asks a cashier which batch
--
-- The three new sources have one thing in common: there is no screen at
-- the moment they happen. A recipe is consumed by a trigger, a transfer
-- is a van, and a conversion is somebody with a knife. So the lots are
-- chosen rather than asked for, and the rule is the one every kitchen
-- already follows: first to expire, first out.
--
-- On the way in there is nothing to choose. A transfer's receipt takes
-- exactly the lots its own dispatch sent — read off the outbound
-- movement, not picked again — so a batch keeps its identity and its
-- expiry date across the journey. That is the whole point of tracking
-- it: a recall that stops at the kitchen door is not a recall.
--
-- A conversion's outputs inherit the input's batch when there was only
-- one, because the pieces of one chicken are that chicken. When several
-- batches went into one run, the outputs get a lot named after the run
-- carrying the *earliest* expiry among them, which is the only answer
-- that is safe in the direction that matters.
--
-- ---------------------------------------------------------------------
-- A batch that is not there cannot be taken
--
-- `check_movement_lots` refuses a negative lot balance, and it is right
-- to: 0106 calls it "where a recall list starts lying". So the callers
-- cap rather than the trigger inventing.
--
--   * A transfer and a conversion refuse outright when the lots are
--     short, even for a shop that allows negative stock. Allowing a
--     negative *quantity* is a shop saying it has not counted; allowing
--     a negative *batch* is a shop claiming to have shipped a specific
--     carton it does not have.
--   * A recipe takes what the batches cover and no more. It cannot
--     refuse — the customer has paid — and a figure that agrees with
--     the batch ledger is worth more than one that is arithmetically
--     tidy and useless to a recall.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What the batches actually hold
-- ---------------------------------------------------------------------
create or replace function app.lot_available(
  p_item uuid, p_warehouse uuid)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(sum(b.quantity), 0)
    from public.v_lot_balances b
   where b.item_id = p_item
     and b.warehouse_id = p_warehouse
     and b.quantity > 0;
$$;

revoke all on function app.lot_available(uuid, uuid) from public, anon;
grant execute on function app.lot_available(uuid, uuid) to authenticated;

-- First to expire, first out. The same order `suggest_lots` offers a
-- human, without the membership check: this is called from inside a
-- trigger that has already established who is doing what.
create or replace function app.pick_lots_fefo(
  p_item uuid, p_warehouse uuid, p_quantity numeric)
returns table (lot_id uuid, take numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_left numeric := abs(coalesce(p_quantity, 0));
  r      record;
begin
  for r in
    select b.lot_id, b.quantity
      from public.v_lot_balances b
     where b.item_id = p_item
       and b.warehouse_id = p_warehouse
       and b.quantity > 0
     order by b.expiry_date asc nulls last, b.lot_ref
  loop
    exit when v_left <= 0;
    lot_id := r.lot_id;
    take   := least(r.quantity, v_left);
    v_left := v_left - take;
    return next;
  end loop;
end;
$$;

revoke all on function app.pick_lots_fefo(uuid, uuid, numeric)
  from public, anon;
grant execute on function app.pick_lots_fefo(uuid, uuid, numeric)
  to authenticated;

comment on function app.pick_lots_fefo(uuid, uuid, numeric) is
  'Which batches to take, earliest expiry first. Returns less than asked for when the batches do not cover it; the caller is responsible for not asking for more than they hold.';

-- ---------------------------------------------------------------------
-- Naming the units, when there is no document to read it off
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0106. The three documents it already knew are
-- unchanged; what follows them is the branch that used to be a raise.
create or replace function app.materialise_movement_lots()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_track text;
  v_code  text;
  v_sign  numeric := sign(new.quantity);
  v_found integer := 0;
  r       record;
  v_lot   uuid;
  v_ref   text;
  v_exp   date;
  v_n     integer;
begin
  select i.tracking, i.code into v_track, v_code
    from public.items i where i.id = new.item_id;

  if v_track is null or v_track = 'none' then
    return null;
  end if;

  -- 0152's arm, kept. An opening balance has no document line to read
  -- lots from, so `import_opening_stock` writes them itself and this
  -- stands aside. Carried across explicitly rather than inherited: this
  -- function is being replaced from source, and a replacement built
  -- from 0106's copy would silently revert it -- which is exactly what
  -- the first draft of this migration did, and what `opening_stock.sql`
  -- caught.
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

  if v_found > 0 then
    return null;
  end if;

  -- ------------------------------------------------------------------
  -- A transfer arriving: the same batches its own van carried
  -- ------------------------------------------------------------------
  --
  -- Read off the dispatch rather than picked again, so a batch keeps
  -- its identity across the journey. A short delivery takes from those
  -- batches earliest-expiry first and stops when the count is met; what
  -- is left behind is the shortfall the receipt already wrote off.
  if new.source_table = 'stock_transfers' and new.quantity > 0
     and new.source_line_id is not null then
    declare v_left numeric := new.quantity;
    begin
      for r in
        select sml.lot_id, -sml.quantity as quantity
          from public.stock_movement_lots sml
          join public.stock_movements m on m.id = sml.movement_id
          join public.stock_lots l on l.id = sml.lot_id
         where m.source_table = 'stock_transfers'
           and m.source_line_id = new.source_line_id
           and m.quantity < 0
         order by l.expiry_date asc nulls last, l.lot_ref
      loop
        exit when v_left <= 0;
        insert into public.stock_movement_lots
          (org_id, movement_id, lot_id, quantity)
        values (new.org_id, new.id, r.lot_id, least(r.quantity, v_left));
        v_left  := v_left - least(r.quantity, v_left);
        v_found := v_found + 1;
      end loop;
    end;
    if v_found > 0 then
      return null;
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- A conversion's output: the chicken it came off
  -- ------------------------------------------------------------------
  if new.source_table = 'item_conversions' and new.quantity > 0 then
    select count(distinct sml.lot_id),
           min(l.lot_ref), min(l.expiry_date)
      into v_n, v_ref, v_exp
      from public.stock_movement_lots sml
      join public.stock_lots l on l.id = sml.lot_id
      join public.stock_movements m on m.id = sml.movement_id
     where m.source_table = 'item_conversions'
       and m.source_line_id is not distinct from new.source_line_id
       and m.quantity < 0;

    -- Several batches in one pot: a lot of its own, carrying the
    -- earliest expiry of what went in. See the header -- the safe
    -- direction is the early one.
    if coalesce(v_n, 0) <> 1 then
      v_ref := 'CONV-' || to_char(new.movement_date, 'YYYYMMDD') || '-'
                       || left(replace(new.source_id::text, '-', ''), 6);
    end if;

    insert into public.stock_lots
      (org_id, item_id, lot_ref, kind, expiry_date)
    values (new.org_id, new.item_id, v_ref, v_track, v_exp)
    on conflict (org_id, item_id, lot_ref) do update
      set expiry_date = coalesce(excluded.expiry_date, stock_lots.expiry_date),
          updated_at  = now()
    returning id into v_lot;

    insert into public.stock_movement_lots
      (org_id, movement_id, lot_id, quantity)
    values (new.org_id, new.id, v_lot, new.quantity);
    return null;
  end if;

  -- ------------------------------------------------------------------
  -- Anything going out with nobody to ask: earliest expiry first
  -- ------------------------------------------------------------------
  if new.quantity < 0
     and new.source_table in ('stock_transfers', 'item_conversions', 'pos_sales')
  then
    for r in
      select p.lot_id, p.take
        from app.pick_lots_fefo(new.item_id, new.warehouse_id, new.quantity) p
    loop
      insert into public.stock_movement_lots
        (org_id, movement_id, lot_id, quantity)
      values (new.org_id, new.id, r.lot_id, -r.take);
      v_found := v_found + 1;
    end loop;
    if v_found > 0 then
      return null;
    end if;
  end if;

  raise exception
    'Item % is tracked by %, so every unit has to be named before this '
    'can be posted. Nothing was recorded against this line.',
    v_code, v_track using errcode = '23514';
end;
$$;

-- ---------------------------------------------------------------------
-- A recipe takes what the batches cover
-- ---------------------------------------------------------------------
--
-- Re-created from 0264 with one clause: a lot-tracked component is
-- capped at what its batches actually hold in that warehouse. It cannot
-- refuse — see 0264's header, by the time this runs the customer has
-- paid — and it must not ask for more than the batches cover, because
-- `check_movement_lots` refuses a negative batch balance and would take
-- the whole settled sale down with it.
--
-- An untracked component is unchanged and still goes negative, which is
-- the honest answer for a kitchen that has not weighed its rice.
create or replace function app.pos_deplete_recipes(p_sale uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_wh     uuid;
  v_row    record;
  v_cost   numeric := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
  v_moved  numeric;
  v_qty    numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    return null;
  end if;

  for v_row in
    with need as (
      select c.item_id, sum(c.quantity) as quantity
        from public.pos_sale_lines l
        cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
       where l.sale_id = p_sale and l.item_id is not null
       group by c.item_id
      union all
      select c.item_id, sum(c.quantity)
        from public.pos_sale_lines l
        join public.pos_sale_line_modifiers m on m.line_id = l.id
        join public.pos_modifiers pm on pm.id = m.modifier_id
        cross join lateral app.pos_item_consumption(
          pm.recipe_item_id,
          app.uom_qty(pm.recipe_item_id,
                      coalesce(pm.recipe_quantity, 0),
                      coalesce(pm.recipe_uom_code,
                               (select i.uom_code from public.items i
                                 where i.id = pm.recipe_item_id)))
            * m.quantity * l.quantity) c
       where l.sale_id = p_sale
         and pm.recipe_item_id is not null
         and coalesce(pm.recipe_quantity, 0) > 0
       group by c.item_id
    )
    select n.item_id, sum(n.quantity) as quantity, i.name, i.tracking
      from need n join public.items i on i.id = n.item_id
     where i.track_inventory
     group by n.item_id, i.name, i.tracking
     having sum(n.quantity) > 0
  loop
    v_qty := round(v_row.quantity, 4);

    -- The one new clause. See the header.
    if v_row.tracking is not null and v_row.tracking <> 'none' then
      v_qty := least(v_qty, round(app.lot_available(v_row.item_id, v_wh), 4));
    end if;
    if v_qty <= 0 then
      continue;
    end if;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id, notes)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      coalesce(v_sale.completed_at::date, current_date),
      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,
      'pos_sales', p_sale, 'Recipe ' || v_sale.sale_no);

    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id
     order by sm.created_at desc limit 1;

    v_cost := v_cost + coalesce(v_moved, 0);
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost ' || v_sale.sale_no,
      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients ' || v_sale.sale_no,
      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id,
    coalesce(v_sale.completed_at::date, current_date),
    'stock_movement', v_lines,
    'Recipe consumption ' || v_sale.sale_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

revoke all on function app.pos_deplete_recipes(uuid)
  from public, anon, authenticated;

comment on function app.pos_deplete_recipes(uuid) is
  'Moves a settled sale''s ingredients out of the outlet''s warehouse and posts their cost. A batch-tracked ingredient is taken only as far as its batches go, because a negative batch balance is refused and would fail a sale that has already been paid for.';

-- ---------------------------------------------------------------------
-- A transfer will not ship a batch it has not got
-- ---------------------------------------------------------------------
--
-- Re-created from 0265 with one clause. `allow_negative_stock` is a
-- shop saying it has not counted; it is not a shop claiming to have put
-- a specific carton on a van. A tracked item is checked against its
-- batches whatever that switch says.
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
    select l.*, i.name as item_name, i.uom_code as base_uom, i.tracking
      from public.stock_transfer_lines l
      join public.items i on i.id = l.item_id
     where l.transfer_id = p_id
     order by l.line_no
  loop
    v_qty := round(app.uom_qty(v_line.item_id, v_line.quantity, v_line.uom_code), 6);

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

    -- The new clause. See the header.
    if v_line.tracking is not null and v_line.tracking <> 'none'
       and app.lot_available(v_line.item_id, v_t.from_warehouse_id) < v_qty then
      raise exception
        'The batches of % in that store come to %, which is less than the '
        '% on this transfer. A van cannot carry a batch nobody has.',
        v_line.item_name,
        round(app.lot_available(v_line.item_id, v_t.from_warehouse_id), 4),
        round(v_qty, 4)
        using errcode = '23514';
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
-- And a conversion, for the same reason
-- ---------------------------------------------------------------------
--
-- Re-created from 0265 with the same batch check, plus one thing the
-- lot machinery needs: every movement of one run carries the same
-- `source_line_id`. Without it the trigger cannot tell this morning's
-- run of a conversion from this afternoon's, and the outputs of one
-- would inherit the batch of the other. There is no line table to name,
-- so the run's own identifier stands in — which is what the column
-- means: which occurrence of the source this movement belongs to.
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
    current_date, 'assembly_out', v_c.from_item_id, v_wh, -v_qty, 0,
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
      current_date, 'assembly_in', v_out.item_id, v_wh, v_oqty,
      case when v_oqty = 0 then 0 else round(v_share / v_oqty, 6) end,
      'item_conversions', p_conversion, v_run, v_c.name, auth.uid());
  end loop;

  return round(v_value, 2);
end;
$$;

revoke all on function public.run_item_conversion(uuid, numeric, uuid)
  from public, anon;
grant execute on function public.run_item_conversion(uuid, numeric, uuid)
  to authenticated;

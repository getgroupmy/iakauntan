-- =====================================================================
-- The gift set that is six other things
--
-- `items.item_type` has had `bundle` since 0003. It appears in that
-- check constraint and in 0103's import validator and **nowhere else**:
-- no explosion, no pricing, no screen. An enum value that implies a
-- capability nobody built is the same dead end the credit-note finding
-- was about, and it has been sitting there for two hundred and seventy
-- migrations.
--
-- Worse than absent. Because a bundle holds no stock of its own,
-- `post_sales_document` writes no movement for it -- the `track_inventory`
-- test sees false and skips the line. So a shop that set an item to
-- `bundle` and sold a hundred of them moved nothing off any shelf and
-- booked no cost of sale at all. The margin on those hundred is the
-- whole selling price.
--
-- ---------------------------------------------------------------------
-- A bundle is a recipe sold off an invoice
--
-- `pos_recipes` is already "an item made of other items", with a
-- recursive explosion, cycle detection that catches a bundle containing
-- itself through an intermediate, and wastage. A second table holding
-- the same shape would be the duplication removed in 0264, when
-- `pos_sold_out` turned out to be `pos_item_stops` under another name.
--
-- So a bundle *is* a `pos_recipes` row. `upsert_item_bundle` writes one
-- with a yield of one -- nobody makes twenty gift sets from a single
-- definition the way a kitchen makes twenty portions from one pot -- and
-- the POS and the invoice cycle read the same rows. The name on the
-- table is historical and says where the idea arrived, not who owns it.
--
-- ---------------------------------------------------------------------
-- What selling one does
--
-- On posting, each bundle line explodes and its components leave stock
-- at their own weighted average, and the total is the cost of sale:
--
--   Dr 5200 Cost of Goods Sold      Cr 1310 Inventory
--
-- A credit note for the same invoice puts them back, mirroring 0269.
--
-- A bundle that tracked inventory itself would move twice -- once as the
-- bundle, once as its parts -- so `upsert_item_bundle` refuses to define
-- one on an item that does, and says which switch to turn off.
--
-- ---------------------------------------------------------------------
-- Its own movement source, on purpose
--
-- The component movements are written as `sales_bundles`, not
-- `sales_documents`. A bundle's components are not the invoice line, so
-- the lot invariant finds no `document_line_lots` for them; naming them
-- `sales_documents` and teaching the earliest-expiry arm about that
-- source would quietly start picking batches for every ordinary invoice
-- line somebody forgot to name lots on, which the invariant refuses on
-- purpose. One new literal, contained to bundles.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Defining one
-- ---------------------------------------------------------------------
--
-- Each entry of p_lines is `{item, quantity, uom, wastage}`. It writes
-- the same tables `upsert_pos_recipe` writes, deliberately: see the
-- header.
create or replace function public.upsert_item_bundle(
  p_org    uuid,
  p_item   uuid,
  p_lines  jsonb,
  p_notes  text default null,
  p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_item public.items;
  v_id   uuid;
  v_e    jsonb;
  v_n    integer := 0;
  v_comp uuid;
  v_qty  numeric;
  v_uom  text;
begin
  if not app.can_write_module(p_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;

  select * into v_item from public.items where id = p_item and org_id = p_org;
  if v_item.id is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  -- A bundle that held stock of its own would move twice: once as
  -- itself from the posting function, once as its parts from the
  -- trigger below.
  if v_item.track_inventory then
    raise exception
      'Item % keeps its own stock, so a bundle of it would come off the '
      'shelf twice. Turn stock tracking off first — a bundle holds no '
      'stock, its parts do.', v_item.code using errcode = '23514';
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'A bundle with nothing in it is an ordinary item.'
      using errcode = '23514';
  end if;

  insert into public.pos_recipes (org_id, item_id, yield_quantity, notes, is_active)
  values (p_org, p_item, 1, p_notes, p_active)
  on conflict (item_id) do update
    set yield_quantity = 1, notes = excluded.notes,
        is_active = excluded.is_active, updated_at = now()
  returning id into v_id;

  delete from public.pos_recipe_lines where recipe_id = v_id;

  for v_e in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    v_comp := (v_e->>'item')::uuid;
    v_qty  := round(coalesce((v_e->>'quantity')::numeric, 0), 6);
    v_uom  := coalesce(nullif(v_e->>'uom', ''),
                       (select i.uom_code from public.items i
                         where i.id = v_comp));

    if v_comp = p_item then
      raise exception 'A bundle cannot contain itself.' using errcode = '23514';
    end if;
    if v_qty <= 0 then
      raise exception 'A part of a bundle has to be some of something.'
        using errcode = '23514';
    end if;
    if not exists (select 1 from public.items i
                    where i.id = v_comp and i.org_id = p_org
                      and i.deleted_at is null) then
      raise exception 'One of the parts is not on this company''s list.'
        using errcode = 'P0002';
    end if;

    -- The same check 0264 makes, in the same shape: does this part's
    -- own tree reach back to the bundle. A shallow "is it in the list"
    -- test misses a bundle containing a bundle that contains it, and
    -- the explosion stops at a repeat -- so a loop would silently
    -- under-deplete for ever rather than fail.
    if exists (select 1 from app.pos_recipe_uses(v_comp) u
                where u.item_id = p_item) then
      raise exception
        'That would make % a part of itself, through its own sub-bundles.',
        v_item.code using errcode = '23514';
    end if;

    -- Proves the unit converts at all, while somebody can still fix it.
    perform app.uom_qty(v_comp, v_qty, v_uom);

    insert into public.pos_recipe_lines
      (org_id, recipe_id, line_no, component_item_id, quantity, uom_code,
       wastage_percent)
    values (p_org, v_id, v_n, v_comp, v_qty, v_uom,
            round(coalesce((v_e->>'wastage')::numeric, 0), 4));
  end loop;

  update public.items set item_type = 'bundle' where id = p_item;
  return v_id;
end;
$$;

revoke all on function public.upsert_item_bundle(uuid, uuid, jsonb, text, boolean)
  from public, anon;
grant execute on function public.upsert_item_bundle(uuid, uuid, jsonb, text, boolean)
  to authenticated;

comment on function public.upsert_item_bundle(uuid, uuid, jsonb, text, boolean) is
  'Defines what a bundle is made of. Writes the same rows a POS recipe does, because they are the same idea.';

-- ---------------------------------------------------------------------
-- What one is made of, and what it costs
-- ---------------------------------------------------------------------
create or replace function public.item_bundle_for(p_item uuid)
returns table (
  component_id uuid,
  code         text,
  name         text,
  quantity     numeric,
  uom_code     text,
  wastage_percent numeric,
  unit_cost    numeric,
  line_cost    numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select c.item_id, i.code, i.name, round(c.quantity, 6), i.uom_code,
           coalesce(l.wastage_percent, 0),
           round(coalesce(i.average_cost, 0), 6),
           round(c.quantity * coalesce(i.average_cost, 0), 2)
      from app.pos_recipe_components(p_item, 1) c
      join public.items i on i.id = c.item_id
      left join public.pos_recipe_lines l
        on l.component_item_id = c.item_id
       and l.recipe_id = (select r.id from public.pos_recipes r
                           where r.item_id = p_item)
     order by i.code;
end;
$$;

revoke all on function public.item_bundle_for(uuid) from public, anon;
grant execute on function public.item_bundle_for(uuid) to authenticated;

-- What it costs and what that leaves. The number somebody needs before
-- deciding what to charge for the set.
create or replace function public.bundle_margin(p_item uuid)
returns table (
  price      numeric,
  cost       numeric,
  margin     numeric,
  margin_pct numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   uuid;
  v_price numeric(18, 2);
  v_cost  numeric(18, 2);
begin
  select i.org_id, i.unit_price into v_org, v_price
    from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  select round(coalesce(sum(b.line_cost), 0), 2) into v_cost
    from public.item_bundle_for(p_item) b;

  return query select
    v_price, v_cost, round(v_price - v_cost, 2),
    case when v_price = 0 then null
         else round((v_price - v_cost) / v_price * 100, 2) end;
end;
$$;

revoke all on function public.bundle_margin(uuid) from public, anon;
grant execute on function public.bundle_margin(uuid) to authenticated;

-- How many can be sold out of what is on the shelf, and what runs out
-- first. The same question `pos_item_availability` answers for a
-- kitchen, asked of one item in one warehouse.
create or replace function public.bundle_availability(
  p_item uuid, p_warehouse uuid default null)
returns table (
  can_make      numeric,
  limiting_item text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_wh uuid;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  v_wh := coalesce(p_warehouse, (select w.id from public.warehouses w
                                  where w.org_id = v_org and w.is_default
                                  limit 1));

  return query
    select coalesce(min(floor(coalesce(sl.quantity, 0) / c.quantity)), 0),
           (array_agg(i.name order by
              floor(coalesce(sl.quantity, 0) / c.quantity)))[1]
      from app.pos_recipe_components(p_item, 1) c
      join public.items i on i.id = c.item_id
      left join public.stock_levels sl
        on sl.item_id = c.item_id and sl.warehouse_id = v_wh
     where c.quantity > 0
       and i.track_inventory;
end;
$$;

revoke all on function public.bundle_availability(uuid, uuid) from public, anon;
grant execute on function public.bundle_availability(uuid, uuid) to authenticated;

create or replace function public.item_bundles_list(p_org uuid)
returns table (
  item_id    uuid,
  code       text,
  name       text,
  price      numeric,
  cost       numeric,
  parts      bigint,
  is_active  boolean)
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
    select i.id, i.code, i.name, i.unit_price,
           coalesce((select round(sum(b.line_cost), 2)
                       from public.item_bundle_for(i.id) b), 0),
           (select count(*) from public.pos_recipe_lines l
             where l.recipe_id = r.id),
           r.is_active
      from public.items i
      join public.pos_recipes r on r.item_id = i.id
     where i.org_id = p_org
       and i.item_type = 'bundle'
       and i.deleted_at is null
     order by i.code;
end;
$$;

revoke all on function public.item_bundles_list(uuid) from public, anon;
grant execute on function public.item_bundles_list(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Selling one takes its parts off the shelf
-- ---------------------------------------------------------------------
--
-- `p_sign` is 1 when an invoice is posted and -1 when a credit note
-- puts the parts back, so the two directions cannot drift apart the way
-- two copies of an explosion would.
create or replace function app.move_document_bundles(
  p_document uuid, p_sign integer)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc   public.sales_documents;
  v_line  record;
  v_row   record;
  v_wh    uuid;
  v_qty   numeric;
  v_unit  numeric;
  v_moved numeric;
  v_cost  numeric(18, 2) := 0;
  v_cogs  uuid;
  v_inv   uuid;
  v_lines jsonb;
  v_entry uuid;
begin
  select * into v_doc from public.sales_documents where id = p_document;
  if v_doc.id is null then
    return null;
  end if;

  for v_line in
    select l.id, l.item_id,
           coalesce(l.base_quantity, l.quantity) as qty, l.warehouse_id
      from public.sales_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_document
       and l.line_type = 'item'
       and i.item_type = 'bundle'
       and not i.track_inventory
       and coalesce(l.base_quantity, l.quantity) > 0
       and exists (select 1 from public.pos_recipes r
                    where r.item_id = l.item_id and r.is_active)
  loop
    v_wh := coalesce(v_line.warehouse_id,
                     (select w.id from public.warehouses w
                       where w.org_id = v_doc.org_id and w.is_default limit 1));

    for v_row in
      select c.item_id, c.quantity
        from app.pos_recipe_components(v_line.item_id, v_line.qty) c
        join public.items i on i.id = c.item_id
       where i.track_inventory
    loop
      v_qty := round(v_row.quantity, 6);
      if v_qty <= 0 then
        continue;
      end if;

      -- Going out, the weighted average is filled in for us: 0009's
      -- outbound arm reads it when unit_cost is zero. Coming back it is
      -- not -- an inbound movement takes the cost the caller gives it,
      -- and a zero would put the parts back at nothing and dilute the
      -- average of everything left on the shelf. So a return is valued
      -- at the price the same parts left at, read off the invoice being
      -- credited, exactly as 0269 does for a till sale.
      v_unit := 0;
      if p_sign = -1 then
        select sm.unit_cost into v_unit
          from public.stock_movements sm
         where sm.source_table = 'sales_bundles'
           and sm.source_id = v_doc.original_invoice_id
           and sm.item_id = v_row.item_id
           and sm.quantity < 0
         order by sm.created_at desc limit 1;
        -- No invoice named, or none found: what it is carried at now is
        -- the only honest answer left.
        v_unit := coalesce(v_unit,
          (select coalesce(i.average_cost, 0) from public.items i
            where i.id = v_row.item_id), 0);
      end if;

      insert into public.stock_movements (
        org_id, movement_no, movement_date, movement_type, item_id,
        warehouse_id, quantity, unit_cost, source_table, source_id,
        source_line_id, notes, created_by)
      values (
        v_doc.org_id,
        app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
        v_doc.doc_date,
        (case when p_sign = 1 then 'assembly_out' else 'assembly_in' end)
          ::app.stock_movement_type,
        v_row.item_id, v_wh, -p_sign * v_qty, v_unit,
        'sales_bundles', p_document, v_line.id,
        'Bundle ' || v_doc.doc_no, auth.uid());

      select sm.total_cost into v_moved
        from public.stock_movements sm
       where sm.source_table = 'sales_bundles'
         and sm.source_id = p_document
         and sm.item_id = v_row.item_id
       order by sm.created_at desc limit 1;
      v_cost := v_cost + coalesce(v_moved, 0);
    end loop;
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_doc.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_doc.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  -- v_cost is negative when stock left, because a movement out has a
  -- negative total. Cost of sales is therefore the debit, and the
  -- credit note reverses both sides by arriving with the other sign.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cogs,
      'description', 'Bundle cost ' || v_doc.doc_no,
      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),
    jsonb_build_object('account_id', v_inv,
      'description', 'Bundle components ' || v_doc.doc_no,
      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)));

  v_entry := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date, 'stock_movement', v_lines,
    'Bundle components ' || v_doc.doc_no, 'sales_documents', p_document);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'sales_bundles' and sm.source_id = p_document
     and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

revoke all on function app.move_document_bundles(uuid, integer)
  from public, anon, authenticated;

create or replace function app.document_bundles_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if new.status <> 'posted' or old.status is not distinct from 'posted' then
    return new;
  end if;
  if new.doc_type = 'invoice' then
    perform app.move_document_bundles(new.id, 1);
  elsif new.doc_type = 'credit_note' then
    perform app.move_document_bundles(new.id, -1);
  end if;
  return new;
end;
$$;

revoke all on function app.document_bundles_trigger()
  from public, anon, authenticated;

create trigger sales_document_bundles
  after update on public.sales_documents
  for each row execute function app.document_bundles_trigger();

-- ---------------------------------------------------------------------
-- The lot invariant learns one new source
-- ---------------------------------------------------------------------

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
  -- An ingredient coming back off a credit note
  -- ------------------------------------------------------------------
  --
  -- To the batches this sale took, most recently taken first. The last
  -- thing out of the pot is the first thing back into it, and a batch
  -- that was emptied and closed should not be reopened ahead of one
  -- that is still open.
  if new.source_table = 'pos_sales' and new.quantity > 0 then
    declare v_back numeric := new.quantity;
    begin
      for r in
        select sml.lot_id, -sml.quantity as quantity
          from public.stock_movement_lots sml
          join public.stock_movements m on m.id = sml.movement_id
         where m.source_table = 'pos_sales'
           and m.source_id = new.source_id
           and m.item_id = new.item_id
           and m.quantity < 0
         order by m.created_at desc, sml.lot_id
      loop
        exit when v_back <= 0;
        insert into public.stock_movement_lots
          (org_id, movement_id, lot_id, quantity)
        values (new.org_id, new.id, r.lot_id, least(r.quantity, v_back))
        on conflict (movement_id, lot_id) do update
          set quantity = public.stock_movement_lots.quantity
                         + excluded.quantity;
        v_back  := v_back - least(r.quantity, v_back);
        v_found := v_found + 1;
      end loop;
    end;
    if v_found > 0 then
      return null;
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Anything going out with nobody to ask: earliest expiry first
  -- ------------------------------------------------------------------
  --
  -- 0277 adds `sales_bundles` to this list and nothing else in this
  -- function. The source is deliberately not `sales_documents`: a
  -- bundle's components are not the invoice line, so the first loop
  -- above finds no `document_line_lots` for them and falls through --
  -- and putting `sales_documents` here would quietly start picking
  -- batches for every ordinary invoice line that somebody forgot to
  -- name lots on, which the invariant currently refuses on purpose.
  --
  -- Everything else below and above is carried across from 0269
  -- verbatim. 0267 rebuilt this function from an older copy and
  -- silently reverted 0152's opening-stock arm; the rule since then is
  -- that a re-creation starts from the last definer and changes one
  -- thing.
  if new.quantity < 0
     and new.source_table in ('stock_transfers', 'item_conversions',
                              'pos_sales', 'sales_bundles')
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

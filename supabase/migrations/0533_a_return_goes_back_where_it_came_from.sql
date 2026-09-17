-- =====================================================================
-- 0533  A return goes back to the batch it came out of
--
-- Found by a mutation sweep of `app.materialise_movement_lots`. The
-- fixture set out to prove the rule the function's own comment states —
--
--   "To the batches this sale took, most recently taken first. The last
--    thing out of the pot is the first thing back into it, and a batch
--    that was emptied and closed should not be reopened ahead of one
--    that is still open."
--
-- — and it passed on some runs and failed on others.
--
-- THE ORDER IS `m.created_at desc, sml.lot_id`. Across two sales that is
-- fine. WITHIN ONE SALE it is not: a single line that spans two batches
-- writes both of them against ONE movement, so `created_at` ties and the
-- tie-break is `sml.lot_id` — a random uuid. Which batch a credit note
-- goes back to is then decided by `gen_random_uuid()`.
--
-- A sale of five that empties a three-unit batch and starts a ten-unit
-- one is the ordinary case, not a corner one. Two of those five coming
-- back should go to the batch still open. Half the time they reopened
-- the one that had been emptied and closed — and a closed batch with
-- stock in it again is a batch somebody will pick from, on a date that
-- has already been counted as gone.
--
-- THE FIX IS TO MIRROR THE PICKER. `app.pick_lots_fefo` takes
-- `expiry_date asc nulls last, lot_ref`, so putting things back in the
-- reverse of that order — `expiry_date desc nulls first, lot_ref desc` —
-- returns to the batch the pick reached LAST, which is what the comment
-- means and what the `created_at` clause was reaching for between
-- movements.
--
-- Everything else in this function is carried across from 0277
-- verbatim. The rule since 0267 is that a re-creation starts from the
-- last definer and changes one thing; this changes the `order by` of
-- the credit-note loop and nothing else.
-- =====================================================================

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
  -- stands aside.
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
  -- To the batches this sale took, in the reverse of the order they
  -- were taken in. The last thing out of the pot is the first thing
  -- back into it, and a batch that was emptied and closed should not be
  -- reopened ahead of one that is still open.
  --
  -- 0533: the tie-break used to be `sml.lot_id`, a random uuid, and
  -- `m.created_at` ties whenever one sale line spans two batches --
  -- which is the ordinary case, since that is what happens when a batch
  -- runs out mid-line. So which batch a credit note went back to was
  -- decided by `gen_random_uuid()`.
  --
  -- The order below is exactly the reverse of `app.pick_lots_fefo`'s
  -- `expiry_date asc nulls last, lot_ref`, so what goes back is what the
  -- pick reached last.
  if new.source_table = 'pos_sales' and new.quantity > 0 then
    declare v_back numeric := new.quantity;
    begin
      for r in
        select sml.lot_id, -sml.quantity as quantity
          from public.stock_movement_lots sml
          join public.stock_movements m on m.id = sml.movement_id
          join public.stock_lots l on l.id = sml.lot_id
         where m.source_table = 'pos_sales'
           and m.source_id = new.source_id
           and m.item_id = new.item_id
           and m.quantity < 0
         order by m.created_at desc,
                  l.expiry_date desc nulls first, l.lot_ref desc
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
  -- The source is deliberately not `sales_documents`: a bundle's
  -- components are not the invoice line, so the first loop above finds
  -- no `document_line_lots` for them and falls through -- and putting
  -- `sales_documents` here would quietly start picking batches for
  -- every ordinary invoice line that somebody forgot to name lots on,
  -- which the invariant currently refuses on purpose.
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

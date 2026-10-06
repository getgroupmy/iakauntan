-- A bundle's cost of sale read back from the wrong line.
--
-- `app.move_document_bundles` (0277) takes a bundle's parts off the shelf
-- when an invoice posts and books what they cost. It loops over the
-- invoice's bundle LINES, inserts one movement per part, and then read
-- that movement's cost back with a second query:
--
--     where source_table = 'sales_bundles' and source_id = p_document
--       and item_id = v_row.item_id
--     order by sm.created_at desc limit 1
--
-- `created_at` defaults to `now()`, the TRANSACTION's timestamp, so every
-- movement one posting inserts carries the same value and "newest" is
-- whichever row the sort happens to return. With one bundle line that is
-- the only row. With two lines that share a part it is either of them.
--
-- Found by the mutation sweep on 6 October 2026, and reproduced before it
-- was believed: the gift set from `item_bundles.sql` (parts cost 29), one
-- invoice, ten sets on line 1 and one set on line 2. The movements took
-- RM 319.00 of parts off the shelf; the journal booked RM 58.00 cost of
-- sale -- 29 + 29, because the line loop has no ORDER BY, line 2 ran
-- first, and line 1 then read line 2's movement back. Inventory in the
-- ledger overstated by RM 261, in a journal that balances.
--
-- Task #83's audit of this exact read-back cleared `pos_deplete_recipes`,
-- whose loop is `group by item_id` -- one movement per part, so the
-- predicate matches one row. This loop has no such grouping, and the
-- audit's list did not reach it.
--
-- The fix is `insert ... returning total_cost`: the cost of the row just
-- written, as the BEFORE trigger set it. `0422` already reads a
-- manufacturing issue's cost the same way. `materialise_movement_lots`
-- fires AFTER insert and writes lots, not the movement's cost, so the
-- value returned is the value stored.
--
-- The return arm's own lookup (`p_sign = -1`, the unit cost the parts
-- left at on the credited invoice) has the same ordering shape but is
-- left alone: every outbound movement of one part in one posting is
-- valued at the weighted average, which an outbound movement does not
-- move beyond rounding in the sixth decimal place, so whichever row it
-- returns prices the return the same to the sen.
--
-- Production had no bundle items when this was written (checked
-- read-only), so no posted journal is wrong; this closes it before one
-- is. `supabase/tests/item_bundles.sql` asserts the two-line invoice.

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
        'Bundle ' || v_doc.doc_no, auth.uid())
      -- 0745. The cost of THIS movement, as `app.apply_stock_movement`
      -- set it in its BEFORE trigger. It was read back with a second
      -- query, newest by `created_at`, keyed on document and part --
      -- and every movement one posting inserts has the same
      -- `created_at`, so two bundle lines sharing a part read each
      -- other's.
      returning total_cost into v_moved;
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

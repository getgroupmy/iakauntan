-- =====================================================================
-- iAkauntan :: 0917 an item's unit changes with nothing counted in it
--
-- `items.uom_code` is the unit an item's stock is counted in. Every
-- `stock_movements.quantity` is in it, and so is the running average
-- cost; `app.uom_qty` turns a quantity written in another unit into it
-- (`0264`), and `item_uom_packs.qty_in_stock_uom` says how many of it
-- one carton holds. Nothing stopped the unit changing under them, and
-- the item screen offers it on every edit.
--
-- Measured on 22 November 2026, locally, as the owner with the role
-- `authenticated`: ten litres bought at 25 (10 on hand, 1310 at 250);
-- the unit changed from LTR to MLT by one update; one litre sold. The
-- ten on hand now read as ten millilitres at 25 each, so the litre
-- took 1,000 of them: -990 on hand, and 25,000 of cost of sales
-- against a sale of 40.
--
-- Production on 22 November: 23 items holding stock, in C62, H87, SET
-- and LTR; no item with a pack size.
--
-- Answered "refuse with stock or pack sizes", for every writer: an
-- item's unit may not change while any one warehouse's movements of it
-- add up to anything but nothing, nor while it has a pack size set --
-- a carton of 24 pieces would become a carton of 24 of whatever the
-- new unit is. Adjust the stock out and remove the pack sizes, change
-- the unit, and put both back in the new one. `0914` and `0916` drew
-- the same line for the other two settings stock is read through.
-- Asked only when the unit changes: the app saves an item whole.
-- =====================================================================

create or replace function app.an_items_unit_changes_with_nothing_counted()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_held  text;
  v_packs text;
begin
  -- SECURITY DEFINER because it reads the stock, and a writer who may
  -- not read the movements must not be waved through by reading none.
  if new.uom_code is not distinct from old.uom_code then
    return new;
  end if;

  select string_agg(trim(to_char(s.qty, 'FM999999990.####')) || ' at '
                      || coalesce(w.code, 'no warehouse'), ', ' order by w.code)
    into v_held
    from (select m.warehouse_id, sum(m.quantity) qty
            from public.stock_movements m
           where m.item_id = old.id
           group by m.warehouse_id
          having sum(m.quantity) <> 0) s
    left join public.warehouses w on w.id = s.warehouse_id;

  if v_held is not null then
    raise exception
      '% (%) still has stock on hand (%), counted in %, so its unit stays '
      '%. The quantity on hand and its cost would be read as % without '
      'either changing. Adjust the stock out, change the unit, then '
      'adjust it back in.',
      old.name, old.code, v_held, old.uom_code, old.uom_code, new.uom_code
      using errcode = '23514';
  end if;

  select string_agg(k.uom_code || ' = '
                      || trim(to_char(k.qty_in_stock_uom, 'FM999999990.######'))
                      || ' ' || old.uom_code, ', ' order by k.uom_code)
    into v_packs
    from public.item_uom_packs k
   where k.item_id = old.id;

  if v_packs is not null then
    raise exception
      '% (%) has pack sizes counted in % (%), so its unit stays %. Each '
      'would become that many % without changing. Remove the pack sizes, '
      'change the unit, then set them again.',
      old.name, old.code, old.uom_code, v_packs, old.uom_code, new.uom_code
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.an_items_unit_changes_with_nothing_counted() from public, anon, authenticated;

comment on function app.an_items_unit_changes_with_nothing_counted() is
  'Refuses, for every writer, a change of an item''s uom_code while any '
  'warehouse''s movements of it add up to anything but zero, or while it '
  'has a pack size: both are counted in the unit, and would be read in '
  'the new one unchanged. 0917.';

create trigger an_items_unit_changes_with_nothing_counted
  before update of uom_code on public.items
  for each row execute function app.an_items_unit_changes_with_nothing_counted();

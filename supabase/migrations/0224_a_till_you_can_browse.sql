-- What a till shows when nobody has scanned anything yet.
--
-- ## The screen this replaces
--
-- An empty pane reading "Ready — scan an item, or type part of its
-- name". True, and useless to most of the shops this module is sold to.
-- A barcode is a retail assumption: a warung's nasi lemak has no label,
-- a salon's haircut has no label, and a stall's roti john has no label.
-- For three of the five business types the only way to ring anything up
-- was to already know what it was called.
--
-- ## Sellable, defined once
--
-- The browse list must offer exactly what `pos_lookup_item` would
-- return and what `app.pos_sale_line_sellable` would accept, or the
-- till shows a tile that raises when tapped. So the rules are repeated
-- here deliberately and identically:
--
--   * not deleted, active, and `is_sold`
--   * not a style with variants under it -- 0211 made a style
--     unsellable precisely so somebody picks the size and colour, and a
--     grid tile is exactly the sort of place that rule gets forgotten
--
-- The variants themselves are sold, so they appear. A style with three
-- colours contributes three tiles rather than one, which is the honest
-- shape: the price and the stock differ per variant.
--
-- ## Why the count comes back with the rows
--
-- The client decides between showing items and showing categories by
-- whether the items fit on the screen it actually has, which only the
-- client knows. What it cannot cheaply work out is how many items sit
-- behind a category it is not showing, and a category tile that does
-- not say "6 items" is a door with nothing written on it.

create or replace function public.pos_menu(p_outlet uuid)
returns table (
  item_id     uuid,
  code        text,
  name        text,
  unit_price  numeric,
  uom_code    text,
  category_id uuid,
  category    text,
  variant_attributes jsonb,
  on_hand     numeric,
  tracks_stock boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with outlet as (
    select o.org_id, o.warehouse_id
      from public.pos_outlets o
     where o.id = p_outlet
       and app.can_read_module(o.org_id, 'pos')
  )
  select i.id, i.code, i.name, i.unit_price, i.uom_code,
         i.category_id,
         -- Named rather than left null, because the client groups on
         -- this and a null heading reads as a bug rather than as a
         -- shop that never set its categories up.
         coalesce(c.name, 'Uncategorised'),
         i.variant_attributes,
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = i.id
                      and sl.warehouse_id = (select o.warehouse_id from outlet o)), 0),
         i.track_inventory
    from public.items i
    join outlet o on o.org_id = i.org_id
    left join public.item_categories c on c.id = i.category_id
   where i.deleted_at is null
     and i.is_active
     and i.is_sold
     -- The rule `pos_sale_line_sellable` enforces. A style with
     -- variants is not a thing you can put in a bag, so it is not a
     -- thing this screen may offer.
     and not exists (select 1 from public.items v
                      where v.parent_item_id = i.id and v.deleted_at is null)
   order by coalesce(c.name, 'Uncategorised'), i.name;
$$;

revoke all on function public.pos_menu(uuid) from public, anon;
grant execute on function public.pos_menu(uuid) to authenticated;

comment on function public.pos_menu(uuid) is
  'Everything an outlet can actually sell, for a till to browse when '
  'nothing has been scanned. Applies the same sellability rules as '
  'pos_lookup_item and pos_sale_line_sellable, so no tile on the screen '
  'can raise when it is tapped.';

-- =====================================================================
-- iAkauntan :: 0914 an item with stock keeps tracking it
--
-- Posting decides from `items.track_inventory` whether a line moves
-- stock and books its cost: `app.post_sales_document_internal` takes
-- the goods out at average cost (cost of sales against 1310) only for
-- an item that tracks inventory, and a bill receives them only for
-- one. Nothing stopped the flag -- or `item_type`, which the item
-- screen turns it off with -- changing while the item had stock.
--
-- Measured on 8 November 2026, locally, as the owner with the role
-- `authenticated`: ten bought at 25 (10 on hand, 1310 at 250); the
-- tracking switched off by one update, as the item screen's own switch
-- does; all ten sold at 40. The sale moved no stock and booked no cost:
-- still 10 on hand, 1310 still at 250, the profit overstated by 250.
-- Switched back on, the ten sold units were on hand again. Made a
-- service with ten on hand, it was accepted as well.
--
-- `create_item_variants` already refuses to turn a style that holds
-- stock into one that holds none (`0571`), for the same reason.
--
-- Production on 8 November: 23 stock items, every one with stock on
-- hand; no untracked item with any.
--
-- Answered "refuse while stock is on hand", for every writer: an item
-- may not stop tracking inventory, nor stop being a stock item, while
-- its movements in any one warehouse add up to anything but nothing.
-- Sell, adjust or write the stock off first. Turning tracking on, and
-- every other change to an item, is not asked.
-- =====================================================================

create or replace function app.an_item_with_stock_keeps_tracking_it()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_held text;
begin
  -- SECURITY DEFINER because it reads the stock, and a writer who may
  -- not read the movements must not be waved through by reading none.
  if not ((old.track_inventory and not new.track_inventory)
          or (old.item_type = 'stock' and new.item_type is distinct from 'stock')) then
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
      '% (%) still has stock on hand (%), so it keeps tracking it. '
      'Posting takes stock out and books its cost only for an item that '
      'tracks it, so a sale after the switch would leave the goods and '
      'their value in the books. Sell, adjust or write the stock off '
      'first.',
      old.name, old.code, v_held
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.an_item_with_stock_keeps_tracking_it() from public, anon, authenticated;

comment on function app.an_item_with_stock_keeps_tracking_it() is
  'Refuses, for every writer, an item''s tracking turned off or its '
  'type changed from stock while its movements in any warehouse add up '
  'to anything but zero. Posting moves stock and books cost of sales '
  'only for a tracked item. 0914.';

create trigger an_item_with_stock_keeps_tracking_it
  before update of track_inventory, item_type on public.items
  for each row execute function app.an_item_with_stock_keeps_tracking_it();

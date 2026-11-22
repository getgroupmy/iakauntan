-- =====================================================================
-- iAkauntan :: 0916 how an item is tracked changes with none on hand
--
-- `items.tracking` says how an item's units are identified -- `none`,
-- `batch` or `serial` (`0106`). Once it is not `none`,
-- `app.check_movement_lots` makes every movement name the units it
-- moves, and refuses one that would take a batch below nothing.
-- `v_lot_balances` is derived from those names and is what the expiry
-- and recall lists read. Nothing stopped the setting changing while
-- the item had stock, and the item screen offers it on any stock item.
--
-- Measured on 22 November 2026, locally, as the owner with the role
-- `authenticated`, each posting committed as far as its deferred
-- constraint:
--
--   * turned ON with ten on hand: the ten could no longer leave. A sale
--     naming no batch was refused ("every unit has to be named"), and a
--     sale naming one was refused because the batch would stand at -5;
--   * turned OFF with ten in LOT-MAC: all ten sold with no batch named,
--     and LOT-MAC went on saying ten were on the shelf. Turned back on:
--     nothing on hand, ten in its batches. `0106` named exactly this as
--     the one failure that would make the feature harmful -- "a recall
--     list saying a batch is on the shelf when it was sold last month".
--
-- Production on 22 November: no item tracked by batch or serial, no
-- batch with a balance, and 23 untracked items holding stock -- so the
-- first is what the first person to turn tracking on would have met.
--
-- Answered "refuse while stock is on hand", for every writer: how an
-- item is tracked may not change while any one warehouse's movements
-- add up to anything but nothing, nor while any batch or serial of it
-- still has a balance. To start tracking a stocked item: adjust the
-- stock out, change the setting, and adjust it back in naming its
-- batches. `0914` drew the same line for `track_inventory`. Asked only
-- when the setting changes: the app saves an item whole, and sends
-- `tracking` back with every edit.
-- =====================================================================

create or replace function app.tracking_changes_with_none_on_hand()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_held text;
  v_lots text;
  v_now  text;
  v_why  text;
begin
  -- SECURITY DEFINER because it reads the stock, and a writer who may
  -- not read the movements must not be waved through by reading none.
  if new.tracking is not distinct from old.tracking then
    return new;
  end if;

  v_now := case old.tracking
             when 'none'  then 'not tracked by batch or serial number'
             when 'batch' then 'tracked by batch'
             else 'tracked by serial number'
           end;
  v_why := case
             when old.tracking = 'none' then
               'Units received before the change carry no batch or serial '
               'number, and once every unit has to be named they could be '
               'neither sold nor adjusted.'
             else
               'Its batch and serial records would go on saying those '
               'units are on the shelf after they had gone.'
           end;

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
      '% (%) still has stock on hand (%), so it stays %. % Adjust the '
      'stock out, change how it is tracked, then adjust it back in.',
      old.name, old.code, v_held, v_now, v_why
      using errcode = '23514';
  end if;

  -- With nothing on hand a batch can still say it holds some, where
  -- units left it unnamed before this rule. Changing the setting then
  -- would carry that balance into the new way of tracking.
  select string_agg(trim(to_char(b.quantity, 'FM999999990.####')) || ' in '
                      || b.lot_ref, ', ' order by b.lot_ref)
    into v_lots
    from public.v_lot_balances b
   where b.item_id = old.id;

  if v_lots is not null then
    raise exception
      '% (%) has nothing on hand, but its batch and serial records still '
      'say % -- so it stays % until they are put right. Changing how it '
      'is tracked would carry that balance with it.',
      old.name, old.code, v_lots, v_now
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.tracking_changes_with_none_on_hand() from public, anon, authenticated;

comment on function app.tracking_changes_with_none_on_hand() is
  'Refuses, for every writer, a change of an item''s tracking (none, '
  'batch, serial) while any warehouse''s movements of it add up to '
  'anything but zero, or any batch or serial of it still has a balance. '
  'Turned on with stock, the stock could not leave; turned off, the '
  'batch records went on saying it was there. 0916.';

create trigger tracking_changes_with_none_on_hand
  before update of tracking on public.items
  for each row execute function app.tracking_changes_with_none_on_hand();

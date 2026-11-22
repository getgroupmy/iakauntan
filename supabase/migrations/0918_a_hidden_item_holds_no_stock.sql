-- =====================================================================
-- iAkauntan :: 0918 a hidden item holds no stock
--
-- An item is hidden two ways: `is_active` switched off, or `deleted_at`
-- set. `stock_on_hand` -- the stock listing, and what the stock take
-- starts from -- leaves a hidden item out (`i.deleted_at is null and
-- i.is_active`), which is right for an item with nothing left and
-- wrong for one that still has some: its stock and its value stay in
-- the books, and the listing no longer agrees with 1310.
--
-- Measured on 22 November 2026, locally, as the owner with the role
-- `authenticated`:
--
--   * two items, ten of each bought at 25 (1310 at 500); one switched
--     off: the listing showed one item worth 250. Soft-deleted instead,
--     the same. A delete outright was already refused, by the posted
--     line that names the item;
--   * the other way round -- one item switched off and one soft-deleted
--     with nothing on hand, then a bill for ten of each posted: the
--     listing showed nothing, with 500 in 1310.
--
-- A warehouse switched off was measured too and is not this: its stock
-- still lists and still sells, and `warehouses` has no `deleted_at`.
--
-- The app has no button for either; a direct write or an import does
-- it. Production on 22 November: no hidden item, 23 live items holding
-- stock.
--
-- Answered "refuse hiding with stock", and then "close both roads",
-- for every writer:
--
--   * an item may not be switched off or soft-deleted while any one
--     warehouse's movements of it add up to anything but nothing;
--   * a stock movement may not leave a hidden item's stock in a
--     warehouse anywhere but between what it holds there and nothing
--     -- so not receiving, a return or an adjustment in, nor a sale of
--     more than it has. What it already holds can still leave, so an
--     item hidden before this rule can be emptied, and a movement of
--     no units (a landed cost) passes.
--
-- To receive or take back a retired item, switch it on first.
-- =====================================================================

create or replace function app.an_item_holding_stock_is_not_hidden()
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
  if not ((old.is_active and not new.is_active)
          or (old.deleted_at is null and new.deleted_at is not null)) then
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
      '% (%) still has stock on hand (%), so it stays in use. The stock '
      'listing leaves out an item that is switched off or removed, while '
      'what it holds stays in the books. Sell, adjust or write the stock '
      'off first.',
      old.name, old.code, v_held
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.an_item_holding_stock_is_not_hidden() from public, anon, authenticated;

comment on function app.an_item_holding_stock_is_not_hidden() is
  'Refuses, for every writer, an item switched off (is_active) or '
  'soft-deleted (deleted_at) while any warehouse''s movements of it add '
  'up to anything but zero: stock_on_hand leaves a hidden item out, and '
  'its value would stay in the books unseen. 0918.';

create trigger an_item_holding_stock_is_not_hidden
  before update of is_active, deleted_at on public.items
  for each row execute function app.an_item_holding_stock_is_not_hidden();

-- ---------------------------------------------------------------------
-- The other road: stock arriving in an item that is already hidden
-- ---------------------------------------------------------------------
create or replace function app.a_hidden_item_takes_no_stock()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_item   public.items;
  v_before numeric;
  v_after  numeric;
begin
  select * into v_item from public.items i where i.id = new.item_id;
  if v_item.id is null
     or (v_item.is_active and v_item.deleted_at is null) then
    return new;
  end if;

  select coalesce(sum(m.quantity), 0) into v_before
    from public.stock_movements m
   where m.item_id = new.item_id
     and m.warehouse_id = new.warehouse_id;
  v_after := v_before + new.quantity;

  -- Between what it holds and nothing is let through: what a hidden
  -- item already holds can still leave it, and no more than that.
  if not (v_after * v_before >= 0 and abs(v_after) <= abs(v_before)) then
    raise exception
      '% (%) has been % and takes no more stock: this would take it from '
      '% to % at %. The stock listing leaves a hidden item out, so what '
      'it held would stay in the books unseen. Switch the item back on '
      'first.',
      v_item.name, v_item.code,
      case when v_item.deleted_at is not null then 'removed' else 'switched off' end,
      trim(to_char(v_before, 'FM999999990.####')),
      trim(to_char(v_after, 'FM999999990.####')),
      coalesce((select w.code from public.warehouses w where w.id = new.warehouse_id),
               'that warehouse')
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.a_hidden_item_takes_no_stock() from public, anon, authenticated;

comment on function app.a_hidden_item_takes_no_stock() is
  'Refuses, for every writer, a stock movement that leaves a hidden '
  'item''s stock in a warehouse anywhere but between what it holds and '
  'zero (is_active off or deleted_at set). What it holds can still '
  'leave, and a movement of no units passes. 0918.';

create trigger a_hidden_item_takes_no_stock
  before insert on public.stock_movements
  for each row execute function app.a_hidden_item_takes_no_stock();

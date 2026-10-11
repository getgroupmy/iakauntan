-- =====================================================================
-- iAkauntan :: 0813 the stock figures are the stock's
--
-- A sale posts its cost of goods sold at `items.average_cost`, read
-- when the invoice is posted. `app.apply_stock_movement` keeps that
-- cost and `items.quantity_on_hand`, re-deriving both from
-- `stock_levels` on every movement; `stock_movements`, `stock_levels`
-- and `stock_lots` are written only by SECURITY DEFINER functions --
-- posting, adjustments, transfers, receipts, opening stock, the till.
-- The app never sends either item column (`Item.toJson` names neither)
-- and never writes the three tables. But a client could write all of
-- them: the item through the item editor's own policies, the three
-- tables through their own.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: fifty on hand at RM10. The average cost set to RM0.01
-- by hand, and the quantity to 5,000; ten then sold posted RM0.10 to
-- cost of sales instead of RM100. A level's `value` written the same way
-- would carry the wrong cost through the next re-derivation.
--
-- Answered "guard and close". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that changes an item's `average_cost` or `quantity_on_hand`, or
-- creates an item with either set; the functions run as their owner,
-- and the movement trigger one level down, and pass. NOT security
-- definer itself. And `stock_movements`, `stock_levels` and `stock_lots`
-- become read-only to clients, as `0804` and `0806` to `0812` made
-- their tables: the grants are revoked and the write policies dropped,
-- `stock_movements`' restrictive `module_gate_` ones with them. Reading
-- stays. The item editor is unaffected, and a stock adjustment is still
-- drafted by the app and posted through `post_stock_adjustment`.
--
-- Production held twenty-three stock items, twenty-three levels and
-- ninety-four movements, every quantity agreeing with its levels, on
-- 11 October.
-- =====================================================================

create or replace function app.stock_figures_are_the_stocks()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.average_cost <> 0 or new.quantity_on_hand <> 0 then
      raise exception
        'An item is created with nothing on hand and no cost (this one '
        'said % at %). Stock and its cost arrive by receiving it, by an '
        'opening stock import or by a stock adjustment.',
        new.quantity_on_hand, new.average_cost
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.average_cost is distinct from old.average_cost
     or new.quantity_on_hand is distinct from old.quantity_on_hand then
    raise exception
      'What % has on hand and what it cost follow from the stock that '
      'moved, and are not written directly (% at % -> % at %). Receive '
      'it, adjust it, or count it instead.',
      new.code, old.quantity_on_hand, old.average_cost,
      new.quantity_on_hand, new.average_cost
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.stock_figures_are_the_stocks() from public, anon, authenticated;

comment on function app.stock_figures_are_the_stocks() is
  'On items: refuses a client''s own statement that writes average_cost '
  'or quantity_on_hand, or creates an item with either set. The stock '
  'functions, and the movement trigger under them, pass. 0813.';

create trigger a_stock_figures_are_the_stocks
  before insert or update on public.items
  for each row execute function app.stock_figures_are_the_stocks();

revoke insert, update, delete on public.stock_movements from authenticated, anon;
drop policy if exists stock_movements_insert on public.stock_movements;
drop policy if exists stock_movements_update on public.stock_movements;
drop policy if exists stock_movements_delete on public.stock_movements;

revoke insert, update, delete on public.stock_levels from authenticated, anon;
drop policy if exists stock_levels_insert on public.stock_levels;
drop policy if exists stock_levels_update on public.stock_levels;
drop policy if exists stock_levels_delete on public.stock_levels;

revoke insert, update, delete on public.stock_lots from authenticated, anon;
drop policy if exists stock_lots_insert on public.stock_lots;
drop policy if exists stock_lots_update on public.stock_lots;
drop policy if exists stock_lots_delete on public.stock_lots;
drop policy if exists module_gate_insert on public.stock_movements;
drop policy if exists module_gate_update on public.stock_movements;
drop policy if exists module_gate_delete on public.stock_movements;

comment on table public.stock_movements is
  'Every movement of stock in or out, at its cost. WRITTEN ONLY BY '
  'FUNCTION -- 0813 revoked insert, update and delete from clients and '
  'dropped the write policies; posting, adjustments, transfers, receipts, '
  'opening stock and the till write it.';

comment on table public.stock_levels is
  'What each warehouse holds of each item, and its value. WRITTEN ONLY BY '
  'FUNCTION -- 0813: kept by app.apply_stock_movement as stock moves.';

comment on table public.stock_lots is
  'Lots and their expiry, as stock moves in and out. WRITTEN ONLY BY '
  'FUNCTION -- 0813: kept by the movement functions.';

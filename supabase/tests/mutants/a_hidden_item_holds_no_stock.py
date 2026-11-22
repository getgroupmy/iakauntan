# Mutants for 0918 -- an item holding stock is not hidden, and a hidden
# item takes no stock, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0918_a_hidden_item_holds_no_stock.sql \
#       supabase/tests/a_hidden_item_holds_no_stock.sql \
#       supabase/tests/mutants/a_hidden_item_holds_no_stock.py

H = 'an_item_holding_stock_is_not_hidden'
T = 'a_hidden_item_takes_no_stock'

# --- hiding an item that holds stock ---------------------------------
m('hiding: only the app is asked',
  H,
  "  if not ((old.is_active and not new.is_active)\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if not ((old.is_active and not new.is_active)\n",
  '-- app only')

m('hiding: switching off is not asked',
  H,
  "  if not ((old.is_active and not new.is_active)\n",
  "  if not ((false)  -- off is free\n",
  '-- off is free')

m('hiding: a soft delete is not asked',
  H,
  "          or (old.deleted_at is null and new.deleted_at is not null)) then\n",
  "          or (false)) then  -- delete is free\n",
  '-- delete is free')

m('hiding: every write is asked, not only a hiding',
  H,
  "  if not ((old.is_active and not new.is_active)\n"
  "          or (old.deleted_at is null and new.deleted_at is not null)) then\n",
  "  if false then  -- every write\n",
  '-- every write')

m('hiding: stock is counted across warehouses, not in each',
  H,
  "          having sum(m.quantity) <> 0) s\n",
  "          having (select sum(quantity) from public.stock_movements\n"
  "                   where item_id = old.id) <> 0) s  -- every warehouse\n",
  '-- every warehouse')

# --- stock moving into a hidden item ---------------------------------
m('movement: only the app is asked',
  T,
  "  select * into v_item from public.items i where i.id = new.item_id;\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  select * into v_item from public.items i where i.id = new.item_id;\n",
  '-- app only')

m('movement: an item switched off is not asked',
  T,
  "     or (v_item.is_active and v_item.deleted_at is null) then\n",
  "     or (v_item.deleted_at is null) then  -- off is free\n",
  '-- off is free')

m('movement: an item removed is not asked',
  T,
  "     or (v_item.is_active and v_item.deleted_at is null) then\n",
  "     or (v_item.is_active) then  -- removed is free\n",
  '-- removed is free')

m('movement: a top-up is let through',
  T,
  "  if not (v_after * v_before >= 0 and abs(v_after) <= abs(v_before)) then\n",
  "  if not (v_after * v_before >= 0) then  -- top-ups free\n",
  '-- top-ups free')

m('movement: selling past nothing is let through',
  T,
  "  if not (v_after * v_before >= 0 and abs(v_after) <= abs(v_before)) then\n",
  "  if not (abs(v_after) <= abs(v_before)) then  -- past nothing\n",
  '-- past nothing')

m('movement: nothing leaves a hidden item',
  T,
  "  if not (v_after * v_before >= 0 and abs(v_after) <= abs(v_before)) then\n",
  "  if true then  -- nothing leaves\n",
  '-- nothing leaves')

m('movement: a movement of no units is refused',
  T,
  "  if not (v_after * v_before >= 0 and abs(v_after) <= abs(v_before)) then\n",
  "  if not (v_after * v_before >= 0 and abs(v_after) < abs(v_before)) then  -- no-unit refused\n",
  '-- no-unit refused')

m('movement: the item''s stock is counted across warehouses',
  T,
  "   where m.item_id = new.item_id\n"
  "     and m.warehouse_id = new.warehouse_id;\n",
  "   where m.item_id = new.item_id;  -- every warehouse\n",
  '-- every warehouse')

m('CONTROL: a comment inside the hiding function',
  H,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')

m('CONTROL: a comment inside the movement function',
  T,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')

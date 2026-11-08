# Mutants for 0914 -- an item holding stock keeps tracking it, and
# stays a stock item, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0914_an_item_with_stock_keeps_tracking_it.sql \
#       supabase/tests/an_item_with_stock_keeps_tracking_it.sql \
#       supabase/tests/mutants/an_item_with_stock_keeps_tracking_it.py

F = 'an_item_with_stock_keeps_tracking_it'

m('only the app is asked',
  F,
  "  if not ((old.track_inventory and not new.track_inventory)\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if not ((old.track_inventory and not new.track_inventory)\n",
  '-- app only')

m('switching tracking off is not asked',
  F,
  "  if not ((old.track_inventory and not new.track_inventory)\n",
  "  if not ((false)  -- tracking free\n",
  '-- tracking free')

m('changing the type is not asked',
  F,
  "          or (old.item_type = 'stock' and new.item_type is distinct from 'stock')) then\n",
  "          or (false)) then  -- type free\n",
  '-- type free')

m('every change to the flags is asked, turning tracking on too',
  F,
  "  if not ((old.track_inventory and not new.track_inventory)\n",
  "  if not ((old.track_inventory is distinct from new.track_inventory)  -- both ways\n",
  '-- both ways')

m('stock is counted across warehouses, not in each',
  F,
  "          having sum(m.quantity) <> 0) s\n",
  "          having (select sum(quantity) from public.stock_movements\n"
  "                   where item_id = old.id) <> 0) s  -- every warehouse\n",
  '-- every warehouse')

m('CONTROL: a comment inside the function',
  F,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')

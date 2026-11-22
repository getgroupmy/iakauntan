# Mutants for 0917 -- an item's stock unit changes only with no stock
# on hand and no pack size set.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0917_an_items_unit_changes_with_nothing_counted_in_it.sql \
#       supabase/tests/an_items_unit_changes_with_nothing_counted.sql \
#       supabase/tests/mutants/an_items_unit_changes_with_nothing_counted.py

F = 'an_items_unit_changes_with_nothing_counted'

m('only the app is asked',
  F,
  "  if new.uom_code is not distinct from old.uom_code then\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if new.uom_code is not distinct from old.uom_code then\n",
  '-- app only')

m('every write is asked, not only a change',
  F,
  "  if new.uom_code is not distinct from old.uom_code then\n",
  "  if false then  -- every write\n",
  '-- every write')

m('stock on hand does not matter',
  F,
  "  if v_held is not null then\n",
  "  if false then  -- stock free\n",
  '-- stock free')

m('a pack size does not matter',
  F,
  "  if v_packs is not null then\n",
  "  if false then  -- packs free\n",
  '-- packs free')

m('stock is counted across warehouses, not in each',
  F,
  "          having sum(m.quantity) <> 0) s\n",
  "          having (select sum(quantity) from public.stock_movements\n"
  "                   where item_id = old.id) <> 0) s  -- every warehouse\n",
  '-- every warehouse')

m('any item''s pack sizes are counted',
  F,
  "   where k.item_id = old.id;\n",
  "   where k.org_id = old.org_id;  -- any item\n",
  '-- any item')

m('CONTROL: a comment inside the function',
  F,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')
